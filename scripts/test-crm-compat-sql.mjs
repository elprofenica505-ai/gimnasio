import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const sql = (path) =>
  readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const db = new PGlite();
let count = 0;
const check = (label, ok) => {
  assert.ok(ok, label);
  count++;
  console.log(`  ✅ ${label}`);
};
const row = async (q, args = []) => (await db.query(q, args)).rows[0];
await db.exec(`
create schema auth; create role anon nologin; create role authenticated nologin;
create table auth.users(id uuid primary key default gen_random_uuid(),email text,raw_user_meta_data jsonb default '{}'::jsonb,created_at timestamptz default now());
create table auth.current_user(id uuid);
create function auth.uid() returns uuid language sql stable as $$ select id from auth.current_user limit 1 $$;
grant usage on schema auth to anon,authenticated; grant select on auth.current_user to anon,authenticated;
`);
for (const f of [
  "supabase/migrations/00001_schema.sql",
  "tests/fixtures/base-catalog.sql",
  "tests/fixtures/finance-bank-accounts.sql",
  "supabase/migrations/00012_profiles_self_read.sql",
  "supabase/migrations/00020_clients_crm.sql",
])
  await db.exec(sql(f));
async function as(id, q, args = []) {
  await db.exec("reset role; delete from auth.current_user;");
  if (id) await db.query("insert into auth.current_user values($1)", [id]);
  await db.exec(`set role ${id ? "authenticated" : "anon"}`);
  try {
    return await db.query(q, args);
  } finally {
    await db.exec("reset role; delete from auth.current_user;");
  }
}
async function reject(id, q, args, pattern) {
  await assert.rejects(as(id, q, args), pattern);
  check(`rechaza ${pattern}`, true);
}
const user = async (name) =>
  (
    await row(
      "insert into auth.users(email,raw_user_meta_data) values($1,$2) returning id",
      [`${name}@test.invalid`, JSON.stringify({ full_name: `Prueba ${name}` })],
    )
  ).id;
const admin = await user("admin"),
  staff = await user("staff"),
  member = await user("member");
await db.query("update profiles set role='admin' where id=$1", [admin]);
await db.query("update profiles set role='staff' where id=$1", [staff]);
const id = (
  await as(
    staff,
    "select public.crm_create_client('Cliente ficticio sin celular') as id",
  )
).rows[0].id;
const linked = (
  await row("select id from gym_clients where profile_id=$1", [member])
).id;
await db.exec(`insert into bank_accounts(id,name,account_type,currency,balance) values('test-nio','Caja ficticia','caja_fuerte','NIO',900),('test-usd','USD ficticia','banco','USD',12),('test-off','Inactiva','banco','NIO',0);
update bank_accounts set is_active=false where id='test-off';
insert into payment_methods(id,name,currency) values('test-both','Ambas','BOTH'),('test-nio','Efectivo NIO','NIO'),('test-usd','Efectivo USD','USD'),('test-off','Inactivo','BOTH');
update payment_methods set is_active=false where id='test-off';`);
await db.query(
  "insert into member_balances(member_id,credit_nio,credit_usd,debt_nio,debt_usd) values($1,100,7,20,3)",
  [member],
);
await db.query(
  `insert into transactions(type,account_id,member_id,client_id,amount,currency,amount_nio,amount_usd,fx_used,concept) values('income','test-nio',$1,$2,100,'NIO',100,2.5,40,'Movimiento ficticio previo')`,
  [member, linked],
);
console.log(
  "\n▶ Compatibilidad con estructura exportada bank_accounts / saldos separados",
);
await reject(staff, "select public.crm_detail($1)", [id], /balance_nio/);
const snapshot = async () =>
  JSON.stringify(
    (
      await db.query(
        `select 'bank' as tipo,to_jsonb(a) as datos from bank_accounts a union all select 'balance',to_jsonb(b) from member_balances b union all select 'tx',to_jsonb(t) from transactions t order by tipo,datos`,
      )
    ).rows,
  );
const tokenBefore = (await as(staff, "select crm_get_card($1) as token", [id]))
  .rows[0].token;
const clientBefore = JSON.stringify(
  (await db.query("select * from gym_clients order by id")).rows,
);
const before = await snapshot();
const compat = sql("supabase/migrations/00022_crm_finance_compat.sql");
await db.exec(compat);
await db.exec(compat);
check(
  "migración repetida conserva cuentas, saldos y movimientos byte a byte",
  (await snapshot()) === before,
);
check(
  "conserva fichas y QR existentes",
  JSON.stringify(
    (await db.query("select * from gym_clients order by id")).rows,
  ) === clientBefore &&
    (await as(staff, "select crm_get_card($1) as token", [id])).rows[0]
      .token === tokenBefore,
);
check(
  "no crea accounts paralela",
  !(await row("select to_regclass('public.accounts') as table_id")).table_id,
);
check(
  "identifica estructura confirmada",
  (await row("select crm_finance_layout() as layout")).layout ===
    "bank_accounts_split",
);
const options = (await as(staff, "select crm_options() as value")).rows[0]
  .value;
check(
  "opciones leen planes, métodos y cuentas reales sin 42703",
  options.plans.length > 0 &&
    options.methods.length === 3 &&
    options.accounts.length === 2,
);
check(
  "BOTH habilita NIO y USD",
  options.methods.find((m) => m.id === "test-both").accepts_nio &&
    options.methods.find((m) => m.id === "test-both").accepts_usd,
);
check(
  "monedas exclusivas se respetan",
  !options.methods.find((m) => m.id === "test-nio").accepts_usd &&
    !options.methods.find((m) => m.id === "test-usd").accepts_nio,
);
check(
  "cobro deshabilitado con explicación explícita",
  options.payments_enabled === false && !!options.payment_block_reason,
);
const detail = (await as(staff, "select crm_detail($1) as value", [id])).rows[0]
  .value;
check(
  "ficha sin cuenta abre con QR e historiales",
  detail.client.id === id &&
    !!detail.card &&
    Array.isArray(detail.visits) &&
    Array.isArray(detail.events),
);
check(
  "ficha sin cuenta no inventa saldo",
  detail.balance === null && detail.balances === null,
);
const linkedDetail = (
  await as(admin, "select crm_detail($1) as value", [linked])
).rows[0].value;
check(
  "crédito/deuda NIO/USD conservados sin compensar",
  JSON.stringify(linkedDetail.balances) ===
    JSON.stringify({
      debt_nio: 20,
      debt_usd: 3,
      credit_nio: 100,
      credit_usd: 7,
    }),
);
check("no inventa un saldo neto en NIO", linkedDetail.balance === null);
check(
  "historial financiero existente sigue visible",
  linkedDetail.payments.length === 1 &&
    linkedDetail.payments[0].concept === "Movimiento ficticio previo",
);
const visit = (
  await as(staff, "select crm_check_in($1,'manual') as value", [id])
).rows[0].value;
const repeat = (
  await as(staff, "select crm_check_in($1,'manual') as value", [id])
).rows[0].value;
check(
  "visita manual sigue funcionando una vez al día",
  !visit.already && repeat.already,
);
const args = [
  id,
  "11111111-1111-4111-8111-111111111111",
  50,
  "NIO",
  "test-nio",
  "test-nio",
  "Pago ficticio",
  1,
];
const pay = "select crm_record_payment($1,$2,$3,$4,$5,$6,$7,$8)";
await reject(staff, pay, args, /FINANCE_REVIEW_REQUIRED/);
await reject(member, pay, args, /AUTH/);
await reject(
  staff,
  "select crm_record_payment_repository($1,$2,$3,$4,$5,$6,$7,$8)",
  args,
  /permission denied/,
);
await reject(staff, "select crm_finance_layout()", [], /permission denied/);
await reject(member, "select crm_options()", [], /AUTH/);
await reject(member, "select crm_detail($1)", [id], /AUTH/);
await reject(null, "select crm_options()", [], /permission denied/);
check(
  "rechazo de pago no crea tx/eventos de cobro ni altera saldos",
  (await snapshot()) === before &&
    (
      await row(
        "select count(*)::int as n from client_events where action='payment'",
      )
    ).n === 0,
);
// Nuevo contrato: todas las secciones se ejercitan en una transacción READ ONLY.
const readMigration = sql(
  "supabase/migrations/00023_finance_read_bank_accounts.sql",
);
const beforeRead = await snapshot();
const policiesBefore = JSON.stringify(
  (
    await db.query(
      "select * from pg_policies order by schemaname,tablename,policyname",
    )
  ).rows,
);
await db.exec(readMigration);
await db.exec(readMigration);
check(
  "00023 repetida no toca cuentas, saldos, movimientos ni políticas",
  (await snapshot()) === beforeRead &&
    policiesBefore ===
      JSON.stringify(
        (
          await db.query(
            "select * from pg_policies order by schemaname,tablename,policyname",
          )
        ).rows,
      ),
);
await reject(null, "select finance_read('summary')", [], /permission denied/);
await reject(member, "select finance_read('summary')", [], /AUTH/);
await reject(
  staff,
  "select finance_read('unknown')",
  [],
  /INVALID_FINANCE_SECTION/,
);
const oldPay = "select record_payment($1,10,'NIO','test-nio','test-nio')";
await reject(null, oldPay, [member], /permission denied/);
await reject(member, oldPay, [member], /AUTH/);
await reject(staff, oldPay, [member], /FINANCE_REVIEW_REQUIRED/);
await reject(admin, oldPay, [member], /FINANCE_REVIEW_REQUIRED/);
check(
  "rechazos del escritor antiguo no modifican datos",
  (await snapshot()) === beforeRead,
);
await db.query(
  "insert into cash_sessions(opened_by,opening_balance_nio,opening_balance_usd) values($1,40,2),($1,70,3)",
  [staff],
);
await db.exec(`
insert into expense_categories(id,name) values('test-cat','Categoría ficticia');
insert into transactions(type,status,account_id,method_id,amount,currency,amount_nio,amount_usd,fx_used,concept) values
 ('income','completed','test-nio','test-nio',200,'NIO',200,5,40,'Ficticio NIO'),
 ('income','completed','test-usd','test-usd',12,'USD',480,12,40,'Ficticio USD'),
 ('expense','completed','test-nio','test-nio',50,'NIO',50,1.25,40,'Ficticio gasto'),
 ('transfer','completed','test-nio','test-nio',9999,'NIO',9999,249.975,40,'Ficticia transferencia'),
 ('income','cancelled','test-nio','test-nio',8888,'NIO',8888,222.2,40,'Ficticio cancelado'),
 ('income','pending','test-nio','test-nio',7777,'NIO',7777,194.425,40,'Ficticio pendiente');
insert into transactions(type,account_id,occurred_at,amount,currency,amount_nio,amount_usd,fx_used,concept) values
 ('income','test-nio','2001-02-01T05:59:00Z',11,'NIO',11,0.275,40,'Antes del corte Managua'),
 ('income','test-nio','2001-02-01T06:00:00Z',22,'NIO',22,0.55,40,'Después del corte Managua');
`);
const readSnapshot = await snapshot();
const finance = async (section) =>
  (await as(staff, "select finance_read($1,366) as v", [section])).rows[0].v
    .data;
// Una función invocada por el propietario también exige identidad staff.
await reject(null, "select finance_read('accounts')", [], /permission denied/);
for (const section of [
  "methods",
  "accounts",
  "categories",
  "transactions",
  "daily",
  "monthly",
  "method_totals",
  "receivables",
  "summary",
]) {
  await db.query("insert into auth.current_user values($1)", [admin]);
  await db.exec("begin read only; set local role authenticated");
  const result = (await db.query("select finance_read($1) as v", [section]))
    .rows[0].v;
  check(
    `finance_read ${section}: contrato y READ ONLY`,
    result.finance_layout === "bank_accounts_split" &&
      result.section === section &&
      (section === "summary" ? !!result.data : Array.isArray(result.data)),
  );
  await db.exec("rollback; reset role; delete from auth.current_user");
}
check(
  "00023 no habilita cobros CRM",
  (await as(staff, "select crm_options() as v")).rows[0].v.payments_enabled ===
    false,
);
const summary = await finance("summary");
check(
  "resumen conserva equivalentes guardados y excluye pendientes/cancelados/transferencias del dinero",
  summary.incomeMonth === 780 &&
    summary.expenseMonth === 50 &&
    summary.netMonth === 730 &&
    summary.txMonth === 5,
);
check(
  "deuda USD y NIO separada, sin compensar crédito ni inventar facturas",
  summary.totalOwed === 20 &&
    summary.totalOwedUsd === 3 &&
    summary.pendingInvoices === null,
);
check(
  "sesiones múltiples se cuentan sin fingir un único arqueo",
  summary.openRegisterCount === 2 &&
    summary.openRegister.openingAmountUsd !== undefined,
);
const receivables = await finance("receivables");
check(
  "cuentas no inventa mora ni fechas/facturas",
  receivables.length === 1 &&
    receivables[0].total_owed_nio === 20 &&
    receivables[0].total_owed_usd === 3 &&
    receivables[0].days_overdue === null &&
    receivables[0].oldest_due === null &&
    receivables[0].invoices_open === null,
);
const daily = await finance("daily");
check(
  "corte diario Managua y mensual no usa UTC",
  daily.find((d) => d.day === "2001-01-31")?.income_nio === 11 &&
    daily.find((d) => d.day === "2001-02-01")?.income_nio === 22 &&
    (await finance("monthly")).find((m) => m.month === "2001-01-01")
      ?.income_nio === 11,
);
check(
  "historial conserva moneda original, cancelados y transferencias visibles",
  (await finance("transactions")).some(
    (t) => t.currency === "USD" && t.amount === 12 && t.base_amount === 480,
  ) &&
    (await finance("transactions")).some((t) => t.status === "cancelled") &&
    (await finance("transactions")).some((t) => t.direction === "transfer"),
);
const methodTotals = await finance("method_totals");
check(
  "métodos excluyen pendientes/cancelados/transferencias",
  methodTotals.find((m) => m.payment_method_id === "test-usd")?.income_nio ===
    480 &&
    methodTotals.find((m) => m.payment_method_id === "test-nio")?.income_nio ===
      200,
);
check(
  "saldos informados siguen intactos, no calculados desde movimientos",
  (await finance("accounts")).find((a) => a.id === "test-usd")?.balance ===
    12 &&
    (await finance("accounts")).find((a) => a.id === "test-nio")?.balance ===
      900 &&
    (await snapshot()) === readSnapshot,
);
check(
  "RLS sigue activo en tablas financieras",
  (
    await row(
      "select bool_and(relrowsecurity) as ok from pg_class where oid in ('bank_accounts'::regclass,'transactions'::regclass,'member_balances'::regclass,'payment_methods'::regclass,'expense_categories'::regclass,'cash_sessions'::regclass)",
    )
  ).ok,
);
check(
  "member conserva sólo sus movimientos, no adquiere lectura de Caja",
  (await as(member, "select count(*)::int n from transactions")).rows[0].n ===
    1,
);
const originalDataQuery = `select jsonb_build_object('banks',(select jsonb_agg(to_jsonb(b) order by id) from bank_accounts b where id not like 'ejemplo-%'),'balances',(select jsonb_agg(to_jsonb(b) order by member_id) from member_balances b),'clients',(select jsonb_agg(to_jsonb(c) order by id) from gym_clients c where id<>'e0000000-0000-4000-8000-000000000023')) as data`;
const originalDataBeforeSeed = JSON.stringify(await row(originalDataQuery));
const seed = sql("supabase/EJEMPLOS-CAJA-OPCIONAL.sql");
const usersBefore = await row("select count(*)::int as n from auth.users");
const txBeforeSeed = JSON.stringify(
  (await db.query("select * from transactions order by id")).rows,
);
await db.exec(seed);
await db.exec(seed);
check(
  "ejemplos opt-in idempotentes: 2 cuentas en cero, un cliente demo sin perfil/plan",
  (
    await row(
      "select count(*)::int n from bank_accounts where id like 'ejemplo-%' and balance=0",
    )
  ).n === 2 &&
    (
      await row(
        "select count(*)::int n from gym_clients where id='e0000000-0000-4000-8000-000000000023' and is_demo and profile_id is null and plan_id is null",
      )
    ).n === 1,
);
check(
  "seed no crea usuarios ni movimientos",
  (await row("select count(*)::int n from auth.users")).n === usersBefore.n &&
    JSON.stringify(
      (await db.query("select * from transactions order by id")).rows,
    ) === txBeforeSeed,
);
check(
  "seed preserva cuentas, crédito/deuda y fichas existentes",
  JSON.stringify(await row(originalDataQuery)) === originalDataBeforeSeed,
);
await db.exec(
  "update bank_accounts set balance=19 where id='ejemplo-caja-usd-00023'",
);
await db.exec(seed);
check(
  "repetir ejemplos NO reinicia un saldo modificado",
  Number(
    (
      await row(
        "select balance from bank_accounts where id='ejemplo-caja-usd-00023'",
      )
    ).balance,
  ) === 19,
);
await db.exec(
  "update bank_accounts set name='Nombre real en conflicto' where id='ejemplo-caja-nio-00023'",
);
const conflicting = await snapshot();
await assert.rejects(db.exec(seed), /EJEMPLO_ACCOUNT_CONFLICT/);
await db.exec("rollback");
check(
  "conflicto de cuenta aborta sin alterar existentes",
  (await snapshot()) === conflicting,
);
await db.exec(
  "update bank_accounts set name='EJEMPLO - Caja NIO' where id='ejemplo-caja-nio-00023'; update gym_clients set is_demo=false where id='e0000000-0000-4000-8000-000000000023'",
);
await assert.rejects(db.exec(seed), /EJEMPLO_CLIENT_CONFLICT/);
await db.exec("rollback");
check(
  "seed nunca marca un cliente real como ejemplo",
  !(
    await row(
      "select is_demo from gym_clients where id='e0000000-0000-4000-8000-000000000023'",
    )
  ).is_demo,
);

await db.query("delete from member_balances where member_id=$1", [member]);
const missing = (await as(staff, "select crm_detail($1) as value", [linked]))
  .rows[0].value;
check(
  "saldo vinculado ausente sigue desconocido",
  missing.balance === null && missing.balances === null,
);
await db.exec(
  "alter table payment_methods rename column currency to changed_currency",
);
check(
  "esquema parcial no se acepta como compatible",
  (await row("select crm_finance_layout() as layout")).layout === "unsupported",
);
await reject(staff, "select crm_options()", [], /FINANCE_SCHEMA_UNSUPPORTED/);
await reject(
  staff,
  "select finance_read('summary')",
  [],
  /FINANCE_SCHEMA_UNSUPPORTED/,
);
await reject(staff, pay, args, /FINANCE_REVIEW_REQUIRED/);
const partial = (await as(staff, "select crm_detail($1) as value", [id]))
  .rows[0].value;
check(
  "ficha no financiera sigue disponible si esquema deja de coincidir",
  partial.client.id === id && partial.finance_layout === "unsupported",
);
const base = sql("supabase/migrations/00020_clients_crm.sql");
const original = base
  .slice(
    base.indexOf("create or replace function public.crm_record_payment("),
    base.indexOf("-- Directorio paginado"),
  )
  .replace(
    "function public.crm_record_payment(",
    "function public.crm_record_payment_repository(",
  )
  .trim();
check(
  "implementación privada nativa idéntica a FASE2 original",
  compat.includes(original),
);
await db.exec(`
create function public.diagnostic_test_trigger() returns trigger language plpgsql as $$
begin raise exception 'DIAGNOSTIC_EXECUTED_A_TRIGGER'; end; $$;
create trigger diagnostic_test_trigger before insert on public.transactions
for each row execute function public.diagnostic_test_trigger();
`);
await db.exec("begin read only");
const metadata = await db.query(
  sql("supabase/DIAGNOSTICO-ESCRITURA-FINANCIERA.sql"),
);
const exported = JSON.parse(metadata.rows[0].diagnostico);
check(
  "diagnóstico de escritores/vistas/permisos es sólo lectura y no exporta movimientos",
  metadata.rows.length === 1 &&
    Array.isArray(exported.funciones) &&
    Array.isArray(exported.vistas) &&
    Array.isArray(exported.politicas) &&
    !metadata.rows[0].diagnostico.includes("Movimiento ficticio previo"),
);
check(
  "diagnóstico incluye disparadores y su implementación sin ejecutarlos",
  exported.disparadores.some((t) => t.nombre === "diagnostic_test_trigger") &&
    exported.funciones.some((f) =>
      f.definicion.includes("DIAGNOSTIC_EXECUTED_A_TRIGGER"),
    ),
);
check(
  "diagnóstico incluye restricciones y valores por defecto para revisar escritura",
  exported.restricciones.length > 0 &&
    exported.columnas.some((c) => c.column_default !== null),
);
await db.exec("rollback");
await db.close();
console.log(`\n🎉 Compatibilidad CRM: ${count} comprobaciones pasaron\n`);
