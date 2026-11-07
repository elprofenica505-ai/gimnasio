/**
 * Exportación de reportes con filtros (cálculo puro: sin base de datos ni red).
 *
 * Reglas:
 * - Las fechas son días civiles de America/Managua (AAAA-MM-DD), inclusive en ambos extremos.
 * - Un filtro vacío significa "todos". Los filtros se combinan con Y.
 * - La exportación incluye TODOS los movimientos que cumplen los filtros, no sólo los visibles en pantalla.
 * - La deuda por cliente se calcula siempre con todo el historial; el filtro de fechas no cambia saldos.
 *   Los filtros de cliente sí aplican a la lista de pagos pendientes.
 */
import { KIND_LABEL, managuaDay, type DebtEntryRow, type LedgerRow, type NameMaps, type PendingClient } from "./finance-report.ts";

export type ExportKind = "all" | "income" | "expense";
export type ExportStatus = "all" | "completed" | "pending" | "cancelled";

export interface ExportFilters {
  from: string | null;
  to: string | null;
  kind: ExportKind;
  status: ExportStatus;
  methodId: string | null;
  categoryId: string | null;
  accountId: string | null;
  clientId: string | null;
}

export const NO_FILTERS: ExportFilters = {
  from: null,
  to: null,
  kind: "all",
  status: "all",
  methodId: null,
  categoryId: null,
  accountId: null,
  clientId: null,
};

export type ParseResult = { ok: true; filters: ExportFilters } | { ok: false; message: string };

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const KINDS: ExportKind[] = ["all", "income", "expense"];
const STATUSES: ExportStatus[] = ["all", "completed", "pending", "cancelled"];

function isRealDay(s: string): boolean {
  const [y, m, d] = s.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d;
}

/** Lee y valida los filtros de la URL. Un valor desconocido se rechaza; nunca se ignora en silencio. */
export function parseExportFilters(params: URLSearchParams): ParseResult {
  const read = (key: string): string | null => {
    const v = (params.get(key) ?? "").trim();
    return v === "" ? null : v;
  };

  const from = read("from");
  const to = read("to");
  if (from && (!DAY_RE.test(from) || !isRealDay(from))) return { ok: false, message: "La fecha de inicio no es válida." };
  if (to && (!DAY_RE.test(to) || !isRealDay(to))) return { ok: false, message: "La fecha final no es válida." };
  if (from && to && from > to) return { ok: false, message: "La fecha de inicio es posterior a la fecha final." };

  const kind = (read("kind") ?? "all") as ExportKind;
  if (!KINDS.includes(kind)) return { ok: false, message: "El tipo de movimiento no es válido." };
  const status = (read("status") ?? "all") as ExportStatus;
  if (!STATUSES.includes(status)) return { ok: false, message: "El estado no es válido." };

  const ids: Record<"methodId" | "categoryId" | "accountId" | "clientId", string | null> = {
    methodId: read("method"),
    categoryId: read("category"),
    accountId: read("account"),
    clientId: read("client"),
  };
  for (const v of Object.values(ids)) {
    if (v !== null && !ID_RE.test(v)) return { ok: false, message: "Uno de los filtros no es válido." };
  }

  return { ok: true, filters: { from, to, kind, status, ...ids } };
}

/** Movimientos que cumplen los filtros. Las transferencias sólo entran cuando el tipo es «Todos». */
export function filterLedger(rows: LedgerRow[], f: ExportFilters): LedgerRow[] {
  return rows.filter((r) => {
    const day = managuaDay(r.occurredAt);
    if (f.from && day < f.from) return false;
    if (f.to && day > f.to) return false;
    if (f.kind !== "all" && r.type !== f.kind) return false;
    if (f.status !== "all" && r.status !== f.status) return false;
    if (f.methodId && r.methodId !== f.methodId) return false;
    if (f.categoryId && r.categoryId !== f.categoryId) return false;
    if (f.accountId && r.accountId !== f.accountId) return false;
    if (f.clientId && r.clientId !== f.clientId) return false;
    return true;
  });
}

/** Historial de deudas dentro del rango de fechas y del cliente elegido. */
export function filterDebtEntries(entries: DebtEntryRow[], f: ExportFilters): DebtEntryRow[] {
  return entries.filter((e) => {
    const day = managuaDay(e.occurredAt);
    if (f.from && day < f.from) return false;
    if (f.to && day > f.to) return false;
    if (f.clientId && e.clientId !== f.clientId) return false;
    return true;
  });
}

/** Pagos pendientes: el saldo es total, sólo se filtra por cliente. */
export function filterPending(pending: PendingClient[], f: ExportFilters): PendingClient[] {
  return f.clientId ? pending.filter((p) => p.clientId === f.clientId) : pending;
}

/** Filas de texto para la hoja «Resumen» y para la descripción del CSV. */
export function describeFilters(f: ExportFilters, maps: NameMaps): [string, string][] {
  const name = (id: string | null, source: Record<string, string> | Record<string, { name: string }>) => {
    if (!id) return "Todos";
    const v = source[id];
    if (!v) return id;
    return typeof v === "string" ? v : v.name;
  };
  const kindText: Record<ExportKind, string> = { all: "Todos", income: "Ingresos", expense: "Egresos" };
  const statusText: Record<ExportStatus, string> = {
    all: "Todos",
    completed: "Completados",
    pending: "Pendientes",
    cancelled: "Anulados",
  };
  return [
    ["Desde (Managua)", f.from ?? "Inicio del historial"],
    ["Hasta (Managua)", f.to ?? "Hoy"],
    ["Tipo", kindText[f.kind]],
    ["Estado", statusText[f.status]],
    ["Método de pago", name(f.methodId, maps.methods)],
    ["Categoría", name(f.categoryId, maps.categories)],
    ["Cuenta", name(f.accountId, maps.accounts)],
    ["Cliente", name(f.clientId, maps.clients)],
  ];
}

/** Nombre de archivo: incluye el rango para que no se confundan descargas distintas. */
export function exportFilename(f: ExportFilters, ext: "xlsx" | "csv"): string {
  const from = f.from ?? "inicio";
  const to = f.to ?? "hoy";
  return `Power-Box-Gym-Reporte_${from}_a_${to}.${ext}`;
}

const stampFmt = new Intl.DateTimeFormat("sv-SE", {
  timeZone: "America/Managua",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

/** Encabezados de la hoja «Movimientos» y del CSV. Mismo orden en los dos formatos. */
export const MOVEMENT_HEADERS = [
  "Fecha (Managua)", "Tipo", "Origen", "Estado", "Cliente", "Concepto", "Método", "Cuenta", "Categoría",
  "Moneda", "Monto", "Tasa manual", "Equivalente NIO", "Comisión estimada NIO", "Efectivo recibido",
  "Vuelto", "Deuda antes", "Deuda después", "Referencia", "ID",
];

export function movementCells(r: LedgerRow): (string | number | null)[] {
  return [
    stampFmt.format(new Date(r.occurredAt)),
    r.type === "income" ? "Ingreso" : r.type === "expense" ? "Gasto" : "Transferencia",
    KIND_LABEL[r.kind] ?? r.kind,
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
  ];
}

/**
 * CSV seguro para Excel: BOM UTF-8 (acentos correctos), CRLF, comillas cuando hacen falta
 * y protección contra fórmulas (una celula que empieza con = + - @ se escribe con apóstrofo).
 */
export function csvCell(v: string | number | null | undefined): string {
  if (v === null || v === undefined) return "";
  if (typeof v === "number") return Number.isFinite(v) ? String(v) : "";
  let s = v;
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  if (/[",\r\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

export function buildMovementsCsv(rows: LedgerRow[]): string {
  const lines = [MOVEMENT_HEADERS.map(csvCell).join(",")];
  for (const r of rows) lines.push(movementCells(r).map(csvCell).join(","));
  return `\uFEFF${lines.join("\r\n")}\r\n`;
}
