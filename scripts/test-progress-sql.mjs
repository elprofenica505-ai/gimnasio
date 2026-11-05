// Prueba local de 00039 (medidas, metas y rutinas) sobre la cadena de migraciones
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
// Fechas de borde de la regla de 12 meses, calculadas desde hoy (nunca fijas:
// una fecha escrita a mano vence en cuanto pasa el día en que se escribió).
const borde = (await db.query(`select ($1::date + interval '12 months')::date::text as limite,
  ($1::date + interval '12 months' + interval '1 day')::date::text as excede`, [today])).rows[0];
const vals = { cintura_cm: 80, biceps_relajado_cm: 30.5 };

// 1) Registro de medidas por rol
ok('admin registra medición', (await as(admin, 'aal2', 'select public.record_body_measurement($1,$2,$3,$4,$5,$6) as id',
  [ana, today, 70.2, 165, JSON.stringify(vals), 'primera'])).length === 1);
ok('caja registra medición', (await as(cashier, 'aal2', 'select public.record_body_measurement($1,$2,$3,$4,$5,null) as id',
  [ana, today, 70.0, null, JSON.stringify({})])).length === 1);
ok('entrenador con acceso aprobado registra medición', (await as(trainer, 'aal2', 'select public.record_body_measurement($1,$2,$3,$4,$5,null) as id',
  [ana, today, 69.5, 165, JSON.stringify({})])).length === 1);
ok('entrenador SIN acceso no registra medición del cliente ajeno', await denied(
  as(trainer, 'aal2', 'select public.record_body_measurement($1,$2,$3,null,$4,null)', [luis, today, 80, JSON.stringify({})])));
ok('entrenador sin aal2 no registra (MFA)', await denied(
  as(trainer, 'aal1', 'select public.record_body_measurement($1,$2,$3,null,$4,null)', [ana, today, 69, JSON.stringify({})])));
ok('cliente (sin rol de personal) no registra medición', await denied(
  as(member, 'aal2', 'select public.record_body_measurement($1,$2,$3,null,$4,null)', [ana, today, 69, JSON.stringify({})])));
ok('anon no registra medición', await denied(
  as(null, null, 'select public.record_body_measurement($1,$2,$3,null,$4,null)', [ana, today, 69, JSON.stringify({})])));

// 2) Datos: vacío no es cero, cero se rechaza, futuro se rechaza
const med = (await as(admin, 'aal2', 'select * from body_measurements where client_id=$1 order by created_at', [ana]));
ok('las medidas no tomadas quedan vacías (NULL), no copiadas ni en cero',
  med[0].gluteo_cm === null && med[0].muslo_cm === null && med[0].cintura_cm === '80.0' && med[0].biceps_relajado_cm === '30.5');
ok('la segunda medición sin circunferencias no copia la primera', med[1].cintura_cm === null);
ok('peso cero se rechaza', await denied(as(admin, 'aal2', 'select public.record_body_measurement($1,$2,0,null,$3,null)', [ana, today, JSON.stringify({})])));
ok('circunferencia cero se rechaza', await denied(as(admin, 'aal2', 'select public.record_body_measurement($1,$2,70,null,$3,null)', [ana, today, JSON.stringify({ muslo_cm: 0 })])));
ok('medición en el futuro (día de Managua) se rechaza', await denied(
  as(admin, 'aal2', "select public.record_body_measurement($1,(now() at time zone 'America/Managua')::date + 1,70,null,$2,null)", [ana, JSON.stringify({})])));

// 3) Solo agregar: nadie edita ni borra
ok('admin no puede editar una medición (ni con UPDATE directo)', await denied(
  as(admin, 'aal2', "update body_measurements set weight_kg = 1 where client_id = $1", [ana])));
ok('nadie puede borrar una medición', await denied(
  as(admin, 'aal2', "delete from body_measurements where client_id = $1", [ana])));
ok('tablas sin INSERT directo para el personal', await denied(
  as(admin, 'aal2', "insert into body_measurements(client_id, measured_on, weight_kg) values ($1, $2, 70)", [ana, today]), /permission denied|42501/));

// 4) Lectura por rol
ok('admin ve medidas de ana', (await as(admin, 'aal2', 'select id from body_measurements where client_id=$1', [ana])).length === 3);
ok('caja ve medidas de ana', (await as(cashier, 'aal2', 'select id from body_measurements where client_id=$1', [ana])).length === 3);
ok('entrenador con acceso ve medidas de ana', (await as(trainer, 'aal2', 'select id from body_measurements where client_id=$1', [ana])).length === 3);
ok('entrenador sin acceso no ve medidas de luis (cero filas, sin error)', (await as(trainer, 'aal2', 'select id from body_measurements where client_id=$1', [luis])).length === 0);
ok('otro entrenador no ve medidas de ana', (await as(trainer2, 'aal2', 'select id from body_measurements where client_id=$1', [ana])).length === 0);
ok('cliente no ve medidas', (await as(member, 'aal2', 'select id from body_measurements')).length === 0);

// 5) Metas
const goal = (actor, type, start, target, weight, label = null) => as(actor, 'aal2',
  'select public.set_client_goal($1,$2,$3,$4,$5,$6) as id', [ana, type, label, start, target, weight]);
ok('admin crea meta de pérdida', (await goal(admin, 'perdida', today, '2027-01-20', 65)).length === 1);
ok('la meta nueva cancela la anterior: solo una activa',
  (await as(admin, 'aal2', "select count(*)::int as n from client_goals where client_id=$1 and status='activa'", [ana]))[0].n === 1);
ok('caja NO cambia metas', await denied(goal(cashier, 'perdida', today, '2027-01-20', 65)));
ok('entrenador con acceso cambia metas', (await goal(trainer, 'ganancia', today, '2027-01-20', 75)).length === 1);
ok('la meta anterior queda cancelada, no borrada (sigue en la tabla)',
  (await as(admin, 'aal2', "select count(*)::int as n from client_goals where client_id=$1 and status='cancelada'", [ana]))[0].n === 1);
ok('entrenador sin acceso no cambia metas de luis', await denied(
  as(trainer, 'aal2', 'select public.set_client_goal($1,$2,null,$3,$4,$5)', [luis, 'perdida', today, '2027-01-20', 60])));
ok('meta de más de 12 meses se rechaza', await denied(goal(admin, 'perdida', today, borde.excede, 65)));
ok('meta de 12 meses exactos se acepta', (await goal(admin, 'perdida', today, borde.limite, 65)).length === 1);
ok('pérdida sin peso objetivo se rechaza', await denied(goal(admin, 'perdida', today, '2027-01-20', null)));
ok('meta "otra" sin descripción se rechaza', await denied(goal(admin, 'otra', today, '2027-01-20', null, '')));
ok('meta "otra" con descripción se acepta', (await goal(admin, 'otra', today, '2027-01-20', null, 'Correr 5 km')).length === 1);
ok('fecha límite anterior al inicio se rechaza', await denied(goal(admin, 'perdida', today, today, 65)));

// 6) Rutinas
const routine = (actor, name) => as(actor, 'aal2',
  'select public.set_client_routine($1,$2,$3,$4) as id',
  [ana, name, ['lunes', 'miércoles'], JSON.stringify([{ ejercicio: 'Sentadilla', series: 4, reps: '8', descanso_s: 90 }])]);
ok('admin asigna rutina', (await routine(admin, 'Fuerza 3 días')).length === 1);
ok('entrenador con acceso cambia la rutina (la anterior se cierra)', (await routine(trainer, 'Pierna')).length === 1);
ok('solo una rutina activa',
  (await as(admin, 'aal2', "select count(*)::int as n from client_routines where client_id=$1 and status='activa'", [ana]))[0].n === 1);
ok('la rutina anterior queda cerrada con fecha de fin',
  (await as(admin, 'aal2', "select count(*)::int as n from client_routines where client_id=$1 and status='cerrada' and ends_on is not null", [ana]))[0].n === 1);
ok('caja NO asigna rutinas', await denied(routine(cashier, 'X')));
ok('rutina sin ejercicios se rechaza', await denied(as(admin, 'aal2',
  'select public.set_client_routine($1,$2,$3,$4)', [ana, 'Vacía', ['lunes'], '[]'])));
ok('caja sí lee rutinas', (await as(cashier, 'aal2', 'select id from client_routines where client_id=$1', [ana])).length === 2);

// 7) Acceso sin MFA y anon en lectura
ok('admin sin aal2 no lee medidas', (await as(admin, 'aal1', 'select id from body_measurements')).length === 0);
ok('anon no lee metas', await denied(as(null, null, 'select id from client_goals'), /permission denied|42501/));

// 8) Mi progreso (00040): el cliente ve SOLO sus datos, sin notas del personal
const memberClient = (await db.query(`select id from gym_clients where profile_id = $1`, [member])).rows[0].id;
await db.query(`insert into body_measurements(client_id, measured_on, weight_kg, height_cm, cintura_cm, notes) values ($1, $2, 81.5, 165, 90, 'NOTA INTERNA DEL PERSONAL')`, [memberClient, today]);
const mine = await as(member, 'aal1', 'select public.my_progress() as p');
ok('el cliente ve su propia medición', mine[0].p && mine[0].p.measurements.length === 1 && mine[0].p.measurements[0].weight_kg == 81.5);
ok('la respuesta no incluye notas del personal', !JSON.stringify(mine[0].p).includes('NOTA INTERNA'));
ok('el cliente no ve datos de otro cliente', !JSON.stringify(mine[0].p).includes('ANA EJEMPLO') && !JSON.stringify(mine[0].p).includes('LUIS EJEMPLO'));
const other = (await as(trainer2, 'aal2', 'select public.my_progress() as p'))[0].p;
ok('otra cuenta sin medidas propias no ve datos ajenos', other === null || (other.measurements.length === 0 && !JSON.stringify(other).includes('ANA EJEMPLO')));
ok('anon no puede llamar my_progress', await denied(as(null, null, 'select public.my_progress()'), /permission denied|42501/));

// 9) Altura de ficha en Mi progreso (00052 + 00054): manda la ficha, no la medición
await db.exec(sql('supabase/migrations/00052_altura_en_ficha.sql'));
await db.exec(sql('supabase/migrations/00054_mi_progreso_altura_ficha.sql'));
const consFicha = (await as(member, 'aal1', 'select public.my_progress() as p'))[0].p;
ok('00052 rellena la ficha con la última medición y my_progress la devuelve',
  consFicha.ficha_height_cm == 165);
// La corrección de altura (00053) solo cambia la ficha; la medición histórica no se toca.
await db.query(`update gym_clients set height_cm = 172 where id = $1`, [memberClient]);
const corregido = (await as(member, 'aal1', 'select public.my_progress() as p'))[0].p;
ok('tras corregir la ficha, el cliente ve la altura nueva sin esperar otra medición',
  corregido.ficha_height_cm == 172 && corregido.measurements[0].height_cm == 165);
const ajeno = (await as(trainer2, 'aal2', 'select public.my_progress() as p'))[0].p;
ok('otra cuenta no recibe la altura ajena', ajeno === null || ajeno.ficha_height_cm == null);
ok('anon sigue sin poder llamar my_progress (00054)', await denied(as(null, null, 'select public.my_progress()'), /permission denied|42501/));

console.log(`\n${checks} comprobaciones PASS (00039 medidas, metas y rutinas)`);
