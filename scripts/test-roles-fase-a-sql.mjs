// Prueba local de la Fase A (00033) sobre una copia de la base con la cadena de migraciones
// y el estado ya aplicado en producción (00030, crm_is_staff de 00031, 00032).
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

for (const f of ['00001_schema.sql', '../tests/fixtures/base-catalog.sql', '00010_finance.sql', '00012_profiles_self_read.sql', '00020_clients_crm.sql',
  '00022_crm_finance_compat.sql', '00023_finance_read_bank_accounts.sql', '00025_account_assigned_plan.sql',
  '00026_booking_read_policy.sql', '00027_client_finance_read.sql', '00030_access_hardening.sql']) {
  await db.exec(sql(f.startsWith('../') ? f.slice(3) : `supabase/migrations/${f}`));
}
// Estado de producción antes de Fase A: crm_is_staff (00031) y 00032.
await db.exec(`create or replace function public.crm_is_staff() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false) and exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff'));$$;
  revoke all on function public.crm_is_staff() from public, anon; grant execute on function public.crm_is_staff() to authenticated;`);
await db.exec(sql('supabase/migrations/00032_mfa_is_staff_y_privilegios_anon.sql'));

const makeUser = async (email, role) => {
  const id = (await db.query('insert into auth.users(email, raw_user_meta_data) values ($1, $2) returning id',
    [email, JSON.stringify({ full_name: 'EJEMPLO ' + email })])).rows[0].id;
  await db.exec('delete from auth.current_user');
  if (role) await db.query('update profiles set role = $2::user_role where id = $1', [id, role]);
  return id;
};
const admin = await makeUser('admin@test.invalid', 'admin');
const cashier = await makeUser('caja@test.invalid', null);
const trainer = await makeUser('entrenador@test.invalid', null);
const member = await makeUser('cliente@test.invalid', null);
await db.exec(sql('supabase/migrations/00033_roles_fase_a.sql'));
ok('00033 se aplica sin error', true);
await db.exec('delete from auth.current_user');
await db.query("update profiles set role = 'cashier' where id = $1", [cashier]);
await db.query("update profiles set role = 'trainer' where id = $1", [trainer]);

const as = async (actor, aal, q, args = []) => {
  await db.exec('reset role; delete from auth.current_user');
  if (actor) await db.query('insert into auth.current_user values ($1, $2)', [actor, aal]);
  await db.exec(`set role ${actor ? 'authenticated' : 'anon'}`);
  try { return (await db.query(q, args)).rows; } finally { await db.exec('reset role'); }
};
const fn = async (actor, aal, name) => (await as(actor, aal, `select public.${name}() as x`))[0].x;

// 1) Funciones de rol con MFA
ok('admin aal2 es admin', await fn(admin, 'aal2', 'is_admin') === true);
ok('admin aal1 NO es admin (sin MFA)', await fn(admin, 'aal1', 'is_admin') === false);
ok('caja aal2 NO es admin', await fn(cashier, 'aal2', 'is_admin') === false);
ok('caja aal2 es caja', await fn(cashier, 'aal2', 'is_cashier') === true);
ok('caja aal1 NO es caja (sin MFA)', await fn(cashier, 'aal1', 'is_cashier') === false);
ok('entrenador aal2 es entrenador', await fn(trainer, 'aal2', 'is_trainer') === true);
ok('cliente NO es admin, caja ni entrenador',
  !(await fn(member, 'aal2', 'is_admin')) && !(await fn(member, 'aal2', 'is_cashier')) && !(await fn(member, 'aal2', 'is_trainer')));

// 2) Sin cambio de acceso: los roles nuevos no pasan por las reglas actuales
ok('caja NO cuenta como personal (is_staff false)', await fn(cashier, 'aal2', 'is_staff') === false);
ok('entrenador NO cuenta como personal (is_staff false)', await fn(trainer, 'aal2', 'is_staff') === false);
ok('admin aal2 sigue siendo personal (is_staff true)', await fn(admin, 'aal2', 'is_staff') === true);
const cajaClientes = await as(cashier, 'aal2', 'select count(*)::int c from gym_clients').catch(e => [{ c: 0, err: e.code }]);
ok('caja NO lee gym_clients', cajaClientes[0].c === 0);
const cajaTx = await as(cashier, 'aal2', 'select count(*)::int c from transactions').catch(e => [{ c: 0, err: e.code }]);
ok('caja NO lee transacciones de otros', cajaTx[0].c === 0);

// 3) Interruptores del administrador
const adminRead = await as(admin, 'aal2', "select enabled from staff_permissions where key = 'cashier_can_void'");
ok('admin lee cashier_can_void = false', adminRead.length === 1 && adminRead[0].enabled === false);
ok('caja NO ve los interruptores', (await as(cashier, 'aal2', 'select key from staff_permissions')).length === 0);
ok('cliente NO ve los interruptores', (await as(member, 'aal2', 'select key from staff_permissions')).length === 0);
await as(null, null, 'select key from staff_permissions').then(
  () => assert.fail('anon no debe leer'), e => ok('visitante NO lee interruptores (permiso denegado)', e.code === '42501'));

await as(cashier, 'aal2', "update staff_permissions set enabled = true where key = 'cashier_can_void'");
const afterCashier = await as(admin, 'aal2', "select enabled from staff_permissions where key = 'cashier_can_void'");
ok('caja NO puede activarse el permiso', afterCashier[0].enabled === false);

await as(admin, 'aal1', "update staff_permissions set enabled = true where key = 'cashier_can_void'");
const afterAal1 = await as(admin, 'aal2', "select enabled from staff_permissions where key = 'cashier_can_void'");
ok('admin sin MFA NO puede cambiar el interruptor', afterAal1[0].enabled === false);

await as(admin, 'aal2', "update staff_permissions set enabled = true, updated_by = $1, updated_at = now() where key = 'cashier_can_void'", [admin]);
const afterAdmin = await as(admin, 'aal2', "select enabled, updated_by from staff_permissions where key = 'cashier_can_void'");
ok('admin con MFA activa el permiso y queda registrado', afterAdmin[0].enabled === true && afterAdmin[0].updated_by === admin);

await as(admin, 'aal2', "update staff_permissions set enabled = false where key = 'cashier_can_void'");
ok('admin desactiva el permiso de nuevo', (await as(admin, 'aal2', "select enabled from staff_permissions where key = 'cashier_can_void'"))[0].enabled === false);

await as(admin, 'aal2', "insert into staff_permissions(key, enabled) values ('otro_permiso', true)").then(
  () => assert.fail('no debe insertar'), e => ok('nadie crea permisos nuevos desde la app (insert denegado)', e.code === '42501'));
await as(admin, 'aal2', "update staff_permissions set key = 'hack' where key = 'cashier_can_void'").then(
  () => assert.fail('no debe cambiar la clave'), e => ok('la clave del permiso no se puede cambiar (columna protegida)', e.code === '42501'));
await as(admin, 'aal2', 'delete from staff_permissions').then(
  () => assert.fail('no debe borrar'), e => ok('nadie borra permisos (delete denegado)', e.code === '42501'));

// 4) Nadie se autoasciende: el rol de perfil no se puede cambiar desde la API de usuarios
await as(member, 'aal2', "update profiles set role = 'admin' where id = $1", [member]).then(
  () => assert.fail('cliente no debe autoascenderse'), e => ok('cliente NO puede cambiarse a admin (permiso denegado)', e.code === '42501' || /ADMIN_ONLY/.test(e.message)));
await as(cashier, 'aal2', "update profiles set role = 'admin' where id = $1", [cashier]).then(
  () => assert.fail('caja no debe autoascenderse'), e => ok('caja NO puede cambiarse a admin (permiso denegado)', e.code === '42501' || /ADMIN_ONLY/.test(e.message)));
await as(trainer, 'aal2', "update profiles set role = 'admin' where id = $1", [trainer]).then(
  () => assert.fail('entrenador no debe autoascenderse'), e => ok('entrenador NO puede cambiarse a admin (permiso denegado)', e.code === '42501' || /ADMIN_ONLY/.test(e.message)));

// 5) Administrador sigue operando
const adminClientes = await as(admin, 'aal2', 'select count(*)::int c from gym_clients');
ok('admin con MFA sigue leyendo clientes', adminClientes[0].c >= 0);

console.log(`\nPASS ${checks} comprobaciones de Fase A`);
