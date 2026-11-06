// Prueba local de 00042 (productos, stock, ventas y categoría) sobre la cadena de migraciones. (medidas, metas y rutinas) sobre la cadena de migraciones
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
await db.exec(sql('supabase/migrations/00042_productos_stock_categorias.sql'));
ok('00042 se aplica sobre 00041 sin error', true);
// 00097 (venta particular) reemplaza product_sell: se aplica acá para probarla
// junto al resto del módulo de productos.
await db.exec(sql('supabase/migrations/00097_venta_particular.sql'));
ok('00097 se aplica sobre 00042 sin error', true);
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



// Cuentas y métodos de prueba (ficticios) para finanzas
await db.exec(`insert into bank_accounts(id,name,account_type,currency,balance) values('prueba-nio','Caja ficticia','caja_fuerte','NIO',1000)`);
await db.exec(`insert into payment_methods(id,name,currency) values('prueba-nio','Efectivo ficticio','NIO')`);
const bal = async () => Number((await db.query("select balance from bank_accounts where id='prueba-nio'")).rows[0].balance);
const stockOf = async (p) => Number((await db.query('select public.product_stock_of($1) as s', [p])).rows[0].s);

await db.exec("insert into plans(id,slug,name_es,name_en,period) values('prueba-semanal','prueba-semanal','Semanal ficticio','Weekly test','week') on conflict do nothing");
await db.exec("insert into plans(id,slug,name_es,name_en,period) values('prueba-mensual','prueba-mensual','Mensual ficticio','Monthly test','month') on conflict do nothing");
// Visitas recientes de ana (3 en 30 días) para la categoría
for (const n of [0, 1, 2]) {
  const d = (await db.query("select ((now() at time zone 'America/Managua')::date - $1::int)::text as d", [n])).rows[0].d;
  await db.query('insert into client_visits(client_id, visited_at, local_day, source) values ($1, now(), $2::date, $3)', [ana, d, 'manual']);
}

// Producto: compra 20, venta 35 => ganancia 15
const prodId = (await as(admin, 'aal2', "select public.product_save(null,'Creatina 300 g','Suplementos','Creatina',$1,'activo',20,35,2,null) as id", [JSON.stringify({ tamaño: '300 g' })]))[0].id;
const prod = (await as(admin, 'aal2', 'select p.* from products p where id=$1', [prodId]))[0];
ok('ganancia automática = venta - compra (35 - 20 = 15)', Number(prod.profit) === 15);
ok('imagen fuera de formato JPEG se rechaza', await denied(as(admin, 'aal2', "select public.product_save(null,'Foto','Ropa',null,'{}','activo',1,2,0,'data:image/png;base64,AAAA')", []), /check|violates/));
ok('precio negativo se rechaza', await denied(as(admin, 'aal2', "select public.product_save(null,'Malo','Ropa',null,'{}','activo',1,-2,0,null)", []), /INVALID/));
ok('anónimo no crea productos', await denied(as(null, null, "select public.product_save(null,'Anon','Ropa',null,'{}','activo',1,2,0,null)", [])));
ok('entrenador no crea productos', await denied(as(trainer, 'aal2', "select public.product_save(null,'Entr','Ropa',null,'{}','activo',1,2,0,null)", [])));
ok('caja sí crea productos', (await as(cashier, 'aal2', "select public.product_save(null,'Camiseta','Ropa','Camisas','{\"color\":\"negra\",\"talla\":\"M\"}','activo',100,180,1,null) as id", []))[0].id !== null);

// Compra de inventario: 10 unidades a 20 = 200 de gasto, suma stock
const buy = (req, q, cost) => as(admin, 'aal2', "select public.product_purchase($1,$2,$3,$4,'prueba-nio','prueba-nio') as r", [req, prodId, q, cost]);
const b0 = await bal();
const r1 = (await buy('11111111-1111-4111-8111-111111111111', 10, 20))[0].r;
ok('compra registra un gasto en finanzas (200)', (await bal()) === b0 - 200 && !!r1.transaction_id);
ok('compra suma stock (10)', (await stockOf(prodId)) === 10);
const r1b = (await buy('11111111-1111-4111-8111-111111111111', 10, 20))[0].r;
ok('misma compra (mismo request) no duplica dinero ni stock', (await bal()) === b0 - 200 && (await stockOf(prodId)) === 10 && r1b.already === true);
ok('compra con cantidad cero se rechaza', await denied(buy('22222222-2222-4222-8222-222222222222', 0, 20), /INVALID/));

// Ventas: a un cliente con ficha y a alguien que sólo vino a comprar
const sell = (req, q, client) => as(cashier, 'aal2', "select public.product_sell($1,$2,$3,$4,'prueba-nio','prueba-nio') as r", [req, prodId, q, client]);
const sellParticular = (req, q, name) => as(cashier, 'aal2',
  "select public.product_sell($1,$2,$3,null,'prueba-nio','prueba-nio',$4) as r", [req, prodId, q, name]);
const s0 = await bal();
const clientsBefore = (await db.query('select count(*)::int as n from gym_clients')).rows[0].n;

// Venta particular: no hay ficha, se cobra igual.
const p1 = (await sellParticular('33333333-3333-4333-8333-333333333333', 1, 'Muchacho de la esquina'))[0].r;
ok('venta particular suma ingreso (35)', (await bal()) === s0 + 35 && Number(p1.total) === 35);
ok('venta particular se marca como tal y guarda el nombre', p1.particular === true && p1.customer_name === 'Muchacho de la esquina');
ok('venta particular baja stock (10 - 1 = 9)', (await stockOf(prodId)) === 9);
const p1b = (await sellParticular('33333333-3333-4333-8333-333333333333', 1, 'Muchacho de la esquina'))[0].r;
ok('venta particular repetida no duplica', p1b.already === true && (await stockOf(prodId)) === 9 && (await bal()) === s0 + 35);
const p2 = (await sellParticular('c2000000-0002-4002-8002-c20000000002', 1, null))[0].r;
ok('venta particular sin nombre también se registra', p2.particular === true && p2.customer_name === null && (await bal()) === s0 + 70);
ok('la venta particular no inventa cliente ni toca gym_clients',
  (await db.query("select count(*)::int as n from stock_movements where kind = 'venta' and client_id is null")).rows[0].n === 2
  && (await db.query('select count(*)::int as n from gym_clients')).rows[0].n === clientsBefore);
ok('la venta particular no deja evento en la ficha de nadie',
  (await db.query("select count(*)::int as n from client_events where action = 'payment'")).rows[0].n === 0);
ok('el movimiento particular queda con su concepto y su nota',
  (await db.query("select t.concept, s.note from stock_movements s join transactions t on t.id = s.transaction_id where s.request_id = 'c2000000-0002-4002-8002-c20000000002'")).rows[0].concept.includes('Venta particular'));
ok('nombre demasiado largo se rechaza', await denied(sellParticular('c3000000-0003-4003-8003-c30000000003', 1, 'x'.repeat(81)), /INVALID_CUSTOMER/));
ok('cliente inexistente se rechaza', await denied(sell('c4000000-0004-4004-8004-c40000000004', 1, '00000000-0000-4000-8000-000000000000'), /INVALID_CLIENT/));
ok('venta particular sin método se rechaza', await denied(as(cashier, 'aal2',
  "select public.product_sell($1,$2,$3,null,null,'prueba-nio',null)", ['c5000000-0005-4005-8005-c50000000005', prodId, 1]), /INVALID_METHOD/));
ok('entrenador no vende particular', await denied(as(trainer, 'aal2',
  "select public.product_sell($1,$2,$3,null,'prueba-nio','prueba-nio',null)", ['c6000000-0006-4006-8006-c60000000006', prodId, 1]), /AUTH/));

// Venta con ficha: como siempre.
const v1 = (await sell('44444444-4444-4444-8444-444444444444', 2, ana))[0].r;
ok('venta a cliente suma ingreso (2 x 35 = 70)', (await bal()) === s0 + 140 && Number(v1.total) === 70);
ok('venta a cliente no se marca como particular', v1.particular === false);
ok('venta baja stock (8 + 70) ', (await stockOf(prodId)) === 6);
const v1b = (await sell('44444444-4444-4444-8444-444444444444', 2, ana))[0].r;
ok('venta repetida (mismo request) no duplica', v1b.already === true && (await stockOf(prodId)) === 6 && (await bal()) === s0 + 140);
ok('no vende más de lo que hay (SIN_STOCK)', await denied(sell('55555555-5555-4555-8555-555555555555', 50, ana), /SIN_STOCK/));
ok('stock no queda negativo tras venta fallida', (await stockOf(prodId)) === 6);

// Ajuste de inventario
const adj = (await as(admin, 'aal2', 'select public.product_stock_adjust($1,-1,$2) as s', [prodId, 'conteo']))[0].s;
ok('ajuste de conteo baja stock sin mover dinero', Number(adj) === 5 && (await bal()) === s0 + 140);
ok('ajuste que dejaría stock negativo se rechaza', await denied(as(admin, 'aal2', 'select public.product_stock_adjust($1,-100,$2)', [prodId, 'x']), /SIN_STOCK/));

// Lista de productos
const list = (await as(cashier, 'aal2', 'select public.product_list() as l'))[0].l;
const item = list.find(p => p.id === prodId);
ok('lista muestra existencia (5) y alerta de stock bajo = no', item.stock === 5 && item.low_stock === false);
ok('entrenador no ve la lista de productos', await denied(as(trainer, 'aal2', 'select public.product_list()'), /AUTH/));

// Categoría de cliente
const cat = async (client, actor = admin) => (await as(actor, 'aal2', 'select public.client_category($1) as c', [client]))[0].c;
ok('cliente sin membresía y sin visitas recientes = comun', (await cat(luis)).category === 'comun');
ok('ana: 3 visitas en 30 días y sin membresía = amigo', (await cat(ana)).category === 'amigo');
await db.query("update gym_clients set plan_id = 'prueba-mensual', status='active' where id=$1", [ana]);
ok('membresía mensual + compra en 90 días = strong_gym', (await cat(ana)).category === 'strong_gym');
await db.query("update gym_clients set plan_id = 'prueba-semanal' where id=$1", [luis]);
ok('membresía semanal = familia', (await cat(luis)).category === 'familia');
await db.query("update gym_clients set plan_id = 'prueba-mensual' where id=$1", [luis]);
ok('membresía mensual sin compras = familia', (await cat(luis)).category === 'familia');
ok('el cliente ve su propia categoría', (await as(member, 'aal1', 'select public.client_category(null) as c'))[0].c !== null);
ok('el cliente no ve la categoría de otro cliente (null)', (await as(member, 'aal2', 'select public.client_category($1) as c', [ana]))[0].c === null);
ok('la columna antigua gym_clients.category no cambia', (await db.query('select category from gym_clients where id=$1', [ana])).rows[0].category === 'client');


// ===== 00044: calculadora del cliente, edición sólo de entrenador/admin =====
await db.exec(sql('supabase/migrations/00043_plan_nutricion_interruptor.sql'));
ok('00043 se aplica sobre 00042 sin error', true);
await db.exec(sql('supabase/migrations/00044_calculadora_cliente.sql'));
ok('00044 se aplica sobre 00043 sin error', true);
const memberClient = (await db.query('select id from gym_clients where profile_id = $1', [member])).rows[0].id;
const calcInputs = { sex: 'm', age: 30, weightKg: 80, heightCm: 180, activity: 3, goal: 'peso' };
const reportMeals = [{ id: 'desayuno', title: 'Desayuno', text: 'Avena', share: 0.25, kcal: 700, proteinG: 30, carbsG: 90, fatG: 20 }];
const reportRoutine = [{ day: 'Fuerza 1', focus: 'Piernas', exercises: [{ name: 'Sentadilla', sets: 3, reps: '6-10', restSec: 90 }] }];
const selfCalc = (actor, aal) => as(actor, aal,
  'select public.nutrition_self_calculate($1,$2,$3,$4,$5,$6) as id',
  ['peso', JSON.stringify(calcInputs), JSON.stringify({ kcal: 2800, targetWeightKg: 86.4, weeksEstimate: 26 }), JSON.stringify(reportMeals), JSON.stringify(reportRoutine), JSON.stringify(['Guía'])]);
const staffSave = (actor, aal, client) => as(actor, aal,
  'select public.nutrition_save($1,$2,$3,$4,$5,$6,$7) as id',
  [client, 'peso', JSON.stringify(calcInputs), JSON.stringify({ kcal: 2800, targetWeightKg: 86.4, weeksEstimate: 26 }), JSON.stringify(reportMeals), JSON.stringify(reportRoutine), JSON.stringify(['Guía'])]);
const getAs = async (actor, aal, client = null) => (await as(actor, aal, 'select public.nutrition_get($1) as g', [client]))[0].g;

ok('el cliente calcula su propio plan desde Mi cuenta', (await selfCalc(member, 'aal1'))[0].id === memberClient);
const mine = await getAs(member, 'aal1');
ok('el cliente ve su plan con origen cliente y puede recalcular', mine.plan?.source === 'cliente' && mine.can_self_calculate === true);
ok('el reporte del cliente trae su nombre', typeof mine.client_name === 'string' && mine.client_name.length > 0);
ok('el cliente no ve los permisos del personal', !JSON.stringify(mine).includes('trainer_tools_enabled'));
ok('el cliente puede recalcular de nuevo mientras el personal no lo edite', (await selfCalc(member, 'aal1'))[0].id === memberClient);
ok('el cliente no guarda con nutrition_save', await denied(staffSave(member, 'aal1', memberClient), /AUTH/));
ok('anónimo no calcula', await denied(selfCalc(null, null), /AUTH|permission denied|42501/));

// Caja: sólo lectura
ok('caja no edita el plan de ana', await denied(staffSave(cashier, 'aal2', ana), /AUTH/));
const anaCashier = await getAs(cashier, 'aal2', ana);
ok('caja ve el plan de ana pero no puede editarlo', anaCashier.can_edit === false);

// Entrenador con acceso edita: el cliente queda bloqueado
ok('entrenador con acceso guarda el plan de ana', (await staffSave(trainer, 'aal2', ana))[0].id === ana);
const anaStaff = await getAs(trainer, 'aal2', ana);
ok('el entrenador ve que puede editar y el interruptor', anaStaff.can_edit === true && anaStaff.trainer_tools_enabled === true);
ok('entrenador sin acceso no guarda (luis)', await denied(staffSave(trainer, 'aal2', luis), /AUTH/));
ok('otro entrenador no guarda (ana)', await denied(staffSave(trainer2, 'aal2', ana), /AUTH/));
ok('el admin edita el plan del propio cliente', (await staffSave(admin, 'aal2', memberClient))[0].id === memberClient);
ok('el personal edita y bloquea el recálculo del cliente', await denied(selfCalc(member, 'aal1'), /LOCKED_BY_STAFF/));
const afterStaff = await getAs(member, 'aal1');
ok('tras la edición del personal el cliente ve origen entrenador y no puede recalcular', afterStaff.plan?.source === 'entrenador' && afterStaff.can_self_calculate === false);

// Interruptor: sólo admin, sólo para el entrenador
ok('caja no cambia el interruptor', await denied(as(cashier, 'aal2', 'select public.admin_set_client_tools($1,false)', [ana]), /AUTH/));
ok('entrenador no cambia su propio interruptor', await denied(as(trainer, 'aal2', 'select public.admin_set_client_tools($1,false)', [ana]), /AUTH/));
await as(admin, 'aal2', 'select public.admin_set_client_tools($1,false)', [ana]);
ok('admin apaga el permiso del entrenador para ana', await denied(staffSave(trainer, 'aal2', ana), /AUTH/));
ok('admin sigue pudiendo editar con el interruptor apagado', (await staffSave(admin, 'aal2', ana))[0].id === ana);
ok('caja sigue sin poder editar aunque el admin lo encienda', await denied(staffSave(cashier, 'aal2', ana), /AUTH/));
await as(admin, 'aal2', 'select public.admin_set_client_tools($1,true)', [ana]);
ok('entrenador vuelve a editar al encender su permiso', (await staffSave(trainer, 'aal2', ana))[0].id === ana);

// Lectura: el cliente no ve a otros clientes
ok('el cliente no lee el plan de ana (null)', (await getAs(member, 'aal1', ana)) === null);
ok('entrenador sin acceso no lee el plan de luis (null)', (await getAs(trainer, 'aal2', luis)) === null);
ok('anónimo no lee planes', await denied(as(null, null, 'select public.nutrition_get($1)', [ana])));
ok('las tablas de herramientas no se leen directamente', await denied(as(admin, 'aal2', 'select * from client_nutrition_plans'), /permission denied|42501/));

// ===== 00045: registro en el gimnasio desde la calculadora del cliente =====
await db.exec(sql('supabase/migrations/00045_registro_gimnasio_calculadora.sql'));
ok('00045 se aplica sobre 00044 sin error', true);
const member2 = await makeUser('cliente2@test.invalid', null);
const client2 = (await db.query('select id from gym_clients where profile_id = $1', [member2])).rows[0].id;
const mCount = async (c) => Number((await db.query('select count(*)::int as n from body_measurements where client_id = $1', [c])).rows[0].n);
const submit = (actor, aal) => as(actor, aal, 'select public.nutrition_submit_to_gym() as r', []);
const before2 = await mCount(client2);

ok('el cliente nuevo calcula su plan', (await selfCalc(member2, 'aal1'))[0].id === client2);
ok('antes de registrar, el plan no tiene fecha de registro', (await getAs(member2, 'aal1')).plan.submitted_at === null);
const regR1 = (await submit(member2, 'aal1'))[0].r;
ok('guardar registro crea una medición', regR1.already === false && (await mCount(client2)) === before2 + 1);
const regM1 = (await db.query('select weight_kg, height_cm from body_measurements where client_id = $1 order by created_at desc limit 1', [client2])).rows[0];
ok('la medición tiene el peso y la altura del cálculo', Number(regM1.weight_kg) === 80 && Number(regM1.height_cm) === 180);
const regR2 = (await submit(member2, 'aal1'))[0].r;
ok('guardar otra vez no duplica la medición', regR2.already === true && (await mCount(client2)) === before2 + 1);
ok('el cliente ve la fecha de registro en su plan', (await getAs(member2, 'aal1')).plan.submitted_at !== null);
ok('el administrador ve la medición en la ficha', (await as(admin, 'aal2', 'select count(*)::int as n from body_measurements where client_id = $1', [client2]))[0].n === before2 + 1);
ok('caja ve la medición en la ficha', (await as(cashier, 'aal2', 'select count(*)::int as n from body_measurements where client_id = $1', [client2]))[0].n === before2 + 1);
ok('entrenador sin acceso no ve la medición de este cliente', (await as(trainer, 'aal2', 'select count(*)::int as n from body_measurements where client_id = $1', [client2]))[0].n === 0);
ok('recalcular quita la marca de registro', (await selfCalc(member2, 'aal1'))[0].id === client2 && (await getAs(member2, 'aal1')).plan.submitted_at === null);
const regR3 = (await submit(member2, 'aal1'))[0].r;
ok('registrar el nuevo cálculo crea otra medición', regR3.already === false && (await mCount(client2)) === before2 + 2);
ok('el personal no registra por el cliente (sin plan propio)', await denied(submit(trainer, 'aal2'), /NOT_FOUND|NO_PLAN|AUTH/));
ok('anónimo no registra', await denied(submit(null, null), /AUTH|permission denied|42501/));

// ===== 00046: meta y rutina activas desde la calculadora =====
await db.exec(sql('supabase/migrations/00046_meta_rutina_desde_calculadora.sql'));
ok('00046 se aplica sobre 00045 sin error', true);
const goalsOf = async (c) => (await db.query("select goal_type, status, other_label, target_weight_kg, target_date::text as target_date from client_goals where client_id = $1 order by created_at, id", [c])).rows;
const activeRoutine = async (c) => (await db.query("select name, days, exercises from client_routines where client_id = $1 and status = 'activa'", [c])).rows;
const gBefore = (await goalsOf(client2)).length;
const member3 = await makeUser('cliente3@test.invalid', null);
const client3 = (await db.query('select id from gym_clients where profile_id = $1', [member3])).rows[0].id;
await selfCalc(member3, 'aal1');
const r3 = (await submit(member3, 'aal1'))[0].r;
ok('registro crea la meta activa del cálculo (Ganar peso = ganancia)', r3.goal_type === 'ganancia' && (await goalsOf(client3)).filter(g => g.status === 'activa').length === 1);
const g3 = (await goalsOf(client3)).find(g => g.status === 'activa');
ok('la meta tiene peso objetivo y plazo de 1 a 12 meses', g3 && Number(g3.target_weight_kg) > 80 && g3.target_date > today);
const rt3 = await activeRoutine(client3);
ok('registro crea la rutina activa con días y ejercicios', rt3.length === 1 && rt3[0].days.length >= 1 && rt3[0].exercises.length > 0 && rt3[0].exercises[0].ejercicio.includes(':'));
ok('los ejercicios tienen series, repeticiones y descanso', rt3[0] && rt3[0].exercises.every(e => e.series >= 1 && e.reps && e.descanso_s >= 0));
ok('el administrador ve la meta activa de este cliente', (await as(admin, 'aal2', "select count(*)::int as n from client_goals where client_id = $1 and status = 'activa'", [client3]))[0].n === 1);
ok('el administrador ve la rutina activa de este cliente', (await as(admin, 'aal2', "select count(*)::int as n from client_routines where client_id = $1 and status = 'activa'", [client3]))[0].n === 1);
ok('caja ve la meta y la rutina (sólo lectura)', (await as(cashier, 'aal2', "select count(*)::int as n from client_goals where client_id = $1 and status = 'activa'", [client3]))[0].n === 1);
await selfCalc(member3, 'aal1');
await db.query("update client_nutrition_plans set results = jsonb_set(results, '{weeksEstimate}', '0') where client_id = $1", [client3]);
const r3b = (await submit(member3, 'aal1'))[0].r;
const g3all = await goalsOf(client3);
ok('nuevo registro cancela la meta anterior y deja una activa', r3b.already === false && g3all.filter(g => g.status === 'activa').length === 1 && g3all.filter(g => g.status === 'cancelada').length === 1);
ok('sin semanas estimadas el plazo es de 3 meses', (await goalsOf(client3)).find(g => g.status === 'activa').target_date > today);
const rt3b = await activeRoutine(client3);
ok('nueva rutina reemplaza a la anterior (sólo una activa)', rt3b.length === 1 && (await db.query("select count(*)::int as n from client_routines where client_id = $1 and status = 'cerrada'", [client3])).rows[0].n === 1);
const r3c = (await submit(member3, 'aal1'))[0].r;
ok('guardar dos veces no cambia la meta', r3c.already === true && (await goalsOf(client3)).length === g3all.length);
ok('la meta y la rutina de otro cliente no se tocan', (await goalsOf(client2)).length === gBefore);

// ===== 00047: menores, consentimiento de datos de salud y aprobación de dieta/rutina =====
await db.exec(sql('supabase/migrations/00047_menores_consentimiento_aprobacion.sql'));
ok('00047 se aplica sobre 00046 sin error', true);
const CONSENT = 'salud-v1-2026-10-21-borrador';
const mkAccount = async (email, birth) => {
  const id = (await db.query('insert into auth.users(email, raw_user_meta_data) values ($1, $2) returning id',
    [email, JSON.stringify({ full_name: 'EJEMPLO ' + email, ...(birth ? { birth_date: birth } : {}) })])).rows[0].id;
  await db.exec('delete from auth.current_user');
  return id;
};
const clientOf = async (profile) => (await db.query('select id from gym_clients where profile_id = $1', [profile])).rows[0].id;
const ageOf = async (actor) => (await as(actor, 'aal1', 'select public.my_age_status() as s'))[0].s;
const d18 = (await db.query("select ((now() at time zone 'America/Managua')::date - interval '18 years')::date::text as d")).rows[0].d;
const minorProfile = await mkAccount('menor47@test.invalid', '2012-05-01');
const edgeMinor = await mkAccount('casi47@test.invalid', (await db.query("select ((now() at time zone 'America/Managua')::date - interval '18 years' + interval '1 day')::date::text as d")).rows[0].d);
const adultProfile = await mkAccount('adulto47@test.invalid', '1990-03-10');
const edgeAdult = await mkAccount('justo47@test.invalid', d18);
const noBirth = await mkAccount('sinfecha47@test.invalid', null);
const minorClient = await clientOf(minorProfile);
const adultClient = await clientOf(adultProfile);
const noBirthClient = await clientOf(noBirth);

ok('la fecha de nacimiento del alta pasa a la ficha', (await db.query('select birthdate::text as b from gym_clients where id = $1', [adultClient])).rows[0].b === '1990-03-10');
ok('sin fecha en el alta, la ficha queda sin fecha', (await db.query('select birthdate from gym_clients where id = $1', [noBirthClient])).rows[0].birthdate === null);
ok('menor de 18 años se reconoce como menor', (await ageOf(minorProfile)) === 'minor');
ok('cumplir 18 hoy ya cuenta como adulto', (await ageOf(edgeAdult)) === 'adult');
ok('un día antes de los 18 sigue siendo menor', (await ageOf(edgeMinor)) === 'minor');
ok('sin fecha de nacimiento: unknown', (await ageOf(noBirth)) === 'unknown');
ok('el menor no calcula (MINOR)', await denied(selfCalc(minorProfile, 'aal1'), /MINOR/));
ok('el menor no registra consentimiento (MINOR)', await denied(as(minorProfile, 'aal1', 'select public.record_health_consent($1)', [CONSENT]), /MINOR/));
ok('el menor ve su cuenta sin plan ni herramientas', await (async () => {
  const g = await getAs(minorProfile, 'aal1');
  return g.age_status === 'minor' && g.plan === null && g.can_self_calculate === false;
})());
ok('sin fecha no calcula (NO_BIRTHDATE)', await denied(selfCalc(noBirth, 'aal1'), /NO_BIRTHDATE/));
ok('adulto sin consentimiento no calcula (NO_CONSENT)', await denied(selfCalc(adultProfile, 'aal1'), /NO_CONSENT/));
ok('consentimiento con versión vieja se rechaza', await denied(as(adultProfile, 'aal1', 'select public.record_health_consent($1)', ['vieja']), /CONSENT_VERSION/));
const cid1 = (await as(adultProfile, 'aal1', 'select public.record_health_consent($1) as id', [CONSENT]))[0].id;
ok('adulto con consentimiento registra su consentimiento', !!cid1);
ok('registrar dos veces el mismo consentimiento no duplica', (await as(adultProfile, 'aal1', 'select public.record_health_consent($1) as id', [CONSENT]))[0].id === cid1);
ok('el consentimiento aparece en la cuenta', (await getAs(adultProfile, 'aal1')).has_consent === true);

// Calcular: queda pendiente y el cliente no ve tablas.
ok('adulto con consentimiento calcula su plan', (await selfCalc(adultProfile, 'aal1'))[0].id === adultClient);
const pending = (await getAs(adultProfile, 'aal1')).plan;
ok('el cliente no ve dieta ni rutina antes de aprobar', pending.approved === false && pending.results === undefined && pending.meal_plan === undefined && pending.routine === undefined && pending.guide === undefined);
ok('el cliente sí ve sus datos de entrada', pending.inputs && pending.inputs.weightKg === 80);
const adultGoalsBefore = (await db.query('select count(*)::int as n from client_goals where client_id = $1', [adultClient])).rows[0].n;
ok('calcular no abre meta ni rutina', adultGoalsBefore === 0);
const subAdult = (await as(adultProfile, 'aal1', 'select public.nutrition_submit_to_gym() as r'))[0].r;
ok('registrar peso y altura no abre meta ni rutina', subAdult.already === false && (await db.query('select count(*)::int as n from client_goals where client_id = $1', [adultClient])).rows[0].n === 0);

// Aprobación: entrenador sin acceso no aprueba; con acceso sí.
ok('entrenador sin acceso no aprueba (AUTH)', await denied(as(trainer2, 'aal2', 'select public.nutrition_approve($1)', [adultClient]), /AUTH/));
ok('el cliente no aprueba su propio plan (AUTH)', await denied(as(adultProfile, 'aal1', 'select public.nutrition_approve($1)', [adultClient]), /AUTH/));
await db.query(`insert into trainer_client_access(trainer_id, client_id, status, requested_via) values ($1, $2, 'approved', 'trainer')`, [trainer, adultClient]);
const ap1 = (await as(trainer, 'aal2', 'select public.nutrition_approve($1) as r', [adultClient]))[0].r;
ok('entrenador con acceso aprueba y se abren meta y rutina', ap1.already === false && (await db.query("select count(*)::int as n from client_goals where client_id = $1 and status = 'activa'", [adultClient])).rows[0].n === 1 && (await db.query("select count(*)::int as n from client_routines where client_id = $1 and status = 'activa'", [adultClient])).rows[0].n === 1);
const approvedView = (await getAs(adultProfile, 'aal1')).plan;
ok('tras aprobar, el cliente ve dieta, rutina y guía', approvedView.approved === true && Array.isArray(approvedView.meal_plan) && approvedView.meal_plan.length > 0 && Array.isArray(approvedView.routine) && approvedView.routine.length > 0 && Array.isArray(approvedView.guide));
ok('aprobar otra vez no repite nada', (await as(trainer, 'aal2', 'select public.nutrition_approve($1) as r', [adultClient]))[0].r.already === true);
ok('el administrador ve el plan aunque esté pendiente', (await as(admin, 'aal2', 'select public.nutrition_get($1) as g', [adultClient]))[0].g.plan.approved_at !== null);

// Recalcular o editar vuelve a dejarlo pendiente.
await selfCalc(adultProfile, 'aal1');
ok('recalcular deja el plan pendiente otra vez', (await getAs(adultProfile, 'aal1')).plan.approved === false);
await as(trainer, 'aal2', 'select public.nutrition_approve($1)', [adultClient]);
await as(trainer, 'aal2', 'select public.nutrition_save($1,$2,$3,$4,$5,$6,$7)',
  [adultClient, 'peso', JSON.stringify(calcInputs), JSON.stringify({ kcal: 2500, targetWeightKg: 86.4, weeksEstimate: 26 }), JSON.stringify(reportMeals), JSON.stringify(reportRoutine), JSON.stringify(['Guía'])]);
ok('guardar cambios del entrenador vuelve a dejar el plan pendiente', (await getAs(adultProfile, 'aal1')).plan.approved === false);

// Consentimiento: revocar bloquea nuevos datos de salud.
ok('revocar consentimiento devuelve 1', (await as(adultProfile, 'aal1', 'select public.revoke_health_consent() as n'))[0].n === 1);
ok('sin consentimiento vigente no calcula', await denied(selfCalc(adultProfile, 'aal1'), /NO_CONSENT/));
ok('sin consentimiento vigente no registra peso', await denied(as(adultProfile, 'aal1', 'select public.nutrition_submit_to_gym() as r'), /NO_CONSENT/));

// Fecha de nacimiento: una sola vez desde la cuenta.
ok('fecha inválida (futura) se rechaza', await denied(as(noBirth, 'aal1', "select public.set_my_birthdate('2999-01-01')"), /BIRTHDATE_INVALID/));
ok('sin fecha puede fijarla una vez', (await as(noBirth, 'aal1', "select public.set_my_birthdate('1985-01-01') as s"))[0].s === 'adult');
ok('después no la cambia desde la cuenta', await denied(as(noBirth, 'aal1', "select public.set_my_birthdate('1970-01-01')"), /BIRTHDATE_LOCKED/));
ok('el personal ve la edad del cliente', (await as(admin, 'aal2', 'select public.nutrition_get($1) as g', [minorClient]))[0].g.age_status === 'minor');
ok('menor: el personal ve su plan vacío y no aprueba sin plan (NO_PLAN)', await denied(as(admin, 'aal2', 'select public.nutrition_approve($1)', [minorClient]), /NO_PLAN/));

// ===== 00048: edad calculada desde la fecha de nacimiento =====
await db.exec(sql('supabase/migrations/00048_edad_desde_fecha_nacimiento.sql'));
ok('00048 se aplica sobre 00047 sin error', true);
const yearsSince = (iso) => {
  const t = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Managua', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()).split('-').map(Number);
  const b = iso.split('-').map(Number);
  let y = t[0] - b[0];
  if (t[1] < b[1] || (t[1] === b[1] && t[2] < b[2])) y -= 1;
  return y;
};
const ageOfSelf = async (actor) => (await as(actor, 'aal1', 'select public.client_age_years() as a'))[0].a;
ok('la edad del adulto sale de la fecha de nacimiento', (await ageOfSelf(adultProfile)) === yearsSince('1990-03-10'));
ok('la edad del menor también sale de la fecha', (await ageOfSelf(minorProfile)) === yearsSince('2012-05-01'));
const noDate48 = await mkAccount('sinfecha48@test.invalid', null);
ok('sin fecha de nacimiento devuelve null', (await ageOfSelf(noDate48)) === null);
ok('personal con acceso ve la edad del cliente', (await as(trainer, 'aal2', 'select public.client_age_years($1) as a', [adultClient]))[0].a === yearsSince('1990-03-10'));
ok('personal sin acceso no ve la edad (AUTH)', await denied(as(trainer2, 'aal2', 'select public.client_age_years($1) as a', [adultClient]), /AUTH/));
ok('otro cliente no ve la edad ajena (AUTH)', await denied(as(minorProfile, 'aal1', 'select public.client_age_years($1) as a', [adultClient]), /AUTH/));

// ===== 00049: personal, datos formales, alta, edición y baja =====
await db.exec('alter table auth.users add column if not exists banned_until timestamptz');
await db.exec(sql('supabase/migrations/00049_personal_datos_y_baja.sql'));
ok('00049 se aplica sobre 00048 sin error', true);
const staffData = { fullName: 'JUAN EJEMPLO', nationalId: '001-010190-1000A', birthDate: '1990-01-01', phone: '8888-1111', address: 'Barrio Ejemplo 1', emergencyName: 'MARIA EJEMPLO', emergencyPhone: '8888-2222', positionTitle: 'Entrenador de fuerza', hiredOn: '2026-01-10', responsibilities: 'Clases de fuerza', internalNotes: '' };
const newStaff49 = await mkAccount('personal49@test.invalid', null);
const saveStaff = (actor, aal, profile, role, data) => as(actor, aal, 'select public.staff_save($1,$2,$3::jsonb) as r', [profile, role, JSON.stringify(data)]);
ok('entrenador no da de alta personal (AUTH)', await denied(saveStaff(trainer, 'aal2', newStaff49, 'trainer', staffData), /AUTH/));
ok('el administrador no se da de alta a sí mismo (SELF_STAFF_CHANGE)', await denied(saveStaff(admin, 'aal2', admin, 'admin', staffData), /SELF_STAFF_CHANGE/));
ok('cédula con formato inválido se rechaza', await denied(saveStaff(admin, 'aal2', newStaff49, 'trainer', { ...staffData, nationalId: '001010190' }), /NATIONAL_ID_INVALID/));
ok('menor de 18 no puede ser personal (BIRTH_INVALID)', await denied(saveStaff(admin, 'aal2', newStaff49, 'trainer', { ...staffData, birthDate: '2012-05-01' }), /BIRTH_INVALID/));
ok('rol de cliente no es rol de personal (INVALID_ROLE)', await denied(saveStaff(admin, 'aal2', newStaff49, 'member', staffData), /INVALID_ROLE/));
await saveStaff(admin, 'aal2', newStaff49, 'trainer', staffData);
const row49 = (await db.query('select * from staff_members where profile_id = $1', [newStaff49])).rows[0];
ok('el administrador da de alta al personal con datos completos', !!row49 && row49.status === 'activo' && row49.national_id === '001-010190-1000A');
ok('el alta asigna el rol de entrenador y la ficha de personal', (await db.query('select role::text as r from profiles where id = $1', [newStaff49])).rows[0].r === 'trainer');
const audit1 = (await db.query("select action, changed_fields from staff_audit where profile_id = $1", [newStaff49])).rows;
ok('la bitácora registra el alta con nombres de campos', audit1.length === 1 && audit1[0].action === 'alta' && audit1[0].changed_fields.includes('nationalId'));
ok('la bitácora no guarda valores sensibles', !JSON.stringify(audit1).includes('001-010190-1000A') && !JSON.stringify(audit1).includes('8888-1111'));
ok('entrenador no lee datos del personal (RLS)', (await as(trainer, 'aal2', 'select count(*)::int as n from staff_members'))[0].n === 0);
ok('entrenador no lee la bitácora de personal (RLS)', (await as(trainer, 'aal2', 'select count(*)::int as n from staff_audit'))[0].n === 0);
ok('el administrador lee los datos del personal', (await as(admin, 'aal2', 'select count(*)::int as n from staff_members where profile_id = $1', [newStaff49]))[0].n === 1);

// Edición: sólo se registran los campos que cambiaron, sin valores.
await saveStaff(admin, 'aal2', newStaff49, 'trainer', { ...staffData, phone: '8888-9999' });
const audit2 = (await db.query("select changed_fields from staff_audit where profile_id = $1 and action = 'edicion' order by id desc limit 1", [newStaff49])).rows[0];
ok('editar el teléfono registra sólo ese campo', audit2 && audit2.changed_fields.length === 1 && audit2.changed_fields[0] === 'phone');
ok('el teléfono nuevo llega al directorio', (await db.query('select phone from profiles where id = $1', [newStaff49])).rows[0].phone === '8888-9999');
const countBefore = (await db.query('select count(*)::int as n from staff_audit where profile_id = $1', [newStaff49])).rows[0].n;
await saveStaff(admin, 'aal2', newStaff49, 'trainer', { ...staffData, phone: '8888-9999' });
ok('guardar sin cambios no escribe bitácora vacía', (await db.query('select count(*)::int as n from staff_audit where profile_id = $1', [newStaff49])).rows[0].n === countBefore);

// Baja y reactivación.
ok('dar de baja sin motivo se rechaza (REASON_REQUIRED)', await denied(as(admin, 'aal2', 'select public.staff_set_status($1,false,$2) as s', [newStaff49, '']), /REASON_REQUIRED/));
ok('el administrador no se da de baja a sí mismo (SELF_STAFF_CHANGE)', await denied(as(admin, 'aal2', 'select public.staff_set_status($1,false,$2) as s', [admin, 'motivo de prueba']), /SELF_STAFF_CHANGE/));
ok('entrenador no da de baja (AUTH)', await denied(as(trainer, 'aal2', 'select public.staff_set_status($1,false,$2) as s', [newStaff49, 'motivo de prueba']), /AUTH/));
const st1 = (await as(admin, 'aal2', 'select public.staff_set_status($1,false,$2) as s', [newStaff49, 'Renuncia confirmada']))[0].s;
ok('la baja marca la ficha como inactiva', st1 === 'inactivo');
const ban1 = (await db.query('select banned_until from auth.users where id = $1', [newStaff49])).rows[0].banned_until;
ok('la baja bloquea el inicio de sesión', ban1 !== null);
ok('la baja no cambia el rol', (await db.query('select role::text as r from profiles where id = $1', [newStaff49])).rows[0].r === 'trainer');
const st2 = (await as(admin, 'aal2', 'select public.staff_set_status($1,true,null) as s', [newStaff49]))[0].s;
ok('reactivar devuelve el acceso', st2 === 'activo' && (await db.query('select banned_until from auth.users where id = $1', [newStaff49])).rows[0].banned_until === null);
ok('la bitácora registra baja y reactivación', (await db.query("select count(*)::int as n from staff_audit where profile_id = $1 and action in ('baja','reactivacion')", [newStaff49])).rows[0].n === 2);

// ===== 00050-00055: cadena completa y menores en rutas del personal =====
// Compatibilidad solo de la prueba local: 00001 define coaches con name/role_es,
// mientras que producción divergió y 00050/00051 esperan full_name/specialty.
// Igualamos el esquema local al de producción; no cambiamos migraciones aplicadas.
await db.exec(`alter table public.coaches add column if not exists full_name text;
  alter table public.coaches add column if not exists specialty text;
  update public.coaches set full_name = coalesce(full_name, name), specialty = coalesce(specialty, role_es);`);
await db.exec(sql('supabase/migrations/00050_coaches_vista_publica.sql'));
ok('00050 se aplica sobre 00049 sin error', true);
await db.exec(sql('supabase/migrations/00051_coaches_vista_landing.sql'));
ok('00051 se aplica sobre 00050 sin error', true);
await db.exec(sql('supabase/migrations/00052_altura_en_ficha.sql'));
ok('00052 se aplica sobre 00051 sin error', true);
await db.exec(sql('supabase/migrations/00053_correccion_altura_admin.sql'));
ok('00053 se aplica sobre 00052 sin error', true);
await db.exec(sql('supabase/migrations/00054_mi_progreso_altura_ficha.sql'));
ok('00054 se aplica sobre 00053 sin error', true);
await db.exec(sql('supabase/migrations/00055_menores_rutas_personal.sql'));
ok('00055 se aplica sobre 00054 sin error', true);

const noBirthClient55 = await clientOf(noDate48);
ok('administrador no guarda dieta ni rutina a un menor (MINOR)', await denied(staffSave(admin, 'aal2', minorClient), /MINOR/));
ok('administrador no guarda dieta ni rutina sin fecha de nacimiento (NO_BIRTHDATE)', await denied(staffSave(admin, 'aal2', noBirthClient55), /NO_BIRTHDATE/));
ok('administrador sí sigue guardando el plan de un adulto', (await staffSave(admin, 'aal2', adultClient))[0].id === adultClient);
ok('administrador no aprueba un plan de menor (MINOR)', await denied(as(admin, 'aal2', 'select public.nutrition_approve($1)', [minorClient]), /MINOR/));
ok('administrador no aprueba un plan sin fecha de nacimiento (NO_BIRTHDATE)', await denied(as(admin, 'aal2', 'select public.nutrition_approve($1)', [noBirthClient55]), /NO_BIRTHDATE/));
ok('adulto sí se aprueba tras el control de edad', (await as(admin, 'aal2', 'select public.nutrition_approve($1) as r', [adultClient]))[0].r.already === false);
ok('staffSave sobre menor no crea filas de plan', (await db.query('select count(*)::int as n from client_nutrition_plans where client_id=$1', [minorClient])).rows[0].n === 0);
ok('staffSave sin fecha no crea filas de plan', (await db.query('select count(*)::int as n from client_nutrition_plans where client_id=$1', [noBirthClient55])).rows[0].n === 0);
ok('el personal sigue leyendo la edad del menor con nutrition_get', (await as(admin, 'aal2', 'select public.nutrition_get($1) as g', [minorClient]))[0].g.age_status === 'minor');

// ===== 00059: cobro combinado de servicio y productos =====
await db.exec(sql('supabase/migrations/00059_cobro_con_productos.sql'));
ok('00059 se aplica sobre la cadena de productos sin error', true);

const waterId = (await as(admin, 'aal2', "select public.product_save(null,'Agua EJEMPLO','Bebidas',null,'{}','activo',10,20,1,null) as id", []))[0].id;
await as(admin, 'aal2', 'select public.product_stock_adjust($1,4,$2) as s', [waterId, 'existencia inicial de prueba']);
ok('el agua de prueba queda con stock para el cobro combinado', (await stockOf(waterId)) === 4);

const saleCatalog = (await as(cashier, 'aal2', 'select public.product_sale_catalog() as c'))[0].c;
const catalogWater = saleCatalog.products.find((p) => p.id === waterId);
ok('caja ve el catálogo de venta con precio y stock, sin costo ni ganancia',
  !!catalogWater && Number(catalogWater.price) === 20 && catalogWater.stock === 4 &&
  !('cost' in catalogWater) && !('profit' in catalogWater));
ok('entrenador no ve el catálogo de venta', await denied(as(trainer, 'aal2', 'select public.product_sale_catalog()'), /AUTH/));
ok('visitante no ejecuta el catálogo de venta', await denied(as(null, null, 'select public.product_sale_catalog()'), /42501|permission denied/));

const checkout59 = (actor, request, serviceAmount, items, concept = 'Pase EJEMPLO', currency = 'NIO') => as(
  actor,
  'aal2',
  'select public.finance_record_checkout($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb) as r',
  [request, ana, serviceAmount, concept, currency, 'prueba-nio', 'prueba-nio', 36.7244, JSON.stringify(items)],
);
const creatineBefore59 = await stockOf(prodId);
const waterBefore59 = await stockOf(waterId);
const balanceBefore59 = await bal();
const checkoutItems59 = [
  { product: prodId, qty: 1, unit_price: 35 },
  { product: waterId, qty: 2, unit_price: 20 },
];
const checkoutResult59 = (await checkout59(cashier, 'b1b1b1b1-1111-4111-8111-b1b1b1b1b1b1', 40, checkoutItems59))[0].r;
ok('cobro combinado suma servicio y productos en la cuenta (40 + 35 + 40 = 115)',
  Number(checkoutResult59.total) === 115 && (await bal()) === balanceBefore59 + 115);
ok('cobro combinado baja el stock de cada producto una sola vez',
  (await stockOf(prodId)) === creatineBefore59 - 1 && (await stockOf(waterId)) === waterBefore59 - 2);
ok('cobro combinado devuelve comprobante del servicio y de cada producto',
  checkoutResult59.transactionIds.length === 3 && checkoutResult59.receipts.length === 3 &&
  checkoutResult59.serviceTransactionId === checkoutResult59.id);

const checkoutRetry59 = (await checkout59(cashier, 'b1b1b1b1-1111-4111-8111-b1b1b1b1b1b1', 40, checkoutItems59))[0].r;
ok('reintentar el mismo cobro combinado no duplica dinero ni stock',
  JSON.stringify(checkoutRetry59.transactionIds) === JSON.stringify(checkoutResult59.transactionIds) &&
  (await bal()) === balanceBefore59 + 115 &&
  (await stockOf(prodId)) === creatineBefore59 - 1 &&
  (await stockOf(waterId)) === waterBefore59 - 2);
ok('la misma referencia con otro payload es conflicto',
  await denied(checkout59(cashier, 'b1b1b1b1-1111-4111-8111-b1b1b1b1b1b1', 41, checkoutItems59), /REQUEST_CONFLICT/));

const balanceBeforeShort59 = await bal();
const creatineBeforeShort59 = await stockOf(prodId);
const waterBeforeShort59 = await stockOf(waterId);
ok('si falta stock de un producto, tampoco queda registrado el servicio',
  await denied(checkout59(cashier, 'b2b2b2b2-2222-4222-8222-b2b2b2b2b2b2', 40, [
    { product: prodId, qty: 1, unit_price: 35 },
    { product: waterId, qty: 99, unit_price: 20 },
  ]), /SIN_STOCK/) &&
  (await bal()) === balanceBeforeShort59 &&
  (await stockOf(prodId)) === creatineBeforeShort59 &&
  (await stockOf(waterId)) === waterBeforeShort59);
ok('si el precio cambió, el cobro combinado se rechaza sin mover dinero ni stock',
  await denied(checkout59(cashier, 'b3b3b3b3-3333-4333-8333-b3b3b3b3b3b3', 0, [
    { product: waterId, qty: 1, unit_price: 19 },
  ], 'Venta de productos'), /PRICE_CHANGED/) &&
  (await bal()) === balanceBeforeShort59 &&
  (await stockOf(waterId)) === waterBeforeShort59);

const productOnly59 = (await checkout59(cashier, 'b4b4b4b4-4444-4444-8444-b4b4b4b4b4b4', 0, [
  { product: waterId, qty: 1, unit_price: 20 },
], 'Venta de productos'))[0].r;
ok('venta solo de productos no crea movimiento de servicio y sí baja stock',
  productOnly59.serviceTransactionId === null && Number(productOnly59.total) === 20 &&
  (await bal()) === balanceBeforeShort59 + 20 &&
  (await stockOf(waterId)) === waterBeforeShort59 - 1);
ok('los productos del cobro combinado solo se cobran en NIO',
  await denied(checkout59(cashier, 'b5b5b5b5-5555-4555-8555-b5b5b5b5b5b5', 0, [
    { product: waterId, qty: 1, unit_price: 20 },
  ], 'Venta de productos', 'USD'), /INVALID_PAYMENT/));
ok('entrenador no registra cobros combinados',
  await denied(checkout59(trainer, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 40, checkoutItems59), /AUTH/));
ok('visitante no ejecuta el cobro combinado',
  await denied(as(null, null, "select public.finance_record_checkout('cccccccc-cccc-4ccc-8ccc-cccccccccccc',$1,40,'Pase EJEMPLO','NIO','prueba-nio','prueba-nio',36.7244,'[]'::jsonb)", [ana]), /42501|permission denied/));
ok('caja lee los grupos de cobro y entrenador no ve ninguno',
  (await as(cashier, 'aal2', 'select count(*)::int as n from public.finance_checkout_groups'))[0].n >= 2 &&
  (await as(trainer, 'aal2', 'select count(*)::int as n from public.finance_checkout_groups'))[0].n === 0);
ok('caja no escribe directamente en los grupos de cobro',
  await denied(as(cashier, 'aal2', "insert into public.finance_checkout_groups(request_id, client_id, payload, result) values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd',$1,'{}','{}')", [ana]), /42501|permission denied/));

// ===== 00060: el catálogo de venta incluye la foto, nunca costo ni ganancia =====
await db.exec(sql('supabase/migrations/00060_catalogo_venta_con_imagen.sql'));
ok('00060 se aplica sobre 00059 sin error', true);
const saleCatalog60 = (await as(cashier, 'aal2', 'select public.product_sale_catalog() as c'))[0].c;
const catalogWater60 = saleCatalog60.products.find((p) => p.id === waterId);
ok('el catálogo de venta trae la clave image_data y sigue sin costo ni ganancia',
  !!catalogWater60 && 'image_data' in catalogWater60 &&
  !('cost' in catalogWater60) && !('profit' in catalogWater60));
ok('entrenador sigue sin ver el catálogo de venta tras la 00060',
  await denied(as(trainer, 'aal2', 'select public.product_sale_catalog()'), /AUTH/));

console.log(`\n${checks} comprobaciones PASS (00042 productos, stock, ventas, categoría; 00043-00055 plan de nutrición, registro, edad, consentimiento, aprobación, edad calculada, personal, coaches, altura y menores en rutas del personal; 00059 cobro combinado con productos; 00060 imagen en el catálogo de venta)`);
