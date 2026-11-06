// Prueba de `00087` (FIN-04: abrir, arqueo y cierre de caja) en PGlite.
//
// Qué se comprueba, por rol y contra una base de verdad:
//   · sin sesión o siendo socio, nada: `AUTH`;
//   · un cajero sin segundo factor tampoco;
//   · abrir valida montos y no deja dos cajas abiertas a la vez;
//   · repetir el mismo pedido devuelve la misma caja (no abre dos turnos);
//   · lo esperado suma apertura + ingresos − egresos **de la cuenta de caja**,
//     sólo entre la apertura y el cierre: lo de banco, lo anulado y lo previo
//     no cuentan;
//   · sólo quien abrió (o un administrador) puede cerrar;
//   · un faltante exige motivo escrito; si cuadra, no;
//   · el arqueo queda guardado y no cambia después;
//   · la tabla ya no acepta escrituras sueltas: insertar, cambiar o borrar una
//     caja desde la sesión de un cajero falla.
import { PGlite } from "@electric-sql/pglite";
import { readFileSync, readdirSync } from "node:fs";
import assert from "node:assert/strict";

const MIGRATIONS = new URL("../supabase/migrations/", import.meta.url);
const sql = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = (file) => readFileSync(new URL(file, MIGRATIONS), "utf8");

const db = new PGlite();
// Los `numeric` vuelven como número: se comparan así, no como texto.
const money = (value) => Number(value);
let checks = 0;
const ok = (name, condition) => {
  assert.ok(condition, name);
  checks++;
  console.log(`✅ ${name}`);
};

/** Última definición real de `crm_is_staff()` entre todas las migraciones. */
function finalCrmIsStaff() {
  const files = readdirSync(MIGRATIONS).filter((file) => file.endsWith(".sql")).sort();
  let found = null;
  for (const file of files) {
    for (const match of migration(file).matchAll(
      /create or replace function public\.crm_is_staff\(\)[\s\S]*?\$\$;/gi,
    )) {
      found = match[0];
    }
  }
  return found;
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
  await db.exec(sql(file.startsWith("fixtures") ? `tests/${file}` : `supabase/migrations/${file}`));
}

await db.exec(migration("00033_roles_fase_a.sql"));
await db.exec(finalCrmIsStaff());

const cashMigration = migration("00087_cierre_y_arqueo_de_caja.sql");
await db.exec(cashMigration);
// Se aplica dos veces: tiene que poder repetirse sin romper nada.
await db.exec(cashMigration);
ok("la migración se puede aplicar dos veces", true);

const newUser = async (email, role) => {
  const id = (
    await db.query("insert into auth.users(email) values($1) returning id", [`${email}@test.invalid`])
  ).rows[0].id;
  if (role)
    await db.query("update profiles set role = $2::user_role where id = $1", [id, role]);
  return id;
};
const admin = await newUser("admin", "admin");
const cashier = await newUser("caja", "cashier");
const otherCashier = await newUser("caja2", "cashier");
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

const state = async (actor = cashier, aal = "aal2") =>
  (await as(actor, aal, "select public.finance_cash_state() as value")).at(0).value;

const open = (requestId, nio = 0, usd = 0, notes = "", actor = cashier, aal = "aal2") =>
  as(
    actor,
    aal,
    "select public.finance_cash_open(p_request => $1, p_open_nio => $2, p_open_usd => $3, p_notes => $4) as value",
    [requestId, nio, usd, notes],
  );

const close = (requestId, session, nio, usd, notes = "", actor = cashier, aal = "aal2") =>
  as(
    actor,
    aal,
    "select public.finance_cash_close(p_request => $1, p_session => $2, p_counted_nio => $3, p_counted_usd => $4, p_notes => $5) as value",
    [requestId, session, nio, usd, notes],
  );

// Cuentas: una de caja (la que cuenta para el arqueo) y un banco (que no).
await db.exec(`insert into bank_accounts(id, name, account_type, currency, balance) values
  ('caja_fuerte_nio', 'Caja Fuerte Córdobas', 'caja_fuerte', 'NIO', 0),
  ('caja_fuerte_usd', 'Caja Fuerte Dólares', 'caja_fuerte', 'USD', 0),
  ('banco_bac_nio', 'BAC Córdobas', 'banco', 'NIO', 0)`);

// Métodos: las claves existen en catálogo porque las transacciones los referencian.
await db.exec(`insert into payment_methods(id, name, currency) values
  ('efectivo_nio', 'Efectivo Córdobas', 'NIO'),
  ('efectivo_usd', 'Efectivo Dólares', 'USD'),
  ('transfer_bac_nio', 'Transferencia BAC', 'NIO')`);

const insertTx = async (values) =>
  db.query(
    `insert into transactions(occurred_at, type, status, amount, currency, amount_nio, amount_usd, fx_used, account_id, method_id, concept)
     values (coalesce($1::timestamptz, now()), $2::transaction_type, coalesce($3::transaction_status, 'completed'), $4::numeric, $5::text, $4::numeric, round($4::numeric / 40, 4), 40, $6::text, $7::text, $8::text)`,
    [
      values.at ?? null,
      values.type ?? "income",
      values.status ?? null,
      values.amount ?? 100,
      values.currency ?? "NIO",
      values.account ?? "caja_fuerte_nio",
      values.method ?? "efectivo_nio",
      values.concept ?? "Pase del día",
    ],
  );

// --- 1. Puertas de entrada ---
await assert.rejects(
  as(null, null, "select public.finance_cash_state()"),
  /permission denied|AUTH/i,
);
await assert.rejects(state(member, "aal2"), /AUTH/);
await assert.rejects(state(cashier, "aal1"), /AUTH/);
await assert.rejects(open(crypto.randomUUID(), 0, 0, "", cashier, "aal1"), /AUTH/);
await assert.rejects(close(crypto.randomUUID(), crypto.randomUUID(), 0, 0, "", member), /AUTH/);

// Las funciones internas no se pueden llamar desde la sesión.
await assert.rejects(
  as(cashier, "aal2", "select public.finance_cash_movements(now(), now())"),
  /permission denied/i,
);
await assert.rejects(
  as(cashier, "aal2", "select public.finance_cash_row_json(gen_random_uuid())"),
  /permission denied/i,
);
ok("las funciones internas no quedan expuestas", true);

// --- 2. Validación de montos al abrir ---
for (const bad of [-1, 1.005, 100000000]) {
  await assert.rejects(open(crypto.randomUUID(), bad, 0), /INVALID_AMOUNT/);
}
await assert.rejects(open(crypto.randomUUID(), 0, 0, "x".repeat(501)), /INVALID_NOTES/);
ok("abrir rechaza montos y notas inválidas", true);

// --- 3. Abrir ---
const start = await state();
ok("al principio no hay caja abierta", start.open === null && start.history.length === 0);

const openRequest = crypto.randomUUID();
const opened = (await open(openRequest, 500, 20, "Turno de la mañana")).at(0).value;
ok("el cajero abre la caja", opened.open === true && money(opened.openingNio) === 500);
ok("la apertura queda a nombre de quien abrió", opened.openedByName === "caja");
ok("sin movimientos, lo esperado es la apertura", money(opened.expectedNio) === 500 && money(opened.expectedUsd) === 20);

const replay = (await open(openRequest, 500, 20, "Turno de la mañana")).at(0).value;
ok("repetir el mismo pedido devuelve la misma caja", replay.id === opened.id);

await assert.rejects(open(crypto.randomUUID(), 10, 0), /CASH_ALREADY_OPEN/);
ok("no se puede tener dos cajas abiertas", true);

// --- 4. Lo que cuenta para el arqueo ---
await insertTx({ amount: 560, concept: "Gimnasio mensual" });
await insertTx({ amount: 40, concept: "Pase del día" });
await insertTx({ type: "expense", amount: 100, concept: "Compra de agua" });
await insertTx({ amount: 10, currency: "USD", account: "caja_fuerte_usd", method: "efectivo_usd", concept: "Boxeo" });
await insertTx({ type: "expense", amount: 5, currency: "USD", account: "caja_fuerte_usd", method: "efectivo_usd", concept: "Varios" });
// No cuentan: un movimiento de banco, uno cancelado y uno de antes de abrir.
await insertTx({ amount: 9999, account: "banco_bac_nio", method: "transfer_bac_nio", concept: "Transferencia" });
await insertTx({ amount: 777, status: "cancelled", concept: "Cobro cancelado" });
await insertTx({ amount: 888, at: new Date(Date.now() - 86400000), concept: "Cobro de ayer" });

const live = await state();
ok("ingresos de caja sumados", money(live.open.expectedNio) === 1000);
ok("egresos de caja restados", money(live.open.movements.expenseNio) === 100);
ok("el dólar se cuenta aparte", money(live.open.expectedUsd) === 25);
ok("sólo se miran movimientos de la cuenta de caja", live.open.movements.count === 5);
ok(
  "el detalle por cuenta explica el número",
  Array.isArray(live.open.movements.accounts) && live.open.movements.accounts.length === 2,
);

// --- 5. Quién puede cerrar ---
await assert.rejects(
  close(crypto.randomUUID(), opened.id, 1000, 25, "", otherCashier),
  /CASH_NOT_YOURS/,
);
ok("otro cajero no cierra el turno ajeno", true);

// --- 6. Faltante sin motivo ---
await assert.rejects(
  close(crypto.randomUUID(), opened.id, 990, 25, ""),
  /CASH_DIFFERENCE_REASON_REQUIRED/,
);
ok("un faltante exige motivo escrito", true);

// --- 7. Cierre que cuadra ---
const closeRequest = crypto.randomUUID();
const closed = (await close(closeRequest, opened.id, 1000, 25, "")).at(0).value;
ok("el cierre guarda lo contado", money(closed.countedNio) === 1000 && money(closed.countedUsd) === 25);
ok("el cierre guarda lo esperado", money(closed.expectedNio) === 1000);
ok("sin diferencia cuando cuadra", money(closed.differenceNio) === 0 && money(closed.differenceUsd) === 0);
ok("la caja queda cerrada", closed.open === false && closed.closedAt !== null);
ok("queda quién cerró", closed.closedByName === "caja");

const after = await state();
ok("ya no hay caja abierta", after.open === null);
ok("el cierre aparece en el historial", after.history.length === 1 && after.history[0].id === opened.id);

const closeReplay = (await close(closeRequest, opened.id, 1000, 25, "")).at(0).value;
ok("repetir el cierre no cambia el arqueo", closeReplay.id === opened.id);
await assert.rejects(
  close(crypto.randomUUID(), opened.id, 1000, 25, ""),
  /CASH_ALREADY_CLOSED/,
);
ok("una caja cerrada no se vuelve a cerrar", true);

// Un movimiento que llega después no reescribe un arqueo firmado.
await insertTx({ amount: 50, concept: "Cobro posterior al cierre" });
const signed = (await state()).history[0];
ok("el arqueo guardado no cambia después", money(signed.expectedNio) === 1000 && money(signed.countedNio) === 1000);

// --- 8. Cierre con sobrante y motivo, hecho por el administrador ---
const second = (await open(crypto.randomUUID(), 0, 0, "", admin)).at(0).value;
await insertTx({ amount: 200, concept: "Venta de camiseta" });
const withReason = (
  await close(crypto.randomUUID(), second.id, 210, 0, "Sobraron C$10: propina", admin)
).at(0).value;
ok("el administrador cierra y el sobrante queda con motivo", money(withReason.differenceNio) === 10);
ok("el motivo del cierre se guarda", withReason.closeNotes === "Sobraron C$10: propina");
ok("el historial queda con dos cajas", (await state()).history.length === 2);

// --- 9. La tabla ya no acepta escrituras sueltas ---
await assert.rejects(
  as(cashier, "aal2", "insert into public.cash_sessions(opened_by) values ($1)", [cashier]),
  /permission denied|row-level security/i,
);
await assert.rejects(
  as(cashier, "aal2", "update public.cash_sessions set opening_balance_nio = 0"),
  /permission denied|row-level security/i,
);
await assert.rejects(
  as(cashier, "aal2", "delete from public.cash_sessions"),
  /permission denied|row-level security/i,
);
await assert.rejects(
  as(cashier, "aal2", "select count(*) from public.cash_sessions"),
  /permission denied/i,
);
ok("nadie inserta, cambia, borra ni lee la tabla directo", true);

// El dueño de la base tampoco puede dejar dos cajas abiertas: lo corta el índice.
await open(crypto.randomUUID(), 0, 0, "", admin);
await assert.rejects(
  db.query("insert into cash_sessions(opened_by) values ($1)", [admin]),
  /duplicate key|cash_sessions_one_open_key/i,
);
ok("el índice impide dos cajas abiertas a la vez", true);

console.log(`\n${checks} comprobaciones de cierre y arqueo (FIN-04) pasaron.`);

// --- 10. Un movimiento de una caja ya cerrada no se anula (00088) ---
// Se aplica sobre el mismo escenario: la primera caja ya está cerrada y tuvo
// movimientos de efectivo dentro de su ventana.
const closedSession = (await state()).history.at(-1);
const insideCash = (
  await db.query(
    "select id from transactions where account_id = 'caja_fuerte_nio' and occurred_at between $1 and $2 order by occurred_at limit 1",
    [closedSession.openedAt, closedSession.closedAt],
  )
).rows[0];
// Piezas de las que depende el plan de anulación (00080). En producción ya
// existen; acá se declaran mínimas para probar la regla nueva tal cual.
await db.exec(`create table if not exists public.finance_voids(
  id uuid primary key default gen_random_uuid(),
  original_id uuid not null, reversal_id uuid, created_at timestamptz not null default now()
);
create or replace function public.finance_permission_enabled(p_key text) returns boolean
language sql stable as $$ select true $$;
create or replace function public.plan_local_today() returns date
language sql stable as $$ select (now() at time zone 'America/Managua')::date $$;`);

await db.exec(migration("00088_anular_caja_cerrada.sql"));
await db.exec(migration("00088_anular_caja_cerrada.sql"));
ok("la migración de caja cerrada se puede aplicar dos veces", true);
ok(
  "la función reconoce el movimiento firmado",
  (await db.query("select public.finance_cash_session_closed($1) as v", [insideCash.id])).rows[0].v === true,
);
const afterClose = (
  await db.query(
    "select id from transactions where account_id = 'caja_fuerte_nio' and occurred_at > $1 order by occurred_at limit 1",
    [closedSession.closedAt],
  )
).rows[0];
ok(
  "lo posterior al cierre no queda dentro del arqueo",
  (await db.query("select public.finance_cash_session_closed($1) as v", [afterClose.id])).rows[0].v === false,
);
const bankTx = (
  await db.query("select id from transactions where account_id = 'banco_bac_nio' limit 1")
).rows[0];
ok(
  "un movimiento de banco no entra en la regla",
  (await db.query("select public.finance_cash_session_closed($1) as v", [bankTx.id])).rows[0].v === false,
);

const plan = async (id, actor = admin) =>
  (await as(actor, "aal2", "select public.finance_void_plan($1) as value", [id])).at(0).value;
const closedPlan = await plan(insideCash.id);
ok("un cobro de una caja cerrada no se anula", closedPlan.allowed === false && closedPlan.code === "CASH_SESSION_CLOSED");
ok("el plan lo dice con un dato, no solo con el código", closedPlan.closedCashSession === true);
ok("un movimiento posterior al cierre se sigue anulando", (await plan(afterClose.id)).code === "ALLOWED");
ok("un movimiento de banco se sigue anulando", (await plan(bankTx.id)).code === "ALLOWED");

console.log(`\nComprobaciones finales de cierre y arqueo: ${checks}.`);
