import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildRows, dailyClose, managuaDay, monthlyComparison, commissionsByMethod, pendingPayments, totalsFor, cents,
} from "../src/lib/reports/finance-report.ts";
import { buildMasterWorkbook, MASTER_FILENAME } from "../src/lib/reports/workbook.ts";
import ExcelJS from "exceljs";
import { createLoader } from "./helpers/react-loader.mjs";

const { loadFinanceReport } = await createLoader({
  "server-only": "export {};",
})("lib/reports/load.ts");

const maps = {
  methods: { efectivo_nio: { name: "Efectivo Córdobas", feePct: 0 }, tarjeta_pos: { name: "Tarjeta POS", feePct: 3.5 } },
  categories: { alquiler: "Alquiler" },
  accounts: { caja: "Caja NIO" },
  clients: { c1: "Ana" },
};
const base = { currency: "NIO", fxUsed: null, accountId: "caja", clientId: null, reference: null, cashReceived: null, changeGiven: null, debtBefore: null, debtAfter: null };
const inputs = [
  // 2026-10-18 21:30 Managua (03:30Z del 19)
  { ...base, id: "t1", occurredAt: "2026-10-19T03:30:00Z", type: "income", status: "completed", amount: 100, amountNio: 100, amountUsd: 2.5, methodId: "tarjeta_pos", clientId: "c1", concept: "Mensualidad", kind: "service_income", cashReceived: 100, changeGiven: 0 },
  { ...base, id: "t2", occurredAt: "2026-10-18T15:00:00Z", type: "income", status: "completed", amount: 200, amountNio: 200, amountUsd: 5, methodId: "efectivo_nio", clientId: "c1", concept: "Abono", kind: "debt_payment", cashReceived: 250, changeGiven: 50, debtBefore: 300, debtAfter: 100 },
  { ...base, id: "t3", occurredAt: "2026-10-18T16:00:00Z", type: "expense", status: "completed", amount: 1000, amountNio: 1000, amountUsd: 27, methodId: null, categoryId: "alquiler", concept: "Alquiler", kind: "expense" },
  { ...base, id: "t4", occurredAt: "2026-10-18T17:00:00Z", type: "income", status: "pending", amount: 999, amountNio: 999, amountUsd: 27, methodId: "efectivo_nio", concept: "Pendiente", kind: "service_income" },
  { ...base, id: "t5", occurredAt: "2026-10-18T17:30:00Z", type: "income", status: "cancelled", amount: 888, amountNio: 888, amountUsd: 24, methodId: "efectivo_nio", concept: "Anulado", kind: "service_income" },
  { ...base, id: "t6", occurredAt: "2026-10-18T18:00:00Z", type: "transfer", status: "completed", amount: 500, amountNio: 500, amountUsd: 13, methodId: "efectivo_nio", concept: "Transferencia", kind: "legacy" },
  { ...base, id: "t7", occurredAt: "2026-09-02T18:00:00Z", type: "expense", status: "completed", amount: 40, amountNio: 40, amountUsd: 1, methodId: null, categoryId: "alquiler", concept: "Setiembre", kind: "expense" },
];
const rows = buildRows(inputs, maps);

test("día y mes se calculan en America/Managua", () => {
  assert.equal(managuaDay("2026-10-19T03:30:00Z"), "2026-10-18");
  assert.equal(managuaDay("2026-10-19T06:30:00Z"), "2026-10-19");
});

test("cierre del día: sólo completados, neto y efectivo", () => {
  const c = dailyClose(rows, "2026-10-18");
  assert.equal(c.incomeNio, 300);
  assert.equal(c.expenseNio, 1000);
  assert.equal(c.netNio, -700);
  assert.equal(c.count, 3);
  assert.equal(c.cashReceivedNio, 350);
  assert.equal(c.changeGivenNio, 50);
  assert.equal(c.pending.length, 1);
  assert.equal(c.cancelled.length, 1);
  assert.deepEqual(c.byMethod.map((m) => [m.methodName, m.incomeNio]).sort(), [["Efectivo Córdobas", 200], ["Tarjeta POS", 100]].sort());
});

test("comisión estimada sólo en ingresos completados y por método", () => {
  const t1 = rows.find((r) => r.id === "t1");
  assert.equal(t1.commissionNio, 3.5);
  assert.equal(rows.find((r) => r.id === "t4").commissionNio, 0);
  assert.equal(dailyClose(rows, "2026-10-18").commissionNio, 3.5);
});

test("comparativo mensual: 12 meses, cronológico, sin transferencias", () => {
  const m = monthlyComparison(rows, "2026-10-18", 12);
  assert.equal(m.length, 12);
  assert.equal(m[0].month, "2025-11");
  assert.equal(m.at(-1).month, "2026-10");
  const oct = m.at(-1);
  assert.equal(oct.incomeNio, 300);
  assert.equal(oct.expenseNio, 1000);
  assert.equal(oct.netNio, -700);
  const sep = m.find((x) => x.month === "2026-09");
  assert.equal(sep.expenseNio, 40);
});

test("pagos pendientes: último saldo por cliente, sin compensar monedas", () => {
  const entries = [
    { id: "e1", clientId: "c1", clientName: "Ana", occurredAt: "2026-10-01T10:00:00Z", kind: "charge", amount: 300, currency: "NIO", before: null, after: { debtNio: 300, debtUsd: 0, creditNio: 0, creditUsd: 0 }, concept: "Cargo", actorName: null, transactionId: null },
    { id: "e2", clientId: "c1", clientName: "Ana", occurredAt: "2026-10-05T10:00:00Z", kind: "payment", amount: 200, currency: "NIO", before: { debtNio: 300, debtUsd: 0, creditNio: 0, creditUsd: 0 }, after: { debtNio: 100, debtUsd: 0, creditNio: 0, creditUsd: 0 }, concept: "Abono", actorName: "Caja", transactionId: "t2" },
    { id: "e3", clientId: "c2", clientName: "Luis", occurredAt: "2026-10-02T10:00:00Z", kind: "charge", amount: 20, currency: "USD", before: null, after: { debtNio: 0, debtUsd: 20, creditNio: 0, creditUsd: 0 }, concept: "Cargo USD", actorName: null, transactionId: null },
    { id: "e4", clientId: "c3", clientName: "Mara", occurredAt: "2026-10-03T10:00:00Z", kind: "charge", amount: 50, currency: "NIO", before: null, after: { debtNio: 0, debtUsd: 0, creditNio: 0, creditUsd: 0 }, concept: "Saldado", actorName: null, transactionId: null },
  ];
  const p = pendingPayments(entries);
  assert.deepEqual(p.map((x) => x.clientName), ["Ana", "Luis"]);
  assert.equal(p[0].balance.debtNio, 100);
  assert.equal(p[1].balance.debtUsd, 20);
  assert.equal(p[1].balance.debtNio, 0);
  const t = totalsFor(rows, p, "2026-10-01", "2026-10-31");
  assert.equal(t.pendingDebtNio, 100);
  assert.equal(t.pendingDebtUsd, 20);
});

test("comisiones por método en el período", () => {
  const c = commissionsByMethod(rows, "2026-10-01", "2026-10-31");
  const pos = c.find((x) => x.methodName === "Tarjeta POS");
  assert.equal(pos.grossNio, 100);
  assert.equal(pos.commissionNio, 3.5);
  assert.equal(c.some((x) => x.methodName === "Efectivo Córdobas" && x.commissionNio === 0), true);
});

test("cents evita arrastre de punto flotante", () => {
  assert.equal(cents(0.1 + 0.2), 0.3);
});

test("Excel maestro: nombre fijo, hojas y cifras con los mismos datos", async () => {
  const data = { generatedAt: "2026-10-19T03:30:00Z", rows, debtEntries: [], maps };
  const buf = await buildMasterWorkbook(data, new Date("2026-10-19T03:30:00Z"));
  assert.equal(MASTER_FILENAME, "Power-Box-Gym-Maestro.xlsx");
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(buf);
  assert.deepEqual(wb.worksheets.map((w) => w.name), [
    "Resumen", "Movimientos", "Cierre diario", "Comparativo mensual", "Gastos por categoría",
    "Pagos pendientes", "Historial de deudas", "Comisiones",
  ]);
  const mov = wb.getWorksheet("Movimientos");
  assert.equal(mov.rowCount, inputs.length + 1);
  const daily = wb.getWorksheet("Cierre diario");
  const day = [];
  daily.eachRow((r, n) => { if (n > 1) day.push([String(r.getCell(1).value), r.getCell(2).value, r.getCell(3).value]); });
  assert.deepEqual(day.find((d) => d[0] === "2026-10-18"), ["2026-10-18", 300, 1000]);
});

test("cierre de caja sin saldos ni ledger de deudas: el comprobante conserva cuenta y tipo abono", async () => {
  const tables = {
    transactions: [{
      id: "tx-abono",
      occurred_at: "2026-10-18T15:00:00Z",
      type: "income",
      status: "completed",
      amount: 200,
      currency: "NIO",
      amount_nio: 200,
      amount_usd: 5,
      fx_used: 40,
      method_id: "efectivo_nio",
      category_id: null,
      account_id: "caja",
      client_id: "c1",
      concept: "Abono",
      reference: null,
    }],
    finance_entries: [{
      transaction_id: "tx-abono",
      receipt: {
        kind: "debt_payment",
        accountId: "caja",
        accountName: "Caja NIO",
        cashReceived: 250,
        changeGiven: 50,
        debtBefore: 300,
        debtAfter: 100,
      },
    }],
    // La RLS de cuentas por cobrar y de saldos devuelve estas tablas vacías.
    client_debt_entries: [],
    bank_accounts: [],
    payment_methods: [{ id: "efectivo_nio", name: "Efectivo Córdobas", fee_pct: 0 }],
    expense_categories: [],
    gym_clients: [{ id: "c1", full_name: "Ana" }],
  };
  const supabase = {
    from(table) {
      const chain = {
        select: () => chain,
        order: () => chain,
        range: async () => ({ data: tables[table] ?? [], error: null }),
      };
      return chain;
    },
  };

  const report = await loadFinanceReport(supabase);
  assert.equal(report.rows[0].kind, "debt_payment");
  assert.equal(report.rows[0].accountName, "Caja NIO");
  assert.equal(report.rows[0].debtBefore, 300);
  assert.equal(report.rows[0].debtAfter, 100);
});
