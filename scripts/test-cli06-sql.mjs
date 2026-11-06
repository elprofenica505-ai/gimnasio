// CLI-06: catálogo de planes y modalidades (modelo C).
// Verifica que un plan NUEVO, creado desde Administración, ya se pueda cobrar
// con vigencia propia, sin escribir código por modalidad.
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
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false) and exists(select 1 from public.profiles where id = auth.uid() and role::text in ('admin','cashier'));$$;
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
  "supabase/migrations/00067_vigencias_planes.sql",
  "supabase/migrations/00068_catalogo_planes.sql",
]) {
  await db.exec(sql(f));
}
ok("00068 se aplica sobre 00067 sin error", true);

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
const rpc = async (name, args) =>
  (await asAdmin(`select public.${name}(${args.map((_, i) => `$${i + 1}`).join(",")}) as value`, args)).rows[0].value;
const denied = async (label, promise, pattern) => {
  await assert.rejects(promise, pattern, label);
  ok(label, true);
};

await db.exec(`insert into bank_accounts(id,name,account_type,currency,balance) values('caja-nio','Caja EJEMPLO','caja_fuerte','NIO',1000),('caja-usd','Caja USD EJEMPLO','caja_fuerte','USD',500);
  insert into payment_methods(id,name,currency) values('efectivo-nio','Efectivo EJEMPLO','NIO'),('efectivo-usd','Efectivo USD EJEMPLO','USD');`);

const ana = (await row("select id from gym_clients where profile_id=$1", [member]))?.id ??
  (await row("insert into gym_clients(full_name, status, profile_id) values ('ANA EJEMPLO','active',$1) returning id", [member])).id;
const luis = (await row("select id from gym_clients where profile_id=$1", [member2]))?.id ??
  (await row("insert into gym_clients(full_name, status, profile_id) values ('LUIS EJEMPLO','active',$1) returning id", [member2])).id;

// 1. Los planes existentes quedaron migrados a datos, sin tocar precios.
const termsDia = await rpc("plan_validity_terms", ["pln_dia"]);
ok("Día quedó como gimnasio de 1 día", termsDia.access === "gym" && termsDia.days === 1 && Number(termsDia.amount) === 40);
const termsBoxeo = await rpc("plan_validity_terms", ["pln_boxeo"]);
ok("Boxeo quedó como disciplina de 30 días en USD",
  termsBoxeo.access === "class" && termsBoxeo.class_id === "cls_boxeo" && termsBoxeo.currency === "USD" && Number(termsBoxeo.amount) === 20);
ok("La tarifa NIO de los 4 planes no cambió",
  (await row("select price_nio from public.plans where id='pln_gimnasio'")).price_nio == 560);

// 2. Un plan NUEVO, creado desde Administración, ya tiene vigencia.
const zumba = await rpc("admin_save_plan", [
  null, "Zumba mensual", "Monthly Zumba", "zumba-mensual", "month", 400,
  "class", "cls_zumba", 30, "NIO", 400, true, 6,
]);
ok("El administrador crea Zumba mensual con disciplina y 30 días",
  zumba.slug === "zumba-mensual" && zumba.class_id === "cls_zumba" && zumba.duration_days === 30);
const termsZumba = await rpc("plan_validity_terms", [zumba.id]);
ok("El plan nuevo ya informa su vigencia sin código extra",
  termsZumba.access === "class" && termsZumba.class_id === "cls_zumba" && Number(termsZumba.amount) === 400 && termsZumba.currency === "NIO");

// 3. Ese plan aparece en las opciones de cobro y se puede cobrar.
const options = await rpc("crm_options", []);
const optZumba = options.plans.find((p) => p.slug === "zumba-mensual");
ok("El plan nuevo llega solo a las opciones de cobro",
  optZumba && optZumba.access === "class" && optZumba.duration_days === 30 && Number(optZumba.validity_amount) === 400);

const payZumba = await rpc("finance_record_movement_plan", [
  "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa", ana, 400, "Zumba EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1, zumba.id,
]);
const today = (await row("select public.plan_local_today() as d")).d;
const iso = (d) => new Date(d).toISOString().slice(0, 10);
ok("Cobrar el plan nuevo crea su vigencia",
  payZumba.plan.class_id === "cls_zumba" && payZumba.plan.days === 30 && iso(payZumba.plan.started_on) === iso(today));

// 4. Zumba y gimnasio conviven sin pisarse.
await rpc("finance_record_movement_plan", ["bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb", ana, 560, "Gimnasio EJEMPLO", "NIO", "efectivo-nio", "caja-nio", 1, "pln_gimnasio"]);
const validity = await rpc("crm_client_validity", [ana]);
const zubaRow = validity.classes.find((c) => c.key === "cls_zumba");
ok("Gimnasio y Zumba coexisten con vigencias separadas",
  validity.gym.state === "active" && zubaRow?.state === "active");
ok("Zumba tiene su propio plan y no reemplaza al de gimnasio",
  zubaRow.plan_id === zumba.id && validity.gym.plan_id === "pln_gimnasio");
ok("Quedan dos segmentos separados en la ficha",
  validity.segments.filter((s) => s.access === "gym").length === 1 &&
  validity.segments.filter((s) => s.class_id === "cls_zumba").length === 1);

// 5. Reservas: Zumba ahora exige vigencia porque tiene plan configurado.
const nextDay = new Date(new Date(iso(today) + "T00:00:00Z").getTime() + 2 * 86400000).toISOString().slice(0, 10);
await db.query(`insert into sessions(id,class_id,starts_at,ends_at,capacity,room,status) values
  ('ses_cli06_zumba','cls_zumba', ($1::date + time '18:00') at time zone 'America/Managua', ($1::date + time '19:00') at time zone 'America/Managua', 10, 'Sala EJEMPLO','scheduled')`, [nextDay]);
const book = (actor, id) => as(actor, "aal1", "select public.book_session($1) as value", [id]).then((r) => r.rows[0].value);
await denied("Sin plan de Zumba, la reserva se rechaza", book(member2, "ses_cli06_zumba"), /PLAN_REQUIRED/);
ok("Con plan de Zumba vigente, la reserva se confirma", (await book(member, "ses_cli06_zumba")).status === "confirmed");

// 6. Una disciplina sin planes configurados no se bloquea.
const otherClass = (await row("select id from classes where slug = 'musculacion'")).id;
await db.query(`insert into sessions(id,class_id,starts_at,ends_at,capacity,room,status) values
  ('ses_cli06_otra',$1, ($2::date + time '18:00') at time zone 'America/Managua', ($2::date + time '19:00') at time zone 'America/Managua', 10, 'Sala EJEMPLO','scheduled')`, [otherClass, nextDay]);
ok("Una disciplina sin plan configurado no bloquea reservas", (await book(member2, "ses_cli06_otra")).status === "confirmed");

// 7. Validaciones y seguridad del módulo.
await denied("Caja no puede crear planes", as(cashier, "aal2",
  "select public.admin_save_plan(null,'X EJEMPLO','X',  'x-ejemplo','month',100,'gym',null,30,'NIO',100,true,9)"), /AUTH/);
await denied("Un slug repetido se rechaza", rpc("admin_save_plan", [
  null, "Repetido", "Repeated", "zumba-mensual", "month", 100, "gym", null, 30, "NIO", 100, true, 9,
]), /PLAN_EXISTS/);
await denied("Un plan con disciplina inexistente se rechaza", rpc("admin_save_plan", [
  null, "Fantasma", "Ghost", "fantasma", "month", 100, "class", "cls_no_existe", 30, "NIO", 100, true, 9,
]), /INVALID_CLASS/);
await denied("Duración de 0 días se rechaza", rpc("admin_save_plan", [
  null, "Cero", "Zero", "cero", "month", 100, "gym", null, 0, "NIO", 100, true, 9,
]), /INVALID_DURATION/);
await denied("Un plan sin duración no puede tener moneda de vigencia", rpc("admin_save_plan", [
  null, "Suelto", "Loose", "suelto", "month", 100, null, null, null, "NIO", 100, true, 9,
]), /INVALID_VALIDITY/);

// 8. Un plan sin vigencia sigue siendo cobro genérico.
const loose = await rpc("admin_save_plan", [
  null, "Clase suelta", "Single class", "clase-suelta", "session", 50, null, null, null, null, null, true, 10,
]);
ok("Un plan sin duración se guarda sin vigencia", loose.duration_days === null && (await rpc("plan_validity_terms", [loose.id])) === null);

// 9. Desactivar un plan lo saca de las opciones sin borrar datos.
await rpc("admin_save_plan", [zumba.id, "Zumba mensual", "Monthly Zumba", "zumba-mensual", "month", 400, "class", "cls_zumba", 30, "NIO", 400, false, 6]);
const optionsOff = await rpc("crm_options", []);
ok("Un plan desactivado no se ofrece para cobrar", !optionsOff.plans.some((p) => p.slug === "zumba-mensual"));
ok("Desactivarlo no borra la vigencia ya creada",
  (await row("select count(*) as n from payment_plans where plan_id=$1", [zumba.id])).n > 0);

// 10. El catálogo del administrador trae todo lo necesario.
const catalog = await rpc("admin_plans_catalog", []);
ok("El catálogo administrativo lista planes y disciplinas",
  catalog.plans.length >= 6 && catalog.classes.some((c) => c.slug === "zumba"));
ok("El catálogo informa la vigencia de cada plan",
  catalog.plans.find((p) => p.slug === "gimnasio-mensual").duration_days === 30);

console.log(`\n${checks} comprobaciones PASS (CLI-06 catálogo de planes, 00068)`);
