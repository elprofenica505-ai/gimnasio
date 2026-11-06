import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const db = new PGlite();
await db.exec(`
 create schema auth;
 create role anon nologin; create role authenticated nologin;
 create table auth.users(id uuid primary key default gen_random_uuid(),email text,raw_user_meta_data jsonb default '{}'::jsonb,created_at timestamptz default now());
 create table auth.current_user(id uuid);
 create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
 grant usage on schema auth to anon,authenticated; grant select on auth.current_user to anon,authenticated;
`);
for (const file of [
  "00001_schema.sql",
  "tests/fixtures/base-catalog.sql",
  "00010_finance.sql",
  "00011_finance_seed.sql",
  "00012_profiles_self_read.sql",
  "00020_clients_crm.sql",
])
  await db.exec(
    readFileSync(
      new URL(
        file.startsWith("tests/")
          ? `../${file}`
          : `../supabase/migrations/${file}`,
        import.meta.url,
      ),
      "utf8",
    ),
  );

// Cuentas de caja neutras para la suite: 00011 ya no trae cuentas del
// gimnasio anterior (semilla desarmada); cada instalación configura las suyas.
await db.exec(
  "insert into public.accounts (id, slug, name, kind, currency, holder_name) values" +
    " ('acc_test_nio','caja-test-nio','Caja de prueba (C$)','cash','NIO','Gimnasio de prueba')," +
    " ('acc_test_usd','caja-test-usd','Caja de prueba (US$)','cash','USD','Gimnasio de prueba')" +
    " on conflict (id) do nothing;",
);
const nativeWriterQuery =
  "select pg_get_functiondef(oid) as definition from pg_proc where pronamespace='public'::regnamespace and proname='record_payment' order by oid";
const nativeWriterBefore = JSON.stringify(
  (await db.query(nativeWriterQuery)).rows,
);
const migration = readFileSync(
  new URL("../supabase/FASE2.sql", import.meta.url),
  "utf8",
);
await db.exec(migration); // idempotencia
let count = 0;
function check(label, test) {
  assert.ok(test, label);
  console.log(`  ✅ ${label}`);
  count++;
}
const row = async (sql, args = []) => (await db.query(sql, args)).rows[0];
async function as(id, sql, args = []) {
  await db.exec("reset role; delete from auth.current_user;");
  if (id) await db.query("insert into auth.current_user values($1)", [id]);
  await db.exec(`set role ${id ? "authenticated" : "anon"};`);
  try {
    return await db.query(sql, args);
  } finally {
    await db.exec("reset role; delete from auth.current_user;");
  }
}
async function reject(id, sql, args, fragment) {
  try {
    await as(id, sql, args);
    assert.fail(`debía rechazar: ${fragment}`);
  } catch (e) {
    if (e.code === "ERR_ASSERTION") throw e;
    assert.ok(e.message.includes(fragment), e.message);
    count++;
    console.log(`  ✅ rechaza ${fragment}`);
  }
}
console.log("\n▶ FASE 2: CRM, permisos, QR y cobros");
const admin = (
  await row(
    "insert into auth.users(email,raw_user_meta_data) values('admin@test.invalid','{\"full_name\":\"Admin prueba\"}') returning id",
  )
).id;
const staff = (
  await row(
    "insert into auth.users(email,raw_user_meta_data) values('staff@test.invalid','{\"full_name\":\"Recepción prueba\"}') returning id",
  )
).id;
const member = (
  await row(
    "insert into auth.users(email,raw_user_meta_data) values('cliente@test.invalid','{\"full_name\":\"Cliente prueba\"}') returning id",
  )
).id;
await db.query("update public.profiles set role='admin' where id=$1", [admin]);
await db.query("update public.profiles set role='staff' where id=$1", [staff]);
check(
  "profile web crea ficha vinculada, sin otra tabla de usuarios",
  !!(await row("select id from public.gym_clients where profile_id=$1", [
    member,
  ])),
);
const usersBefore = (await row("select count(*)::int as n from auth.users")).n;
const id = (
  await as(staff, "select public.crm_create_client($1) as id", [
    "Cliente sin celular",
  ])
).rows[0].id;
check(
  "alta rápida sin email, teléfono ni auth.users",
  usersBefore === (await row("select count(*)::int as n from auth.users")).n,
);
await reject(
  staff,
  "select public.crm_create_client($1)",
  ["Cliente sin celular"],
  "DUPLICATE_CLIENT",
);
await reject(
  staff,
  "insert into public.gym_clients(full_name) values('Inserción directa')",
  [],
  "permission denied",
);
const token = (await as(staff, "select public.crm_get_card($1) as token", [id]))
  .rows[0].token;
check(
  "QR resuelve a ficha sin datos personales en token",
  (await as(staff, "select public.crm_find_card($1) as id", [token])).rows[0]
    .id === id,
);
await reject(member, "select public.crm_directory()", [], "AUTH");
await reject(null, "select public.crm_directory()", [], "permission denied");
await reject(member, "select public.crm_find_card($1)", [token], "AUTH");
check(
  "RLS oculta directorio al cliente",
  (await as(member, "select * from public.gym_clients")).rows.length === 0,
);
await reject(
  staff,
  "select * from public.client_cards",
  [],
  "permission denied",
);
await reject(
  member,
  "update public.profiles set role='admin' where id=auth.uid()",
  [],
  "permission denied",
);
check(
  "perfil no fue promovido",
  (await row("select role from public.profiles where id=$1", [member])).role ===
    "member",
);
await reject(member, "select public.crm_get_card($1)", [id], "AUTH");
const pass = (await as(member, "select public.crm_my_pass() as p")).rows[0].p;
check(
  "carnet propio sólo entrega ficha vinculada",
  pass.name === "Cliente prueba" && !!pass.token,
);
const update = "select public.crm_update_client($1,$2,$3,$4,$5,$6,$7,$8)";
await reject(
  staff,
  update,
  [id, "Cliente sin celular", "", "", "family", "active", "", ""],
  "ADMIN_ONLY",
);
await as(admin, update, [
  id,
  "Cliente sin celular",
  "",
  "",
  "family",
  "active",
  "",
  "Preferencia comercial de prueba",
]);
const tagBefore = (
  await row("select category from public.gym_clients where id=$1", [id])
).category;
await reject(
  member,
  "select public.crm_check_in($1,$2,$3)",
  [id, "qr", token],
  "AUTH",
);
await reject(
  staff,
  "select public.crm_check_in($1,$2,$3)",
  [id, "qr", null],
  "INVALID_CARD",
);
const first = (
  await as(staff, "select public.crm_check_in($1,$2,$3) as r", [
    id,
    "qr",
    token,
  ])
).rows[0].r;
const second = (
  await as(staff, "select public.crm_check_in($1,$2) as r", [id, "manual"])
).rows[0].r;
check(
  "primera entrada sí; reescaneo/entrada manual no duplica",
  !first.already && second.already && first.id === second.id,
);
check(
  "escanear y entrar no crea cobros",
  (
    await row(
      "select count(*)::int as n from public.transactions where client_id=$1",
      [id],
    )
  ).n === 0,
);
check(
  "día de asistencia usa Nicaragua",
  (
    await row(
      "select local_day=(now() at time zone 'America/Managua')::date as ok from public.client_visits where id=$1",
      [first.id],
    )
  ).ok,
);
const newToken = (
  await as(staff, "select public.crm_rotate_card($1) as token", [id])
).rows[0].token;
check("reemplazar carnet cambia token", token !== newToken);
await reject(staff, "select public.crm_find_card($1)", [token], "INVALID_CARD");
await reject(
  staff,
  "select public.crm_check_in($1,$2,$3)",
  [id, "qr", token],
  "INVALID_CARD",
);
await as(admin, update, [
  id,
  "Cliente sin celular",
  "",
  "",
  "family",
  "frozen",
  "",
  "",
]);
await reject(
  staff,
  "select public.crm_check_in($1,$2)",
  [id, "manual"],
  "INACTIVE",
);
await as(admin, update, [
  id,
  "Cliente sin celular",
  "",
  "",
  "family",
  "active",
  "",
  "",
]);
const directory = (
  await as(staff, "select public.crm_directory($1,$2) as d", [
    "sin celular",
    "family",
  ])
).rows[0].d;
check(
  "filtros por nombre/etiqueta con frecuencia real",
  directory.total === 1 && directory.rows[0].visits_30 === 1,
);
check(
  "no autoasigna etiquetas por visitas",
  (await row("select category from public.gym_clients where id=$1", [id]))
    .category === tagBefore,
);
const cash = (
  await row(
    "select id from public.accounts where currency='NIO' and is_active limit 1",
  )
).id;
const method = (
  await row(
    "select id from public.payment_methods where accepts_nio and is_active limit 1",
  )
).id;
const request = "cf000000-0000-4000-8000-000000000001";
const payment =
  "select public.crm_record_payment($1,$2,$3,$4,$5,$6,$7,$8) as id";
const args = [
  id,
  request,
  350,
  "NIO",
  method,
  cash,
  "Entrenamiento de prueba",
  1,
];
const paid = (await as(staff, payment, args)).rows[0].id;
const retry = (await as(staff, payment, args)).rows[0].id;
check(
  "cobro crea una transacción y reintentar no duplica",
  paid === retry &&
    (
      await row(
        "select count(*)::int as n from public.transactions where crm_request_id=$1",
        [request],
      )
    ).n === 1,
);
check(
  "pago sin cuenta web se vincula a ficha CRM",
  (
    await row(
      "select member_id,client_id,base_amount from public.transactions where id=$1",
      [paid],
    )
  ).client_id === id,
);
const conflict = [...args];
conflict[2] = 400;
await reject(staff, payment, conflict, "REQUEST_CONFLICT");
await reject(member, payment, args, "AUTH");
const bad = [...args];
bad[1] = "cf000000-0000-4000-8000-000000000002";
bad[3] = "USD";
bad[4] = (
  await row(
    "select id from public.payment_methods where accepts_usd and is_active limit 1",
  )
).id;
await reject(staff, payment, bad, "INVALID_ACCOUNT");
const detail = (await as(staff, "select public.crm_detail($1) as d", [id]))
  .rows[0].d;
check(
  "historial separado de cobros/entradas/cambios",
  detail.visits.length === 1 &&
    detail.payments.length === 1 &&
    detail.events.some((e) => e.action === "updated"),
);
check(
  "sin cuenta financiera vinculada no inventa saldo",
  detail.balance === null,
);
const financeOptions = (await as(staff, "select public.crm_options() as value"))
  .rows[0].value;
check(
  "modelo original conserva cobros habilitados",
  financeOptions.payments_enabled === true &&
    financeOptions.finance_layout === "repository",
);
check(
  "opciones originales conservan métodos y cuentas",
  financeOptions.methods.length > 0 && financeOptions.accounts.length > 0,
);
await reject(member, "select public.crm_options()", [], "AUTH");
await reject(
  staff,
  "select public.crm_record_payment_repository($1,$2,$3,$4,$5,$6,$7,$8)",
  args,
  "permission denied",
);
const imported = (
  await as(staff, "select public.crm_import_client($1) as r", [
    JSON.stringify({
      fullName: "Cliente CSV sin correo",
      birthdate: "1997-05-12",
      address: "Dirección de prueba",
    }),
  ])
).rows[0].r;
const dup = (
  await as(staff, "select public.crm_import_client($1) as r", [
    JSON.stringify({ fullName: "Cliente CSV sin correo" }),
  ])
).rows[0].r;
check(
  "CSV sin correo y reintento sin duplicar",
  imported.imported && !dup.imported && imported.id === dup.id,
);
check(
  "importación conserva campos opcionales",
  (
    await row("select address from public.gym_clients where id=$1", [
      imported.id,
    ])
  ).address === "Dirección de prueba",
);
await reject(
  staff,
  "select public.crm_create_client($1,$2,$3,$4)",
  ["Plan inválido", null, null, "inexistente"],
  "foreign key",
);
const seed = readFileSync(
  new URL("../supabase/migrations/00021_clients_seed.sql", import.meta.url),
  "utf8",
);
await db.exec(seed);
const seedBefore = (
  await row("select count(*)::int as n from public.client_visits")
).n;
await db.exec(seed);
check(
  "seed opcional (vaciada): cero fichas ficticias, cero datos ajenos",
  (await row("select count(*)::int as n from public.gym_clients where is_demo"))
    .n === 0,
);
check(
  "seed idempotente, no duplica asistencias",
  (await row("select count(*)::int as n from public.client_visits")).n ===
    seedBefore,
);
await db.exec("begin read only");
const writerMetadata = await db.query(
  readFileSync(
    new URL(
      "../supabase/DIAGNOSTICO-ESCRITURA-FINANCIERA.sql",
      import.meta.url,
    ),
    "utf8",
  ),
);
const writerData = JSON.parse(writerMetadata.rows[0].diagnostico);
check(
  "diagnóstico nativo identifica escritor de saldos y vistas sin ejecutarlos",
  writerData.funciones.some((f) => f.nombre === "update_member_balance") &&
    writerData.vistas.some((v) => v.nombre === "v_daily_cash"),
);
await db.exec("rollback");
check(
  "00023 no reemplaza escritor ni reglas del modelo nativo",
  JSON.stringify((await db.query(nativeWriterQuery)).rows) ===
    nativeWriterBefore,
);
await reject(
  staff,
  "select finance_read('summary')",
  [],
  "FINANCE_SCHEMA_UNSUPPORTED",
);
await reject(member, "select finance_read('summary')", [], "AUTH");
await reject(null, "select finance_read('summary')", [], "permission denied");
const optionalBankSeed = readFileSync(
  new URL("../supabase/EJEMPLOS-CAJA-OPCIONAL.sql", import.meta.url),
  "utf8",
);
await assert.rejects(db.exec(optionalBankSeed), /FINANCE_SCHEMA_UNSUPPORTED/);
await db.exec("rollback");
check(
  "seed de cuentas bank_accounts rechaza esquema nativo sin crear tabla paralela",
  !(await row("select to_regclass('public.bank_accounts') as t")).t,
);
await assert.rejects(
  db.exec(
    readFileSync(
      new URL(
        "../supabase/migrations/00024_finance_movements.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  ),
  /FINANCE_SCHEMA_UNSUPPORTED/,
);
await db.exec("rollback");
check(
  "actualización bancaria rechaza esquema nativo sin instalación parcial",
  !(await db.query("select to_regclass('public.finance_entries') as t")).rows[0]
    .t,
);
await db.close();
console.log(`\n🎉 CRM: ${count} comprobaciones pasaron\n`);
