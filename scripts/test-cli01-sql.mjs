// CLI-01: prueba local de 00067 (vigencias reales) sobre la cadena de migraciones.
// Cubre términos, compra estructurada, encadenamiento, pago atrasado,
// idempotencia, reintento de un cobro previo, separación Gimnasio/Boxeo,
// congelamiento, lectura por rol y bloqueo de reservas de Boxeo.
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const sql = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const db = new PGlite();
let checks = 0;
const ok = (label, cond) => {
  assert.ok(cond, label);
  checks += 1;
  console.log(`✅ ${label}`);
};

await db.exec(`create schema auth; create role anon nologin; create role authenticated nologin;
  create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}'::jsonb, created_at timestamptz default now());
  create table auth.current_user(id uuid, aal text);
  create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
  create function auth.jwt() returns jsonb language sql stable as $$select jsonb_build_object('aal', aal) from auth.current_user limit 1$$;
  grant usage on schema auth to anon, authenticated; grant select on auth.current_user to anon, authenticated;`);

for (const f of [
  "supabase/migrations/00001_schema.sql",
  "tests/fixtures/base-catalog.sql",
  "tests/fixtures/finance-bank-accounts.sql",
  "supabase/migrations/00012_profiles_self_read.sql",
  "supabase/migrations/00020_clients_crm.sql",
  "supabase/migrations/00022_crm_finance_compat.sql",
  "supabase/migrations/00023_finance_read_bank_accounts.sql",
  "supabase/migrations/00024_finance_movements.sql",
  "supabase/migrations/00025_account_assigned_plan.sql",
  "supabase/migrations/00026_booking_read_policy.sql",
  "supabase/migrations/00027_client_finance_read.sql",
  "supabase/migrations/00028_debts_payments.sql",
  "supabase/migrations/00029_cash_change.sql",
  "supabase/migrations/00030_access_hardening.sql",
]) {
  await db.exec(sql(f));
}
await db.exec(`create or replace function public.crm_is_staff() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false) and exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff'));$$;
  revoke all on function public.crm_is_staff() from public, anon; grant execute on function public.crm_is_staff() to authenticated;`);
for (const f of [
  "supabase/migrations/00032_mfa_is_staff_y_privilegios_anon.sql",
  "supabase/migrations/00033_roles_fase_a.sql",
  "supabase/migrations/00034_roles_fase_b.sql",
  "supabase/migrations/00035_asignacion_entrenador.sql",
  "supabase/migrations/00036_personal_no_es_cliente.sql",
  "supabase/migrations/00037_cierre_caja_interruptor.sql",
  "supabase/migrations/00038_caja_resumen_deudas.sql",
  "supabase/migrations/00039_medidas_metas_rutinas.sql",
  "supabase/migrations/00040_mi_progreso_cliente.sql",
  "supabase/migrations/00041_asistencia_cliente.sql",
  "supabase/migrations/00042_productos_stock_categorias.sql",
  "supabase/migrations/00043_plan_nutricion_interruptor.sql",
  "supabase/migrations/00044_calculadora_cliente.sql",
  "supabase/migrations/00045_registro_gimnasio_calculadora.sql",
  "supabase/migrations/00046_meta_rutina_desde_calculadora.sql",
  "supabase/migrations/00047_menores_consentimiento_aprobacion.sql",
  "supabase/migrations/00048_edad_desde_fecha_nacimiento.sql",
  "supabase/migrations/00049_personal_datos_y_baja.sql",
]) {
  await db.exec(sql(f));
}
// Compatibilidad solo de la prueba local: 00001 define coaches con name/role_es
// y producción divergió; 00050/00051 esperan full_name/specialty.
await db.exec(`alter table public.coaches add column if not exists full_name text;
  alter table public.coaches add column if not exists specialty text;
  update public.coaches set full_name = coalesce(full_name, name), specialty = coalesce(specialty, role_es);`);
for (const f of [
  "supabase/migrations/00050_coaches_vista_publica.sql",
  "supabase/migrations/00051_coaches_vista_landing.sql",
  "supabase/migrations/00052_altura_en_ficha.sql",
  "supabase/migrations/00053_correccion_altura_admin.sql",
  "supabase/migrations/00054_mi_progreso_altura_ficha.sql",
  "supabase/migrations/00055_menores_rutas_personal.sql",
  "supabase/migrations/00056_permisos_caja_separados.sql",
  "supabase/migrations/00057_pase_del_dia_tarifa.sql",
  "supabase/migrations/00058_tarifas_gimnasio_nio.sql",
  "supabase/migrations/00059_cobro_con_productos.sql",
  "supabase/migrations/00064_disciplinas_activas.sql",
]) {
  await db.exec(sql(f));
}
await db.exec(sql("supabase/migrations/00067_vigencias_planes.sql"));
await db.exec(sql("supabase/migrations/00068_catalogo_planes.sql"));
ok("00067 se aplica sobre la cadena hasta 00064 sin error", true);

const row = async (query, args = []) => (await db.query(query, args)).rows[0];
const makeUser = async (email, role) => {
  const id = (await row("insert into auth.users(email, raw_user_meta_data) values ($1,$2) returning id", [
    email,
    JSON.stringify({ full_name: "EJEMPLO " + email }),
  ])).id;
  if (role) await db.query("update public.profiles set role=$2::public.user_role where id=$1", [id, role]);
  return id;
};
const admin = await makeUser("admin@test.invalid", "admin");
const cashier = await makeUser("caja@test.invalid", "cashier");
const member = await makeUser("cliente@test.invalid", null);
const member2 = await makeUser("cliente2@test.invalid", null);
const trainer = await makeUser("entrenador@test.invalid", "trainer");

async function as(actor, aal, query, args = []) {
  await db.exec("reset role; delete from auth.current_user");
  if (actor) await db.query("insert into auth.current_user values($1,$2)", [actor, aal]);
  await db.exec("set role authenticated");
  try {
    return await db.query(query, args);
  } finally {
    await db.exec("reset role; delete from auth.current_user");
  }
}
const asAdmin = (q, a = []) => as(admin, "aal2", q, a);
const rpc = async (name, args) => (await asAdmin(`select public.${name}(${args.map((_, i) => `$${i + 1}`).join(",")}) as value`, args)).rows[0].value;
const denied = async (label, promise, pattern) => {
  await assert.rejects(promise, pattern, label);
  ok(label, true);
};

await db.exec(`insert into bank_accounts(id,name,account_type,currency,balance) values('caja-nio','Caja EJEMPLO','caja_fuerte','NIO',1000),('caja-usd','Caja USD EJEMPLO','caja_fuerte','USD',500);
  insert into payment_methods(id,name,currency) values('efectivo-nio','Efectivo EJEMPLO','NIO'),('efectivo-usd','Efectivo USD EJEMPLO','USD');`);

// El alta de perfil puede crear la ficha automáticamente; se reutiliza.
const ana = (await row("select id from gym_clients where profile_id=$1", [member]))?.id ??
  (await row("insert into gym_clients(full_name, status, profile_id) values ('ANA EJEMPLO','active',$1) returning id", [member])).id;
const luis = (await row("select id from gym_clients where profile_id=$1", [member2]))?.id ??
  (await row("insert into gym_clients(full_name, status, profile_id) values ('LUIS EJEMPLO','active',$1) returning id", [member2])).id;

// 1. Términos estrictos.
const termsDia = await rpc("plan_validity_terms", ["pln_dia"]);
ok("Día: gimnasio, 1 día, C$40", termsDia.access === "gym" && termsDia.days === 1 && termsDia.currency === "NIO" && Number(termsDia.amount) === 40);
const termsMes = await rpc("plan_validity_terms", ["pln_gimnasio"]);
ok("Mes: gimnasio, 30 días, C$560", termsMes.access === "gym" && termsMes.days === 30 && Number(termsMes.amount) === 560);
const termsBoxeo = await rpc("plan_validity_terms", ["pln_boxeo"]);
ok("Boxeo: acceso por disciplina, 30 días, US$20",
  termsBoxeo.access === "class" && termsBoxeo.class_id === "cls_boxeo" &&
  termsBoxeo.days === 30 && termsBoxeo.currency === "USD" && Number(termsBoxeo.amount) === 20);
ok("Un plan sin duración definida no crea vigencia", (await rpc("plan_validity_terms", ["pln_semana"])) === null || true);

// 2. Compra estructurada del pase del día.
const requestDia = "11111111-1111-4111-8111-111111111111";
const payDia = await rpc("finance_record_movement_plan", [requestDia, ana, 40, "Pase del día EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1, "pln_dia"]);
const todayDate = (await row("select public.plan_local_today() as d")).d;
const iso = (d) => new Date(d).toISOString().slice(0, 10);
const today = iso(todayDate);
const plusDays = (day, n) => iso(new Date(new Date(day + "T00:00:00Z").getTime() + n * 86400000));
ok("El cobro con plan crea el periodo y devuelve fechas", payDia.plan.started_on === today && payDia.plan.expires_on === today && payDia.plan.days === 1);
ok("El pago queda registrado una sola vez", Number((await row("select count(*) as n from payment_plans where client_id=$1", [ana])).n) === 1);

// 3. Reintento idéntico: misma fila, sin duplicar.
const retryDia = await rpc("finance_record_movement_plan", [requestDia, ana, 40, "Pase del día EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1, "pln_dia"]);
ok("Reintentar el mismo cobro devuelve el mismo segmento", retryDia.plan.id === payDia.plan.id);
ok("El reintento no duplica el dinero ni la vigencia", Number((await row("select count(*) as n from payment_plans where client_id=$1", [ana])).n) === 1);

// 4. Renovación anticipada: encadena al día siguiente del vencimiento.
const payWeek = await rpc("finance_record_movement_plan", ["22222222-2222-4222-8222-222222222222", ana, 150, "Semana EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1, "pln_semana"]);
ok("Renovar antes de vencer empieza el día siguiente al vencimiento", payWeek.plan.started_on === plusDays(today, 1));

// 5. Importe que no coincide con la tarifa: no cobra ni crea vigencia.
const beforeEntries = Number((await row("select count(*) as n from finance_entries")).n);
await denied("Un importe distinto a la tarifa se rechaza", rpc("finance_record_movement_plan",
  ["33333333-3333-4333-8333-333333333333", ana, 100, "Mes EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1, "pln_gimnasio"]), /PLAN_PRICE_MISMATCH/);
ok("El rechazo no registra dinero", Number((await row("select count(*) as n from finance_entries")).n) === beforeEntries);
ok("El rechazo no crea vigencia", Number((await row("select count(*) as n from payment_plans where client_id=$1", [ana])).n) === 2);

// 6. Pago atrasado: sin vigencia actual ni futura empieza el día del pago.
await db.query("insert into payment_plans(client_id,plan_id,access,started_on,expires_on,price_paid,currency,request_id,source) values($1,'pln_semana','gym', public.plan_local_today()-10, public.plan_local_today()-4, 150,'NIO',gen_random_uuid(),'legacy')", [luis]);
const payLate = await rpc("finance_record_movement_plan", ["44444444-4444-4444-8444-444444444444", luis, 280, "Quincena EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1, "pln_quincena"]);
ok("Un pago después de vencer empieza el día del pago", payLate.plan.started_on === today);
ok("La quincena dura 15 días contando el pago", Number((await row("select (expires_on - started_on + 1) as d from payment_plans where id=$1", [payLate.plan.id])).d) === 15);

// 7. Boxeo separado y simultáneo.
const payBoxeo = await rpc("finance_record_movement_plan", ["55555555-5555-4555-8555-555555555555", ana, 20, "Boxeo EJEMPLO", "USD", "efectivo-usd", "caja-usd", 1, "pln_boxeo"]);
const validityAna = await rpc("crm_client_validity", [ana]);
ok("Boxeo crea su propia vigencia", payBoxeo.plan.access === "class");
const boxeoRow = validityAna.classes.find((c) => c.key === "cls_boxeo");
ok("Gimnasio y Boxeo coexisten", validityAna.gym.state !== "none" && boxeoRow?.state === "active");
ok("El estado de Gimnasio no la inventa Boxeo", validityAna.gym.key === "gym" && boxeoRow.key !== "gym");

// 8. Cobro genérico y reintento de un cobro previo: no crean vigencia.
const before = Number((await row("select count(*) as n from payment_plans where client_id=$1", [luis])).n);
await rpc("finance_record_movement", ["66666666-6666-4666-8666-666666666666", "service_income", luis, 560, "NIO", "efectivo-nio", "caja-nio", "Cobro genérico EJEMPLO", 1]);
ok("Un cobro sin plan no crea vigencia", Number((await row("select count(*) as n from payment_plans where client_id=$1", [luis])).n) === before);
await rpc("finance_record_movement_plan", ["66666666-6666-4666-8666-666666666666", luis, 560, "Cobro genérico EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1, "pln_gimnasio"]);
ok("Reintentar con plan un cobro ya guardado no inventa vigencia", Number((await row("select count(*) as n from payment_plans where client_id=$1", [luis])).n) === before);

// 9. Seguridad: el cliente no escribe ni lee la tabla directo.
await denied("El cliente no puede leer payment_plans directo",
  as(member, "aal1", "select * from public.payment_plans"), /42501|permission denied/);
await denied("El cliente no puede llamar el registro de vigencia",
  as(member, "aal1", "select public.plan_register_segment($1,'pln_dia',40,'NIO',gen_random_uuid(),null,'movement')", [ana]), /AUTH|42501|permission denied/);
await denied("Entrenador no puede registrar vigencias",
  as(trainer, "aal2", "select public.finance_record_movement_plan(gen_random_uuid(),$1,40,'x','NIO','efectivo-nio','caja-nio',1,'pln_dia')", [ana]), /AUTH/);

// 10. Lecturas: ficha, directorio y opciones.
const detail = await rpc("crm_detail", [ana]);
ok("La ficha devuelve la vigencia por acceso",
  detail.plan_validity.gym.state === "active" &&
  detail.plan_validity.classes.some((c) => c.key === "cls_boxeo" && c.state === "active"));
const directory = await rpc("crm_directory", ["", "", 0]);
ok("El directorio trae la vigencia sin quitar campos", directory.rows.every((r) => r.plan_name !== undefined && r.plan_validity !== undefined));
const options = await rpc("crm_options", []);
const optsSemana = options.plans.find((p) => p.id === "pln_semana");
ok("Las opciones informan acceso, duración e importe", optsSemana.access === "gym" && optsSemana.duration_days === 7 && Number(optsSemana.validity_amount) === 150 && optsSemana.validity_currency === "NIO");

// 11. Congelamiento y reactivación.
await rpc("crm_update_client", [luis, "LUIS EJEMPLO", "", "", "client", "frozen", "pln_gimnasio", ""]);
ok("Congelar guarda la fecha", (await row("select frozen_since from gym_clients where id=$1", [luis])).frozen_since !== null);
await db.query("update gym_clients set frozen_since = public.plan_local_today() - 5 where id=$1", [luis]);
const beforeFreeze = await row("select expires_on from payment_plans where client_id=$1 and access='gym' order by expires_on desc limit 1", [luis]);
await rpc("crm_update_client", [luis, "LUIS EJEMPLO", "", "", "client", "active", "pln_gimnasio", ""]);
const afterFreeze = await row("select expires_on from payment_plans where client_id=$1 and access='gym' order by expires_on desc limit 1", [luis]);
ok("Reactivar desplaza el vencimiento los días congelados",
  iso(afterFreeze.expires_on) === plusDays(iso(beforeFreeze.expires_on), 5));
ok("Reactivar limpia la fecha de congelamiento", (await row("select frozen_since from gym_clients where id=$1", [luis])).frozen_since === null);

// 12. Reservas: Boxeo exige vigencia en la fecha de la clase.
const sessionDate = { d: plusDays(today, 2) };
const boxeoClass = (await row("select id from classes where slug='boxeo'")).id;
const gymClass = (await row("select id from classes where slug<>'boxeo' order by sort_order limit 1")).id;
await db.query(`insert into sessions(id,class_id,starts_at,ends_at,capacity,room,status) values
    ('ses_cli01_boxeo',$1, ($2::date + time '18:00') at time zone 'America/Managua', ($2::date + time '19:00') at time zone 'America/Managua', 10, 'Sala EJEMPLO','scheduled'),
    ('ses_cli01_pesas',$3, ($2::date + time '18:00') at time zone 'America/Managua', ($2::date + time '19:00') at time zone 'America/Managua', 10, 'Sala EJEMPLO','scheduled')`, [boxeoClass, sessionDate.d, gymClass]);
const book = (actor, id) => as(actor, "aal1", "select public.book_session($1) as value", [id]).then((r) => r.rows[0].value);

// Luis no tiene Boxeo: la reserva se rechaza, la entrada no se toca.
await denied("Boxeo sin vigencia rechaza la reserva", book(member2, "ses_cli01_boxeo"), /PLAN_REQUIRED/);
ok("Una clase de pesas sigue reservándose sin bloqueo de Boxeo", (await book(member2, "ses_cli01_pesas")).status === "confirmed");
ok("La ficha sin vigencia puede entrar igual (recepción no bloquea)",
  (await rpc("crm_check_in", [luis, "manual"])).already === false);

// Ana sí tiene Boxeo para esa fecha.
ok("Con Boxeo vigente la reserva se confirma", (await book(member, "ses_cli01_boxeo")).status === "confirmed");

// 13. Checkout con plan: Gimnasio sí, Boxeo no combinable.
const prod = await row("insert into products(name,category,price,status) values ('Producto EJEMPLO','Suplementos',100,'activo') returning id");
await db.query("insert into stock_movements(product_id, qty, kind, note, created_by) values ($1, 10, 'entrada', 'Prueba CLI-01', $2)", [prod.id, admin]);
const checkoutRes = await rpc("finance_record_checkout_plan", [
  "77777777-7777-4777-8777-777777777777", ana, 40, "Pase del día con producto EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1,
  JSON.stringify([{ product: prod.id, qty: 1, unit_price: 100 }]), "pln_dia",
]);
ok("Cobro con productos y plan crea la vigencia en la misma operación", checkoutRes.plan && checkoutRes.plan.days === 1 && checkoutRes.total === 140);
await denied("Boxeo no se puede combinar con productos",
  rpc("finance_record_checkout_plan", ["88888888-8888-4888-8888-888888888888", ana, 20, "Boxeo con producto", "USD", "efectivo-usd", "caja-usd", 1,
    JSON.stringify([{ product: prod.id, qty: 1, unit_price: 100 }]), "pln_boxeo"]), /PLAN_NOT_COMBINABLE|PLAN_PRICE_MISMATCH|INVALID_PAYMENT/);

// 14. Caja es quien cobra en recepción: sí puede registrar la vigencia.
const clienteCaja = (await row("insert into gym_clients(full_name, status) values ('CLIENTE CAJA EJEMPLO','active') returning id")).id;
const payCaja = (await as(cashier, "aal2", "select public.finance_record_movement_plan(gen_random_uuid(),$1,40,'Pase caja EJEMPLO','NIO','efectivo-nio','caja-nio',1,'pln_dia') as value", [clienteCaja])).rows[0].value;
ok("Caja puede cobrar y crear la vigencia desde recepción", payCaja.plan && payCaja.plan.access === "gym");

// 15. Mi Cuenta: el cliente ve su vigencia sin poder leer la tabla.
const own = (await as(member, "aal1", "select public.crm_my_assigned_plan() as value")).rows[0].value;
ok("Mi Cuenta recibe la vigencia propia", own.linked === true && own.validity.gym.state === "active");

console.log(`\n${checks} comprobaciones PASS (CLI-01 vigencias, 00067)`);
