// Prueba local de la Fase B (00034) sobre una copia de la base con la cadena de migraciones
// y el estado ya aplicado: 00030, crm_is_staff de 00031, 00032 y 00033.
// Casos positivos y negativos para administrador, caja, entrenador, cliente y visitante.
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
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
// Estado de producción antes de Fase B: crm_is_staff (00031, admin+staff), 00032 y 00033.
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
const admin2 = await makeUser('admin2@test.invalid', 'admin');
const cashier = await makeUser('caja@test.invalid', 'cashier');
const trainer = await makeUser('entrenador@test.invalid', 'trainer');
const legacyStaff = await makeUser('staff-viejo@test.invalid', 'staff');
const member = await makeUser('cliente@test.invalid', null);
const visitor = null;

// Datos de prueba: un cliente con contacto y una visita de hoy y otra de hace 40 días.
const clientId = (await db.query(`insert into gym_clients(full_name, phone, email, medical_notes, status)
  values ('CLIENTE EJEMPLO', '+505 8000 0000', 'cliente-ejemplo@test.invalid', 'nota privada', 'active') returning id`)).rows[0].id;
await db.query(`insert into client_visits(client_id, source, local_day) values ($1, 'manual', (now() at time zone 'America/Managua')::date)`, [clientId]);
await db.query(`insert into client_visits(client_id, source, local_day) values ($1, 'manual', (now() at time zone 'America/Managua')::date - 40)`, [clientId]);

const as = async (actor, aal, q, args = []) => {
  await db.exec('reset role; delete from auth.current_user');
  if (actor) await db.query('insert into auth.current_user values ($1, $2)', [actor, aal]);
  await db.exec(`set role ${actor ? 'authenticated' : 'anon'}`);
  try { return (await db.query(q, args)).rows; } finally { await db.exec('reset role'); }
};
const denied = (p, re = /AUTH|42501|permission denied|row-level/) => p.then(
  () => false, e => re.test(`${e.code ?? ''} ${e.message}`));
const fn = async (actor, aal, name) => (await as(actor, aal, `select public.${name}() as x`))[0].x;

// Antes de 00034: el rol 'staff' existe, así que se prueba su migración.
await db.exec(sql('supabase/migrations/00034_roles_fase_b.sql'));
ok('00034 se aplica sin error', true);

// 1) Migración del rol staff
const legacyRole = (await db.query('select role::text r from profiles where id=$1', [legacyStaff])).rows[0].r;
ok('cuenta staff existente pasa a entrenador', legacyRole === 'trainer');
ok('ya no quedan cuentas con rol staff', (await db.query("select count(*)::int c from profiles where role::text='staff'")).rows[0].c === 0);

// 2) Guardias de datos
ok('admin con MFA es personal', await fn(admin, 'aal2', 'is_staff') === true);
ok('caja con MFA es personal', await fn(cashier, 'aal2', 'is_staff') === true);
ok('caja sin MFA NO es personal', await fn(cashier, 'aal1', 'is_staff') === false);
ok('entrenador NO es personal', await fn(trainer, 'aal2', 'is_staff') === false);
ok('cliente NO es personal', await fn(member, 'aal2', 'is_staff') === false);
ok('visitante NO puede ejecutar is_staff (permiso denegado)', await denied(fn(visitor, null, 'is_staff'), /42501|permission denied/));
ok('crm_is_staff: caja sí, entrenador no', await fn(cashier, 'aal2', 'crm_is_staff') === true && await fn(trainer, 'aal2', 'crm_is_staff') === false);

// 3) Datos de clientes: caja y admin ven contacto; entrenador y cliente no
const gcCount = async a => (await as(a.id, 'aal2', 'select count(*)::int c from gym_clients'))[0].c;
ok('caja ve el contacto del cliente', (await as(cashier, 'aal2', "select phone from gym_clients where full_name='CLIENTE EJEMPLO'"))[0].phone === '+505 8000 0000');
ok('admin ve el cliente de ejemplo', (await as(admin, 'aal2', "select count(*)::int c from gym_clients where full_name='CLIENTE EJEMPLO'"))[0].c === 1);
ok('entrenador NO lee la tabla de clientes', (await as(trainer, 'aal2', 'select count(*)::int c from gym_clients'))[0].c === 0);
ok('cliente NO lee la tabla de clientes', (await as(member, 'aal2', 'select count(*)::int c from gym_clients'))[0].c === 0);
ok('entrenador NO lee perfiles de otras personas', (await as(trainer, 'aal2', 'select count(*)::int c from profiles where id <> $1', [trainer]))[0].c === 0);
ok('entrenador NO ve notas médicas (0 filas)', (await as(trainer, 'aal2', 'select medical_notes from gym_clients')).length === 0);
ok('entrenador NO llama crm_detail', await denied(as(trainer, 'aal2', 'select public.crm_detail($1)', [clientId])));
ok('entrenador NO llama crm_directory', await denied(as(trainer, 'aal2', "select public.crm_directory('', '', 0)")));
ok('caja SÍ llama crm_directory', (await as(cashier, 'aal2', "select public.crm_directory('', '', 0) x")).length === 1);

// 4) Lista del entrenador: sólo nombre y asistencia
const roster = await as(trainer, 'aal2', 'select * from trainer_roster()');
const mine = roster.find(r => r.full_name === 'CLIENTE EJEMPLO');
ok('entrenador ve la lista de clientes activos (incluye el de ejemplo)', roster.length >= 1 && !!mine);
ok('la lista muestra asistencia de hoy y de 30 días', mine.visited_today === true && mine.visits_30d === 1);
ok('la lista NO tiene teléfono, correo ni notas',
  !Object.keys(roster[0]).some(k => /phone|email|medical|notes|address/.test(k)));
ok('caja NO usa trainer_roster', await denied(as(cashier, 'aal2', 'select * from trainer_roster()')));
ok('cliente NO usa trainer_roster', await denied(as(member, 'aal2', 'select * from trainer_roster()')));
ok('admin NO usa trainer_roster (sólo entrenador)', await denied(as(admin, 'aal2', 'select * from trainer_roster()')));
ok('visitante NO ve trainer_roster', await denied(as(null, null, 'select * from trainer_roster()'), /42501|permission denied/));
ok('entrenador sin MFA NO ve la lista', await denied(as(trainer, 'aal1', 'select * from trainer_roster()')));

// 5) Finanzas: caja sí, entrenador no
ok('caja lee finanzas (finance_read)', (await as(cashier, 'aal2', "select public.finance_read('summary',5) x")).length === 1);
ok('entrenador NO lee finanzas', await denied(as(trainer, 'aal2', "select public.finance_read('summary',5)")));
ok('cliente NO lee transacciones', (await as(member, 'aal2', 'select count(*)::int c from transactions'))[0].c === 0);
ok('entrenador NO lee transacciones', (await as(trainer, 'aal2', 'select count(*)::int c from transactions'))[0].c === 0);

// 6) Sólo administrador: reporte de deudas, importación, planes, clases, entrenadores, horarios
ok('admin ejecuta el reporte de deudas', (await as(admin, 'aal2', "select public.finance_debt_report('summary') x")).length === 1);
await db.exec(sql('supabase/migrations/00038_caja_resumen_deudas.sql'));
ok('caja ejecuta el resumen de deudas (00038)', (await as(cashier, 'aal2', "select public.finance_debt_report('summary') x")).length === 1);
ok('caja sin aal2 NO ejecuta el resumen de deudas', await denied(as(cashier, 'aal1', "select public.finance_debt_report('summary')")));
ok('entrenador NO ejecuta el reporte de deudas', await denied(as(trainer, 'aal2', "select public.finance_debt_report('summary')")));
ok('caja NO importa clientes', await denied(as(cashier, 'aal2', `select public.crm_import_client('{"fullName":"NUEVO EJEMPLO"}'::jsonb)`)));
ok('admin SÍ importa clientes (con MFA)', (await as(admin, 'aal2', `select public.crm_import_client('{"fullName":"NUEVO EJEMPLO"}'::jsonb) x`)).length === 1);

// En estas tablas authenticated sólo tiene SELECT (sin GRANT de escritura). La política sólo es defensa adicional.
ok('caja NO escribe planes', await denied(as(cashier, 'aal2', "update public.plans set is_popular = is_popular returning id")));
ok('entrenador NO escribe planes', await denied(as(trainer, 'aal2', "update public.plans set is_popular = is_popular returning id")));
const pol = (await db.query(`select tablename, policyname, qual, with_check from pg_policies where schemaname='public'
  and tablename in ('plans','classes','coaches','sessions') and cmd in ('ALL','*','INSERT','UPDATE','DELETE')`)).rows;
ok('políticas de escritura de planes/clases/entrenadores/horarios son sólo admin',
  pol.length === 4 && pol.every(r => /is_admin/.test(r.qual ?? '') && /is_admin/.test(r.with_check ?? '')));
ok('caja NO crea clases', await denied(as(cashier, 'aal2', `insert into classes(id, name_es, name_en) values ('x-caja', 'x', 'x')`)));
ok('caja NO crea horarios', await denied(as(cashier, 'aal2', `insert into sessions(class_id, starts_at, ends_at, capacity) values ('x', now(), now() + interval '1 hour', 5)`)));

// 7) Asignación de roles
ok('caja NO asigna roles', await denied(as(cashier, 'aal2', 'select public.admin_set_role($1, $2)', [member, 'trainer'])));
ok('entrenador NO asigna roles', await denied(as(trainer, 'aal2', 'select public.admin_set_role($1, $2)', [member, 'trainer'])));
ok('admin sin MFA NO asigna roles', await denied(as(admin, 'aal1', 'select public.admin_set_role($1, $2)', [member, 'trainer'])));
ok('nadie asigna rol staff (no válido)', await denied(as(admin, 'aal2', 'select public.admin_set_role($1, $2)', [member, 'staff']), /INVALID_ROLE/));
ok('admin NO se cambia su propio rol', await denied(as(admin, 'aal2', 'select public.admin_set_role($1, $2)', [admin, 'member']), /SELF_ROLE_CHANGE/));
ok('admin NO asigna rol a cuenta inexistente', await denied(as(admin, 'aal2', 'select public.admin_set_role($1, $2)', ['00000000-0000-0000-0000-000000000000', 'trainer']), /NOT_FOUND/));

await as(admin, 'aal2', 'select public.admin_set_role($1, $2)', [member, 'cashier']);
ok('admin asigna caja a un cliente', (await db.query('select role::text r from profiles where id=$1', [member])).rows[0].r === 'cashier');
await as(admin, 'aal2', 'select public.admin_set_role($1, $2)', [member, 'trainer']);
ok('admin cambia el mismo rol a entrenador', (await db.query('select role::text r from profiles where id=$1', [member])).rows[0].r === 'trainer');
await as(admin, 'aal2', 'select public.admin_set_role($1, $2)', [member, 'member']);
ok('admin devuelve la cuenta a cliente', (await db.query('select role::text r from profiles where id=$1', [member])).rows[0].r === 'member');

await as(admin, 'aal2', 'select public.admin_set_role($1, $2)', [admin2, 'member']);
ok('admin quita admin a otro administrador (hay dos)', (await db.query('select role::text r from profiles where id=$1', [admin2])).rows[0].r === 'member');
ok('la bitácora registra los cambios de rol', (await db.query('select count(*)::int c from role_changes')).rows[0].c >= 3);
ok('admin lee la bitácora', (await as(admin, 'aal2', 'select count(*)::int c from role_changes'))[0].c >= 3);
ok('caja NO lee la bitácora', (await as(cashier, 'aal2', 'select count(*)::int c from role_changes'))[0].c === 0);

// 8) Nadie se autoasciende por la API de perfiles
ok('caja NO se cambia a admin por API', await denied(as(cashier, 'aal2', "update profiles set role = 'admin' where id = $1", [cashier])));
ok('entrenador NO se cambia a admin por API', await denied(as(trainer, 'aal2', "update profiles set role = 'admin' where id = $1", [trainer])));
ok('cliente NO se cambia a caja por API', await denied(as(member, 'aal2', "update profiles set role = 'cashier' where id = $1", [member])));

// 9) Visitante sin sesión
ok('visitante NO ejecuta admin_set_role', await denied(as(null, null, 'select public.admin_set_role($1, $2)', [member, 'trainer'])));

// 10) Permisos de caja separados (00056): nacen apagados y no pisan el cierre diario.
await db.exec(sql('supabase/migrations/00037_cierre_caja_interruptor.sql'));
await as(admin, 'aal2', "update staff_permissions set enabled=true where key='cashier_can_view_daily_close'");
await db.exec(sql('supabase/migrations/00056_permisos_caja_separados.sql'));
ok('00056 se aplica tras 00037 y 00038', true);

const setCashierPermission = (key, enabled) =>
  as(admin, 'aal2', 'update staff_permissions set enabled=$2 where key=$1', [key, enabled]);
const cashierPermissionsAs = async (actor, aal = 'aal2') =>
  (await as(actor, aal, 'select public.cashier_permissions() as x'))[0].x;
const financeReadAs = async (actor, section) =>
  (await as(actor, 'aal2', 'select public.finance_read($1, 30) as x', [section]))[0].x.data;

const storedPermissions = await db.query(
  `select key, enabled from staff_permissions
   where key like 'cashier_can_%' and key <> 'cashier_can_void' order by key`,
);
const storedByKey = Object.fromEntries(storedPermissions.rows.map((r) => [r.key, r.enabled]));
ok('00056 conserva encendido el cierre diario ya activado', storedByKey.cashier_can_view_daily_close === true);
ok('los cinco permisos nuevos nacen apagados', [
  'cashier_can_view_monthly_result',
  'cashier_can_view_charts',
  'cashier_can_view_account_balances',
  'cashier_can_manage_expenses',
  'cashier_can_view_receivables',
].every((key) => storedByKey[key] === false));

const initialCashierPermissions = await cashierPermissionsAs(cashier);
ok('cashier_permissions devuelve cierre diario y demás permisos apagados',
  initialCashierPermissions.dailyClose === true &&
  ['monthlyResult', 'charts', 'accountBalances', 'expenses', 'receivables']
    .every((key) => initialCashierPermissions[key] === false));
const adminPermissions = await cashierPermissionsAs(admin);
ok('admin conserva todos los permisos aunque los interruptores de caja estén apagados',
  Object.values(adminPermissions).every((value) => value === true));
const trainerPermissions = await cashierPermissionsAs(trainer);
ok('entrenador no recibe permisos de caja', Object.values(trainerPermissions).every((value) => value === false));
const cashierNoMfaPermissions = await cashierPermissionsAs(cashier, 'aal1');
ok('caja sin MFA no recibe permisos financieros', Object.values(cashierNoMfaPermissions).every((value) => value === false));
ok('visitante NO ejecuta cashier_permissions',
  await denied(as(null, null, 'select public.cashier_permissions()'), /42501|permission denied/));

// Datos financieros ficticios para probar lecturas, saldos, gastos y deudas por rol.
await db.exec(`
  insert into bank_accounts(id,name,account_type,currency,balance)
    values('perm-nio','CUENTA EJEMPLO NIO','caja_fuerte','NIO',900);
  insert into payment_methods(id,name,currency) values('perm-both','EJEMPLO ambas monedas','BOTH');
  insert into expense_categories(id,name) values('perm-category','GASTO EJEMPLO');
`);
await db.query(
  'insert into member_balances(member_id,credit_nio,credit_usd,debt_nio,debt_usd) values($1,0,0,50,2)',
  [member],
);
await db.query(
  'insert into client_debt_balances(client_id,credit_nio,credit_usd,debt_nio,debt_usd) values($1,0,0,25,0)',
  [clientId],
);
await db.exec(`
  insert into transactions(type,status,occurred_at,account_id,method_id,amount,currency,amount_nio,amount_usd,fx_used,concept)
  values
    ('income','completed',((date_trunc('month',(now() at time zone 'America/Managua')) - interval '1 month' + interval '1 day') at time zone 'America/Managua'),'perm-nio','perm-both',500,'NIO',500,12.5,40,'INGRESO EJEMPLO MES ANTERIOR'),
    ('expense','completed',((date_trunc('month',(now() at time zone 'America/Managua')) - interval '1 month' + interval '1 day') at time zone 'America/Managua'),'perm-nio','perm-both',200,'NIO',200,5,40,'GASTO EJEMPLO MES ANTERIOR');
`);

const recordMovement = (actor, kind, amount, categoryId = null) =>
  as(actor, 'aal2',
    'select public.finance_record_movement($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) as id',
    [randomUUID(), kind, kind === 'expense' ? null : clientId, amount, 'NIO', 'perm-both', 'perm-nio',
      kind === 'expense' ? 'GASTO EJEMPLO HOY' : 'SERVICIO EJEMPLO HOY', 40, categoryId]);

const serviceTx = (await recordMovement(cashier, 'service_income', 100))[0].id;
ok('con los permisos nuevos apagados, caja sigue cobrando servicios', !!serviceTx);
ok('con gastos apagado, caja NO registra un gasto',
  await denied(recordMovement(cashier, 'expense', 30, 'perm-category'), /AUTH/));
const adminExpenseTx = (await recordMovement(admin, 'expense', 30, 'perm-category'))[0].id;
ok('admin sí registra el gasto de ejemplo', !!adminExpenseTx);
ok('caja puede recuperar el comprobante de su cobro',
  (await as(cashier, 'aal2', 'select public.finance_receipt($1) as x', [serviceTx]))[0].x.id === serviceTx);
ok('con gastos apagado, caja NO abre el comprobante de un gasto',
  await denied(as(cashier, 'aal2', 'select public.finance_receipt($1)', [adminExpenseTx]), /AUTH/));
ok('con gastos apagado, caja NO lista comprobantes de gastos',
  await denied(as(cashier, 'aal2', "select public.finance_recent_receipts('expense')"), /AUTH/));

const paymentReceipt = (await as(cashier, 'aal2',
  'select public.finance_debt_record($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) as x',
  [randomUUID(), 'payment', clientId, 10, 'NIO', 'ABONO EJEMPLO', 'perm-both', 'perm-nio', 40, null]))[0].x;
ok('con cuentas por cobrar apagado, caja sigue registrando un abono desde la ficha',
  paymentReceipt.after.debt_nio === 15);
const operationalDebtDetail = (await as(cashier, 'aal2',
  'select public.finance_debt_detail($1) as x', [clientId]))[0].x;
ok('el detalle operativo de la ficha sigue disponible para registrar abonos',
  operationalDebtDetail.balances.debt_nio === 15);

for (const section of ['monthly', 'daily', 'method_totals', 'receivables', 'categories']) {
  ok(`caja sin permiso NO lee finance_read('${section}')`,
    await denied(financeReadAs(cashier, section), /AUTH/));
}
const maskedSummary = await financeReadAs(cashier, 'summary');
ok('el resumen diario sigue, pero mes y deuda consolidada quedan en cero sin permiso',
  maskedSummary.incomeToday === 110 && maskedSummary.incomeMonth === 0 &&
  maskedSummary.expenseMonth === 0 && maskedSummary.netMonth === 0 &&
  maskedSummary.totalOwed === 0 && maskedSummary.totalOwedUsd === 0);
const maskedAccounts = await financeReadAs(cashier, 'accounts');
ok('sin permiso de saldos, finance_read conserva cuentas operativas pero oculta el monto',
  maskedAccounts.some((a) => a.name === 'CUENTA EJEMPLO NIO') &&
  maskedAccounts.every((a) => a.balance === 0));
const visibleTransactions = await financeReadAs(cashier, 'transactions');
ok('sin permiso de gastos, los movimientos recientes no incluyen egresos',
  visibleTransactions.every((t) => t.type !== 'expense'));
ok('sin permiso, caja NO abre la lista consolidada de cuentas por cobrar',
  await denied(as(cashier, 'aal2', "select public.finance_debt_report('receivables')"), /AUTH/));
const maskedDebtSummary = (await as(cashier, 'aal2',
  "select public.finance_debt_report('summary') as x"))[0].x;
ok('el resumen de deuda responde en cero sin permiso de cuentas por cobrar',
  maskedDebtSummary.data.totalOwed === 0 && maskedDebtSummary.data.totalOwedUsd === 0);
const cashierOptionsOff = (await as(cashier, 'aal2', 'select public.finance_options() as x'))[0].x;
ok('sin permiso de gastos, finance_options no entrega categorías',
  Array.isArray(cashierOptionsOff.categories) && cashierOptionsOff.categories.length === 0);

ok('RLS: sin permiso de saldos, caja no lee bank_accounts directamente',
  (await as(cashier, 'aal2', 'select count(*)::int c from bank_accounts'))[0].c === 0);
ok('RLS: sin cuentas por cobrar, caja no lee saldos de clientes directamente',
  (await as(cashier, 'aal2', 'select count(*)::int c from member_balances'))[0].c === 0 &&
  (await as(cashier, 'aal2', 'select count(*)::int c from client_debt_balances'))[0].c === 0 &&
  (await as(cashier, 'aal2', 'select count(*)::int c from client_debt_entries'))[0].c === 0);
ok('RLS: el cliente conserva la lectura de su propio saldo',
  (await as(member, 'aal2', 'select count(*)::int c from member_balances where member_id=$1', [member]))[0].c === 1);
ok('admin lee el resultado mensual real',
  (await financeReadAs(admin, 'monthly')).some((r) => r.income_nio === 500 && r.net_nio === 300));
ok('admin lee el saldo real de la cuenta',
  (await financeReadAs(admin, 'accounts')).some((a) => a.name === 'CUENTA EJEMPLO NIO' && a.balance === 980));

await setCashierPermission('cashier_can_view_monthly_result', true);
ok('al encender resultado mensual, caja lee el mes pero no la lista de deudas',
  (await financeReadAs(cashier, 'monthly')).some((r) => r.net_nio === 300) &&
  await denied(as(cashier, 'aal2', "select public.finance_debt_report('receivables')"), /AUTH/));

await setCashierPermission('cashier_can_view_charts', true);
const chartDaily = await financeReadAs(cashier, 'daily');
const chartMethods = await financeReadAs(cashier, 'method_totals');
ok('al encender gráficos, caja lee series sin exponer egresos si gastos sigue apagado',
  chartDaily.length > 0 && chartDaily.every((r) => r.expense_nio === 0) &&
  chartMethods.length > 0 && chartMethods.every((r) => r.expense_nio === 0));

await setCashierPermission('cashier_can_view_account_balances', true);
ok('al encender saldos, caja ve el monto real por RPC y por tabla',
  (await financeReadAs(cashier, 'accounts')).some((a) => a.balance === 980) &&
  (await as(cashier, 'aal2', 'select count(*)::int c from bank_accounts'))[0].c === 1);

await setCashierPermission('cashier_can_view_receivables', true);
const receivablesReport = (await as(cashier, 'aal2',
  "select public.finance_debt_report('receivables') as x"))[0].x;
ok('al encender cuentas por cobrar, caja abre la lista y lee saldos por RLS',
  receivablesReport.data.some((r) => r.client_id === clientId && r.total_owed_nio === 15) &&
  (await as(cashier, 'aal2', 'select count(*)::int c from member_balances'))[0].c === 1 &&
  (await as(cashier, 'aal2', 'select count(*)::int c from client_debt_balances'))[0].c === 1);

await setCashierPermission('cashier_can_manage_expenses', true);
const cashierExpenseTx = (await recordMovement(cashier, 'expense', 5, 'perm-category'))[0].id;
const expenseReceipts = (await as(cashier, 'aal2',
  "select public.finance_recent_receipts('expense') as x"))[0].x;
ok('al encender gastos, caja registra y lista comprobantes de gastos',
  !!cashierExpenseTx && expenseReceipts.some((r) => r.id === cashierExpenseTx));
ok('al encender gastos, finance_options entrega las categorías',
  (await as(cashier, 'aal2', 'select public.finance_options() as x'))[0].x.categories
    .some((c) => c.id === 'perm-category'));

for (const key of [
  'cashier_can_view_monthly_result',
  'cashier_can_view_charts',
  'cashier_can_view_account_balances',
  'cashier_can_manage_expenses',
  'cashier_can_view_receivables',
]) await setCashierPermission(key, false);
ok('al apagar de nuevo, caja pierde las vistas delegadas',
  await denied(financeReadAs(cashier, 'monthly'), /AUTH/) &&
  (await as(cashier, 'aal2', 'select count(*)::int c from bank_accounts'))[0].c === 0);

// 11) Pase del día (00057): tarifa NIO separada del precio histórico USD.
await db.exec(sql('supabase/migrations/00057_pase_del_dia_tarifa.sql'));
ok('00057 se aplica tras 00056', true);

const dayPassRow = async () =>
  (await db.query("select price, price_nio, period from plans where slug='pase-del-dia'")).rows[0];
const boxingRow = (await db.query("select price, price_nio from plans where slug='boxeo'")).rows[0];
let storedDayPass = await dayPassRow();
ok('00057 deja el pase del día en C$40 sin tocar su precio USD',
  storedDayPass.price === null && Number(storedDayPass.price_nio) === 40 &&
  storedDayPass.period === 'session');
ok('00057 no convierte el precio histórico de Boxeo (US$20) a córdobas',
  Number(boxingRow.price) === 20 && boxingRow.price_nio === null);

const crmOptionsForCashier = (await as(cashier, 'aal2', 'select public.crm_options() as x'))[0].x;
const offeredDayPass = crmOptionsForCashier.plans.find((p) => p.slug === 'pase-del-dia');
ok('crm_options entrega a caja la tarifa NIO del pase del día',
  offeredDayPass?.period === 'session' && Number(offeredDayPass.price_nio) === 40);

const changedTariff = (await as(admin, 'aal2',
  'select public.admin_set_day_pass_price_nio($1) as x', [45.5]))[0].x;
ok('admin con MFA cambia solo la tarifa NIO del pase del día',
  Number(changedTariff.price_nio) === 45.5 && changedTariff.is_active === true);
ok('caja NO cambia la tarifa del pase del día',
  await denied(as(cashier, 'aal2', 'select public.admin_set_day_pass_price_nio(50)'), /AUTH/));
ok('admin sin MFA NO cambia la tarifa del pase del día',
  await denied(as(admin, 'aal1', 'select public.admin_set_day_pass_price_nio(50)'), /AUTH/));
ok('visitante NO ejecuta el editor de tarifa',
  await denied(as(null, null, 'select public.admin_set_day_pass_price_nio(50)'), /42501|permission denied/));
ok('la tarifa rechaza cero y más de dos decimales',
  await denied(as(admin, 'aal2', 'select public.admin_set_day_pass_price_nio(0)'), /INVALID_PRICE/) &&
  await denied(as(admin, 'aal2', 'select public.admin_set_day_pass_price_nio(10.999)'), /INVALID_PRICE/));

const clearedTariff = (await as(admin, 'aal2',
  'select public.admin_set_day_pass_price_nio($1) as x', [null]))[0].x;
ok('admin puede quitar la tarifa rápida con NULL sin borrar el plan',
  clearedTariff.price_nio === null);
await as(admin, 'aal2', 'select public.admin_set_day_pass_price_nio(40)');
storedDayPass = await dayPassRow();
ok('la prueba de 00057 termina restaurando la tarifa aprobada de C$40',
  Number(storedDayPass.price_nio) === 40 && storedDayPass.price === null);

// 12) Tarifas completas de pesas y máquinas (00058), sin tocar Boxeo.
await db.exec(sql('supabase/migrations/00058_tarifas_gimnasio_nio.sql'));
ok('00058 se aplica tras 00057', true);

const gymTariffRows = async () =>
  (await db.query(`select slug, period, price, price_nio, sort_order, is_active
     from plans
    where slug in ('pase-del-dia', 'gimnasio-semanal', 'gimnasio-quincenal', 'gimnasio-mensual')
    order by sort_order`)).rows;
const expectedGymTariffs = [
  ['pase-del-dia', 'session', 40, 2],
  ['gimnasio-semanal', 'week', 150, 3],
  ['gimnasio-quincenal', 'fortnight', 280, 4],
  ['gimnasio-mensual', 'month', 560, 5],
];
let storedGymTariffs = await gymTariffRows();
ok('00058 publica Día C$40, Semana C$150, Quincena C$280 y Mes C$560 en orden',
  storedGymTariffs.length === expectedGymTariffs.length &&
  storedGymTariffs.every((row, index) => {
    const [slug, period, priceNio, sortOrder] = expectedGymTariffs[index];
    return row.slug === slug && row.period === period &&
      Number(row.price_nio) === priceNio && row.sort_order === sortOrder &&
      row.is_active === true;
  }));

const periodConstraint = (await db.query(`select pg_get_constraintdef(oid) as def
  from pg_constraint
 where conname = 'plans_period_check'
   and conrelid = 'plans'::regclass`)).rows[0]?.def ?? '';
ok('00058 permite el periodo fortnight sin abrir otros periodos',
  periodConstraint.includes("'fortnight'") &&
  periodConstraint.includes("'session'") &&
  periodConstraint.includes("'week'") &&
  periodConstraint.includes("'month'"));

const boxingAfterTariffs = async () => {
  const row = (await db.query(`select slug::text as slug,
      price::float8 as price,
      price_nio::float8 as price_nio,
      period::text as period
    from public.plans
   where id = 'pln_boxeo'
   limit 1`)).rows[0];
  return row ? JSON.parse(JSON.stringify(row)) : row;
};
let storedBoxing = await boxingAfterTariffs();
ok('00058 deja Boxeo fuera de las tarifas NIO',
  String(storedBoxing?.slug) === String.fromCharCode(98, 111, 120, 101, 111) &&
  Number(storedBoxing.price) === 20 && storedBoxing.price_nio === null &&
  storedBoxing.period === 'month');

const crmTariffOptionsForCashier = (await as(cashier, 'aal2', 'select public.crm_options() as x'))[0].x;
ok('crm_options entrega a caja las cuatro tarifas de pesas y máquinas',
  expectedGymTariffs.every(([slug, period, priceNio]) => {
    const offered = crmTariffOptionsForCashier.plans.find((plan) => plan.slug === slug);
    return offered?.period === period && Number(offered.price_nio) === priceNio;
  }));

const changedWeeklyTariff = (await as(admin, 'aal2',
  'select public.admin_set_plan_price_nio($1, $2) as x', ['gimnasio-semanal', 155.25]))[0].x;
ok('admin con MFA cambia una tarifa NIO de la lista cerrada',
  changedWeeklyTariff.slug === 'gimnasio-semanal' &&
  changedWeeklyTariff.period === 'week' &&
  Number(changedWeeklyTariff.price_nio) === 155.25);
ok('caja NO cambia las tarifas de pesas y máquinas',
  await denied(as(cashier, 'aal2',
    "select public.admin_set_plan_price_nio('gimnasio-semanal', 999)"), /AUTH/));
ok('admin sin MFA NO cambia las tarifas de pesas y máquinas',
  await denied(as(admin, 'aal1',
    "select public.admin_set_plan_price_nio('gimnasio-semanal', 999)"), /AUTH/));
ok('visitante NO ejecuta el editor genérico de tarifas',
  await denied(as(null, null,
    "select public.admin_set_plan_price_nio('gimnasio-semanal', 999)"), /42501|permission denied/));
ok('el editor genérico rechaza Boxeo y cualquier slug fuera de la lista',
  await denied(as(admin, 'aal2',
    'select public.admin_set_plan_price_nio($1, $2)',
    [String.fromCharCode(98, 111, 120, 101, 111), 750]), /INVALID_PLAN/) &&
  await denied(as(admin, 'aal2',
    "select public.admin_set_plan_price_nio('plan-inventado', 100)"), /INVALID_PLAN/) &&
  await denied(as(admin, 'aal2',
    'select public.admin_set_plan_price_nio($1, $2)', [null, 100]), /INVALID_PLAN/));
ok('el editor genérico rechaza cero y más de dos decimales',
  await denied(as(admin, 'aal2',
    "select public.admin_set_plan_price_nio('gimnasio-mensual', 0)"), /INVALID_PRICE/) &&
  await denied(as(admin, 'aal2',
    "select public.admin_set_plan_price_nio('gimnasio-mensual', 10.999)"), /INVALID_PRICE/));

await db.exec("update plans set period = 'month' where slug = 'gimnasio-semanal'");
ok('un slug válido con el periodo cruzado no se edita como otra tarifa',
  await denied(as(admin, 'aal2',
    "select public.admin_set_plan_price_nio('gimnasio-semanal', 150)"), /NOT_FOUND/));
await db.exec("update plans set period = 'week' where slug = 'gimnasio-semanal'");

const clearedFortnightTariff = (await as(admin, 'aal2',
  'select public.admin_set_plan_price_nio($1, $2) as x', ['gimnasio-quincenal', null]))[0].x;
ok('admin puede quitar solo una tarifa rápida con NULL sin borrar el plan',
  clearedFortnightTariff.slug === 'gimnasio-quincenal' &&
  clearedFortnightTariff.price_nio === null);

await as(admin, 'aal2', "select public.admin_set_plan_price_nio('gimnasio-semanal', 150)");
await as(admin, 'aal2', "select public.admin_set_plan_price_nio('gimnasio-quincenal', 280)");
storedGymTariffs = await gymTariffRows();
storedBoxing = await boxingAfterTariffs();
ok('la prueba de 00058 restaura las tarifas aprobadas y Boxeo sigue intacto',
  storedGymTariffs.every((row, index) =>
    Number(row.price_nio) === expectedGymTariffs[index][2]) &&
  Number(storedBoxing.price) === 20 && storedBoxing.price_nio === null);

console.log(`\nPASS ${checks} comprobaciones de Fase B`);
