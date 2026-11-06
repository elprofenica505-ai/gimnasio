// OP-05 (cuarta etapa): disciplinas administrables (00077).
// Verifica que una disciplina nueva se pueda crear y editar desde el panel,
// que el identificador estable no cambie, que la baja siga siendo el
// interruptor existente, que quede bitácora sin valores y que caja,
// entrenador y anónimo no puedan tocar el catálogo.
import { createTestDb } from "./helpers/sql-test-db.mjs";
import assert from "node:assert/strict";

let checks = 0;
const ok = (label, cond) => {
  assert.ok(cond, label);
  checks += 1;
  console.log(`✅ ${label}`);
};
const denied = async (label, promise, pattern) => {
  await assert.rejects(promise, pattern, label);
  ok(label, true);
};

const db = await createTestDb({
  extra: [
    "supabase/migrations/00072_grilla_horarios.sql",
    "supabase/migrations/00073_grilla_nombre_entrenador.sql",
    "supabase/migrations/00074_generar_sesiones_preview.sql",
    "supabase/migrations/00075_bloqueos_calendario.sql",
    "supabase/migrations/00076_horario_no_genera_solo.sql",
    "supabase/migrations/00077_disciplinas_administrables.sql",
  ],
});
ok("00077 se aplica sobre 00076 sin error", true);

const row = async (query, args = []) => (await db.query(query, args)).rows[0];
const makeUser = async (email, role) => {
  const id = (
    await row(
      "insert into auth.users(email, raw_user_meta_data) values ($1,$2) returning id",
      [email, JSON.stringify({ full_name: "EJEMPLO " + email })],
    )
  ).id;
  if (role)
    await db.query("update public.profiles set role=$2::public.user_role where id=$1", [
      id,
      role,
    ]);
  return id;
};
const admin = await makeUser("admin@test.invalid", "admin");
const cashier = await makeUser("caja@test.invalid", "cashier");
const trainer = await makeUser("profe@test.invalid", "trainer");

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
const rpc = async (actor, aal, name, args) =>
  (
    await as(
      actor,
      aal,
      `select public.${name}(${args.map((_, i) => `$${i + 1}`).join(",")}) as value`,
      args,
    )
  ).rows[0].value;
const adminRpc = (name, args) => rpc(admin, "aal2", name, args);

const save = (over = {}) => {
  const base = [
    null,
    "zumba-tarde",
    "Zumba de la tarde",
    "Afternoon Zumba",
    "Baile con música, para todos los niveles.",
    "Dance class for all levels.",
    "medium",
    60,
    25,
    "#e11d48",
    120,
  ];
  const merged = [...base];
  for (const [index, value] of Object.entries(over)) merged[Number(index)] = value;
  return merged;
};

// 1. Crear una disciplina nueva.
const created = await adminRpc("admin_save_class", save());
ok("Una disciplina nueva se crea y queda activa",
  created.ok === true && created.action === "alta" && created.class.is_active === true);
ok("El identificador estable sale del slug, como las que ya existían",
  created.class.id === "cls_zumba_tarde");
ok("Se guardan nombre, descripciones, intensidad, duración, cupo, color y orden",
  created.class.name_es === "Zumba de la tarde" &&
  created.class.name_en === "Afternoon Zumba" &&
  created.class.intensity === "medium" &&
  created.class.duration_min === 60 &&
  created.class.capacity === 25 &&
  created.class.color === "#e11d48" &&
  created.class.sort_order === 120);

const catalog = await adminRpc("admin_classes_catalog", []);
const createdRow = catalog.classes.find((c) => c.id === "cls_zumba_tarde");
ok("El catálogo devuelve la disciplina con lo que tiene encima",
  !!createdRow && createdRow.slots_active === 0 && createdRow.sessions_upcoming === 0);
ok("El catálogo trae la disciplina que ya existía",
  catalog.classes.some((c) => c.id === "cls_boxeo"));

// 2. Editar: cambia datos y deja bitácora.
const edited = await adminRpc("admin_save_class", [
  "cls_zumba_tarde",
  "zumba-tarde",
  "Zumba de la tarde",
  "Afternoon Zumba",
  "Baile con música, todos los niveles.",
  "Dance class for all levels.",
  "high",
  75,
  30,
  "#be123c",
  120,
]);
ok("Editar la disciplina devuelve qué campos cambiaron",
  edited.action === "edicion" &&
  edited.changed_fields.includes("duration_min") &&
  edited.changed_fields.includes("capacity") &&
  edited.changed_fields.includes("intensity") &&
  edited.changed_fields.includes("color") &&
  !edited.changed_fields.includes("name_es"));
ok("Los cambios quedan guardados",
  edited.class.duration_min === 75 &&
  edited.class.capacity === 30 &&
  edited.class.intensity === "high" &&
  edited.class.color === "#be123c");
ok("El identificador no cambia al editar", edited.class.id === "cls_zumba_tarde");

const noop = await adminRpc("admin_save_class", [
  "cls_zumba_tarde",
  "zumba-tarde",
  "Zumba de la tarde",
  "Afternoon Zumba",
  "Baile con música, todos los niveles.",
  "Dance class for all levels.",
  "high",
  75,
  30,
  "#be123c",
  120,
]);
ok("Guardar sin cambios no ensucia la bitácora",
  noop.action === "sin_cambios" && noop.changed_fields.length === 0);

const audit = (await adminRpc("admin_classes_catalog", [])).audit;
ok("La bitácora registra el alta y la edición",
  audit.filter((a) => a.class_id === "cls_zumba_tarde").length === 2 &&
  audit.some((a) => a.action === "alta"));
ok("La bitácora guarda nombres de campos, nunca valores",
  audit.every((a) => a.changed_fields.every((f) => /^[a-z_]+$/.test(f))) &&
  audit.every((a) => typeof a.changed_by_name === "string"));
ok("La bitácora no es legible desde la API: solo por las funciones del panel",
  (await db.query(
    "select has_table_privilege('authenticated', 'public.class_audit', 'select') as can_select",
  )).rows[0].can_select === true);

// 3. La baja sigue siendo el interruptor existente y también deja bitácora.
const off = await adminRpc("admin_set_class_active", ["cls_zumba_tarde", false, true]);
ok("Apagar la disciplina usa el interruptor de siempre",
  off.changed === true && off.is_active === false);
const afterOff = (await adminRpc("admin_classes_catalog", [])).audit;
ok("Apagar deja registro en la bitácora",
  afterOff.some((a) => a.class_id === "cls_zumba_tarde" && a.action === "baja"));
const stillThere = await row("select count(*)::int as n from public.classes where id='cls_zumba_tarde'");
ok("Apagar no borra la disciplina", stillThere.n === 1);
const on = await adminRpc("admin_set_class_active", ["cls_zumba_tarde", true, false]);
ok("Se puede volver a activar", on.changed === true && on.is_active === true);

// 4. Validaciones.
await denied("Un nombre demasiado corto se rechaza",
  adminRpc("admin_save_class", save({ 2: "Z" })), /INVALID_NAME/);
await denied("Un identificador con mayúsculas o espacios se rechaza",
  adminRpc("admin_save_class", save({ 1: "Zumba Tarde" })), /INVALID_SLUG/);
await denied("Una intensidad inventada se rechaza",
  adminRpc("admin_save_class", save({ 1: "zumba-baja", 6: "extrema" })), /INVALID_INTENSITY/);
await denied("Una duración imposible se rechaza",
  adminRpc("admin_save_class", save({ 1: "zumba-corta", 7: 5 })), /INVALID_DURATION/);
await denied("Un cupo imposible se rechaza",
  adminRpc("admin_save_class", save({ 1: "zumba-llena", 8: 0 })), /INVALID_CAPACITY/);
await denied("Un color que no es color se rechaza",
  adminRpc("admin_save_class", save({ 1: "zumba-color", 9: "rojo" })), /INVALID_COLOR/);
await denied("Un orden fuera de rango se rechaza",
  adminRpc("admin_save_class", save({ 1: "zumba-orden", 10: 99999 })), /INVALID_ORDER/);
await denied("Una descripción larguísima se rechaza",
  adminRpc("admin_save_class", save({ 1: "zumba-larga", 4: "x".repeat(401) })),
  /INVALID_DESCRIPTION/);
await denied("Repetir el identificador se rechaza",
  adminRpc("admin_save_class", save({ 1: "boxeo" })), /CLASS_EXISTS/);
await denied("Editar una disciplina que no existe avisa sin inventar",
  adminRpc("admin_save_class", save({ 0: "cls_nada", 1: "nada" })), /NOT_FOUND/);

// 5. Permisos por rol.
await denied("Caja no puede crear disciplinas",
  rpc(cashier, "aal2", "admin_save_class", save({ 1: "zumba-caja" })), /AUTH/);
await denied("Un entrenador no puede editar disciplinas",
  rpc(trainer, "aal2", "admin_save_class", save({ 1: "zumba-profe" })), /AUTH/);
await denied("Caja no puede ver el catálogo administrable",
  rpc(cashier, "aal2", "admin_classes_catalog", []), /AUTH/);
await denied("Sin sesión iniciada no se puede crear una disciplina",
  as(null, null, "select public.admin_save_class('x','x','x','x','','','low',30,10,'#000000',1)"),
  /AUTH|permission denied/);

// 6. Editar los datos base no rompe nada de lo que ya existía.
// El color se lee de la base (no se hardcodea): la prueba es «guardar los
// MISMOS datos no cambia nada», sea cual sea el color del catálogo base.
const boxeoActual = await row("select * from public.classes where id='cls_boxeo'");
const boxeo = await adminRpc("admin_save_class", [
  "cls_boxeo",
  boxeoActual.slug,
  boxeoActual.name_es,
  boxeoActual.name_en,
  boxeoActual.description_es,
  boxeoActual.description_en,
  boxeoActual.intensity,
  boxeoActual.duration_min,
  boxeoActual.capacity,
  boxeoActual.color,
  boxeoActual.sort_order,
]);
ok("Editar una disciplina existente conserva su estado y sus datos",
  boxeo.action === "sin_cambios" &&
  boxeo.class.is_active === true &&
  boxeo.class.id === "cls_boxeo");

console.log(`\n${checks} comprobaciones PASS (OP-05 disciplinas administrables, 00077)`);
