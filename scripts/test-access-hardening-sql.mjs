import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
const sql=p=>readFileSync(new URL(`../${p}`,import.meta.url),'utf8');
const migration=sql('supabase/migrations/00030_access_hardening.sql');
let checks=0;
for(const layout of ['repository','bank_accounts_split']) {
  const db=new PGlite();
  const check=(name,ok)=>{assert.ok(ok,`${layout}: ${name}`);checks++;console.log(`✅ ${layout}: ${name}`);};
  const row=async(q,args=[]) => (await db.query(q,args)).rows[0];
  try {
    await db.exec(`create schema auth;create role anon nologin;create role authenticated nologin;
      create table auth.users(id uuid primary key default gen_random_uuid(),email text,raw_user_meta_data jsonb default '{}'::jsonb,created_at timestamptz default now());
      create table auth.current_user(id uuid);create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
      grant usage on schema auth to anon,authenticated;grant select on auth.current_user to anon,authenticated;`);
    for(const f of ['supabase/migrations/00001_schema.sql','tests/fixtures/base-catalog.sql',
      layout==='repository'?'supabase/migrations/00010_finance.sql':'tests/fixtures/finance-bank-accounts.sql',
      'supabase/migrations/00012_profiles_self_read.sql','supabase/migrations/00020_clients_crm.sql',
      'supabase/migrations/00022_crm_finance_compat.sql','supabase/migrations/00023_finance_read_bank_accounts.sql',
      'supabase/migrations/00025_account_assigned_plan.sql','supabase/migrations/00026_booking_read_policy.sql',
      'supabase/migrations/00027_client_finance_read.sql']) await db.exec(sql(f));
    if(layout==='bank_accounts_split') {
      for(const f of ['00024_finance_movements.sql','00028_debts_payments.sql','00029_cash_change.sql'])
        await db.exec(sql(`supabase/migrations/${f}`));
      await db.exec(sql('tests/fixtures/security-bank-views.sql'));
      await db.exec("insert into bank_accounts(id,name,account_type,currency,balance) values('test','EJEMPLO','caja_fuerte','NIO',0);insert into payment_methods(id,name,currency) values('test','EJEMPLO','BOTH')");
    } else {
      await db.exec("insert into accounts(id,slug,name,kind,currency) values('test','test','EJEMPLO','cash','NIO');insert into payment_methods(id,slug,kind,name_es,name_en) values('test','test','cash','EJEMPLO','EXAMPLE')");
    }
    const user=async name=>(await row('insert into auth.users(email,raw_user_meta_data) values($1,$2) returning id',[
      `${name}@test.invalid`,JSON.stringify({full_name:`EJEMPLO ${name}`})])).id;
    const admin=await user('admin'),staff=await user('staff'),member=await user('cliente-a'),other=await user('cliente-b');
    await db.query("update profiles set role='admin' where id=$1",[admin]);
    await db.query("update profiles set role='staff' where id=$1",[staff]);
    const client=(await row('select id from gym_clients where profile_id=$1',[member])).id;
    async function as(actor,q,args=[],role=actor?'authenticated':'anon') {
      await db.exec('reset role;delete from auth.current_user');
      if(actor) await db.query('insert into auth.current_user values($1)',[actor]);
      await db.exec(`set role ${role}`);
      try{return await db.query(q,args);}finally{await db.exec('reset role;delete from auth.current_user');}
    }
    const rejected=async(name,actor,q,args=[],role)=>{
      await assert.rejects(as(actor,q,args,role),/permission denied|row-level security|AUTH/);check(name,true);
    };
    for(const [id,amount] of [[member,10],[other,777]]) {
      if(layout==='repository') {
        await db.query("insert into transactions(direction,status,amount,currency,base_amount,payment_method_id,account_id,member_id,concept) values('income','completed',$1,'NIO',$1,'test','test',$2,'EJEMPLO')",[amount,id]);
        await db.query('insert into member_balances(member_id,balance_nio) values($1,$2) on conflict(member_id) do update set balance_nio=excluded.balance_nio',[id,amount]);
        await db.query('insert into invoices(number,member_id,total,due_at) values(gen_random_uuid()::text,$1,$2,current_date+1)',[id,amount]);
      }else {
        await db.query("insert into transactions(type,amount,currency,amount_nio,amount_usd,fx_used,account_id,member_id,concept) values('income',$1,'NIO',$1,0,40,'test',$2,'EJEMPLO')",[amount,id]);
        await db.query('insert into member_balances(member_id,debt_nio) values($1,$2)',[id,amount]);
      }
    }
    if(layout==='bank_accounts_split')await db.query("insert into transactions(type,amount,currency,amount_nio,amount_usd,fx_used,account_id,member_id,concept) values('expense',55,'NIO',55,0,40,'test',$1,'EJEMPLO gasto')",[other]);
    // El fixture base no programa nada (datos del gimnasio anterior desarmados):
    // la suite crea su propia sesión neutra para probar reservas.
    await db.exec("insert into public.sessions(id,class_id,starts_at,ends_at,capacity) values('ses_hardening','cls_zumba',now()+interval '2 days',now()+interval '2 days'+interval '1 hour',30) on conflict (id) do nothing");
    const session=(await row('select id from sessions order by starts_at desc limit 1')).id;
    await db.query("insert into bookings(session_id,user_id,status) values($1,$2,'confirmed'),($1,$3,'confirmed')",[session,member,other]);
    await db.exec('revoke all on function crm_directory(text,text,integer) from authenticated;grant execute on function crm_directory(text,text,integer) to public');
    const views=(await db.query("select relname from pg_class where relnamespace='public'::regnamespace and relkind='v' and relname like 'v_%' order by relname")).rows.map(r=>r.relname);
    // Imitar grants automáticos de Supabase y un grant por columna antiguo.
    await db.exec('grant all on profiles to anon,authenticated;grant update(plan_id,role) on profiles to authenticated;');
    for(const v of views)await db.exec(`grant all on ${v} to anon,authenticated;grant update(${layout==='repository'&&v==='v_member_account'?'full_name':v==='v_account_balances'?'name':(await row("select attname from pg_attribute where attrelid=$1::regclass and attnum>0 order by attnum limit 1",[v])).attname}) on ${v} to authenticated;`);
    check('reproduce autoedición comercial antes de corregir',
      (await as(member,"update profiles set plan_id='pln_boxeo' where id=$1 returning id",[member])).rows.length===1);
    const daily=layout==='repository'?'v_daily_cash':'v_monthly_summary';
    check('reproduce vista financiera anónima antes de corregir',(await as(null,`select * from ${daily}`)).rows.length>0);
    const tables=(await db.query("select relname from pg_class where relnamespace='public'::regnamespace and relkind='r' order by relname")).rows.map(r=>r.relname);
    const snapshot=async()=>JSON.stringify(await Promise.all(tables.map(async t=>[t,(await db.query(`select to_jsonb(t) value from ${t} t order by to_jsonb(t)::text`)).rows])));
    const writers=async()=>JSON.stringify((await db.query("select proname,prosrc,proconfig from pg_proc where pronamespace='public'::regnamespace order by oid")).rows);
    const before=await snapshot(),bodies=await writers();
    await db.exec(migration);await db.exec(migration);
    check('instalar dos veces no modifica ningún registro',await snapshot()===before);
    check('cuerpos de funciones/escritores intactos',await writers()===bodies);
    for(const v of views) {
      await rejected(`${v}: sin lectura anónima`,null,`select * from ${v}`);
      const options=(await row('select reloptions from pg_class where oid=$1::regclass',[v])).reloptions;
      check(`${v}: invoker y barrier`,options.includes('security_invoker=true')&&options.includes('security_barrier=true'));
      for(const actor of [admin,staff]) {
        const all=(await as(actor,`select * from ${v}`)).rows;
        check(`${v}: ${actor===admin?'admin':'staff'} conserva datos reales ficticios`,all.length>0);
        if(['v_members_with_debt','v_top_members','v_member_account','v_accounts_receivable'].includes(v))
          check(`${v}: personal autorizado ve al cliente B`,JSON.stringify(all).includes(other));
        if(['v_daily_cash','v_monthly_pnl','v_monthly_summary'].includes(v))
          check(`${v}: ingreso total no queda limitado al propio perfil`,all.reduce((n,r)=>n+Number(r.income_nio),0)===787);
      }
      const rows=(await as(member,`select * from ${v}`)).rows;
      // Importes por valor exacto, no por texto: un UUID aleatorio puede
      // contener «777» (pasó con el del propio cliente A) y eso no es fuga.
      const importes=rows.flatMap(r=>Object.values(r)).map(Number);
      check(`${v}: cliente A no recibe identidad/importe de B`,!JSON.stringify(rows).includes(other)&&!importes.includes(777)&&!importes.includes(55));
      check(`${v}: autenticado sin identidad no ve datos`,(await as(null,`select * from ${v}`,[],'authenticated')).rows.length===0);
    }
    for(const [field,value] of [['plan_id',"'pln_musculacion'"],['role',"'admin'"],['email',"'otro@test.invalid'"],['id',"gen_random_uuid()"],['created_at','now()'],['updated_at','now()']])
      await rejected(`cliente no modifica ${field}`,member,`update profiles set ${field}=${value} where id=$1`,[member]);
    await rejected('cliente no crea objetos del esquema',member,'create table public.security_intruder(id int)');
    await rejected('cliente no inserta perfil/rol',member,"insert into profiles(id,full_name,role) values(gen_random_uuid(),'intruso','admin')");
    await rejected('cliente no borra perfil',member,'delete from profiles where id=$1',[member]);
    await rejected('anónimo no lee perfiles',null,'select * from profiles');
    check('cliente A sólo lee perfil A',(await as(member,'select id from profiles')).rows.every(r=>r.id===member));
    check('cliente no edita datos personales ajenos',(await as(member,"update profiles set full_name='INTRUSO' where id=$1 returning id",[other])).rows.length===0);
    check('autoedición de nombre/teléfono sigue funcionando',(await as(member,"update profiles set full_name='EJEMPLO editado',phone='55500000' where id=$1 returning id",[member])).rows.length===1);
    for(const actor of [admin,staff]) {
      check('personal autorizado conserva perfiles de clientes',(await as(actor,'select id from profiles where id=$1',[other])).rows.length===1);
      const next=await user(`nuevo-${actor===admin?'admin':'staff'}`);
      check('registro Auth/trigger sigue creando perfil',(await row('select id from profiles where id=$1',[next])).id===next);
      await as(actor,"select crm_update_client($1,'EJEMPLO cliente',null,null,'client','active','pln_boxeo','')",[client]);
      check('plan comercial se edita por RPC autorizada',(await row('select plan_id from gym_clients where id=$1',[client])).plan_id==='pln_boxeo');
    }
    check('ocupación pública sigue contando a ambos clientes',(await as(null,'select booked_count from session_occupancy where session_id=$1',[session])).rows[0].booked_count===2);
    await as(member,'select cancel_booking((select id from bookings where user_id=$1 limit 1))',[member]);
    check('cancelación propia sigue liberando cupo',(await as(null,'select booked_count from session_occupancy where session_id=$1',[session])).rows[0].booked_count===1);
    for(const f of ['generate_week_sessions(current_date)','close_past_sessions()']) {
      await rejected('mantenimiento no invocable anónimamente',null,`select ${f}`);
      await rejected('mantenimiento no invocable por cliente',member,`select ${f}`);
    }
    await as(staff,"select crm_directory('', '', 0)");
    check('conserva EXECUTE authenticated antes heredado de PUBLIC',true);
    check('no abre helpers privados',(await row("select has_function_privilege('authenticated','crm_finance_layout()','EXECUTE') allowed")).allowed===false);
    await rejected('CRM no ejecutable por anónimo',null,"select crm_directory('', '', 0)");
    await rejected('CRM sigue rechazando cliente con sesión',member,"select crm_directory('', '', 0)");
    if(layout==='bank_accounts_split') {
      check('cliente no ve saldos/cuentas globales',(await as(member,'select * from bank_accounts')).rows.length===0);
      const request=randomUUID();
      const payment=(await as(staff,"select finance_record_movement($1,'service_income',$2,2,'NIO','test','test','EJEMPLO seguridad',40,null) id",[request,client])).rows[0].id;
      await as(staff,"select finance_record_movement($1,'service_income',$2,2,'NIO','test','test','EJEMPLO seguridad',40,null)",[request,client]);
      check('cobro conserva idempotencia y suma sólo una vez',Number((await row("select balance from bank_accounts where id='test'")).balance)===2);
      check('comprobante financiero sigue disponible',!!(await as(staff,'select finance_receipt($1) value',[payment])).rows[0].value);
      check('reporte sigue disponible',(await as(staff,"select finance_read('summary',30) value")).rows[0].value.finance_layout==='bank_accounts_split');
      const debtClient=(await as(staff,"select crm_create_client('EJEMPLO deuda sin login') id")).rows[0].id;
      const call=async(actor,kind,amount=null,open=null,received=null)=>(await as(actor,
        kind==='opening'?'select finance_debt_record($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) value':'select finance_debt_record_with_cash($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) value',
        [randomUUID(),kind,debtClient,amount,kind==='opening'?null:'NIO','EJEMPLO seguridad',kind==='payment'?'test':null,kind==='payment'?'test':null,kind==='payment'?40:null,open,...(kind==='opening'?[]:[received])])).rows[0].value;
      await call(admin,'opening',null,{credit_nio:0,credit_usd:0,debt_nio:60,debt_usd:0});
      const cash=await call(staff,'payment',20,null,100);
      check('abono/vuelto conserva deuda y caja',cash.after.debt_nio===40&&Number((await row("select balance from bank_accounts where id='test'")).balance)===22);
      await db.query("update profiles set role='member' where id=$1",[staff]);
      check('rol retirado pierde acceso a cuentas',(await as(staff,'select * from v_account_balances')).rows.length===0);
      await rejected('rol retirado pierde RPC de finanzas',staff,"select finance_read('summary',30)");
    }
  }finally{await db.close();}
}
console.log(`\n🎉 Seguridad de acceso: ${checks} comprobaciones pasaron (PGlite, dos esquemas; no Supabase remoto).`);
