// Prueba de `finance_movements_page` (migración 00084, FIN-05) con PGlite.
//
// Qué se comprueba, por rol y con datos reales en una base de verdad:
//   · sin segundo factor o siendo socio, la función no devuelve nada (AUTH);
//   · el historial se pagina con total estable y sin filas repetidas;
//   · la búsqueda por texto encuentra concepto y nombre del cliente;
//   · escribir un comodín (`%`) no trae todo el historial;
//   · con el interruptor de gastos apagado, los egresos no se devuelven ni
//     se cuentan;
//   · un movimiento anulado llega con su motivo;
//   · los filtros inválidos se rechazan en vez de devolver otra cosa.
//
// La cadena de migraciones y las definiciones se leen de los archivos reales:
// si mañana cambia `crm_is_staff()` o la tabla `finance_voids`, esta prueba usa
// lo mismo que producción.
import { PGlite } from "@electric-sql/pglite";
import { readFileSync, readdirSync } from "node:fs";
import assert from "node:assert/strict";

const MIGRATIONS = new URL("../supabase/migrations/", import.meta.url);
const sql = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = (file) => readFileSync(new URL(file, MIGRATIONS), "utf8");

const db = new PGlite();
let checks = 0;
const ok = (name, condition) => {
  assert.ok(condition, name);
  checks++;
  console.log(`✅ ${name}`);
};

/** Última definición real de `crm_is_staff()` entre todas las migraciones. */
function finalCrmIsStaff() {
  const files = readdirSync(MIGRATIONS)
    .filter((file) => file.endsWith(".sql"))
    .sort();
  let found = null;
  for (const file of files) {
    const text = migration(file);
    for (const match of text.matchAll(
      /create or replace function public\.crm_is_staff\(\)[\s\S]*?\$\$;/gi,
    )) {
      found = match[0];
    }
  }
  return found;
}

/** Tabla real de anulaciones, tomada de la migración que la creó. */
function financeVoidsTable() {
  const text = migration("00080_anulacion_controlada.sql");
  const match = text.match(
    /create table if not exists public\.finance_voids \([\s\S]*?\n\);/i,
  );
  assert.ok(match, "la 00080 tiene que crear public.finance_voids");
  return match[0];
}

await db.exec(`create schema auth; create role anon nologin; create role authenticated nologin;
  create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}'::jsonb, created_at timestamptz default now());
  create table auth.current_user(id uuid, aal text);
  create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
  create function auth.jwt() returns jsonb language sql stable as $j$select jsonb_build_object('aal', aal) from auth.current_user limit 1$j$;
  grant usage on schema auth to anon, authenticated; grant select on auth.current_user to anon, authenticated;`);

for (const file of [
  "00001_schema.sql",
  "fixtures/base-catalog.sql",
  "fixtures/finance-bank-accounts.sql",
  "00012_profiles_self_read.sql",
  "00020_clients_crm.sql",
  "00022_crm_finance_compat.sql",
  "00023_finance_read_bank_accounts.sql",
  "00024_finance_movements.sql",
  "00027_client_finance_read.sql",
]) {
  await db.exec(
    sql(file.startsWith("fixtures") ? `tests/${file}` : `supabase/migrations/${file}`),
  );
}

// Los roles de caja y entrenador (00033) y la versión vigente de la guardia de
// personal. Se toman de las migraciones reales: si cambian, esto cambia igual.
await db.exec(migration("00033_roles_fase_a.sql"));
await db.exec(finalCrmIsStaff());
await db.exec(financeVoidsTable());
await db.exec(migration("00084_movimientos_paginados.sql"));
// Se aplica dos veces: tiene que ser idempotente.
await db.exec(migration("00084_movimientos_paginados.sql"));

const newUser = async (email, role) => {
  const id = (
    await db.query("insert into auth.users(email) values($1) returning id", [
      `${email}@test.invalid`,
    ])
  ).rows[0].id;
  if (role)
    await db.query("update profiles set role = $2::user_role where id = $1", [
      id,
      role,
    ]);
  return id;
};
const admin = await newUser("admin", "admin");
const cashier = await newUser("caja", "cashier");
const member = await newUser("socio", null);

const as = async (actor, aal, query, args = []) => {
  await db.exec("reset role; delete from auth.current_user");
  if (actor) await db.query("insert into auth.current_user values ($1, $2)", [actor, aal]);
  await db.exec(`set role ${actor ? "authenticated" : "anon"}`);
  try {
    return (await db.query(query, args)).rows;
  } finally {
    await db.exec("reset role; delete from auth.current_user");
  }
};

const page = async (args = {}, actor = cashier, aal = "aal2") =>
  (
    await as(
      actor,
      aal,
      `select public.finance_movements_page(
        p_search => $1, p_direction => $2, p_status => $3, p_currency => $4,
        p_method => $5, p_hide_expenses => $6, p_limit => $7, p_offset => $8) as value`,
      [
        args.search ?? "",
        args.direction ?? "",
        args.status ?? "",
        args.currency ?? "",
        args.method ?? "all",
        args.hideExpenses ?? false,
        args.limit ?? 25,
        args.offset ?? 0,
      ],
    )
  ).at(0).value;

// --- Datos: 30 movimientos, un gasto, un cliente con nombre y una anulada ---
await db.exec(`insert into bank_accounts(id, name, account_type, currency, balance)
  values ('caja_fuerte_nio', 'Caja Fuerte Córdobas', 'caja_fuerte', 'NIO', 0)
  on conflict (id) do nothing`);
const clientId = (
  await db.query(
    `insert into gym_clients(full_name) values('María Ejemplo de la Cruz') returning id`,
  )
).rows[0].id;
// Mismas columnas que usa el escritor de producción (`finance_record_checkout`).
const insertTx = async (values) =>
  (
    await db.query(
      `insert into transactions(occurred_at, type, status, amount, currency, amount_nio, amount_usd, fx_used, method_id, account_id, concept, client_id, created_by)
       values (coalesce($1::timestamptz, now()), $2::transaction_type, 'completed', $3::numeric, $4::text, $3::numeric, round($3::numeric / 40, 4), 40, $5::text, 'caja_fuerte_nio', $6::text, $7::uuid, $8::uuid)
       returning id`,
      [
        values.at ?? null,
        values.direction ?? "income",
        values.amount ?? 40,
        values.currency ?? "NIO",
        values.method ?? null,
        values.concept,
        values.client ?? null,
        values.actor ?? null,
      ],
    )
  ).rows[0].id;

const ids = [];
for (let index = 0; index < 30; index += 1) {
  ids.push(
    await insertTx({
      concept: `Pase EJEMPLO ${index + 1}`,
      at: `2026-10-${String(1 + (index % 28)).padStart(2, "0")}T15:00:00Z`,
    }),
  );
}
const gasId = await insertTx({ concept: "Compra de agua", direction: "expense", amount: 120 });
const aguaId = await insertTx({ concept: "Venta de agua fuente pura", amount: 20 });
const clienteId = await insertTx({
  concept: "Gimnasio mensual",
  client: clientId,
  amount: 560,
});
const anuladaId = await insertTx({ concept: "Cobro que se anula", amount: 10 });
const reversalId = await insertTx({
  concept: "Anulación: cobro que se anula",
  direction: "expense",
  amount: 10,
});
await db.query(
  `insert into finance_voids(request_id, original_id, reversal_id, reason, actor_name, payload, receipt)
   values (gen_random_uuid(), $1, $2, 'Se cargó dos veces', 'Carlos EJEMPLO', '{}'::jsonb, '{}'::jsonb)`,
  [anuladaId, reversalId],
);

// --- 1. Puertas de entrada ---
await assert.rejects(
  as(null, null, "select public.finance_movements_page()"),
  /permission denied|AUTH/i,
);
ok("sin sesión, la función no se puede ejecutar", true);

for (const [actor, aal, label] of [
  [member, "aal2", "socio con segundo factor"],
  [cashier, "aal1", "caja sin segundo factor"],
  [admin, "aal1", "administración sin segundo factor"],
]) {
  await assert.rejects(page({}, actor, aal), /AUTH/, label);
  ok(`${label} no lee el historial`, true);
}

// --- 2. Paginación y total ---
const first = await page();
ok(
  "la primera página trae 25 filas y el total real",
  first.rows.length === 25 && first.total === 35,
);
ok(
  "devuelve límite y desplazamiento aplicados",
  first.limit === 25 && first.offset === 0,
);
const second = await page({ offset: 25 });
ok(
  "la segunda página trae las 10 que faltan",
  second.rows.length === 10 && second.total === 35,
);
const seen = new Set(first.rows.map((row) => row.id));
ok(
  "ninguna fila se repite entre páginas",
  second.rows.every((row) => !seen.has(row.id)),
);
const ordered = first.rows.every(
  (row, index, list) =>
    index === 0 || new Date(list[index - 1].occurred_at) >= new Date(row.occurred_at),
);
ok("el orden es de más nuevo a más viejo", ordered);
const beyond = await page({ offset: 100 });
ok("pedir más allá del final devuelve vacío sin romper", beyond.rows.length === 0);

// --- 3. Búsqueda ---
const byConcept = await page({ search: "agua" });
ok(
  "la búsqueda por concepto encuentra movimientos viejos",
  byConcept.total === 2 &&
    byConcept.rows.every((row) => /agua/i.test(row.concept)),
);
const byClient = await page({ search: "María" });
ok(
  "la búsqueda también mira el nombre del cliente",
  byClient.total === 1 && byClient.rows[0].concept === "Gimnasio mensual",
);
const wildcard = await page({ search: "%" });
ok(
  "escribir un comodín no trae todo el historial",
  wildcard.total === 0 && wildcard.rows.length === 0,
);
const underscore = await page({ search: "_" });
ok("el guion bajo tampoco funciona como comodín", underscore.total === 0);
await assert.rejects(page({ search: "a".repeat(81) }), /INVALID_SEARCH/);
ok("una búsqueda demasiado larga se rechaza", true);

// --- 4. Interruptor de gastos ---
const withExpenses = await page({ search: "Compra" });
ok("con el interruptor prendido el gasto aparece", withExpenses.total === 1);
const hidden = await page({ search: "", hideExpenses: true });
ok(
  "con los gastos apagados no se devuelven ni se cuentan",
  hidden.total === 33 &&
    hidden.rows.every((row) => row.direction !== "expense") &&
    !hidden.rows.some((row) => row.id === gasId),
);
const onlyExpenses = await page({ direction: "expense" });
ok(
  "el filtro por egresos devuelve solo egresos",
  onlyExpenses.rows.every((row) => row.direction === "expense"),
);

// --- 5. Filtros por método, moneda y estado ---
const noMethod = await page({ method: "none" });
ok(
  "el filtro «sin método informado» solo trae filas sin método",
  noMethod.rows.length > 0 && noMethod.rows.every((row) => row.payment_method_id === null),
);
await assert.rejects(page({ direction: "regalos" }), /INVALID_DIRECTION/);
await assert.rejects(page({ status: "perdido" }), /INVALID_STATUS/);
// «Revertido» está en la lista de la pantalla aunque el enum no lo tenga:
// tiene que devolver una lista vacía, no un error.
const reversed = await page({ status: "reversed" });
ok("el estado «revertido» no rompe la consulta", reversed.total === 0);
await assert.rejects(page({ currency: "EUR" }), /INVALID_CURRENCY/);
ok("los filtros inválidos se rechazan con su motivo", true);

// --- 6. Anuladas y topes ---
const voided = await page({ search: "se anula" });
const voidedRow = voided.rows.find((row) => row.id === anuladaId);
ok(
  "un movimiento anulado llega con su motivo para marcarlo en Caja",
  voidedRow?.voided_reason === "Se cargó dos veces",
);
const clamped = await page({ limit: 500 });
ok("el límite se recorta a 100 en vez de traer todo", clamped.limit === 100);
const zeroLimit = await page({ limit: 0 });
ok("un límite inválido no deja la lista vacía por accidente", zeroLimit.limit === 1);
const negative = await page({ offset: -5 });
ok("un desplazamiento negativo se trata como cero", negative.offset === 0);

// --- 7. Datos visibles y nombres ---
const clientRow = (await page({ search: "Gimnasio" })).rows[0];
ok(
  "el nombre del cliente viaja con la fila",
  clientRow?.client?.full_name === "María Ejemplo de la Cruz",
);
ok(
  "no se exportan notas internas de más ni columnas nuevas",
  Object.keys(clientRow).sort().join(",") ===
    [
      "account_id",
      "amount",
      "base_amount",
      "client",
      "concept",
      "created_by",
      "currency",
      "direction",
      "expense_category_id",
      "fx_rate",
      "id",
      "member",
      "member_id",
      "notes",
      "occurred_at",
      "payment_method_id",
      "status",
      "voided_reason",
    ].join(","),
);

// --- 8. La tabla de movimientos no cambió ---
const before = Number(
  (await db.query("select count(*)::int as n from transactions")).rows[0].n,
);
await page();
const after = Number(
  (await db.query("select count(*)::int as n from transactions")).rows[0].n,
);
ok("leer el historial no escribe ni borra movimientos", before === after);

console.log(`\n${checks} comprobaciones del historial paginado (FIN-05) en verde.`);
void aguaId;
void clienteId;
