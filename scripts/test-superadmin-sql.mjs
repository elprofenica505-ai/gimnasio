// SÚPER ADMINISTRADOR: la cuenta del dueño del aplicativo es intocable
// desde la app y sus helpers la tratan como administrador. Sobre la cadena
// completa + 00099 (embudo) + 00100.
import { createTestDb, sqlFile } from "./helpers/sql-test-db.mjs";
import assert from "node:assert/strict";

let checks = 0;
const ok = (label, cond) => {
  assert.ok(cond, label);
  checks += 1;
  console.log(`✅ ${label}`);
};
const esperoError = async (fn, codigo) => {
  try {
    await fn();
    return false;
  } catch (e) {
    return String(e?.message ?? e).includes(codigo);
  }
};
const esperoFalla = async (fn) => {
  try {
    await fn();
    return false;
  } catch {
    return true;
  }
};

const db = await createTestDb();
await db.exec(sqlFile("supabase/migrations/00099_embudo_de_ventas.sql"));
await db.exec(sqlFile("supabase/migrations/00100_superadministrador.sql"));
ok("00100 se aplica sobre la cadena completa (con 00099) sin error", true);

const row = async (query, args = []) => (await db.query(query, args)).rows[0];
const makeUser = async (email, role) => {
  const id = (await row("insert into auth.users(email, raw_user_meta_data) values ($1,$2) returning id", [
    email,
    JSON.stringify({ full_name: "EJEMPLO " + email }),
  ])).id;
  if (role) await db.query("update public.profiles set role=$2::public.user_role where id=$1", [id, role]);
  return id;
};
async function as(actor, aal, query, args = []) {
  await db.exec("reset role; delete from auth.current_user");
  if (actor) await db.query("insert into auth.current_user values($1,$2)", [actor, aal]);
  await db.exec(`set role ${actor ? "authenticated" : "anon"}`);
  try {
    return await db.query(query, args);
  } finally {
    await db.exec("reset role; delete from auth.current_user");
  }
}

// ---- Fixtures ------------------------------------------------------------
ok("el enum user_role tiene el valor superadmin",
  (await row("select 'superadmin' = any (enum_range(null::public.user_role)::text[]) as si")).si);

const superadmin = await makeUser("owner@test.invalid", "superadmin");
const admin = await makeUser("admin@test.invalid", "admin");
const cashier = await makeUser("caja@test.invalid", "cashier");
const trainer = await makeUser("profe@test.invalid", "trainer");
const member = await makeUser("socio@test.invalid", "member");

// staff_members para la prueba de baja (columnas NOT NULL del formulario).
const staffRow = (uid, nombre) => [
  uid, nombre, "001-010480-1002K", "1985-04-10", "88880000", "Barrrio El Dorado, Managua",
  "Contacto Emergencia", "88881111", "Dueño del aplicativo", "2024-01-15",
];
await db.query(
  `insert into public.staff_members (profile_id, full_name, national_id, birth_date, phone, address,
     emergency_name, emergency_phone, position_title, hired_on) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
  staffRow(superadmin, "DUEÑO OWNER"));
await db.query(
  `insert into public.staff_members (profile_id, full_name, national_id, birth_date, phone, address,
     emergency_name, emergency_phone, position_title, hired_on) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
  staffRow(admin, "ADMIN PRUEBA"));

const cliente = (await db.query(
  "insert into public.gym_clients (full_name, phone, category) values ('Cliente Prueba','88880001','client') returning id"
)).rows[0].id;

const lead = (await db.query(
  "insert into public.embudo_leads (full_name, phone) values ('Interesado Prueba','88880002') returning id"
)).rows[0].id;

// ---- Helpers: superadmin es admin y es staff ------------------------------
ok("superadmin: is_admin() = true",
  (await as(superadmin, "aal2", "select public.is_admin() as r")).rows[0].r === true);
ok("superadmin: crm_is_staff() = true",
  (await as(superadmin, "aal2", "select public.crm_is_staff() as r")).rows[0].r === true);
ok("admin: is_admin() sigue funcionando igual (regresión cero)",
  (await as(admin, "aal2", "select public.is_admin() as r")).rows[0].r === true);
ok("sin MFA (aal1) nadie es admin, ni siquiera superadmin",
  (await as(superadmin, "aal1", "select public.is_admin() as r")).rows[0].r === false);

// ---- admin_set_role: blindaje --------------------------------------------
await as(admin, "aal2", "select public.admin_set_role($1, 'trainer')", [cashier]);
ok("admin sigue cambiando roles normales (caja → entrenador)", true);

ok("admin NO puede otorgar superadmin",
  await esperoError(
    () => as(admin, "aal2", "select public.admin_set_role($1, 'superadmin')", [trainer]),
    "SUPERADMIN_PROTECTED"));
ok("admin NO puede degradar al superadmin",
  await esperoError(
    () => as(admin, "aal2", "select public.admin_set_role($1, 'member')", [superadmin]),
    "SUPERADMIN_PROTECTED"));
await as(superadmin, "aal2", "select public.admin_set_role($1, 'cashier')", [trainer]);
ok("superadmin sí gestiona personal (entrenador → caja)", true);
ok("ni otro superadmin puede otorgar el rol",
  await esperoError(
    () => as(superadmin, "aal2", "select public.admin_set_role($1, 'superadmin')", [cashier]),
    "SUPERADMIN_PROTECTED"));
ok("el rol del superadmin quedó intacto en la bitácora",
  (await row("select role::text as r from public.profiles where id = $1", [superadmin])).r === "superadmin");

// ---- Guardián del perfil: UPDATE directo e INSERT --------------------------
ok("UPDATE directo al rol del superadmin queda bloqueado (revoca + trigger)",
  await esperoFalla(() => as(admin, "aal2", "update public.profiles set role = 'member' where id = $1", [superadmin]))
  && (await row("select role::text as r from public.profiles where id = $1", [superadmin])).r === "superadmin");

ok("DELETE del superadmin queda bloqueado (revoca + trigger)",
  await esperoFalla(() => as(admin, "aal2", "delete from public.profiles where id = $1", [superadmin]))
  && !!(await row("select 1 from public.profiles where id = $1", [superadmin])));

ok("INSERT de un perfil superadmin desde la app queda bloqueado (revoca + trigger)",
  await esperoFalla(
    () => as(admin, "aal2",
      "insert into public.profiles (id, email, full_name, role) values (gen_random_uuid(), 'x@test.invalid', 'X Y', 'superadmin')"),
  )
  && !(await row("select 1 from public.profiles where email = 'x@test.invalid'")));

ok("member no puede subir su propio rol (queda bloqueado)",
  await esperoFalla(
    () => as(member, "aal2", "update public.profiles set role = 'admin' where id = $1", [member]),
  ));

// ---- Baja de personal ------------------------------------------------------
ok("staff_set_status NO puede dar de baja al superadmin",
  await esperoError(
    () => as(admin, "aal2", "select public.staff_set_status($1, false, 'razón de prueba larga')", [superadmin]),
    "SUPERADMIN_PROTECTED"));

// ---- Válvula de escape: sólo la consola (sin sesión) toca el rol -----------
await db.query("update public.profiles set role = 'admin' where id = $1", [superadmin]);
ok("por consola (sin sesión) sí se puede degradar al superadmin", true);
await db.query("update public.profiles set role = 'superadmin' where id = $1", [superadmin]);
ok("y por consola se restaura el superadmin", true);

// ---- Superadmin en el día a día --------------------------------------------
await as(superadmin, "aal2",
  "select public.crm_update_client($1, 'Cliente Prueba', '88880001', null, 'friend', 'active', null, null)", [cliente]);
ok("superadmin puede editar ficha con cambio de categoría (00067 cubierto)", true);

await as(superadmin, "aal2", "select public.embudo_avanzar_lead($1, 'contactado', null)", [lead]);
ok("superadmin puede operar el embudo (ventas online)", true);

console.log(`\n🧪 ${checks} comprobaciones del súper administrador`);
process.exit(0);
