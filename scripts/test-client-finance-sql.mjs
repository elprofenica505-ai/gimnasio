import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const sql = path => readFileSync(new URL(`../${path}`,import.meta.url),"utf8");
let count=0;
const same = (a,b) => { try { assert.deepEqual(a,b); return true; } catch { return false; } };
function check(label,ok) { assert.ok(ok,label); count++; console.log(`✅ ${label}`); }
for (const layout of ["repository","bank_accounts_split"]) {
  const db=new PGlite();
  try {
    await db.exec(`create schema auth; create role anon nologin; create role authenticated nologin;
      create table auth.users(id uuid primary key default gen_random_uuid(),email text,raw_user_meta_data jsonb default '{}'::jsonb,created_at timestamptz default now());
      create table auth.current_user(id uuid);
      create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
      grant usage on schema auth to anon,authenticated; grant select on auth.current_user to anon,authenticated;`);
    for (const name of ["supabase/migrations/00001_schema.sql","tests/fixtures/base-catalog.sql",
      layout === "repository" ? "supabase/migrations/00010_finance.sql" : "tests/fixtures/finance-bank-accounts.sql",
      "supabase/migrations/00012_profiles_self_read.sql","supabase/migrations/00020_clients_crm.sql",
      "supabase/migrations/00022_crm_finance_compat.sql"])
      await db.exec(sql(name));
    if(layout==='bank_accounts_split') {
      await db.exec(sql("supabase/migrations/00023_finance_read_bank_accounts.sql"));
      await db.exec(sql("supabase/migrations/00024_finance_movements.sql"));
    }
    const row=async(q,args=[]) => (await db.query(q,args)).rows[0];
    const user=async name => (await row("insert into auth.users(email) values($1) returning id",[`${name}@test.invalid`])).id;
    const admin=await user("admin"),staff=await user("staff"),member=await user("member"),other=await user("other");
    await db.query("update profiles set role='admin' where id=$1",[admin]);
    await db.query("update profiles set role='staff' where id=$1",[staff]);
    const client=(await row("select id from gym_clients where profile_id=$1",[member])).id;
    const otherClient=(await row("select id from gym_clients where profile_id=$1",[other])).id;
    async function as(id,q,args=[]) {
      await db.exec("reset role;delete from auth.current_user");
      if (id) await db.query("insert into auth.current_user values($1)",[id]);
      await db.exec(`set role ${id ? "authenticated" : "anon"}`);
      try { return await db.query(q,args); }
      finally { await db.exec("reset role;delete from auth.current_user"); }
    }
    const get=async(id=client,actor=staff) => (await as(actor,"select crm_detail($1) as value",[id])).rows[0].value;
    const manual=(await as(staff,"select crm_create_client('Cliente EJEMPLO sin login') as id")).rows[0].id;
    // Preparar carnets antes del snapshot: crm_detail conserva el mecanismo preexistente de carnet.
    for (const id of [client,otherClient,manual]) await as(staff,"select crm_get_card($1)",[id]);
    const snapshot=async()=>JSON.stringify((await db.query(`select 'balances' as kind,to_jsonb(b) as value from member_balances b
      union all select 'tx',to_jsonb(t) from transactions t union all select 'clients',to_jsonb(c) from gym_clients c
      union all select 'profiles',to_jsonb(p) from profiles p union all select 'cards',to_jsonb(c) from client_cards c
      union all select 'events',to_jsonb(e) from client_events e
      union all select 'accounts',to_jsonb(a) from ${layout==='repository'?'accounts':'bank_accounts'} a order by kind,value`)).rows);
    const before=await snapshot();
    const writers=(await db.query("select oid::regprocedure::text as name,prosrc from pg_proc where proname in ('crm_record_payment','crm_record_payment_repository','crm_check_in','finance_record_movement') order by name")).rows;
    const migration=sql("supabase/migrations/00027_client_finance_read.sql");
    await db.exec(migration);await db.exec(migration);
    check(`${layout}: instalar dos veces no modifica registros`,before===await snapshot());
    check(`${layout}: writers intactos`,JSON.stringify(writers)===JSON.stringify((await db.query("select oid::regprocedure::text as name,prosrc from pg_proc where proname in ('crm_record_payment','crm_record_payment_repository','crm_check_in','finance_record_movement') order by name")).rows));
    const missing=(await get()).finance;
    check(`${layout}: cuenta vinculada sin fila no se transforma en cero`,missing.balance_status==='missing' && missing.balances===null && missing.balance_nio===null);
    check(`${layout}: totales vacíos son cero confirmado, no saldo cero`,same(missing.collections,{count_nio:0,amount_nio:0,count_usd:0,amount_usd:0}));
    check(`${layout}: cuenta/ficha enlazadas por IDs explícitos`,missing.client_id===client && missing.profile_id===member);
    check(`${layout}: sin login se distingue de fila de saldo ausente`,(await get(manual)).finance.balance_status==='unlinked');
    const insertBalance=async()=> layout==='repository'
      ? db.query("insert into member_balances(member_id,balance_nio) values($1,0)",[member])
      : db.query("insert into member_balances(member_id,credit_nio,credit_usd,debt_nio,debt_usd) values($1,0,0,0,0)",[member]);
    await insertBalance();
    check(`${layout}: cero explícito se muestra como registro existente`,(await get()).finance.balance_status==='ready');
    if(layout==='repository') await db.query("update member_balances set balance_nio=-23 where member_id=$1",[member]);
    else await db.query("update member_balances set credit_nio=100,credit_usd=7,debt_nio=20,debt_usd=3 where member_id=$1",[member]);
    const known=(await get()).finance;
    check(`${layout}: no compensa ni convierte saldos`,layout==='repository' ? known.balance_nio===-23 && known.balances===null : same(known.balances,{credit_nio:100,credit_usd:7,debt_nio:20,debt_usd:3}) && known.balance_nio===null);
    if(layout==='bank_accounts_split') await db.exec("insert into bank_accounts(id,name,account_type,currency,balance) values('test','Caja EJEMPLO','caja_fuerte','NIO',9876)");
    async function tx({cid=client,mid=member,amount=10,currency='NIO',status='completed',kind='income',concept='EJEMPLO'}={}) {
      const q=layout==='repository'
        ? "insert into transactions(client_id,member_id,amount,currency,status,direction,base_amount,concept) values($1,$2,$3,$4,$5,$6,$3,$7) returning id"
        : "insert into transactions(client_id,member_id,amount,currency,status,type,amount_nio,amount_usd,fx_used,account_id,concept) values($1,$2,$3,$4,$5,$6,$3,1,40,'test',$7) returning id";
      return (await row(q,[cid,mid,amount,currency,status,kind,concept])).id;
    }
    for(let i=0;i<45;i++) await tx();
    await tx({amount:2,currency:'USD'});
    await tx({cid:null,amount:3,concept:'Legado sin ficha explícita'});
    const pending=await tx({amount:100,status:'pending'});
    const reversed=await tx({amount:200,status:layout==='repository'?'reversed':'cancelled'});
    const expense=await tx({amount:300,kind:'expense'});
    const explicitOther=await tx({cid:otherClient,amount:400,concept:'Ficha ajena explícita prevalece'});
    const profileOther=await tx({cid:otherClient,mid:other,amount:500});
    await tx({cid:manual,mid:null,amount:7});
    const beforeRead=await snapshot();
    const result=await get();
    check(`${layout}: resumen completo no se limita a 40 filas`,result.finance.collections.count_nio===46 && result.finance.collections.amount_nio===453);
    check(`${layout}: USD original separado, no se suma equivalente`,result.finance.collections.count_usd===1 && result.finance.collections.amount_usd===2);
    check(`${layout}: lista limitada a 40 con desempate estable`,result.payments.length===40 && JSON.stringify(result.payments)===JSON.stringify((await get()).payments));
    check(`${layout}: egresos nunca aparecen como cobros`,!result.payments.some(p=>p.id===expense));
    check(`${layout}: ficha explícita ajena no contamina historial propio`,!result.payments.some(p=>[explicitOther,profileOther].includes(p.id)));
    check(`${layout}: pendientes y cancelados/revertidos conservan estado sin inflar totales`,result.payments.some(p=>p.id===pending&&p.status==='pending') && result.payments.some(p=>p.id===reversed&&p.status!=='completed'));
    check(`${layout}: ficha sin login conserva cobros propios sin saldo inventado`,(await get(manual)).finance.collections.amount_nio===7 && (await get(manual)).finance.balance_status==='unlinked');
    check(`${layout}: leer no recalcula saldos, caja, perfiles ni historial`,beforeRead===await snapshot());
    check(`${layout}: admin autorizado`,(await get(client,admin)).finance.client_id===client);
    for(const actor of [member,other,null]) {
      await assert.rejects(get(client,actor),actor ? /AUTH/ : /permission denied/);
      check(`${layout}: sin acceso financiero para ${actor===member?'cliente':actor===other?'otro cliente':'anónimo'}`,true);
    }
    await db.exec('set role authenticated');
    await assert.rejects(db.query('select crm_detail($1)',[client]),/AUTH/);
    await db.exec('reset role');
    check(`${layout}: authenticated sin identidad rechazado`,true);
    await db.query("update profiles set role='member' where id=$1",[staff]);
    await assert.rejects(get(client,staff),/AUTH/);
    check(`${layout}: rol retirado pierde acceso inmediatamente`,true);
    await assert.rejects(get('00000000-0000-4000-8000-000000000099',admin),/NOT_FOUND/);
    check(`${layout}: ficha inexistente no devuelve saldos ficticios`,true);
    await db.query('delete from member_balances where member_id=$1',[member]);
    check(`${layout}: borrar fila de saldo no borra cobros ni se oculta como cero`,(await get(client,admin)).finance.balance_status==='missing' && (await get(client,admin)).finance.collections.amount_nio===453);
    if(layout==='bank_accounts_split') {
      await db.exec("insert into payment_methods(id,name,currency) values('test-method','Efectivo EJEMPLO','NIO')");
      const request=(await row('select gen_random_uuid() as id')).id;
      const balanceBefore=(await row("select balance from bank_accounts where id='test'")).balance;
      const balanceRowsBefore=JSON.stringify((await db.query('select * from member_balances order by member_id')).rows);
      const txResult=(await as(admin,"select finance_record_movement($1,'service_income',$2,2,'NIO','test-method','test','Servicio EJEMPLO',40,null) as id",[request,client])).rows[0].id;
      const after=await get(client,admin);
      check(`${layout}: cobro por servicio sigue visible en resumen y lista`,after.finance.collections.amount_nio===455 && after.payments.some(p=>p.id===txResult));
      check(`${layout}: cobro no inventa registro de saldo ni abona deuda`,after.finance.balance_status==='missing' && balanceRowsBefore===JSON.stringify((await db.query('select * from member_balances order by member_id')).rows));
      check(`${layout}: cobro aumenta sólo la cuenta original`,Number((await row("select balance from bank_accounts where id='test'")).balance)===Number(balanceBefore)+2);
      await as(admin,"select finance_record_movement($1,'service_income',$2,2,'NIO','test-method','test','Servicio EJEMPLO',40,null)",[request,client]);
      check(`${layout}: reintento idempotente no duplica total`,(await get(client,admin)).finance.collections.amount_nio===455);
    }
    await db.exec(layout==='repository'?'alter table accounts rename column is_active to unverified':'alter table bank_accounts rename column is_active to unverified');
    const unsupported=await get(client,admin);
    check(`${layout}: esquema no reconocido no anuncia totales cero`,unsupported.finance.balance_status==='unsupported' && unsupported.finance.collections===null);
  } finally { await db.close(); }
}
console.log(`\n🎉 Finanzas de ficha: ${count} comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).`);
