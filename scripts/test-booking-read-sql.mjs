import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const sql = name => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
let checks = 0;
function check(label, value) { assert.ok(value, label); checks++; console.log(`✅ ${label}`); }
for (const layout of ["repository", "bank_accounts_split"]) {
  const db = new PGlite();
  try {
    await db.exec(`create schema auth; create role anon nologin; create role authenticated nologin;
      create table auth.users(id uuid primary key default gen_random_uuid(),email text,raw_user_meta_data jsonb default '{}'::jsonb,created_at timestamptz default now());
      create table auth.current_user(id uuid);
      create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
      grant usage on schema auth to anon,authenticated; grant select on auth.current_user to anon,authenticated;`);
    for (const file of ["supabase/migrations/00001_schema.sql", "tests/fixtures/base-catalog.sql",
      layout === "repository" ? "supabase/migrations/00010_finance.sql" : "tests/fixtures/finance-bank-accounts.sql",
      "supabase/migrations/00012_profiles_self_read.sql", "supabase/migrations/00020_clients_crm.sql"])
      await db.exec(sql(file));
    const row = async (q, args = []) => (await db.query(q, args)).rows[0];
    const user = async name => (await row("insert into auth.users(email) values($1) returning id", [`${name}@test.invalid`])).id;
    const member = await user("member"), other = await user("other"), staff = await user("staff"), admin = await user("admin");
    await db.query("update profiles set role='staff' where id=$1", [staff]);
    await db.query("update profiles set role='admin' where id=$1", [admin]);
    // Reproducir el diagnóstico remoto: RLS habilitado, SELECT concedido, cero políticas.
    for (const { policyname } of (await db.query("select policyname from pg_policies where schemaname='public' and tablename='bookings'")).rows)
      await db.exec(`drop policy "${policyname.replaceAll('"','""')}" on public.bookings`);
    const classId = (await row("select id from classes limit 1")).id;
    await db.query(`insert into sessions(id,class_id,starts_at,ends_at,capacity) values('read-test',$1,now()+interval '2 days',now()+interval '2 days 1 hour',20)`, [classId]);
    async function as(id, q, args = []) {
      await db.exec("reset role; delete from auth.current_user");
      if (id) await db.query("insert into auth.current_user values($1)", [id]);
      await db.exec(`set role ${id ? "authenticated" : "anon"}`);
      try { return await db.query(q, args); }
      finally { await db.exec("reset role; delete from auth.current_user"); }
    }
    const saved = (await as(member, "select book_session('read-test') as value")).rows[0].value;
    check(`${layout}: reproduce RPC guardado aunque SELECT propio devuelva vacío sin políticas`, saved.status === 'confirmed' && (await as(member,"select * from bookings")).rows.length === 0);
    check(`${layout}: ocupación real ya cuenta la reserva oculta`, Number((await row("select booked_count from session_occupancy where session_id='read-test'")).booked_count) === 1);
    const second = (await as(other, "select book_session('read-test') as value")).rows[0].value;
    const snapshot = async () => JSON.stringify((await db.query(`select 'booking' as kind,to_jsonb(b) as value from bookings b union all select 'profile',to_jsonb(p) from profiles p union all select 'tx',to_jsonb(t) from transactions t order by kind,value`)).rows);
    const before = await snapshot();
    const definitions = async () => JSON.stringify((await db.query("select pg_get_functiondef(oid) from pg_proc where pronamespace='public'::regnamespace and proname in ('book_session','cancel_booking') order by oid")).rows);
    const functionsBefore = await definitions();
    const migration = sql("supabase/migrations/00026_booking_read_policy.sql");
    await db.exec(migration); await db.exec(migration);
    check(`${layout}: reparación idempotente conserva reservas, perfiles y movimientos`, await snapshot() === before);
    check(`${layout}: no reemplaza book_session ni cancel_booking`, await definitions() === functionsBefore);
    const mine = (await as(member, "select id,session_id,status,user_id from bookings")).rows;
    check(`${layout}: cliente recupera exactamente su reserva original y no la ajena`, mine.length === 1 && mine[0].id === saved.id && mine[0].user_id === member);
    const ids = (await as(member, "select session_id from bookings where user_id=$1 and status in ('confirmed','attended')", [member])).rows;
    check(`${layout}: consulta de IDs detecta la clase como reservada`, ids.length === 1 && ids[0].session_id === 'read-test');
    check(`${layout}: otra identidad sólo lee su propia reserva`, (await as(other,"select id from bookings")).rows[0].id === second.id && (await as(other,"select id from bookings where id=$1", [saved.id])).rows.length === 0);
    for (const actor of [staff,admin]) {
      check(`${layout}: ${actor === staff ? 'staff' : 'admin'} puede leer las dos reservas`, (await as(actor,"select id from bookings")).rows.length === 2);
      check(`${layout}: SELECT no habilita UPDATE directo ni siquiera al personal`, (await as(actor,"update bookings set status='cancelled' where id=$1 returning id", [saved.id])).rows.length === 0);
    }
    check(`${layout}: cliente no puede cambiar estado por UPDATE directo`, (await as(member,"update bookings set status='cancelled' where id=$1 returning id", [saved.id])).rows.length === 0);
    await assert.rejects(as(member,"insert into bookings(session_id,user_id) values('read-test',$1)",[staff]), /row-level security/);
    check(`${layout}: SELECT no habilita altas directas manipuladas`, true);
    await assert.rejects(as(member,"delete from bookings where id=$1",[saved.id]),/permission denied/);
    check(`${layout}: no se concede DELETE`, true);
    await assert.rejects(as(null,"select * from bookings"),/permission denied/);
    check(`${layout}: anónimo sin acceso`, true);
    await db.exec("set role authenticated");
    check(`${layout}: authenticated sin identidad no ve filas`, (await db.query("select id from bookings")).rows.length === 0);
    await db.exec("reset role");
    await db.query("update profiles set role='member' where id=$1",[staff]);
    check(`${layout}: rol retirado pierde acceso a reservas ajenas`, (await as(staff,"select id from bookings")).rows.length === 0);
    const cancelled = (await as(member,"select cancel_booking($1) as value",[saved.id])).rows[0].value;
    check(`${layout}: cancelación vía RPC sigue funcionando y es visible al propietario`, cancelled.status === 'cancelled' && (await as(member,"select status from bookings where id=$1",[saved.id])).rows[0].status === 'cancelled');
    check(`${layout}: cancelar libera exactamente un cupo`, Number((await row("select booked_count from session_occupancy where session_id='read-test'")).booked_count) === 1);
    await assert.rejects(as(other,"select cancel_booking($1)",[saved.id]), /NOT_FOUND/);
    check(`${layout}: otra identidad no puede cancelar la reserva`, true);
    await db.exec("create policy test_existing_read on bookings for select to authenticated using(false)");
    await db.exec(migration);
    check(`${layout}: no elimina políticas ajenas existentes`, !!await row("select policyname from pg_policies where tablename='bookings' and policyname='test_existing_read'"));
  } finally { await db.close(); }
}
console.log(`\n🎉 Lectura de reservas: ${checks} comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).`);
