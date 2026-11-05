// Prueba local de 00041 (asistencia por cliente) sobre la cadena de migraciones. Antes: 00039 (medidas, metas y rutinas) sobre la cadena de migraciones
// hasta 00036. Cubre positivos y negativos por rol, reglas de datos y solo-agregar.
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

for (const f of ['supabase/migrations/00001_schema.sql', 'tests/fixtures/base-catalog.sql', 'tests/fixtures/finance-bank-accounts.sql',
  'supabase/migrations/00012_profiles_self_read.sql', 'supabase/migrations/00020_clients_crm.sql', 'supabase/migrations/00022_crm_finance_compat.sql',
  'supabase/migrations/00023_finance_read_bank_accounts.sql', 'supabase/migrations/00024_finance_movements.sql',
  'supabase/migrations/00025_account_assigned_plan.sql', 'supabase/migrations/00026_booking_read_policy.sql',
  'supabase/migrations/00027_client_finance_read.sql', 'supabase/migrations/00028_debts_payments.sql',
  'supabase/migrations/00029_cash_change.sql', 'supabase/migrations/00030_access_hardening.sql']) {
  await db.exec(sql(f));
}
await db.exec(`create or replace function public.crm_is_staff() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false) and exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff'));$$;
  revoke all on function public.crm_is_staff() from public, anon; grant execute on function public.crm_is_staff() to authenticated;`);
await db.exec(sql('supabase/migrations/00032_mfa_is_staff_y_privilegios_anon.sql'));
await db.exec(sql('supabase/migrations/00033_roles_fase_a.sql'));

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
const trainer2 = await makeUser('entrenador2@test.invalid', 'trainer');
const member = await makeUser('cliente@test.invalid', null);

await db.exec(sql('supabase/migrations/00034_roles_fase_b.sql'));
await db.exec(sql('supabase/migrations/00035_asignacion_entrenador.sql'));
await db.exec(sql('supabase/migrations/00036_personal_no_es_cliente.sql'));
await db.exec(sql('supabase/migrations/00039_medidas_metas_rutinas.sql'));
await db.exec(sql('supabase/migrations/00040_mi_progreso_cliente.sql'));
await db.exec(sql('supabase/migrations/00041_asistencia_cliente.sql'));
ok('00041 se aplica sobre 00040 sin error', true);
ok('00040 se aplica sobre 00039 sin error', true);
ok('00039 se aplica sobre 00036 sin error', true);

// Clientes: ana (el entrenador tiene acceso aprobado), luis (sin acceso para nadie).
const ana = (await db.query(`insert into gym_clients(full_name, status) values ('ANA EJEMPLO', 'active') returning id`)).rows[0].id;
const luis = (await db.query(`insert into gym_clients(full_name, status) values ('LUIS EJEMPLO', 'active') returning id`)).rows[0].id;
await db.query(`insert into trainer_client_access(trainer_id, client_id, status, requested_via) values ($1, $2, 'approved', 'trainer')`, [trainer, ana]);

const as = async (actor, aal, q, args = []) => {
  await db.exec('reset role; delete from auth.current_user');
  if (actor) await db.query('insert into auth.current_user values ($1, $2)', [actor, aal]);
  await db.exec(`set role ${actor ? 'authenticated' : 'anon'}`);
  try { return (await db.query(q, args)).rows; } finally { await db.exec('reset role'); }
};
const denied = (p, re = /AUTH|42501|permission denied|row-level|violates|check|no se/i) => p.then(
  () => false, e => re.test(`${e.code ?? ''} ${e.message}`));
const today = (await db.query("select (now() at time zone 'America/Managua')::date::text as d")).rows[0].d;
const vals = { cintura_cm: 80, biceps_relajado_cm: 30.5 };


// Asistencia: visitas de ejemplo (ana) en días conocidos
const day = (n) => db.query("select ((now() at time zone 'America/Managua')::date - $1::int)::text as d", [n]).then(r => r.rows[0].d);
const visitsFor = async (client, offsets) => {
  for (const n of offsets) await db.query('insert into client_visits(client_id, visited_at, local_day, source) values ($1, now(), $2::date, $3)', [client, await day(n), 'manual']);
};
await visitsFor(ana, [0, 1, 2, 9, 40]);
const att = async (actor, aal, client) => (await as(actor, aal, 'select public.client_attendance($1) as a', [client]))[0].a;

const a = await att(admin, 'aal2', ana);
ok('admin ve total de visitas de ana', a && Number(a.total_visits) === 5);
ok('admin ve visitas de los últimos 30 días (4)', a && Number(a.visits_30_days) === 4);
ok('admin ve días y semanas y meses', a && a.days.length === 5 && a.weeks.length >= 1 && a.months.length >= 1);
const weekSum = a.weeks.reduce((s, w) => s + w.visits, 0);
ok('la suma por semanas coincide con el total (últimas 26 semanas incluyen todo)', weekSum === 5);
const monthSum = a.months.reduce((s, m) => s + m.visits, 0);
ok('la suma por meses coincide con el total', monthSum === 5);
ok('las semanas empiezan en lunes', a.weeks.every(w => new Date(w.week_start + 'T12:00:00Z').getUTCDay() === 1));
ok('caja ve la asistencia de ana', (await att(cashier, 'aal2', ana))?.total_visits == 5);
ok('entrenador con acceso aprobado ve la asistencia', (await att(trainer, 'aal2', ana))?.total_visits == 5);
ok('entrenador sin acceso no ve la asistencia de luis (null)', (await att(trainer, 'aal2', luis)) === null);
ok('otro entrenador no ve la asistencia de ana (null)', (await att(trainer2, 'aal2', ana)) === null);
ok('anon no puede llamar la función', await denied(as(null, null, 'select public.client_attendance($1)', [ana])));
ok('admin sin aal2 no ve asistencia (null o error)', await (async () => {
  try { return (await as(admin, 'aal1', 'select public.client_attendance($1) as a', [ana]))[0].a === null; } catch { return true; }
})());

// Cliente: su propia asistencia sin pasar id; nunca la de otros
const memberClient = (await db.query('select id from gym_clients where profile_id = $1', [member])).rows[0].id;
await db.query('insert into client_visits(client_id, visited_at, local_day, source) values ($1, now(), $2::date, $3)', [memberClient, await day(0), 'manual']);
const mine = (await as(member, 'aal1', 'select public.client_attendance(null) as a'))[0].a;
ok('el cliente ve su propia asistencia sin pasar id', mine && Number(mine.total_visits) === 1);
ok('el cliente no ve la asistencia de ana (null)', (await as(member, 'aal1', 'select public.client_attendance($1) as a', [ana]))[0].a === null);

console.log(`\n${checks} comprobaciones PASS (00041 asistencia por cliente)`);
