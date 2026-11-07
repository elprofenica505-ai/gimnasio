import { test } from "node:test";
import assert from "node:assert/strict";
import ExcelJS from "exceljs";
import { buildRows } from "../src/lib/reports/finance-report.ts";
import {
  NO_FILTERS,
  buildMovementsCsv,
  csvCell,
  describeFilters,
  exportFilename,
  filterDebtEntries,
  filterLedger,
  filterPending,
  parseExportFilters,
} from "../src/lib/reports/export-filter.ts";
import { buildFilteredWorkbook, buildMasterWorkbook } from "../src/lib/reports/workbook.ts";

const maps = {
  methods: { m1: { name: "Efectivo", feePct: 0 }, m2: { name: "Tarjeta", feePct: 3 } },
  categories: { c1: "Limpieza" },
  accounts: { a1: "Caja fuerte" },
  clients: { k1: "ANA EJEMPLO", k2: "LUIS EJEMPLO" },
};
const base = { currency: "NIO", amountUsd: 0, fxUsed: null, categoryId: null, accountId: null, cashReceived: null, changeGiven: null, debtBefore: null, debtAfter: null, reference: null };
const inputs = [
  { ...base, id: "T1", occurredAt: "2026-10-21T15:00:00Z", type: "income", status: "completed", amount: 500, amountNio: 500, methodId: "m1", clientId: "k1", concept: "Mensualidad", kind: "service_income" },
  { ...base, id: "T2", occurredAt: "2026-10-22T03:00:00Z", type: "income", status: "completed", amount: 1000, amountNio: 1000, methodId: "m2", clientId: "k2", concept: "Pago \"anual\", julio", kind: "service_income" },
  { ...base, id: "T3", occurredAt: "2026-10-10T12:00:00Z", type: "expense", status: "completed", amount: 300, amountNio: 300, methodId: null, categoryId: "c1", accountId: "a1", concept: "=HYPERLINK(\"x\")", kind: "expense" },
  { ...base, id: "T4", occurredAt: "2026-10-15T12:00:00Z", type: "income", status: "pending", amount: 200, amountNio: 200, methodId: "m1", clientId: "k1", concept: "Pendiente", kind: "service_income" },
  { ...base, id: "T5", occurredAt: "2026-10-16T12:00:00Z", type: "income", status: "cancelled", amount: 800, amountNio: 800, methodId: "m2", clientId: null, concept: "Anulado", kind: "service_income" },
  { ...base, id: "T6", occurredAt: "2026-10-18T12:00:00Z", type: "transfer", status: "completed", amount: 100, amountNio: 100, methodId: null, concept: "Traspaso", kind: "legacy" },
];
const rows = buildRows(inputs, maps);
const ids = (xs) => xs.map((r) => r.id).sort();
const params = (obj) => new URLSearchParams(obj);

test("sin filtros se exporta todo el historial", () => {
  const r = parseExportFilters(params({}));
  assert.equal(r.ok, true);
  assert.deepEqual(r.filters, NO_FILTERS);
  assert.deepEqual(ids(filterLedger(rows, r.filters)), ["T1", "T2", "T3", "T4", "T5", "T6"]);
});

test("una fecha imposible o un rango al revés se rechaza", () => {
  assert.equal(parseExportFilters(params({ from: "2026-02-30" })).ok, false);
  assert.equal(parseExportFilters(params({ to: "21/10/2026" })).ok, false);
  const reversed = parseExportFilters(params({ from: "2026-10-22", to: "2026-10-01" }));
  assert.equal(reversed.ok, false);
  assert.match(reversed.message, /posterior/);
});

test("tipo, estado e identificadores desconocidos se rechazan, no se ignoran", () => {
  assert.equal(parseExportFilters(params({ kind: "todo" })).ok, false);
  assert.equal(parseExportFilters(params({ status: "borrado" })).ok, false);
  assert.equal(parseExportFilters(params({ client: "x;DROP" })).ok, false);
  assert.equal(parseExportFilters(params({ method: "a".repeat(65) })).ok, false);
});

test("el rango de fechas es inclusivo y usa el día de Managua", () => {
  // 2026-10-22 03:00 UTC es 21 de octubre 21:00 en Managua: cuenta el 21, no el 22.
  const day21 = parseExportFilters(params({ from: "2026-10-21", to: "2026-10-21" })).filters;
  assert.deepEqual(ids(filterLedger(rows, day21)), ["T1", "T2"]);
  const day22 = parseExportFilters(params({ from: "2026-10-22", to: "2026-10-22" })).filters;
  assert.deepEqual(ids(filterLedger(rows, day22)), []);
});

test("tipo ingreso excluye transferencias; estado completado excluye pendientes y anulados", () => {
  const f = parseExportFilters(params({ kind: "income", status: "completed" })).filters;
  assert.deepEqual(ids(filterLedger(rows, f)), ["T1", "T2"]);
});

test("método, categoría y cliente se combinan con Y", () => {
  assert.deepEqual(ids(filterLedger(rows, parseExportFilters(params({ method: "m2" })).filters)), ["T2", "T5"]);
  assert.deepEqual(ids(filterLedger(rows, parseExportFilters(params({ category: "c1" })).filters)), ["T3"]);
  assert.deepEqual(ids(filterLedger(rows, parseExportFilters(params({ client: "k1" })).filters)), ["T1", "T4"]);
  const combined = parseExportFilters(params({ method: "m2", status: "completed" })).filters;
  assert.deepEqual(ids(filterLedger(rows, combined)), ["T2"]);
});

test("los pagos pendientes sólo se filtran por cliente, con saldo completo", () => {
  const pending = [
    { clientId: "k1", clientName: "ANA EJEMPLO", balance: { debtNio: 100, debtUsd: 0, creditNio: 0, creditUsd: 0 }, lastEntryAt: "x", entries: [] },
    { clientId: "k2", clientName: "LUIS EJEMPLO", balance: { debtNio: 50, debtUsd: 0, creditNio: 0, creditUsd: 0 }, lastEntryAt: "x", entries: [] },
  ];
  const byDate = parseExportFilters(params({ from: "2026-10-21" })).filters;
  assert.equal(filterPending(pending, byDate).length, 2);
  const byClient = parseExportFilters(params({ client: "k2" })).filters;
  assert.deepEqual(filterPending(pending, byClient).map((p) => p.clientId), ["k2"]);
});

test("el historial de deudas respeta fecha y cliente", () => {
  const entries = [
    { id: "d1", clientId: "k1", occurredAt: "2026-10-21T15:00:00Z" },
    { id: "d2", clientId: "k2", occurredAt: "2026-10-01T15:00:00Z" },
  ];
  const f = parseExportFilters(params({ from: "2026-10-15", client: "k1" })).filters;
  assert.deepEqual(filterDebtEntries(entries, f).map((e) => e.id), ["d1"]);
});

test("la descripción de filtros usa nombres legibles y «Todos» cuando no hay filtro", () => {
  const f = parseExportFilters(params({ from: "2026-10-01", method: "m2" })).filters;
  const map = Object.fromEntries(describeFilters(f, maps));
  assert.equal(map["Desde (Managua)"], "2026-10-01");
  assert.equal(map["Hasta (Managua)"], "Hoy");
  assert.equal(map["Método de pago"], "Tarjeta");
  assert.equal(map.Cliente, "Todos");
});

test("el nombre del archivo incluye el rango", () => {
  assert.equal(exportFilename(NO_FILTERS, "csv"), "Power-Box-Gym-Reporte_inicio_a_hoy.csv");
  const f = parseExportFilters(params({ from: "2026-10-01", to: "2026-10-21" })).filters;
  assert.equal(exportFilename(f, "xlsx"), "Power-Box-Gym-Reporte_2026-10-01_a_2026-10-21.xlsx");
});

test("CSV: acentos con BOM, comillas escapadas y sin fórmulas ejecutables", () => {
  assert.equal(csvCell("=1+1"), "'=1+1");
  assert.equal(csvCell("-5 algo"), "'-5 algo");
  assert.equal(csvCell("a,b"), "\"a,b\"");
  assert.equal(csvCell("dice \"hola\""), "\"dice \"\"hola\"\"\"");
  assert.equal(csvCell(-12.5), "-12.5");
  assert.equal(csvCell(null), "");
  const csv = buildMovementsCsv(filterLedger(rows, NO_FILTERS));
  assert.equal(csv.charCodeAt(0), 0xfeff);
  const lines = csv.slice(1).trim().split("\r\n");
  assert.equal(lines.length, 1 + rows.length);
  assert.match(csv, /"Pago ""anual"", julio"/);
  assert.match(csv, /'=HYPERLINK/);
});

test("el Excel filtrado sólo trae los movimientos que cumplen; el maestro trae todos", async () => {
  const data = { generatedAt: "", rows, debtEntries: [], maps };
  const f = parseExportFilters(params({ method: "m2", status: "completed" })).filters;

  const filtered = new ExcelJS.Workbook();
  await filtered.xlsx.load(await buildFilteredWorkbook(data, f));
  assert.equal(filtered.getWorksheet("Movimientos").rowCount - 1, 1);
  const resumen = filtered.getWorksheet("Resumen");
  const texts = [];
  resumen.eachRow((r) => texts.push(String(r.getCell(1).value)));
  assert.ok(texts.includes("Reporte filtrado"));
  assert.ok(texts.includes("Método de pago"));

  const master = new ExcelJS.Workbook();
  await master.xlsx.load(await buildMasterWorkbook(data));
  assert.equal(master.getWorksheet("Movimientos").rowCount - 1, rows.length);
});

test("un rango sin movimientos produce un Excel válido con aviso, no un error", async () => {
  const data = { generatedAt: "", rows, debtEntries: [], maps };
  const f = parseExportFilters(params({ from: "2001-01-01", to: "2001-01-02" })).filters;
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(await buildFilteredWorkbook(data, f));
  assert.equal(wb.getWorksheet("Movimientos").rowCount - 1, 0);
  let note = "";
  wb.getWorksheet("Resumen").eachRow((r) => {
    if (String(r.getCell(1).value) === "Movimientos incluidos") note = String(r.getCell(3).value);
  });
  assert.match(note, /Ningún movimiento/);
});

test("el Excel guarda textos que parecen fórmulas como texto neutralizado", async () => {
  const data = { generatedAt: "", rows, debtEntries: [], maps };
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(await buildMasterWorkbook(data));
  const all = [];
  wb.eachSheet((ws) => ws.eachRow((r) => r.eachCell((c) => all.push(String(c.value)))));
  assert.ok(all.some((v) => v === "'=HYPERLINK(\"x\")"));
  assert.ok(!all.some((v) => v.startsWith("=HYPERLINK")));
});

test("el Excel filtrado tiene formato de tabla: fechas reales, montos con miles, bordes y filas alternadas", async () => {
  const data = { generatedAt: "", rows, debtEntries: [], maps };
  const f = parseExportFilters(params({})).filters;
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(await buildFilteredWorkbook(data, f));
  const mv = wb.getWorksheet("Movimientos");
  const dateCell = mv.getRow(2).getCell(1);
  assert.ok(dateCell.value instanceof Date, "la fecha debe ser fecha real, no texto");
  assert.equal(dateCell.numFmt, "dd/mm/yyyy hh:mm");
  const amountCol = mv.getRow(1).values.indexOf("Monto");
  assert.equal(mv.getRow(2).getCell(amountCol).numFmt, "#,##0.00;[Red]-#,##0.00");
  assert.ok(mv.getRow(2).getCell(1).border?.top);
  assert.equal(mv.getRow(3).getCell(1).fill?.fgColor?.argb, "FFF1F5F9");
  assert.equal(mv.getRow(1).getCell(1).fill?.fgColor?.argb, "FF0F172A");
  assert.equal(mv.views[0].state, "frozen");
});

test("el Excel maestro conserva sus fechas como texto y sin tabla", async () => {
  const data = { generatedAt: "", rows, debtEntries: [], maps };
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(await buildMasterWorkbook(data));
  const cell = wb.getWorksheet("Movimientos").getRow(2).getCell(1);
  assert.equal(typeof cell.value, "string");
  assert.equal(cell.border, undefined);
});
