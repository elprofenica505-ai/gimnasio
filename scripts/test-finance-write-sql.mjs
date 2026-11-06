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

await db.exec(sql("supabase/migrations/00022_crm_finance_compat.sql"));
await db.exec(sql("supabase/migrations/00023_finance_read_bank_accounts.sql"));
const migration = sql("supabase/migrations/00024_finance_movements.sql");
const businessSnapshot = async () =>
  JSON.stringify(
    (
      await db.query(`
select 'account' as kind,to_jsonb(a) as row from bank_accounts a
union all select 'balance',to_jsonb(b) from member_balances b
union all select 'tx',to_jsonb(t) from transactions t
union all select 'client',to_jsonb(c) from gym_clients c order by kind,row`)
    ).rows,
  );
const before = await businessSnapshot();
await db.exec(migration);
await db.exec(migration);
check(
  "instalación idempotente conserva históricos, cuentas, saldos y fichas",
  (await businessSnapshot()) === before,
);

const { randomUUID } = await import("node:crypto");
const balanceBefore = JSON.stringify(
  (await db.query("select * from member_balances order by member_id")).rows,
);
const planBefore = JSON.stringify(
  (await db.query("select id,plan_id,status from gym_clients order by id"))
    .rows,
);
await db.exec(
  "insert into expense_categories(id,name) values('test-category','Gasto EJEMPLO')",
);
const call =
  "select finance_record_movement($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) as id";
const args = [
  randomUUID(),
  "service_income",
  id,
  100,
  "NIO",
  "test-both",
  "test-nio",
  "Servicio EJEMPLO",
  40,
  null,
];
const tx = (await as(staff, call, args)).rows[0].id;
const receipt = (await as(staff, "select finance_receipt($1) as value", [tx]))
  .rows[0].value;
check(
  "cobro sin login/teléfono crea movimiento, saldo y comprobante con actor",
  receipt.clientId === id &&
    receipt.actorId === staff &&
    receipt.accountBefore === 900 &&
    receipt.accountAfter === 1000,
);
check(
  "NIO con tasa explícita guarda equivalentes sin tocar moneda de la cuenta",
  receipt.amountNio === 100 && receipt.amountUsd === 2.5 && receipt.fx === 40,
);
const state = async () =>
  JSON.stringify(
    (
      await db.query(`select jsonb_build_object(
 'accounts',(select jsonb_agg(to_jsonb(a) order by id) from bank_accounts a),
 'tx',(select jsonb_agg(to_jsonb(t) order by id) from transactions t),
 'entries',(select jsonb_agg(to_jsonb(e) order by transaction_id) from finance_entries e),
 'events',(select jsonb_agg(to_jsonb(e) order by id) from client_events e)) as value`)
    ).rows[0].value,
  );
let snapshot = await state();
check(
  "respuesta perdida: reintento mismo UUID devuelve comprobante sin repetir saldo/evento",
  (await as(admin, call, args)).rows[0].id === tx &&
    (await state()) === snapshot,
);
check(
  "concepto normalizado no cambia identidad",
  (
    await as(
      staff,
      call,
      args.map((v, i) => (i === 7 ? " Servicio EJEMPLO " : v)),
    )
  ).rows[0].id === tx,
);
for (const [index, value] of [
  [1, "expense"],
  [2, linked],
  [3, 101],
  [4, "USD"],
  [5, "test-nio"],
  [6, "test-usd"],
  [7, "Otro concepto"],
  [8, 41],
  [9, "test-category"],
]) {
  const changed = [...args];
  changed[index] = value;
  await reject(staff, call, changed, /REQUEST_CONFLICT/);
}
check(
  "conflictos no alteran movimiento ni saldo",
  (await state()) === snapshot,
);
for (const who of [null, member]) {
  await reject(
    who,
    call,
    [randomUUID(), ...args.slice(1)],
    who ? /AUTH/ : /permission denied/,
  );
  await reject(
    who,
    "select finance_options()",
    [],
    who ? /AUTH/ : /permission denied/,
  );
  await reject(
    who,
    "select finance_receipt($1)",
    [tx],
    who ? /AUTH/ : /permission denied/,
  );
  await reject(
    who,
    "select finance_recent_receipts('expense')",
    [],
    who ? /AUTH/ : /permission denied/,
  );
}
// Una referencia confirmada no permite eludir un rol retirado posteriormente.
await db.query("update profiles set role='member' where id=$1", [staff]);
await reject(staff, call, args, /AUTH/);
await reject(staff, "select finance_receipt($1)", [tx], /AUTH/);
check("rol retirado: reintento y lectura no alteran saldo, transacción ni evento", (await state()) === snapshot);
await db.query("update profiles set role='staff' where id=$1", [staff]);
check("rol restaurado: misma referencia recupera el recibo original sin duplicar", (await as(staff, call, args)).rows[0].id === tx && (await state()) === snapshot);
check(
  "RLS oculta comprobantes al cliente",
  (await as(member, "select * from finance_entries")).rows.length === 0,
);
for (const who of [staff, admin])
  for (const statement of [
    "update bank_accounts set balance=0",
    "update transactions set concept='evil'",
    "delete from transactions",
    "truncate transactions",
    "update finance_entries set receipt='{}'::jsonb",
    "delete from finance_entries",
    "insert into finance_entries(transaction_id,request_id,payload,receipt) values(gen_random_uuid(),gen_random_uuid(),'{}','{}')",
  ])
    await reject(who, statement, [], /permission denied/);
const bad = [
  [0, null, "INVALID_REQUEST"],
  [1, "transfer", "INVALID_PAYMENT"],
  [2, null, "INVALID_PAYMENT"],
  [2, randomUUID(), "NOT_FOUND"],
  [3, 0, "INVALID_PAYMENT"],
  [3, -1, "INVALID_PAYMENT"],
  [3, 1.001, "INVALID_PAYMENT"],
  [3, 100000000, "INVALID_PAYMENT"],
  [4, "EUR", "INVALID_PAYMENT"],
  [5, "test-off", "INVALID_METHOD"],
  [5, "test-usd", "INVALID_METHOD"],
  [5, "missing", "INVALID_METHOD"],
  [6, "test-off", "INVALID_ACCOUNT"],
  [6, "test-usd", "INVALID_ACCOUNT"],
  [6, "missing", "INVALID_ACCOUNT"],
  [7, "x", "INVALID_PAYMENT"],
  [8, 0, "INVALID_PAYMENT"],
  [8, null, "INVALID_PAYMENT"],
  [8, 0.00001, "INVALID_PAYMENT"],
  [8, 10001, "INVALID_PAYMENT"],
  [3, "NaN", "INVALID_PAYMENT"],
  [9, "test-category", "INVALID_PAYMENT"],
];
snapshot = await state();
for (const [index, value, code] of bad) {
  const p = [randomUUID(), ...args.slice(1)];
  p[index] = value;
  await reject(staff, call, p, new RegExp(code));
}
await reject(
  staff,
  call,
  [
    randomUUID(),
    "service_income",
    id,
    99999999,
    "NIO",
    "test-both",
    "test-nio",
    "Equivalente excedido",
    0.0001,
    null,
  ],
  /INVALID_PAYMENT/,
);
await reject(
  staff,
  call,
  [
    randomUUID(),
    "service_income",
    id,
    99999999,
    "USD",
    "test-both",
    "test-usd",
    "Equivalente excedido",
    10000,
    null,
  ],
  /INVALID_PAYMENT/,
);
check("rechazos no dejan efectos parciales", (await state()) === snapshot);
const usd = [
  randomUUID(),
  "service_income",
  linked,
  2.5,
  "USD",
  "test-usd",
  "test-usd",
  "Servicio USD EJEMPLO",
  36.7244,
  null,
];
const usdId = (await as(admin, call, usd)).rows[0].id;
const ur = (await as(staff, "select finance_receipt($1) as value", [usdId]))
  .rows[0].value;
check(
  "USD: saldo suma dólares, equivalente NIO usa tasa guardada exacta",
  ur.amountNio === 91.81 &&
    ur.amountUsd === 2.5 &&
    ur.accountAfter === 14.5 &&
    ur.actorId === admin,
);
const expense = [
  randomUUID(),
  "expense",
  null,
  30,
  "USD",
  "test-both",
  "test-usd",
  "Gasto USD EJEMPLO",
  36.7244,
  "test-category",
];
const expenseId = (await as(staff, call, expense)).rows[0].id;
const er = (await as(staff, "select finance_receipt($1) as value", [expenseId]))
  .rows[0].value;
check(
  "gasto guarda categoría, autor y saldo propio incluso negativo, sin convertir cuenta",
  er.kind === "expense" &&
    er.categoryName === "Gasto EJEMPLO" &&
    er.accountAfter === -15.5 &&
    er.amountNio === 1101.73,
);
await reject(
  staff,
  call,
  [
    randomUUID(),
    "expense",
    null,
    5,
    "NIO",
    "test-both",
    "test-nio",
    "Sin categoría",
    40,
    "missing",
  ],
  /INVALID_CATEGORY/,
);
await reject(
  staff,
  call,
  [
    randomUUID(),
    "expense",
    id,
    5,
    "NIO",
    "test-both",
    "test-nio",
    "Con cliente indebido",
    40,
    "test-category",
  ],
  /INVALID_PAYMENT/,
);
check(
  "cobrar no cambia crédito, deuda, fecha de pago de deuda ni planes",
  balanceBefore ===
    JSON.stringify(
      (await db.query("select * from member_balances order by member_id")).rows,
    ) &&
    planBefore ===
      JSON.stringify(
        (
          await db.query(
            "select id,plan_id,status from gym_clients order by id",
          )
        ).rows,
      ),
);
await db.exec(`create function public.test_fail_event() returns trigger language plpgsql as $$begin raise exception 'TEST_ROLLBACK_EVENT'; end$$;
create trigger test_fail_event before insert on public.client_events for each row execute function public.test_fail_event();`);
snapshot = await state();
await reject(
  staff,
  call,
  [randomUUID(), ...args.slice(1)],
  /TEST_ROLLBACK_EVENT/,
);
check(
  "error de auditoría revierte movimiento, saldo y comprobante juntos",
  (await state()) === snapshot,
);
await db.exec("drop trigger test_fail_event on public.client_events");
await db.exec(`create function public.test_finance_trigger() returns trigger language plpgsql as $$begin return new;end$$;
create trigger test_finance_trigger before insert on public.transactions for each row execute function public.test_finance_trigger();`);
check(
  "un trigger nuevo deshabilita nuevas escrituras",
  !(await as(staff, "select finance_options() as value")).rows[0].value
    .writes_enabled,
);
await reject(
  staff,
  call,
  [randomUUID(), ...args.slice(1)],
  /FINANCE_REVIEW_REQUIRED/,
);
check(
  "reintento confirmado sigue siendo recuperable con trigger nuevo",
  (await as(staff, call, args)).rows[0].id === tx,
);
await assert.rejects(db.exec(migration), /FINANCE_TRIGGER_REVIEW_REQUIRED/);
await db.exec("rollback");
count++;
await db.exec("drop trigger test_finance_trigger on public.transactions");
await db.exec("grant update on bank_accounts to authenticated");
await reject(
  staff,
  call,
  [randomUUID(), ...args.slice(1)],
  /FINANCE_REVIEW_REQUIRED/,
);
await db.exec("revoke update on bank_accounts from authenticated");
await db.exec(
  "update bank_accounts set name='Cuenta renombrada';update payment_methods set name='Método renombrado';update gym_clients set full_name='Cliente renombrado' where id='" +
    id +
    "'",
);
check(
  "comprobante conserva nombres y saldos originales después de editar catálogos",
  JSON.stringify(
    (await as(staff, "select finance_receipt($1) as value", [tx])).rows[0]
      .value,
  ) === JSON.stringify(receipt),
);
await reject(
  staff,
  "select finance_receipt($1)",
  [randomUUID()],
  /RECEIPT_NOT_FOUND/,
);
await reject(
  staff,
  "select finance_recent_receipts('service_income')",
  [],
  /INVALID_PAYMENT/,
);
const clientReceipts = (
  await as(
    staff,
    "select finance_recent_receipts('service_income',$1) as value",
    [id],
  )
).rows[0].value;
check(
  "historial por cliente no mezcla fichas",
  clientReceipts.length === 1 && clientReceipts[0].id === tx,
);
for (let i = 0; i < 51; i++)
  await as(staff, call, [
    randomUUID(),
    "expense",
    null,
    1,
    "NIO",
    "test-both",
    "test-nio",
    "Gasto paginación EJEMPLO",
    40,
    "test-category",
  ]);
const history = (
  await as(staff, "select finance_recent_receipts('expense') as value")
).rows[0].value;
check(
  "historial limita a 50 y ordena los últimos comprobantes",
  history.length === 50 &&
    history.every((r) => r.kind === "expense") &&
    !history.some((r) => r.id === expenseId),
);
const report = (await as(staff, "select finance_read('monthly') as value"))
  .rows[0].value.data;
const sum = (
  await row(
    "select sum(case when type='income' then amount_nio else -amount_nio end) as net from transactions where status='completed'",
  )
).net;
check(
  "reportes incluyen cobros y gastos nuevos con equivalentes guardados",
  Math.abs(report.reduce((n, r) => n + r.net_nio, 0) - Number(sum)) < 0.0001,
);
check(
  "el cobro legacy continúa bloqueado: UI vieja no puede inventar tasa NIO=1",
  (await as(staff, "select crm_options() as value")).rows[0].value
    .payments_enabled === false,
);
await db.close();
console.log(
  `\n🎉 Escritura financiera: ${count} comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)\n`,
);
