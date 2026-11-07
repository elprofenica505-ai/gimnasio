import ExcelJS from "exceljs";
import {
  KIND_LABEL,
  commissionsByMethod,
  dailyClose,
  groupBy,
  managuaDay,
  managuaMonth,
  monthlyComparison,
  pendingPayments,
  totalsFor,
  type LedgerRow,
  type DebtEntryRow,
} from "./finance-report.ts";
import {
  MOVEMENT_HEADERS,
  describeFilters,
  filterDebtEntries,
  filterLedger,
  filterPending,
  type ExportFilters,
} from "./export-filter.ts";
import type { FinanceReportData } from "./load";
import { presentSheet } from "./present.ts";

/** Nombre fijo: el Excel maestro siempre se llama igual y se regenera con datos actuales. */
export const MASTER_FILENAME = "Power-Box-Gym-Maestro.xlsx";

const stampFmt = new Intl.DateTimeFormat("es-NI", {
  timeZone: "America/Managua",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});
const stamp = (iso: string | Date) => stampFmt.format(typeof iso === "string" ? new Date(iso) : iso);

const MONEY = '#,##0.00;[Red]-#,##0.00';

const KIND: Record<string, string> = KIND_LABEL;

function styleHeader(ws: ExcelJS.Worksheet, headers: string[], widths: number[]) {
  ws.columns = headers.map((h, i) => ({ header: h, key: `c${i}`, width: widths[i] ?? 16 }));
  const row = ws.getRow(1);
  row.font = { bold: true, color: { argb: "FFFFFFFF" } };
  row.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF0F172A" } };
  row.alignment = { vertical: "middle" };
  ws.views = [{ state: "frozen", ySplit: 1 }];
  ws.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: headers.length } };
}

/**
 * Un texto que empieza con = + - @ se guarda con apóstrofe: así ninguna herramienta
 * (ni una conversión posterior a CSV) puede tomarlo como fórmula. Los números no cambian.
 */
function neutralize(v: string | number | null): string | number | null {
  return typeof v === "string" && /^[=+\-@\t\r]/.test(v) ? `'${v}` : v;
}

function addRows(ws: ExcelJS.Worksheet, rows: (string | number | null)[][], moneyCols: number[] = []) {
  for (const r of rows) {
    const added = ws.addRow(r.map(neutralize));
    for (const c of moneyCols) added.getCell(c + 1).numFmt = MONEY;
  }
}

/**
 * Excel maestro: una sola fuente de verdad, generada desde la base en cada descarga.
 * Todas las hojas salen de los mismos datos, así no pueden contradecirse.
 */
export async function buildMasterWorkbook(data: FinanceReportData, now = new Date()): Promise<Buffer> {
  return buildLedgerWorkbook(data, now, null);
}

/** Mismo libro, limitado a los movimientos y deudas que cumplen los filtros. */
export async function buildFilteredWorkbook(data: FinanceReportData, filters: ExportFilters, now = new Date()): Promise<Buffer> {
  return buildLedgerWorkbook(data, now, filters);
}

async function buildLedgerWorkbook(data: FinanceReportData, now: Date, filters: ExportFilters | null): Promise<Buffer> {
  const wb = new ExcelJS.Workbook();
  wb.creator = "Power Box Gym";
  wb.created = now;
  const today = managuaDay(now);
  const rows = filters ? filterLedger(data.rows, filters) : data.rows;
  const pending = filters
    ? filterPending(pendingPayments(data.debtEntries), filters)
    : pendingPayments(data.debtEntries);
  const debtEntries = filters ? filterDebtEntries(data.debtEntries, filters) : data.debtEntries;
  const firstDay = rows.length ? managuaDay(rows[0].occurredAt) : today;
  const totals = totalsFor(rows, pending, filters?.from ?? firstDay, filters?.to ?? today);
  const monthNow = managuaMonth(now);
  const monthTotals = totalsFor(rows, pending, `${monthNow}-01`, today);

  // 1. Resumen
  const res = wb.addWorksheet("Resumen");
  styleHeader(res, ["Concepto", "Valor", "Nota"], [38, 20, 70]);
  const scope: (string | number | null)[][] = filters
    ? [
        ["Reporte filtrado", stamp(now), "Sólo incluye los movimientos y deudas de los filtros siguientes."],
        ...describeFilters(filters, data.maps).map(([k, v]) => [k, v, "Filtro aplicado"] as (string | number | null)[]),
        ["Movimientos incluidos", rows.length, rows.length === 0 ? "Ningún movimiento cumple los filtros." : "Con los filtros aplicados."],
      ]
    : [];
  const monthLines: (string | number | null)[][] = filters
    ? []
    : [
        ["Ingresos del mes (NIO)", monthTotals.incomeNio, `Mes ${monthNow}.`],
        ["Egresos del mes (NIO)", monthTotals.expenseNio, `Mes ${monthNow}.`],
      ];
  addRows(res, [
    ...scope,
    ["Actualizado (Managua)", stamp(now), "Este archivo se regenera desde la base cada vez que lo descargás."],
    ["Día de hoy (Managua)", today, "Todos los días se calculan en America/Managua."],
    ["Ingresos históricos (NIO)", totals.incomeNio, filters ? "Sólo movimientos completados dentro de los filtros." : "Sólo movimientos completados, equivalente NIO guardado en cada uno."],
    ["Egresos históricos (NIO)", totals.expenseNio, "Sólo movimientos completados."],
    ["Saldo histórico (NIO)", totals.netNio, "Ingresos menos egresos."],
    ...monthLines,
    ["Comisión estimada histórica (NIO)", totals.commissionNio, "Estimada con el porcentaje por método. No se descuenta de la caja."],
    ["Deuda pendiente (NIO)", totals.pendingDebtNio, "Suma de saldos de deuda por cliente en córdobas."],
    ["Deuda pendiente (USD)", totals.pendingDebtUsd, "Se muestra en dólares; no se convierte."],
    ["Clientes con saldo pendiente", pending.length, "Ver hoja Pagos pendientes."],
    ["Movimientos registrados", rows.length, filters ? "Con los filtros aplicados. Incluye pendientes y anulados." : "Incluye pendientes y anulados."],
  ], [1, 2]);
  res.getColumn(2).alignment = { horizontal: "right" };

  // 2. Movimientos
  const mv = wb.addWorksheet("Movimientos");
  styleHeader(mv, MOVEMENT_HEADERS, [18, 10, 20, 12, 22, 40, 22, 22, 18, 9, 14, 12, 16, 18, 16, 12, 14, 14, 18, 38]);
  addRows(
    mv,
    [...rows].reverse().map((r: LedgerRow) => [
      stamp(r.occurredAt),
      r.type === "income" ? "Ingreso" : r.type === "expense" ? "Gasto" : "Transferencia",
      KIND[r.kind] ?? r.kind,
      r.status === "completed" ? "Completado" : r.status === "pending" ? "Pendiente" : "Anulado",
      r.clientName || null,
      r.concept,
      r.methodName,
      r.accountName,
      r.categoryName || null,
      r.currency,
      r.amount,
      r.fxUsed,
      r.amountNio,
      r.commissionNio,
      r.cashReceived ?? null,
      r.changeGiven ?? null,
      r.debtBefore ?? null,
      r.debtAfter ?? null,
      r.reference,
      r.id,
    ]),
    [10, 11, 12, 13, 14, 15, 16, 17],
  );

  // 3. Cierre diario
  const days = [...new Set(rows.map((r) => managuaDay(r.occurredAt)))].sort();
  const cd = wb.addWorksheet("Cierre diario");
  styleHeader(cd, ["Día", "Ingresos NIO", "Egresos NIO", "Neto NIO", "Movimientos", "Comisión estimada NIO", "Efectivo recibido NIO", "Vuelto NIO"],
    [14, 16, 16, 16, 13, 20, 20, 14]);
  addRows(
    cd,
    days.map((d) => {
      const c = dailyClose(rows, d);
      return [d, c.incomeNio, c.expenseNio, c.netNio, c.count, c.commissionNio, c.cashReceivedNio, c.changeGivenNio];
    }),
    [1, 2, 3, 5, 6, 7],
  );

  // 4. Comparativo mensual (últimos 12 meses hasta hoy)
  const mc = wb.addWorksheet("Comparativo mensual");
  styleHeader(mc, ["Mes", "Ingresos NIO", "Egresos NIO", "Neto NIO", "Movimientos", "Comisión estimada NIO"], [12, 16, 16, 16, 13, 20]);
  addRows(
    mc,
    monthlyComparison(rows, today, 12).map((m) => [m.month, m.incomeNio, m.expenseNio, m.netNio, m.count, m.commissionNio]),
    [1, 2, 3, 5],
  );

  // 5. Gastos por categoría (histórico)
  const gc = wb.addWorksheet("Gastos por categoría");
  styleHeader(gc, ["Categoría", "Egresos NIO", "Movimientos"], [28, 18, 14]);
  const expenses = rows.filter((r) => r.type === "expense" && r.status === "completed");
  addRows(
    gc,
    groupBy(expenses, (r) => r.categoryName || "Sin categoría").map(([name, xs]) => [
      name,
      xs.reduce((a, r) => a + r.amountNio, 0),
      xs.length,
    ]),
    [1],
  );

  // 6. Pagos pendientes
  const pp = wb.addWorksheet("Pagos pendientes");
  styleHeader(pp, ["Cliente", "Deuda NIO", "Deuda USD", "Crédito NIO", "Crédito USD", "Último movimiento (Managua)"],
    [28, 16, 16, 16, 16, 24]);
  addRows(
    pp,
    pending.map((p) => [p.clientName, p.balance.debtNio, p.balance.debtUsd, p.balance.creditNio, p.balance.creditUsd, stamp(p.lastEntryAt)]),
    [1, 2, 3, 4],
  );

  // 7. Historial de deudas
  const hd = wb.addWorksheet("Historial de deudas");
  styleHeader(hd, ["Fecha (Managua)", "Cliente", "Tipo", "Concepto", "Monto", "Moneda", "Deuda NIO antes", "Deuda NIO después",
    "Deuda USD antes", "Deuda USD después", "Efectivo recibido", "Vuelto", "Registró", "ID"],
    [18, 22, 14, 40, 14, 9, 16, 16, 16, 16, 16, 12, 22, 38]);
  addRows(
    hd,
    [...debtEntries]
      .sort((a, b) => (a.occurredAt < b.occurredAt ? 1 : -1))
      .map((e: DebtEntryRow) => [
        stamp(e.occurredAt),
        e.clientName,
        e.kind === "opening" ? "Saldo inicial" : e.kind === "charge" ? "Cargo" : "Abono",
        e.concept,
        e.amount,
        e.currency,
        e.before?.debtNio ?? null,
        e.after.debtNio,
        e.before?.debtUsd ?? null,
        e.after.debtUsd,
        e.cashReceived ?? null,
        e.changeGiven ?? null,
        e.actorName,
        e.id,
      ]),
    [4, 6, 7, 8, 9, 10, 11],
  );

  // 8. Comisiones por método
  const cm = wb.addWorksheet("Comisiones");
  styleHeader(cm, ["Método", "% estimado", "Ingresos brutos NIO", "Comisión estimada NIO", "Ingreso neto estimado NIO", "Movimientos"],
    [26, 12, 20, 22, 26, 13]);
  addRows(
    cm,
    commissionsByMethod(rows, "0000-01-01", "9999-12-31").map((c) => [
      c.methodName,
      c.feePct / 100,
      c.grossNio,
      c.commissionNio,
      Math.round((c.grossNio - c.commissionNio) * 100) / 100,
      c.count,
    ]),
    [2, 3, 4],
  );
  cm.getColumn(2).numFmt = "0.00%";
  cm.addRow([]);
  cm.addRow(["Las comisiones son estimadas con el porcentaje del método y no cambian la caja. Confirmá con tu proveedor."]);

  // Sólo las descargas filtradas llevan la presentación de tabla; el maestro conserva su forma.
  if (filters) for (const ws of wb.worksheets) presentSheet(ws);

  const out = await wb.xlsx.writeBuffer();
  return Buffer.from(out as ArrayBuffer);
}
