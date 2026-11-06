import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
const db=new PGlite();let count=0;
const sql=p=>readFileSync(new URL(`../${p}`,import.meta.url),'utf8');
const row=async(q,args=[]) => (await db.query(q,args)).rows[0];
const check=(name,ok)=>{assert.ok(ok,name);count++;console.log(`✅ ${name}`);};
try {
  await db.exec(`create schema auth;create role anon nologin;create role authenticated nologin;
    create table auth.users(id uuid primary key default gen_random_uuid(),email text,raw_user_meta_data jsonb default '{}'::jsonb,created_at timestamptz default now());
    create table auth.current_user(id uuid);create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
    grant usage on schema auth to anon,authenticated;grant select on auth.current_user to anon,authenticated;`);
  for(const f of ['00001_schema.sql','catalog-fixture','fixture','00012_profiles_self_read.sql','00020_clients_crm.sql','00022_crm_finance_compat.sql','00023_finance_read_bank_accounts.sql','00024_finance_movements.sql','00027_client_finance_read.sql'])
    await db.exec(sql(f==='fixture'?'tests/fixtures/finance-bank-accounts.sql':f==='catalog-fixture'?'tests/fixtures/base-catalog.sql':`supabase/migrations/${f}`));
  const user=async name=>(await row('insert into auth.users(email) values($1) returning id',[`${name}@test.invalid`])).id;
  const admin=await user('admin'),staff=await user('staff'),member=await user('member'),other=await user('other');
  await db.query("update profiles set role='admin' where id=$1",[admin]);await db.query("update profiles set role='staff' where id=$1",[staff]);
  const client=(await row('select id from gym_clients where profile_id=$1',[member])).id;
  async function as(actor,q,args=[]) {
    await db.exec('reset role;delete from auth.current_user');if(actor)await db.query('insert into auth.current_user values($1)',[actor]);
    await db.exec(`set role ${actor?'authenticated':'anon'}`);
    try{return await db.query(q,args);}finally{await db.exec('reset role;delete from auth.current_user');}
  }
  const manual=(await as(staff,"select crm_create_client('EJEMPLO sin cuenta') as id")).rows[0].id;
  await db.exec("insert into bank_accounts(id,name,account_type,currency,balance) values('nio','EJEMPLO NIO','caja_fuerte','NIO',0),('usd','EJEMPLO USD','caja_fuerte','USD',0);insert into payment_methods(id,name,currency) values('both','EJEMPLO ambas','BOTH')");
  const snapshot=async()=>JSON.stringify((await db.query(`select 'profile' as kind,to_jsonb(p) as value from profiles p
    union all select 'balance',to_jsonb(b) from member_balances b union all select 'bank',to_jsonb(b) from bank_accounts b
    union all select 'tx',to_jsonb(t) from transactions t union all select 'receipt',to_jsonb(e) from finance_entries e
    union all select 'event',to_jsonb(e) from client_events e union all select 'client',to_jsonb(c) from gym_clients c order by kind,value`)).rows);
  const before=await snapshot();const migration=sql('supabase/migrations/00028_debts_payments.sql');
  await db.exec(migration);await db.exec(migration);
  check('instalación repetida no crea saldos ni cambia datos existentes',before===await snapshot());
  check('lectores y writers quedan listos',(await row('select finance_debt_ready() as ok')).ok===true);
  const initial={credit_nio:10,credit_usd:3,debt_nio:100,debt_usd:20};
  const zero={credit_nio:0,credit_usd:0,debt_nio:0,debt_usd:0};
  const call=async(d={},actor=staff)=>(await as(actor,'select finance_debt_record($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) as value',[
    d.request??randomUUID(),d.kind??'charge',d.client??client,d.amount===undefined?25:d.amount,d.currency===undefined?'NIO':d.currency,d.concept??'EJEMPLO deuda',d.method??null,d.account??null,d.fx??null,d.open??null,
  ])).rows[0].value;
  const opening=(client,values,request=randomUUID())=>({client,kind:'opening',amount:null,currency:null,open:values,request});
  const get=async(cid=client)=>(await as(staff,'select finance_debt_detail($1) as value',[cid])).rows[0].value;
  const fail=async(d,pattern,actor=staff)=>{const before=await snapshot();await assert.rejects(call(d,actor),pattern);check(`rechazo sin escrituras ${pattern}`,before===await snapshot());};
  check('leer saldo ausente no inventa cero',(await get()).balances===null);
  await fail({},/BALANCE_NOT_INITIALIZED/);
  await fail(opening(client,initial),/ADMIN_REQUIRED/);
  for(const values of [{},{...initial,credit_nio:'10'},{...initial,debt_usd:-1},{...initial,debt_usd:0.001},{...initial,extra:1},{...initial,credit_nio:1e12}])
    await fail(opening(client,values),/INVALID_DEBT/,admin);
  const openRequest=randomUUID();const open=await call(opening(client,initial,openRequest),admin);
  assert.deepEqual(open.after,initial);check('saldo inicial explícito conserva cuatro valores sin mover Caja',open.before===null&&(await row("select balance from bank_accounts where id='nio'")).balance==='0.00');
  check('apertura idempotente recupera mismo asiento',(await call(opening(client,initial,openRequest),admin)).id===open.id);
  await fail(opening(client,zero),/BALANCE_ALREADY_EXISTS/,admin);
  await fail({...opening(client,zero,openRequest)},/REQUEST_CONFLICT/,admin);
  const profilesBefore=(await row('select count(*)::int as n from profiles')).n;
  await call(opening(manual,zero),admin);
  check('ficha sin login opera con cuenta propia sin crear perfil',(await get(manual)).source==='client'&&(await row('select count(*)::int as n from profiles')).n===profilesBefore);
  const charge=await call({});await call({currency:'USD',amount:5});
  check('cargos aumentan sólo deuda elegida',(await get()).balances.debt_nio===125&&(await get()).balances.debt_usd===25);
  check('cargos no mueven Caja ni crean transacciones',(await row('select count(*)::int as n from transactions')).n===0);
  const chargeRetry=await call({request:charge.requestId});check('cargo idempotente no se duplica',chargeRetry.id===charge.id&&(await get()).balances.debt_nio===125);
  const pay={kind:'payment',amount:40,method:'both',account:'nio',fx:40};
  const request=randomUUID();const receipt=await call({...pay,request});
  check('abono parcial baja deuda NIO y sube sólo Caja NIO',receipt.before.debt_nio===125&&receipt.after.debt_nio===85&&Number((await row("select balance from bank_accounts where id='nio'")).balance)===40);
  check('abono deja intactos crédito y deuda USD',receipt.after.credit_nio===10&&receipt.after.credit_usd===3&&receipt.after.debt_usd===25);
  const cash=(await as(staff,'select finance_receipt($1) as value',[receipt.transactionId])).rows[0].value;
  check('comprobante distingue abono de servicio con deuda antes/después',cash.kind==='debt_payment'&&cash.debtBefore===125&&cash.debtAfter===85);
  const serviceHistory=(await as(staff,"select finance_recent_receipts('service_income',$1) as value",[client])).rows[0].value;
  check('abono no se lista como cobro por servicio',serviceHistory.length===0);
  const snap=await snapshot();check('reintento de abono devuelve el mismo registro',(await call({...pay,request})).id===receipt.id&&snap===await snapshot());
  await fail({...pay,amount:86},/PAYMENT_EXCEEDS_DEBT/);
  await fail({...pay,amount:40,account:'usd'},/INVALID_ACCOUNT/);
  await fail({...pay,amount:0},/INVALID_DEBT/);
  await fail({kind:'charge',fx:40},/INVALID_DEBT/);
  await fail({kind:'other'},/INVALID_DEBT/);
  const usdReceipt=await call({...pay,amount:5,currency:'USD',account:'usd'});
  check('abono USD no convierte la deuda NIO',usdReceipt.after.debt_nio===85&&usdReceipt.after.debt_usd===20&&Number((await row("select balance from bank_accounts where id='usd'")).balance)===5);
  await fail({...pay,currency:'USD',account:'usd',amount:20.01},/PAYMENT_EXCEEDS_DEBT/);
  await call({...pay,amount:85});await fail({...pay,amount:0.01},/PAYMENT_EXCEEDS_DEBT/);
  check('liquidar deuda no genera crédito',(await get()).balances.debt_nio===0&&(await get()).balances.credit_nio===10);
  const manualCharge=await call({client:manual,amount:12});await call({...pay,client:manual,amount:2});
  const detail=(await as(staff,'select crm_detail($1) as value',[manual])).rows[0].value;
  check('saldo CRM para ficha sin login coincide con ledger',detail.finance.balance_status==='ready'&&detail.finance.source==='client'&&detail.finance.balances.debt_nio===10);
  check('totales de cobros incluyen sólo dinero recibido, no cargos',detail.finance.collections.amount_nio===2);
  const receivables=(await as(staff,"select finance_debt_report('receivables') as value")).rows[0].value.data;
  check('cuentas por cobrar incluyen ficha sin cuenta web',receivables.some(r=>r.client_id===manual&&r.member_id===null&&r.total_owed_nio===10));
  const summary=(await as(staff,"select finance_debt_report('summary') as value")).rows[0].value.data;
  check('resumen suma deudas NIO/USD sin compensar créditos',summary.totalOwed===10&&summary.totalOwedUsd===20);
  const normal=async(req)=>as(staff,"select finance_record_movement($1,'service_income',$2,1,'NIO','both','nio','EJEMPLO servicio',40,null)",[req,client]);
  await assert.rejects(normal(manualCharge.requestId),/REQUEST_CONFLICT/);check('referencia de deuda no puede reutilizarse en Caja',true);
  const serviceRequest=randomUUID();await normal(serviceRequest);
  await fail({request:serviceRequest},/REQUEST_CONFLICT/);
  await assert.rejects(as(staff,'select finance_record_movement_before_debts($1,\'service_income\',$2,1,\'NIO\',\'both\',\'nio\',\'EJEMPLO\',40,null)',[randomUUID(),client]),/permission denied/);
  check('writer delegado queda privado',true);
  await db.exec(`create function test_event_failure() returns trigger language plpgsql as $$begin raise exception 'TEST_EVENT_FAIL';end$$;
    create trigger test_event_failure before insert on client_events for each row execute function test_event_failure();`);
  const failedRequest=randomUUID();await fail({...pay,client:manual,amount:1,request:failedRequest},/TEST_EVENT_FAIL/);
  check('fallo intermedio no deja ledger',(await row('select count(*)::int as n from client_debt_entries where request_id=$1',[failedRequest])).n===0);
  await db.exec('drop trigger test_event_failure on client_events');await call({...pay,client:manual,amount:1,request:failedRequest});
  check('mismo UUID tras rollback permite un solo abono',(await get(manual)).balances.debt_nio===9);
  await db.exec(`create trigger test_balance_trigger before update on member_balances for each row execute function test_event_failure();`);
  check('trigger no revisado bloquea nuevos cargos',(await get()).writesEnabled===false);
  check('recuperación confirmada funciona aunque escritura nueva se bloquee',(await call({...pay,request})).id===receipt.id);
  await fail({amount:1},/FINANCE_REVIEW_REQUIRED/);await db.exec('drop trigger test_balance_trigger on member_balances');
  for(const actor of [member,other,null]) {
    await fail({amount:1},/AUTH|permission denied/,actor);
    await assert.rejects(as(actor,'select finance_debt_detail($1)',[client]),/AUTH|permission denied/);check('lectura privada por servidor/SQL',true);
    await assert.rejects(as(actor,"select finance_debt_report('summary')"),/AUTH|permission denied/);check('reporte consolidado sólo personal',true);
    if(actor)check('RLS oculta ledger a cliente',(await as(actor,'select * from client_debt_entries')).rows.length===0);
  }
  for(const table of ['member_balances','client_debt_balances','client_debt_entries']) {
    await assert.rejects(as(staff,`delete from ${table}`),/permission denied/);check(`DELETE directo denegado ${table}`,true);
  }
  await db.query("update profiles set role='member' where id=$1",[staff]);
  await fail({...pay,request},/AUTH/,staff);await db.query("update profiles set role='staff' where id=$1",[staff]);
  await assert.rejects(db.query('update gym_clients set profile_id=$1 where id=$2',[other,manual]),/BALANCE_LINK_RECONCILIATION_REQUIRED/);check('vínculos no mezclan saldos de fuentes distintas',true);
  await assert.rejects(db.query('delete from profiles where id=$1',[member]),/BALANCE_LINK_RECONCILIATION_REQUIRED/);check('borrar identidad no borra silenciosamente su saldo',true);
  await db.exec('set role authenticated');
  await assert.rejects(db.query('select finance_debt_detail($1)',[client]),/AUTH/);
  await db.exec('reset role');check('authenticated sin identidad no puede leer deudas',true);
  for(const table of ['member_balances','client_debt_balances','client_debt_entries'])
    check(`sin permisos directos INSERT/UPDATE/DELETE ${table}`,(await row("select has_table_privilege('authenticated',$1,'INSERT,UPDATE,DELETE') as allowed",[table])).allowed===false);
  const cashSnapshot=async()=>JSON.stringify([await snapshot(),(await db.query('select * from client_debt_entries order by id')).rows,(await db.query('select * from client_debt_balances order by client_id')).rows]);
  const beforeCashInstall=await cashSnapshot();await db.exec(sql('supabase/migrations/00029_cash_change.sql'));await db.exec(sql('supabase/migrations/00029_cash_change.sql'));
  check('vuelto: instalar dos veces no cambia registros ni saldos',beforeCashInstall===await cashSnapshot());
  check('vuelto: lectura anuncia capacidad y cajas reales',(await get()).cashProtocol==='cash-v1'&&(await get()).cashAccounts.includes('nio'));
  const cashCall=async(d={},actor=staff)=>(await as(actor,'select finance_debt_record_with_cash($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) as value',[
    d.request??randomUUID(),d.kind??'payment',d.client??client,d.amount??20,d.currency??'NIO',d.concept??'EJEMPLO vuelto',d.method??'both',d.account??'nio',d.fx??40,d.open??null,d.received===undefined?100:d.received,
  ])).rows[0].value;
  const cashFail=async(d,pattern,actor=staff)=>{const before=await cashSnapshot();await assert.rejects(cashCall(d,actor),pattern);check(`vuelto: rechazo atómico ${pattern}`,before===await cashSnapshot());};
  await call({amount:60});
  let bankBefore=Number((await row("select balance from bank_accounts where id='nio'")).balance);
  const txBefore=(await row('select count(*)::int n from transactions')).n;
  const cashId=randomUUID();const cashPartial=await cashCall({request:cashId});
  check('debe60/abona20/entrega100: vuelto80 y deuda40',cashPartial.cashReceived===100&&cashPartial.changeGiven===80&&cashPartial.before.debt_nio===60&&cashPartial.after.debt_nio===40);
  check('Caja recibe sólo20, sin gasto por vuelto',Number((await row("select balance from bank_accounts where id='nio'")).balance)===bankBefore+20&&(await row('select count(*)::int n from transactions')).n===txBefore+1&&(await row('select type::text,amount from transactions where id=$1',[cashPartial.transactionId])).type==='income');
  const cashReceipt=(await as(staff,'select finance_receipt($1) as value',[cashPartial.transactionId])).rows[0].value;
  check('comprobante guarda efectivo100/vuelto80/abono20',cashReceipt.cashReceived===100&&cashReceipt.changeGiven===80&&cashReceipt.amount===20&&cashReceipt.debtAfter===40);
  const afterFirstCash=await cashSnapshot();check('retry de efectivo recupera la misma operación',(await cashCall({request:cashId})).id===cashPartial.id&&afterFirstCash===await cashSnapshot());
  await cashFail({request:cashId,received:101},/REQUEST_CONFLICT/);
  await fail({kind:'payment',amount:20,method:'both',account:'nio',fx:40,concept:'EJEMPLO vuelto',request:cashId},/REQUEST_CONFLICT/);
  await cashFail({amount:41,received:100},/PAYMENT_EXCEEDS_DEBT/);
  for(const received of [null,-1,0,19,100.001,100000000])await cashFail({received},/INVALID_CASH_RECEIVED/);
  await cashFail({kind:'charge'},/INVALID_CASH_RECEIVED/);
  await db.exec("insert into bank_accounts(id,name,account_type,currency,balance) values('cash-test-bank','EJEMPLO banco','banco','NIO',0)");
  await cashFail({account:'cash-test-bank'},/CASH_ACCOUNT_REQUIRED/);
  await cashFail({account:'usd'},/INVALID_ACCOUNT/);
  await cashFail({method:'missing'},/INVALID_METHOD/);
  await cashFail({fx:0},/INVALID_PAYMENT/);
  for(const who of [member,null])await cashFail({},/AUTH|permission denied/,who);
  await db.exec(`create trigger cash_event_failure before update on client_events for each row when (new.details ? 'cash_received') execute function test_event_failure()`);
  const rollbackCash=randomUUID();await cashFail({request:rollbackCash},/TEST_EVENT_FAIL/);await db.exec('drop trigger cash_event_failure on client_events');
  check('mismo intento tras rollback guarda una vez',(await cashCall({request:rollbackCash,received:20})).changeGiven===0);
  await cashCall({amount:20,received:20});await call({amount:60});
  const full=await cashCall({amount:60,received:100});
  check('debe60/abona60/entrega100: vuelto40, deuda0 y crédito intacto',full.changeGiven===40&&full.after.debt_nio===0&&full.after.credit_nio===10);
  const dollars=await cashCall({amount:3,received:5,currency:'USD',account:'usd'});
  check('USD: vuelto sólo en USD, sin convertir deuda ni créditos',dollars.changeGiven===2&&dollars.after.debt_usd===17&&dollars.after.debt_nio===0&&dollars.after.credit_usd===3);
  const noLogin=await cashCall({client:manual,amount:2,received:100});
  check('vuelto también funciona en ficha sin login',noLogin.changeGiven===98&&noLogin.after.debt_nio===7);
  await db.query("update profiles set role='member' where id=$1",[staff]);await cashFail({request:cashId},/AUTH/);await db.query("update profiles set role='staff' where id=$1",[staff]);
  console.log(`\n🎉 Deudas y abonos: ${count} comprobaciones pasaron (PGlite, sin concurrencia real ni Supabase remoto).`);
} finally {await db.close();}
