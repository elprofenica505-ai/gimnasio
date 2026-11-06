// Prueba local del interruptor de cierre del día para caja (supabase/migrations/00037).
// Usa la misma cadena de migraciones que test-roles-fase-b-sql.mjs hasta 00033 y luego aplica 00037.
// Casos: caja con interruptor apagado/encendido; admin, entrenador, cliente y visitante siempre false;
// caja sin aal2 false.
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const sql = p => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
const db = new PGlite();
let checks = 0;
const ok = (name, cond) => { assert.ok(cond, name); checks++; console.log(`✅ ${name}`); };

await db.exec(`create schema auth; create role anon nologin; create role authenticated nologin;
  create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}'::jsonb, created_at timestamptz default now());
  create table auth.current_user(id uuid, aal text);
  create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
  create function auth.jwt() returns jsonb language sql stable as $$select jsonb_build_object('aal', aal) from auth.current_user limit 1$$;
  grant usage on schema auth to anon, authenticated; grant select on auth.current_user to anon, authenticated;`);

for (const f of ['00001_schema.sql', '../tests/fixtures/base-catalog.sql', '../tests/fixtures/finance-bank-accounts.sql', '00012_profiles_self_read.sql', '00020_clients_crm.sql',
  '00022_crm_finance_compat.sql', '00023_finance_read_bank_accounts.sql', '00024_finance_movements.sql', '00025_account_assigned_plan.sql',
  '00026_booking_read_policy.sql', '00027_client_finance_read.sql', '00028_debts_payments.sql', '00029_cash_change.sql',
  '00030_access_hardening.sql']) {
  await db.exec(sql(f.startsWith('../') ? f.slice(3) : `supabase/migrations/${f}`));
}
await db.exec(`create or replace function public.crm_is_staff() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false) and exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff'));$$;
  revoke all on function public.crm_is_staff() from public, anon; grant execute on function public.crm_is_staff() to authenticated;`);
await db.exec(sql('supabase/migrations/00032_mfa_is_staff_y_privilegios_anon.sql'));
await db.exec(sql('supabase/migrations/00033_roles_fase_a.sql'));
await db.exec(sql('supabase/migrations/00037_cierre_caja_interruptor.sql'));

const makeUser = async (email, role) => {
  const id = (await db.query('insert into auth.users(email, raw_user_meta_data) values ($1, $2) returning id',
    [email, JSON.stringify({ full_name: 'EJEMPLO ' + email })])).rows[0].id;
  await db.exec('delete from auth.current_user');
  if (role) await db.query('update profiles set role = $2::user_role where id = $1', [id, role]);
  return id;
};
const admin = await makeUser('admin@test.invalid', 'admin');
const cashier = await makeUser('caja@test.invalid', 'cashier');
const trainer = await makeUser('entrenador@test.invalid', 'trainer');
const member = await makeUser('cliente@test.invalid', null);

const as = async (actor, aal, q, args = []) => {
  await db.exec('reset role; delete from auth.current_user');
  if (actor) await db.query('insert into auth.current_user values ($1, $2)', [actor, aal]);
  await db.exec(`set role ${actor ? 'authenticated' : 'anon'}`);
  try { return (await db.query(q, args)).rows; } finally { await db.exec('reset role'); }
};
const check = async (actor, aal) => {
  // Un error de permiso (visitante o cliente sin rol) cuenta como 'no': la app trata el error como cerrado.
  try { return (await as(actor, aal, 'select public.cashier_daily_close_enabled() as v')).at(0)?.v; } catch { return false; }
};
const setFlag = async (actor, value) => as(actor, 'aal2',
  `update staff_permissions set enabled = $1, updated_by = $2, updated_at = now() where key = 'cashier_can_view_daily_close'`, [value, actor]);

// Estado inicial: apagado por defecto.
const row = await as(admin, 'aal2', `select enabled from staff_permissions where key = 'cashier_can_view_daily_close'`);
ok('el interruptor existe y arranca apagado', row.length === 1 && row[0].enabled === false);
ok('caja no ve cierre del día con el interruptor apagado', (await check(cashier, 'aal2')) === false);

// Encender y apagar desde el administrador.
await setFlag(admin, true);
ok('caja ve cierre del día con el interruptor encendido', (await check(cashier, 'aal2')) === true);
ok('caja sin aal2 no lo ve aunque esté encendido', (await check(cashier, 'aal1')) !== true);
await setFlag(admin, false);
ok('caja vuelve a no verlo al apagar', (await check(cashier, 'aal2')) === false);

// Otros roles nunca lo ven, aunque esté encendido.
await setFlag(admin, true);
ok('administrador no usa la función de caja (false)', (await check(admin, 'aal2')) !== true);
ok('entrenador nunca lo ve', (await check(trainer, 'aal2')) !== true);
ok('cliente nunca lo ve', (await check(member, 'aal2')) !== true);
ok('visitante nunca lo ve', (await check(null, null)) !== true);

// Caja no puede cambiar el interruptor.
let blocked = false;
try {
  const r = await as(cashier, 'aal2', `update staff_permissions set enabled = true where key = 'cashier_can_view_daily_close' returning enabled`);
  blocked = r.length === 0;
} catch { blocked = true; }
ok('caja no puede cambiar el interruptor', blocked);
await setFlag(admin, false);

console.log(`\n${checks} comprobaciones OK`);
