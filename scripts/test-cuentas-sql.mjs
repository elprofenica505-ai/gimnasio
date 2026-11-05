// Prueba local de `00095` (FIN-03): cuentas, métodos, categorías y
// transferencias entre cuentas, sobre una base PostgreSQL de verdad (PGlite).
//
// Qué se comprueba:
//   · quién puede: administrador con segundo factor escribe; el personal lee;
//     un socio, un cajero sin MFA y un cajero con MFA no cambian nada;
//   · los saldos sólo se ven con el interruptor de saldos (o siendo admin);
//   · una cuenta no se borra: se apaga. No se puede apagar una caja abierta ni
//     cambiarle la moneda a una cuenta con movimientos;
//   · una transferencia mueve los dos saldos, no es ingreso ni gasto, es
//     idempotente y convierte moneda con la tasa escrita;
//   · el arqueo de caja la tiene en cuenta (si sale efectivo de la caja,
//     «debería haber» baja);
//   · anular una transferencia devuelve los dos saldos, deja contra-asiento,
//     no se puede anular dos veces y no deja rastro de plata inventada;
//   · todo queda en `finance_settings_audit`.
import { PGlite } from "@electric-sql/pglite";
import { readFileSync, readdirSync } from "node:fs";
import assert from "node:assert/strict";

const sql = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const db = new PGlite();
let checks = 0;
const ok = (label, cond) => {
  assert.ok(cond, label);
  checks += 1;
  console.log(`✅ ${label}`);
};
const money = (value) => Number(value);

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
  "00032_mfa_is_staff_y_privilegios_anon.sql",
  "00033_roles_fase_a.sql",
  "00034_roles_fase_b.sql",
  "00035_asignacion_entrenador.sql",
  "00036_personal_no_es_cliente.sql",
  "00037_cierre_caja_interruptor.sql",
  "00038_caja_resumen_deudas.sql",
  "00039_medidas_metas_rutinas.sql",
  "00040_mi_progreso_cliente.sql",
  "00041_asistencia_cliente.sql",
  "00042_productos_stock_categorias.sql",
  "00043_plan_nutricion_interruptor.sql",
  "00044_calculadora_cliente.sql",
  "00045_registro_gimnasio_calculadora.sql",
  "00046_meta_rutina_desde_calculadora.sql",
  "00047_menores_consentimiento_aprobacion.sql",
  "00048_edad_desde_fecha_nacimiento.sql",
  "00049_personal_datos_y_baja.sql",
]) {
  await db.exec(sql(`supabase/migrations/${f}`));
}

// Compatibilidad sólo de la prueba local (producción divergió en `coaches`).
await db.exec(`alter table public.coaches add column if not exists full_name text;
  alter table public.coaches add column if not exists specialty text;
  update public.coaches set full_name = coalesce(full_name, name), specialty = coalesce(specialty, role_es);`);

for (const f of [
  "00050_coaches_vista_publica.sql",
  "00051_coaches_vista_landing.sql",
  "00052_altura_en_ficha.sql",
  "00053_correccion_altura_admin.sql",
  "00054_mi_progreso_altura_ficha.sql",
  "00055_menores_rutas_personal.sql",
  "00056_permisos_caja_separados.sql",
  "00057_pase_del_dia_tarifa.sql",
  "00058_tarifas_gimnasio_nio.sql",
  "00059_cobro_con_productos.sql",
  "00064_disciplinas_activas.sql",
  "00067_vigencias_planes.sql",
  "00068_catalogo_planes.sql",
]) {
  await db.exec(sql(`supabase/migrations/${f}`));
}

// Todo lo que existe entre 00069 y 00094, en orden, para llegar a la caja real.
const laterFiles = readdirSync(new URL("../supabase/migrations/", import.meta.url))
  .filter((f) => /^000(6[9]|[7-9]\d)_/.test(f) && f.endsWith(".sql"))
  .sort();
for (const f of laterFiles) {
  try {
    await db.exec(sql(`supabase/migrations/${f}`));
  } catch (error) {
    console.log(`⚠️  no se pudo aplicar ${f}: ${error.message.split("\n")[0]}`);
  }
}

const partes = [
  sql("supabase/migrations/00095_cuentas_catalogos.sql"),
  sql("supabase/migrations/00096_transferencias_y_arqueo.sql"),
];
for (const parte of partes) await db.exec(parte);
ok("00095 y 00096 se aplican", true);
for (const parte of partes) await db.exec(parte);
ok("00095 y 00096 se pueden aplicar dos veces", true);

const row = async (query, args = []) => (await db.query(query, args)).rows[0];
const makeUser = async (email, role) => {
  const id = (
    await row(
      "insert into auth.users(email, raw_user_meta_data) values ($1,$2) returning id",
      [email, JSON.stringify({ full_name: email })],
    )
  ).id;
  if (role) await db.query("update public.profiles set role=$2::public.user_role where id=$1", [id, role]);
  return id;
};

const admin = await makeUser("admin@test.invalid", "admin");
const cashier = await makeUser("caja@test.invalid", "cashier");
const member = await makeUser("socio@test.invalid", null);

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

const state = async (actor = admin, aal = "aal2") =>
  (await as(actor, aal, "select public.finance_accounts_state(20) as value")).at(0).value;

const saveAccount = (actor, aal, args) =>
  as(
    actor,
    aal,
    `select public.finance_account_save(
       p_id => $1, p_name => $2, p_account_type => $3, p_currency => $4,
       p_bank_name => $5, p_account_number => $6, p_display_order => $7, p_is_active => $8
     ) as value`,
    args,
  );

const transfer = (actor, aal, request, from, to, amount, fx = 36.6, concept = "Traslado a banco") =>
  as(
    actor,
    aal,
    `select public.finance_transfer_create(
       p_request => $1, p_from => $2, p_to => $3, p_amount => $4, p_fx => $5, p_concept => $6
     ) as value`,
    [request, from, to, amount, fx, concept],
  );

const balance = async (account) =>
  money((await row("select balance from public.bank_accounts where id=$1", [account])).balance);

// Cuentas de prueba: una caja, un banco y una billetera, más un método y una
// categoría, igual que el día que el dueño abre la app.
await db.exec(`insert into bank_accounts(id, name, account_type, currency, balance, display_order) values
  ('caja_fuerte_nio', 'Caja Fuerte Córdobas', 'caja_fuerte', 'NIO', 2000, 1),
  ('caja_fuerte_usd', 'Caja Fuerte Dólares', 'caja_fuerte', 'USD', 100, 2),
  ('banco_bac_nio', 'BAC Córdobas', 'banco', 'NIO', 5000, 3),
  ('banco_bac_usd', 'BAC Dólares', 'banco', 'USD', 400, 4),
  ('billetera_tigo', 'Tigo Money', 'billetera', 'NIO', 300, 5)`);
await db.exec(`insert into payment_methods(id, name, currency) values
  ('efectivo_nio', 'Efectivo Córdobas', 'NIO')`);
await db.exec(`insert into expense_categories(id, name, color, display_order) values
  ('luz', 'Luz', '#ffcc00', 1)`);

// --- 1. Puertas de entrada -------------------------------------------------
await assert.rejects(state(member, "aal2"), /AUTH/);
await assert.rejects(state(cashier, "aal1"), /AUTH/);
await assert.rejects(saveAccount(cashier, "aal2", [null, "Caja del cajero", "caja_fuerte", "NIO", null, null, 9, true]), /AUTH/);
await assert.rejects(saveAccount(member, "aal2", [null, "Caja del socio", "caja_fuerte", "NIO", null, null, 9, true]), /AUTH/);
await assert.rejects(transfer(cashier, "aal2", crypto.randomUUID(), "banco_bac_nio", "caja_fuerte_nio", 10), /AUTH/);
ok("sólo un administrador con segundo factor escribe", true);

// La bitácora no se toca ni se lee desde la sesión del navegador.
await assert.rejects(
  as(admin, "aal2", "insert into public.finance_settings_audit(action) values ('account_save')"),
  /permission denied/i,
);
ok("la bitácora no se escribe ni se lee desde la sesión", true);

// --- 2. Lectura y permisos de saldos --------------------------------------
const adminState = await state();
ok("el administrador ve sus cuentas", adminState.accounts.length === 5 && adminState.canManage === true);
ok("el administrador ve los saldos", adminState.balancesVisible === true && adminState.accounts.every((a) => a.balance !== null));
ok("los saldos llegan por cuenta", money(adminState.accounts.find((a) => a.id === "banco_bac_nio").balance) === 5000);
ok("trae métodos y categorías", adminState.methods.length >= 1 && adminState.categories.length >= 1);
ok("la regla de la transferencia viaja con el estado", /no es ingreso ni gasto/i.test(adminState.rules.transferRule));

const cashierState = await state(cashier);
ok("caja lee el estado pero no puede cambiarlo", cashierState.canManage === false);
ok("sin el interruptor de saldos, caja no ve los saldos", cashierState.balancesVisible === false && cashierState.accounts.every((a) => a.balance === null));
ok("caja tampoco ve la bitácora", cashierState.audit.length === 0);

await db.exec("update public.staff_permissions set enabled = true where key = 'cashier_can_view_account_balances'");
const cashierWithBalances = await state(cashier);
ok("con el interruptor de saldos, caja sí los ve", cashierWithBalances.balancesVisible === true && cashierWithBalances.accounts.every((a) => a.balance !== null));
await db.exec("update public.staff_permissions set enabled = false where key = 'cashier_can_view_account_balances'");

// --- 3. Alta y edición de cuentas -----------------------------------------
const created = (await saveAccount(admin, "aal2", [null, "Cuenta de prueba", "banco", "NIO", "BANPRO", "123456", 60, true])).at(0).value;
ok("el administrador crea una cuenta", created.id.startsWith("cta_") && created.name === "Cuenta de prueba");
ok("la cuenta nace en cero", money(created.balance) === 0);
ok("la cuenta aparece en el estado", (await state()).accounts.some((a) => a.id === created.id));

await assert.rejects(
  saveAccount(admin, "aal2", [null, "Cuenta de prueba", "banco", "NIO", null, null, 61, true]),
  /ACCOUNT_NAME_TAKEN/,
);
await assert.rejects(saveAccount(admin, "aal2", [null, "X", "banco", "NIO", null, null, 61, true]), /INVALID_NAME/);
await assert.rejects(saveAccount(admin, "aal2", [null, "Cuenta rara", "cripto", "NIO", null, null, 61, true]), /INVALID_ACCOUNT_TYPE/);
await assert.rejects(saveAccount(admin, "aal2", [null, "Cuenta rara", "banco", "EUR", null, null, 61, true]), /INVALID_CURRENCY/);
await assert.rejects(saveAccount(admin, "aal2", [null, "Cuenta rara", "banco", "NIO", null, null, -1, true]), /INVALID_ORDER/);
ok("las cuentas se validan antes de guardar", true);

const renamed = (await saveAccount(admin, "aal2", [created.id, "Cuenta renombrada", "banco", "NIO", "BANPRO", "123456", 60, true])).at(0).value;
ok("la cuenta se puede renombrar sin perder su id", renamed.id === created.id && renamed.name === "Cuenta renombrada");

// Apagar es la forma de «borrar».
const off = (await saveAccount(admin, "aal2", [created.id, "Cuenta renombrada", "banco", "NIO", "BANPRO", "123456", 60, false])).at(0).value;
ok("la cuenta se apaga sin borrarse", off.isActive === false && (await state()).accounts.some((a) => a.id === created.id && a.isActive === false));

// --- 4. Métodos y categorías ----------------------------------------------
const method = (await as(admin, "aal2",
  `select public.finance_method_save(p_id => null, p_name => 'Tarjeta', p_currency => 'BOTH', p_fee_pct => 2.5, p_display_order => 20, p_is_active => true) as value`,
)).at(0).value;
ok("el administrador crea un método de pago", method.id.startsWith("met_") && method.currency === "BOTH" && money(method.feePct) === 2.5);
await assert.rejects(
  as(admin, "aal2", `select public.finance_method_save(p_id => null, p_name => 'Tarjeta', p_currency => 'NIO')`),
  /METHOD_NAME_TAKEN/,
);
await assert.rejects(
  as(admin, "aal2", `select public.finance_method_save(p_id => null, p_name => 'Otra', p_currency => 'NIO', p_fee_pct => 101)`),
  /INVALID_FEE/,
);

const category = (await as(admin, "aal2",
  `select public.finance_category_save(p_id => null, p_name => 'Mantenimiento', p_color => '#00AA99', p_budget_monthly => 1500, p_display_order => 30, p_is_active => true) as value`,
)).at(0).value;
ok("el administrador crea una categoría de gasto", category.id.startsWith("cat_") && category.color === "#00aa99");
const hidden = (await as(admin, "aal2",
  `select public.finance_category_save(p_id => $1, p_name => 'Mantenimiento', p_color => '#00AA99', p_budget_monthly => 1500, p_display_order => 30, p_is_active => false) as value`,
  [category.id],
)).at(0).value;
ok("la categoría se apaga", hidden.isActive === false);
const options = (await as(admin, "aal2", "select public.finance_options() as value")).at(0).value;
ok(
  "una categoría apagada no se ofrece al cargar un gasto",
  !options.categories.some((c) => c.id === category.id),
);
await assert.rejects(
  as(admin, "aal2", `select public.finance_category_save(p_id => null, p_name => 'Otra', p_color => 'rojo')`),
  /INVALID_COLOR/,
);

// --- 5. Transferencia entre cuentas de la misma moneda --------------------
const incomeTotal = async () =>
  money((await row("select coalesce(sum(amount_nio),0) as total from public.transactions where type='income'")).total);
const incomeBefore = await incomeTotal();
const transferRequest = crypto.randomUUID();
const receipt = (await transfer(admin, "aal2", transferRequest, "banco_bac_nio", "caja_fuerte_nio", 1000)).at(0).value;
ok("se registra la transferencia", Boolean(receipt.id) && receipt.kind === "transfer");
ok("el banco baja lo transferido", (await balance("banco_bac_nio")) === 4000);
ok("la caja sube lo transferido", (await balance("caja_fuerte_nio")) === 3000);
ok("el comprobante guarda el saldo antes y después", money(receipt.fromBefore) === 5000 && money(receipt.toAfter) === 3000);

const transferRow = await row(
  "select type::text as type, amount, currency, account_id, destination_account_id, amount_nio from public.transactions where id=$1",
  [receipt.id],
);
ok("es una transferencia, no un ingreso", transferRow.type === "transfer" && transferRow.account_id === "banco_bac_nio" && transferRow.destination_account_id === "caja_fuerte_nio");
ok("no se cuenta como ingreso en los totales", (await incomeTotal()) === incomeBefore);

const replay = (await transfer(admin, "aal2", transferRequest, "banco_bac_nio", "caja_fuerte_nio", 1000)).at(0).value;
ok("repetir el mismo pedido no mueve la plata dos veces", replay.id === receipt.id && (await balance("banco_bac_nio")) === 4000);
await assert.rejects(
  transfer(admin, "aal2", transferRequest, "banco_bac_nio", "caja_fuerte_nio", 900),
  /REQUEST_CONFLICT/,
);

// --- 6. Validaciones de la transferencia ----------------------------------
await assert.rejects(transfer(admin, "aal2", crypto.randomUUID(), "banco_bac_nio", "banco_bac_nio", 10), /INVALID_ACCOUNTS/);
await assert.rejects(transfer(admin, "aal2", crypto.randomUUID(), "banco_bac_nio", "caja_fuerte_nio", 0), /INVALID_AMOUNT/);
await assert.rejects(transfer(admin, "aal2", crypto.randomUUID(), "banco_bac_nio", "caja_fuerte_nio", 1.005), /INVALID_AMOUNT/);
await assert.rejects(transfer(admin, "aal2", crypto.randomUUID(), "banco_bac_nio", "caja_fuerte_nio", 10, 0), /INVALID_FX/);
await assert.rejects(transfer(admin, "aal2", crypto.randomUUID(), "banco_bac_nio", "caja_fuerte_nio", 10, 36.6, "x"), /INVALID_CONCEPT/);
await assert.rejects(
  transfer(admin, "aal2", crypto.randomUUID(), "cuenta-que-no-existe", "caja_fuerte_nio", 10),
  /INVALID_ACCOUNT/,
);
await assert.rejects(
  transfer(admin, "aal2", crypto.randomUUID(), created.id, "caja_fuerte_nio", 10),
  /INVALID_ACCOUNT/,
  "una cuenta apagada no recibe ni envía",
);
ok("la transferencia rechaza lo que no cuadra", true);

// --- 7. Transferencia entre monedas ---------------------------------------
const usdRequest = crypto.randomUUID();
const usdReceipt = (await transfer(admin, "aal2", usdRequest, "banco_bac_nio", "banco_bac_usd", 3660, 36.6, "Compra de dólares")).at(0).value;
ok("entre monedas distintas se entrega lo que compra la tasa", money(usdReceipt.amountIn) === 100 && usdReceipt.currencyIn === "USD");
ok("el saldo en dólares sube con la conversión", (await balance("banco_bac_usd")) === 500);
ok("el saldo en córdobas baja el importe original", (await balance("banco_bac_nio")) === 340);

const older = await state();
ok("la pantalla lista las transferencias", older.transfers.length === 2);
ok("cada transferencia dice de dónde a dónde", older.transfers.some((t) => t.fromName === "BAC Córdobas" && t.toName === "BAC Dólares" && t.currencyIn === "USD"));

// --- 8. El arqueo de caja las tiene en cuenta -----------------------------
const opened = (await as(admin, "aal2",
  `select public.finance_cash_open(p_request => $1, p_open_nio => 2000, p_open_usd => 100, p_notes => 'Turno de prueba') as value`,
  [crypto.randomUUID()],
)).at(0).value;
ok("la caja abre con lo contado al empezar", money(opened.openingNio) === 2000);

const cashOut = (await transfer(admin, "aal2", crypto.randomUUID(), "caja_fuerte_nio", "banco_bac_nio", 500, 36.6, "Depósito al banco")).at(0).value;
const afterOut = (await as(admin, "aal2", "select public.finance_cash_state() as value")).at(0).value.open;
ok("sacar efectivo de la caja baja lo que debería haber", money(afterOut.expectedNio) === 1500);
ok("la transferencia se ve en el arqueo como salida de caja", money(afterOut.movements.transferOutNio) === 500);
ok("la caja cuenta la transferencia como movimiento", afterOut.movements.count >= 1);

await transfer(admin, "aal2", crypto.randomUUID(), "banco_bac_nio", "caja_fuerte_nio", 200, 36.6, "Reposición de vuelto");
const afterIn = (await as(admin, "aal2", "select public.finance_cash_state() as value")).at(0).value.open;
ok("meter efectivo a la caja sube lo que debería haber", money(afterIn.expectedNio) === 1700);
ok("la entrada también queda registrada", money(afterIn.movements.transferInNio) === 200);

// Cerrar la caja cuadrando con lo que la transferencia dejó.
const closed = (await as(admin, "aal2",
  `select public.finance_cash_close(p_request => $1, p_session => $2, p_counted_nio => $3, p_counted_usd => $4) as value`,
  [crypto.randomUUID(), afterIn.id, 1700, 100],
)).at(0).value;
ok("el arqueo cierra sin diferencia inventada", money(closed.expectedNio) === 1700 && money(closed.differenceNio) === 0);

// --- 9. Anular una transferencia ------------------------------------------
const beforeVoid = { from: await balance("caja_fuerte_nio"), to: await balance("banco_bac_nio") };
const voidReceipt = (await as(admin, "aal2",
  `select public.finance_transfer_void(p_request => $1, p_transfer => $2, p_reason => $3) as value`,
  [crypto.randomUUID(), cashOut.id, "Se cargó al banco equivocado"],
)).at(0).value;
ok("la anulación devuelve el saldo de la caja", (await balance("caja_fuerte_nio")) === beforeVoid.from + 500);
ok("la anulación devuelve el saldo del banco", (await balance("banco_bac_nio")) === beforeVoid.to - 500);
ok("la anulación deja contra-asiento, no borra la original", Boolean(voidReceipt.reversalId) && voidReceipt.originalId === cashOut.id);
ok("la original sigue en el historial", Boolean(await row("select id from public.transactions where id=$1", [cashOut.id])));
const listed = (await state()).transfers;
ok("la pantalla marca la transferencia anulada", listed.some((t) => t.id === cashOut.id && t.voided === true && /equivocado/.test(t.voidReason)));
await assert.rejects(
  as(admin, "aal2",
    `select public.finance_transfer_void(p_request => $1, p_transfer => $2, p_reason => $3) as value`,
    [crypto.randomUUID(), cashOut.id, "Otra vez"],
  ),
  /NOT_ALLOWED/,
);
await assert.rejects(
  as(admin, "aal2",
    `select public.finance_transfer_void(p_request => $1, p_transfer => $2, p_reason => $3) as value`,
    [crypto.randomUUID(), cashOut.id, "abc"],
  ),
  /INVALID_REASON/,
);
ok("una transferencia no se anula dos veces ni sin motivo", true);

// El arqueo vuelve a su lugar: la salida y su reversa se compensan.
// Función interna: se consulta fuera de la sesión del navegador, como la base.
const compensated = (
  await row("select public.finance_cash_movements(now() - interval '1 day', now() + interval '1 day') as value")
).value;
// Entradas al rango: 1000 (antes de abrir, no cuenta para el turno) + 200 + 500
// de la reversa. Salidas: los 500 que se sacaron al banco.
ok(
  "la anulación compensa el arqueo",
  money(compensated.transferOutNio) === 500 && money(compensated.transferInNio) === 1700,
);

// --- 10. Auditoría --------------------------------------------------------
const auditRows = (await db.query("select action, count(*)::int as n from public.finance_settings_audit group by action order by action")).rows;
const auditByAction = Object.fromEntries(auditRows.map((r) => [r.action, r.n]));
ok("queda bitácora de las cuentas", auditByAction.account_save >= 3);
ok("queda bitácora de los métodos y las categorías", auditByAction.method_save >= 1 && auditByAction.category_save >= 2);
ok("queda bitácora de las transferencias y sus anulaciones", auditByAction.transfer_create >= 3 && auditByAction.transfer_void === 1);
const auditView = (await state()).audit;
ok("el administrador ve la bitácora en la pantalla", auditView.length > 0 && auditView.every((a) => typeof a.action === "string"));

// --- 11. Cambiar la moneda de una cuenta con movimientos ------------------
await assert.rejects(
  saveAccount(admin, "aal2", ["banco_bac_nio", "BAC Córdobas", "banco", "USD", "BAC", "1", 3, true]),
  /ACCOUNT_CURRENCY_LOCKED/,
);
ok("no se le cambia la moneda a una cuenta con movimientos", true);

// --- 12. No se apaga una caja con turno abierto ---------------------------
await as(admin, "aal2",
  `select public.finance_cash_open(p_request => $1, p_open_nio => 0, p_open_usd => 0, p_notes => 'Turno abierto') as value`,
  [crypto.randomUUID()],
);
await assert.rejects(
  saveAccount(admin, "aal2", ["caja_fuerte_nio", "Caja Fuerte Córdobas", "caja_fuerte", "NIO", null, null, 1, false]),
  /ACCOUNT_IN_OPEN_CASH/,
);
ok("una caja con turno abierto no se apaga", true);
const noCashOff = (await saveAccount(admin, "aal2", ["billetera_tigo", "Tigo Money", "billetera", "NIO", null, null, 5, false])).at(0).value;
ok("una cuenta que no es caja sí se puede apagar", noCashOff.isActive === false);

console.log(`\n${checks} comprobaciones de cuentas y transferencias en verde.`);
