import { accountPlanSchema, type AccountPlan } from "@/lib/crm/account-plan";
import "server-only";
import {
  BOOKING_COLUMNS,
  SESSION_COLUMNS,
  rowsByIds,
  resolveSessions,
} from "@/lib/data/relations";
import {
  DataReadError,
  checkedRead,
  requireRows,
} from "@/lib/data/read-result";
import { FinanceReadError } from "@/lib/finance/read-result";
import {
  isFinanceSchemaError,
  readBankFinance,
  readDebtReport,
} from "@/lib/finance/legacy-reader";
import {
  parseVoidPlanImpact,
  type VoidPlanImpact,
} from "@/lib/finance/voids";
import {
  MOVEMENTS_PAGE_SIZE,
  parseMovementsPagePayload,
  type MovementFilters,
  type MovementsPage,
  type MovementRow,
} from "@/lib/finance/movements-page";
import {
  parseAccountsState,
  type AccountsState,
} from "@/lib/finance/accounts";
import {
  CASHIER_PERMISSION_FIELDS,
  CASHIER_PERMISSION_KEYS,
  CASHIER_PERMISSIONS_ALL,
  CASHIER_PERMISSIONS_OFF,
  normalizeCashierPermissions,
  type CashierPermissions,
} from "@/lib/finance/cashier-permissions";

import { cache } from "react";
import { resolveCurrentUser } from "@/lib/auth/current-user";
export type { AuthUser } from "@/lib/auth/current-user";

import { getWeekRange, weekRangeFromKey } from "@/lib/schedule";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { DEMO_MODE, isSupabaseConfigured } from "@/lib/supabase/env";
import type {
  Booking,
  BookingDetail,
  Coach,
  ContactMessage,
  GymClass,
  Plan,
  SessionDetail,
  Session,
  WeekRange,
} from "@/lib/types";
import { demoClasses, demoCoaches, demoPlans } from "./demo-content";
import { generateWeekSessions } from "./demo-sessions";

/** Demo sólo sin configuración; conectado: vacío real o error explícito. */
async function operationalClient() {
  return checkedRead("CONNECTION", async () => {
    const db = await getSupabaseServerClient();
    if (!db && !DEMO_MODE)
      throw new DataReadError("CONNECTION", "UNAVAILABLE");
    return db;
  });
}

async function activeRows<T>(
  table: string,
  operation: string,
  demo: T[],
): Promise<T[]> {
  return checkedRead(operation, async () => {
    const db = await operationalClient();
    if (!db) return demo;
    const result = await db
      .from(table)
      .select("*")
      .eq("is_active", true)
      .order("sort_order", { ascending: true })
      .abortSignal(AbortSignal.timeout(15000));
    return requireRows(operation, result) as T[];
  });
}

export async function getClasses(): Promise<GymClass[]> {
  return activeRows(
    "classes",
    "CLASSES",
    demoClasses.filter((c) => c.is_active),
  );
}

/** Solo Operación: administración necesita ver y reactivar las inactivas. */
export async function getAdminClasses(): Promise<GymClass[]> {
  return checkedRead("ADMIN_CLASSES", async () => {
    const db = await operationalClient();
    if (!db) return demoClasses;
    const result = await db
      .from("classes")
      .select("*")
      .order("sort_order", { ascending: true })
      .abortSignal(AbortSignal.timeout(15000));
    return requireRows("ADMIN_CLASSES", result) as GymClass[];
  });
}
export async function getCoaches(): Promise<Coach[]> {
  return activeRows(
    "coaches_public",
    "COACHES",
    demoCoaches.filter((c) => c.is_active),
  );
}
export async function getPlans(): Promise<Plan[]> {
  return activeRows(
    "plans",
    "PLANS",
    demoPlans.filter((p) => p.is_active),
  );
}

/** Catálogo público de la tienda: sólo productos activos, sin costos. */
export async function getProductsPublic(): Promise<
  { id: string; name: string; category: string; price: string | number; image_data: string | null }[]
> {
  return checkedRead("PRODUCTS_PUBLIC", async () => {
    const db = await operationalClient();
    if (!db) return [];
    const result = await db
      .rpc("tienda_productos")
      .abortSignal(AbortSignal.timeout(15000));
    return requireRows("PRODUCTS_PUBLIC", result) as {
      id: string;
      name: string;
      category: string;
      price: string | number;
      image_data: string | null;
    }[];
  });
}

export interface PlanTariffAdmin {
  id: string;
  slug: string;
  period: Plan["period"];
  nameEs: string;
  /** Tarifa de recepción en córdobas. Nunca se mezcla con `priceUsd`. */
  priceNio: number | null;
  /** Precio histórico de la tabla (`plans.price`), solo informativo. */
  priceUsd: number | null;
  isActive: boolean;
}

export type DayPassTariffAdmin = PlanTariffAdmin;

const GYM_TARIFF_PLANS = [
  { slug: "pase-del-dia", period: "session", fallbackName: "Pase del día" },
  { slug: "gimnasio-semanal", period: "week", fallbackName: "Gimnasio semanal" },
  {
    slug: "gimnasio-quincenal",
    period: "fortnight",
    fallbackName: "Gimnasio quincenal",
  },
  { slug: "gimnasio-mensual", period: "month", fallbackName: "Gimnasio mensual" },
] as const satisfies readonly {
  slug: string;
  period: Plan["period"];
  fallbackName: string;
}[];

function tariffPrice(scope: string, value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const amount = Number(value);
  if (!Number.isFinite(amount) || amount < 0)
    throw new DataReadError(scope, "INVALID");
  return amount;
}

function mapPlanTariffRow(
  scope: string,
  row: Record<string, unknown>,
  expected: (typeof GYM_TARIFF_PLANS)[number],
): PlanTariffAdmin {
  if (
    typeof row.id !== "string" ||
    row.slug !== expected.slug ||
    row.period !== expected.period
  )
    throw new DataReadError(scope, "INVALID");

  return {
    id: row.id,
    slug: expected.slug,
    period: expected.period,
    nameEs:
      typeof row.name_es === "string" && row.name_es
        ? row.name_es
        : expected.fallbackName,
    priceNio: tariffPrice(scope, row.price_nio),
    priceUsd: tariffPrice(scope, row.price),
    isActive: row.is_active === true,
  };
}

function demoPlanTariff(
  scope: string,
  expected: (typeof GYM_TARIFF_PLANS)[number],
): PlanTariffAdmin | null {
  const demo = demoPlans.find((plan) => plan.slug === expected.slug);
  if (!demo) return null;
  if (demo.period !== expected.period) throw new DataReadError(scope, "INVALID");
  return {
    id: demo.id,
    slug: demo.slug,
    period: demo.period,
    nameEs: demo.name_es,
    priceNio: tariffPrice(scope, demo.price_nio),
    priceUsd: tariffPrice(scope, demo.price),
    isActive: demo.is_active,
  };
}

/**
 * Tarifa del pase del día para Administración. Lee también el plan si está
 * inactivo, así la pantalla puede avisar que el cobro rápido no aparecerá.
 * `select("*")` permite que, antes de aplicar 00057, la pantalla responda sin
 * inventar un precio: `price_nio` simplemente vendrá ausente y se lee `null`.
 */
export async function getDayPassTariffAdmin(): Promise<DayPassTariffAdmin | null> {
  return checkedRead("DAY_PASS_TARIFF", async () => {
    const expected = GYM_TARIFF_PLANS[0];
    const supabase = await getSupabaseServerClient();
    if (!supabase) return demoPlanTariff("DAY_PASS_TARIFF", expected);

    const { data, error } = await supabase
      .from("plans")
      .select("*")
      .eq("slug", expected.slug)
      .abortSignal(AbortSignal.timeout(15000))
      .maybeSingle();
    if (error) throw new DataReadError("DAY_PASS_TARIFF", error.code);
    if (!data) return null;

    return mapPlanTariffRow(
      "DAY_PASS_TARIFF",
      data as unknown as Record<string, unknown>,
      expected,
    );
  });
}

/**
 * Las cuatro tarifas NIO de pesas y máquinas para Administración, en orden
 * de duración. También lee planes inactivos para avisar en pantalla; si falta
 * una fila no inventa un plan: la página mostrará la configuración faltante.
 */
export async function getGymTariffsAdmin(): Promise<PlanTariffAdmin[]> {
  return checkedRead("GYM_TARIFFS", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) {
      return GYM_TARIFF_PLANS.flatMap((expected) => {
        const tariff = demoPlanTariff("GYM_TARIFFS", expected);
        return tariff ? [tariff] : [];
      });
    }

    const { data, error } = await supabase
      .from("plans")
      .select("*")
      .in(
        "slug",
        GYM_TARIFF_PLANS.map((plan) => plan.slug),
      )
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("GYM_TARIFFS", error.code);
    if (!Array.isArray(data)) throw new DataReadError("GYM_TARIFFS", "INVALID");

    const bySlug = new Map<string, Record<string, unknown>>();
    for (const item of data as unknown[]) {
      const row = item as Record<string, unknown> | null;
      if (!row || typeof row.slug !== "string" || bySlug.has(row.slug))
        throw new DataReadError("GYM_TARIFFS", "INVALID");
      bySlug.set(row.slug, row);
    }

    return GYM_TARIFF_PLANS.flatMap((expected) => {
      const row = bySlug.get(expected.slug);
      return row ? [mapPlanTariffRow("GYM_TARIFFS", row, expected)] : [];
    });
  });
}

/** Fuente canónica: ficha vinculada a auth.uid(), no profiles.plan_id legado. */
export async function getMyAssignedPlan(): Promise<AccountPlan> {
  return checkedRead("ACCOUNT_PLAN", async () => {
    const db = await operationalClient();
    if (!db) throw new DataReadError("ACCOUNT_PLAN", "UNAVAILABLE");
    const { data, error } = await db.rpc("crm_my_assigned_plan")
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("ACCOUNT_PLAN", error.code);
    const parsed = accountPlanSchema.safeParse(data);
    if (!parsed.success) throw new DataReadError("ACCOUNT_PLAN", "INVALID");
    return parsed.data;
  });
}

/* ------------------------------------------------------------
   Clases de la semana
   ------------------------------------------------------------ */

export async function getSessionsForWeek(
  weekKey?: string | null,
  options?: { includeInactiveClasses?: boolean },
): Promise<{
  week: WeekRange;
  sessions: SessionDetail[];
}> {
  const includeInactiveClasses = options?.includeInactiveClasses === true;
  const week = weekRangeFromKey(weekKey);
  const supabase = await operationalClient();

  if (!supabase) {
    return {
      week,
      sessions: generateWeekSessions(week, { includeInactiveClasses }),
    };
  }

  try {
    const { data, error } = await supabase
      .from("sessions")
      .select(SESSION_COLUMNS)
      .gte("starts_at", week.start.toISOString())
      .lte("starts_at", week.end.toISOString())
      .order("starts_at", { ascending: true })
      .abortSignal(AbortSignal.timeout(15000));

    const rows = requireRows("SESSIONS", {
      data,
      error,
    }) as unknown as Session[];

    // La ocupación la da una vista pública que sólo expone conteos
    // (las reservas están protegidas por RLS).
    const occupancy = new Map<string, number>();

    if (rows.length > 0) {
      const occupancyResult = await supabase
        .from("session_occupancy")
        .select("session_id, booked_count")
        .in(
          "session_id",
          rows.map((row) => row.id),
        )
        .abortSignal(AbortSignal.timeout(15000));

      const occupancyData = requireRows("OCCUPANCY", occupancyResult);
      for (const item of occupancyData as {
        session_id: string;
        booked_count: number;
      }[]) {
        const count = Number(item.booked_count);
        if (
          item.booked_count === null ||
          !Number.isSafeInteger(count) ||
          count < 0
        )
          throw new DataReadError("OCCUPANCY", "INVALID");
        occupancy.set(item.session_id, count);
      }
    }

    const resolved = await resolveSessions(supabase, rows);
    const allSessions = rows.map((row) => {
      const session = resolved.get(row.id)!;
      const bookedCount = occupancy.get(row.id) ?? 0;
      return {
        ...session,
        bookedCount,
        spotsLeft: Math.max(0, session.capacity - bookedCount),
      };
    });
    // La oferta pública no muestra sesiones de disciplinas pausadas ni clases
    // canceladas (un feriado, un profesor enfermo o una fecha suspendida a
    // mano). Operación puede pedirlas explícitamente para ver el historial.
    const sessions = includeInactiveClasses
      ? allSessions
      : allSessions.filter(
          (session) =>
            session.gymClass.is_active === true && session.status === "scheduled",
        );

    return { week, sessions };
  } catch (error) {
    if (error instanceof DataReadError) throw error;
    throw new DataReadError("SESSIONS");
  }
}

/* ------------------------------------------------------------
   Usuario, reservas y consultas
   ------------------------------------------------------------ */

// React cache deduplica dentro del mismo render, no entre usuarios/peticiones.
export const getCurrentUser = cache(async () => {
  const supabase = await getSupabaseServerClient();
  if (!supabase) return null;

  try {
    return await resolveCurrentUser(supabase);
  } catch {
    console.error("[auth/session] No se pudo verificar la sesión");
    return null;
  }
});

/** Carga de reservas y relaciones por IDs bajo la misma sesión/RLS. */
async function bookingSessions(
  db: NonNullable<Awaited<ReturnType<typeof operationalClient>>>,
  bookings: Booking[],
) {
  const rows = await rowsByIds<Session>(
    db,
    "sessions",
    SESSION_COLUMNS,
    bookings.map((row) => row.session_id),
    "BOOKING_SESSIONS",
  );
  return resolveSessions(db, [...rows.values()]);
}

export async function getMyBookings(userId: string): Promise<BookingDetail[]> {
  return checkedRead("BOOKINGS", async () => {
    const db = await operationalClient();
    if (!db) return [];
    const result = await db
      .from("bookings")
      .select(BOOKING_COLUMNS)
      .eq("user_id", userId)
      .order("created_at", { ascending: false })
      .abortSignal(AbortSignal.timeout(15000));
    const rows = requireRows("BOOKINGS", result) as unknown as Booking[];
    const sessions = await bookingSessions(db, rows);
    return rows.map((row) => ({
      ...row,
      session: sessions.get(row.session_id)!,
    }));
  });
}

/** IDs de las clases en las que el usuario ya tiene reserva. */
export async function getBookedSessionIds(userId: string): Promise<string[]> {
  const supabase = await operationalClient();
  if (!supabase) return [];

  try {
    const { data, error } = await supabase
      .from("bookings")
      .select("session_id")
      .eq("user_id", userId)
      .in("status", ["confirmed", "attended"])
      .abortSignal(AbortSignal.timeout(15000));

    return requireRows("BOOKED_IDS", { data, error }).map(
      (row: { session_id: string }) => row.session_id,
    );
  } catch (error) {
    if (error instanceof DataReadError) throw error;
    throw new DataReadError("BOOKED_IDS");
  }
}

export async function getAllBookings(): Promise<
  (Booking & {
    memberName: string;
    memberEmail: string;
    session: SessionDetail;
  })[]
> {
  return checkedRead("BOOKINGS", async () => {
    const db = await operationalClient();
    if (!db) return [];
    const result = await db
      .from("bookings")
      .select(BOOKING_COLUMNS)
      .order("created_at", { ascending: false })
      .limit(500)
      .abortSignal(AbortSignal.timeout(15000));
    const rows = requireRows("BOOKINGS", result) as unknown as Booking[];
    const [sessions, profiles] = await Promise.all([
      bookingSessions(db, rows),
      rowsByIds<{ id: string; full_name: string | null; email: string | null }>(
        db,
        "profiles",
        "id,full_name,email",
        rows.map((row) => row.user_id),
        "BOOKING_PROFILES",
      ),
    ]);
    return rows.map((row) => ({
      ...row,
      memberName: profiles.get(row.user_id)?.full_name ?? "Cliente",
      memberEmail: profiles.get(row.user_id)?.email ?? "",
      session: sessions.get(row.session_id)!,
    }));
  });
}

export async function getContactMessages(): Promise<ContactMessage[]> {
  const supabase = await operationalClient();
  if (!supabase) return [];

  try {
    const { data, error } = await supabase
      .from("messages")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(200)
      .abortSignal(AbortSignal.timeout(15000));

    return requireRows("MESSAGES", { data, error }) as ContactMessage[];
  } catch (error) {
    if (error instanceof DataReadError) throw error;
    throw new DataReadError("MESSAGES");
  }
}

export async function countMembers(): Promise<number> {
  return checkedRead("CLIENT_COUNT", async () => {
    const db = await operationalClient();
    if (!db) return 0;
    const result = await db
      .from("gym_clients")
      .select("id", { count: "exact", head: true })
      .abortSignal(AbortSignal.timeout(15000));
    // Compatibilidad sólo si falta la tabla CRM, no por RLS/red u otro error.
    let count = result.count;
    if (result.error) {
      if (!["42P01", "PGRST205"].includes(result.error.code))
        throw new DataReadError("CLIENT_COUNT", result.error.code);
      const legacy = await db
        .from("profiles")
        .select("id", { count: "exact", head: true })
        .eq("role", "member")
        .abortSignal(AbortSignal.timeout(15000));
      if (legacy.error)
        throw new DataReadError("CLIENT_COUNT", legacy.error.code);
      count = legacy.count;
    }
    if (count === null || !Number.isSafeInteger(count) || count < 0)
      throw new DataReadError("CLIENT_COUNT", "INVALID");
    return count;
  });
}

/* ============================================================
   FASE 1: Finanzas, caja y contabilidad
   ============================================================ */

export type Currency = "NIO" | "USD";

export interface PaymentMethod {
  id: string;
  slug: string;
  kind: string | null;
  nameEs: string;
  nameEn: string;
  detailsEs: string;
  detailsEn: string;
  acceptsNio: boolean;
  acceptsUsd: boolean;
  icon: string;
  isActive: boolean;
  sortOrder: number;
}

export interface ExpenseCategory {
  id: string;
  slug: string;
  nameEs: string;
  nameEn: string;
  icon: string;
  isActive: boolean | null;
  sortOrder: number;
}

export interface Account {
  id: string;
  slug: string;
  name: string;
  kind: "cash" | "bank" | "wallet";
  currency: Currency;
  bankName: string | null;
  accountNumber: string | null;
  holderName: string | null;
  balance?: number;
  isActive: boolean;
}

export interface Transaction {
  id: string;
  occurredAt: string;
  direction: "income" | "expense" | "transfer";
  status: "pending" | "completed" | "reversed" | "cancelled";
  amount: number;
  currency: Currency;
  fxRate: number;
  baseAmount: number;
  paymentMethodId: string | null;
  accountId: string | null;
  memberId: string | null;
  memberName: string | null;
  invoiceId: string | null;
  expenseCategoryId: string | null;
  concept: string;
  notes: string | null;
  createdBy: string | null;
  /** Motivo de la anulación, si este movimiento ya se anuló (FIN-01). */
  voidedReason?: string | null;
}

export interface DailyCashRow {
  day: string;
  incomeNio: number;
  expenseNio: number;
  netNio: number;
  txCount: number;
}

export interface MonthlyPnlRow {
  month: string;
  incomeNio: number;
  expenseNio: number;
  netNio: number;
}

export interface PaymentMethodBreakdown {
  paymentMethodId: string | null;
  nameEs: string | null;
  icon: string;
  txCount: number;
  totalNio: number;
  incomeNio: number;
  expenseNio: number;
}

export interface AccountsReceivableRow {
  memberId: string | null;
  clientId?: string;
  fullName: string;
  email: string;
  phone: string | null;
  invoicesOpen: number | null;
  totalOwedNio: number;
  totalOwedUsd?: number;
  oldestDue: string | null;
  daysOverdue: number | null;
}

export async function getPaymentMethods(): Promise<PaymentMethod[]> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("METHODS", "UNAVAILABLE");
    return [];
  }
  let { data, error } = await supabase
    .from("payment_methods")
    .select(
      "id,slug,kind,name_es,name_en,details_es,details_en,accepts_nio,accepts_usd,icon,is_active,sort_order",
    )
    .eq("is_active", true)
    .order("sort_order");
  if (error) {
    if (!isFinanceSchemaError(error.code))
      throw new FinanceReadError("METHODS", error.code);
    data = await readBankFinance<NonNullable<typeof data>>(supabase, "methods");
  }
  return (data ?? []).map(mapPaymentMethod);
}

export async function getExpenseCategories(): Promise<ExpenseCategory[]> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("CATEGORIES", "UNAVAILABLE");
    return [];
  }
  let { data, error } = await supabase
    .from("expense_categories")
    .select("id,slug,name_es,name_en,icon,is_active,sort_order")
    .eq("is_active", true)
    .order("sort_order");
  if (error) {
    if (!isFinanceSchemaError(error.code))
      throw new FinanceReadError("CATEGORIES", error.code);
    data = await readBankFinance<NonNullable<typeof data>>(
      supabase,
      "categories",
    );
  }
  return (data ?? []).map(mapExpenseCategory);
}

export async function getAccounts(): Promise<Account[]> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("ACCOUNTS", "UNAVAILABLE");
    return [];
  }
  let { data, error } = await supabase
    .from("accounts")
    .select(
      "id,slug,name,kind,currency,bank_name,account_number,holder_name,is_active",
    )
    .eq("is_active", true)
    .order("name");
  if (error) {
    if (!isFinanceSchemaError(error.code))
      throw new FinanceReadError("ACCOUNTS", error.code);
    data = await readBankFinance<NonNullable<typeof data>>(
      supabase,
      "accounts",
    );
  }
  return (data ?? []).map(mapAccount);
}

export async function getRecentTransactions(
  limit = 30,
): Promise<Transaction[]> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("TRANSACTIONS", "UNAVAILABLE");
    return [];
  }
  let { data, error } = await supabase
    .from("transactions")
    .select(
      "id,occurred_at,direction,status,amount,currency,fx_rate,base_amount,payment_method_id,account_id,member_id,invoice_id,expense_category_id,concept,notes,created_by, member:profiles!transactions_member_id_fkey(full_name), client:gym_clients!transactions_client_id_fkey(full_name)",
    )
    .order("occurred_at", { ascending: false })
    .limit(limit);
  if (
    error &&
    ["PGRST200", "PGRST205", "42P01", "42703"].includes(error.code)
  ) {
    const legacy = await supabase
      .from("transactions")
      .select(
        "id,occurred_at,direction,status,amount,currency,fx_rate,base_amount,payment_method_id,account_id,member_id,invoice_id,expense_category_id,concept,notes,created_by, member:profiles!transactions_member_id_fkey(full_name)",
      )
      .order("occurred_at", { ascending: false })
      .limit(limit);
    data = legacy.data as typeof data;
    error = legacy.error;
  }
  if (error) {
    if (!isFinanceSchemaError(error.code))
      throw new FinanceReadError("TRANSACTIONS", error.code);
    data = await readBankFinance<NonNullable<typeof data>>(
      supabase,
      "transactions",
      limit,
    );
  }
  return (data ?? []).map((row) => mapTransaction(row));
}

export async function getDailyCash(days = 14): Promise<DailyCashRow[]> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("DAILY", "UNAVAILABLE");
    return [];
  }
  let { data, error } = await supabase
    .from("v_daily_cash")
    .select("day,income_nio,expense_nio,net_nio,tx_count")
    .limit(days);
  if (error) {
    if (!isFinanceSchemaError(error.code))
      throw new FinanceReadError("DAILY", error.code);
    data = await readBankFinance<NonNullable<typeof data>>(
      supabase,
      "daily",
      days,
    );
  }
  return (data ?? []).map((r) => ({
    day: String(r.day),
    incomeNio: Number(r.income_nio ?? 0),
    expenseNio: Number(r.expense_nio ?? 0),
    netNio: Number(r.net_nio ?? 0),
    txCount: Number(r.tx_count ?? 0),
  }));
}

export async function getMonthlyPnl(months = 6): Promise<MonthlyPnlRow[]> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("MONTHLY", "UNAVAILABLE");
    return [];
  }
  let { data, error } = await supabase
    .from("v_monthly_pnl")
    .select("month,income_nio,expense_nio,net_nio")
    .limit(months);
  if (error) {
    if (!isFinanceSchemaError(error.code))
      throw new FinanceReadError("MONTHLY", error.code);
    data = await readBankFinance<NonNullable<typeof data>>(
      supabase,
      "monthly",
      months,
    );
  }
  return (data ?? []).map((r) => ({
    month: String(r.month),
    incomeNio: Number(r.income_nio ?? 0),
    expenseNio: Number(r.expense_nio ?? 0),
    netNio: Number(r.net_nio ?? 0),
  }));
}

export async function getPaymentMethodsBreakdown(): Promise<
  PaymentMethodBreakdown[]
> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("METHOD_TOTALS", "UNAVAILABLE");
    return [];
  }
  let { data, error } = await supabase
    .from("v_payment_methods_breakdown")
    .select(
      "payment_method_id,name_es,icon,tx_count,total_nio,income_nio,expense_nio",
    );
  if (error) {
    if (!isFinanceSchemaError(error.code))
      throw new FinanceReadError("METHOD_TOTALS", error.code);
    data = await readBankFinance<NonNullable<typeof data>>(
      supabase,
      "method_totals",
    );
  }
  return (data ?? []).map((r) => ({
    paymentMethodId: r.payment_method_id,
    nameEs: r.name_es,
    icon: r.icon ?? "Wallet",
    txCount: Number(r.tx_count ?? 0),
    totalNio: Number(r.total_nio ?? 0),
    incomeNio: Number(r.income_nio ?? 0),
    expenseNio: Number(r.expense_nio ?? 0),
  }));
}

export async function getAccountsReceivable(): Promise<
  AccountsReceivableRow[]
> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("RECEIVABLES", "UNAVAILABLE");
    return [];
  }
  const consolidated = await readDebtReport<{
    member_id: string | null; client_id?: string; full_name: string | null; email: string | null;
    phone: string | null; invoices_open: null; total_owed_nio: number; total_owed_usd: number;
    oldest_due: null; days_overdue: null;
  }[]>(supabase, "receivables");
  if (consolidated !== null) return consolidated.map(r => ({
    memberId:r.member_id, ...(r.client_id ? {clientId:r.client_id} : {}), fullName:r.full_name ?? "—",
    email:r.email ?? "",phone:r.phone,invoicesOpen:null,totalOwedNio:Number(r.total_owed_nio),
    totalOwedUsd:Number(r.total_owed_usd),oldestDue:null,daysOverdue:null,
  }));
  let { data, error } = await supabase
    .from("v_accounts_receivable")
    .select(
      "member_id,full_name,email,phone,invoices_open,total_owed_nio,oldest_due,days_overdue",
    );
  if (error) {
    if (!isFinanceSchemaError(error.code))
      throw new FinanceReadError("RECEIVABLES", error.code);
    data = await readBankFinance<NonNullable<typeof data>>(
      supabase,
      "receivables",
    );
  }
  return (data ?? []).map((r) => ({
    memberId: r.member_id,
    ...("client_id" in r && typeof r.client_id === "string" ? {clientId:r.client_id} : {}),
    fullName: r.full_name ?? "—",
    email: r.email ?? "",
    phone: r.phone,
    invoicesOpen:
      r.invoices_open === null ? null : Number(r.invoices_open ?? 0),
    totalOwedNio: Number(r.total_owed_nio ?? 0),
    ...("total_owed_usd" in r
      ? { totalOwedUsd: Number(r.total_owed_usd) }
      : {}),
    oldestDue: r.oldest_due,
    daysOverdue: r.days_overdue === null ? null : Number(r.days_overdue ?? 0),
  }));
}

export interface CashSummary {
  incomeToday: number;
  expenseToday: number;
  netToday: number;
  txToday: number;
  incomeMonth: number;
  expenseMonth: number;
  netMonth: number;
  txMonth: number;
  pendingInvoices: number | null;
  totalOwed: number;
  totalOwedUsd?: number;
  sourceModel?: string;
  openRegisterCount?: number;
  openRegister: {
    id: string;
    openedAt: string;
    openingAmount: number;
    openingAmountUsd?: number;
  } | null;
}

export async function getCashSummary(): Promise<CashSummary> {
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    if (!DEMO_MODE)
      throw new FinanceReadError("SUMMARY", "UNAVAILABLE");
    return {
      incomeToday: 0,
      expenseToday: 0,
      netToday: 0,
      txToday: 0,
      incomeMonth: 0,
      expenseMonth: 0,
      netMonth: 0,
      txMonth: 0,
      pendingInvoices: 0,
      totalOwed: 0,
      openRegister: null,
    };
  }
  const consolidated = await readDebtReport<CashSummary>(supabase, "summary");
  if (consolidated !== null) return consolidated;
  // Hoy
  const today = new Date().toISOString().slice(0, 10);
  const { data: todayRows, error: todayError } = await supabase
    .from("v_daily_cash")
    .select("day,income_nio,expense_nio,net_nio,tx_count")
    .eq("day", today)
    .maybeSingle();
  // Mes
  const monthStart = new Date();
  monthStart.setDate(1);
  const { data: monthRows, error: monthError } = await supabase
    .from("v_monthly_pnl")
    .select("month,income_nio,expense_nio,net_nio")
    .gte("month", monthStart.toISOString())
    .maybeSingle();
  // Cuentas por cobrar
  const { data: ar, error: arError } = await supabase
    .from("v_accounts_receivable")
    .select("total_owed_nio");
  // Caja abierta
  const { data: open, error: openError } = await supabase
    .from("cash_registers")
    .select("id, opened_at, opening_amount")
    .is("closed_at", null)
    .order("opened_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const failures = [
    ["SUMMARY_DAY", todayError],
    ["SUMMARY_MONTH", monthError],
    ["SUMMARY_DEBT", arError],
    ["SUMMARY_REGISTER", openError],
  ] as const;
  for (const [operation, error] of failures) {
    if (error && !isFinanceSchemaError(error.code))
      throw new FinanceReadError(operation, error.code);
  }
  if (failures.some(([, error]) => !!error))
    return readBankFinance<CashSummary>(supabase, "summary");

  return {
    incomeToday: Number(todayRows?.income_nio ?? 0),
    expenseToday: Number(todayRows?.expense_nio ?? 0),
    netToday: Number(todayRows?.net_nio ?? 0),
    txToday: Number(todayRows?.tx_count ?? 0),
    incomeMonth: Number(monthRows?.income_nio ?? 0),
    expenseMonth: Number(monthRows?.expense_nio ?? 0),
    netMonth: Number(monthRows?.net_nio ?? 0),
    txMonth: Number(monthRows ? 1 : 0),
    pendingInvoices: (ar ?? []).length,
    totalOwed: (ar ?? []).reduce(
      (a, b) => a + Number(b.total_owed_nio ?? 0),
      0,
    ),
    openRegister: open
      ? {
          id: open.id,
          openedAt: open.opened_at,
          openingAmount: Number(open.opening_amount ?? 0),
        }
      : null,
  };
}

/**
 * Permisos efectivos de caja para la sesión actual (00056).
 * La base devuelve todo activado para administración y, para caja, el valor
 * de cada interruptor. Un error nunca se interpreta como permiso concedido.
 */
/** Una anulación ya registrada, para marcarla en la lista de Caja. */
export interface VoidMark {
  originalId: string;
  reversalId: string;
  reason: string;
  actorName: string | null;
  createdAt: string;
}

/**
 * Anulaciones ya guardadas (FIN-01), leídas por la RPC de siempre.
 *
 * Sirve para que la lista de Caja marque lo anulado: sin esto, después de
 * anular el movimiento se veía igual que antes y parecía que no había pasado
 * nada. Un fallo de lectura no se convierte en «no hay anulaciones»: se corta
 * la pantalla con el aviso de siempre.
 */
export async function getRecentVoids(limit = 200): Promise<VoidMark[]> {
  if (DEMO_MODE) return [];
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new FinanceReadError("VOIDS", "UNAVAILABLE");
  const { data, error } = await supabase
    .rpc("finance_voids_recent", { p_limit: limit })
    .abortSignal(AbortSignal.timeout(15000));
  if (error) throw new FinanceReadError("VOIDS", error.code);
  if (data === null || data === undefined) return [];
  if (!Array.isArray(data)) throw new FinanceReadError("VOIDS", "INVALID");
  return data.flatMap((row) => {
    const item = row as Record<string, unknown>;
    const originalId = typeof item.originalId === "string" ? item.originalId : null;
    const reversalId = typeof item.reversalId === "string" ? item.reversalId : null;
    if (!originalId || !reversalId) return [];
    return [{
      originalId,
      reversalId,
      reason: typeof item.reason === "string" ? item.reason : "",
      actorName: typeof item.actorName === "string" ? item.actorName : null,
      createdAt: typeof item.createdAt === "string" ? item.createdAt : "",
    }];
  });
}

/**
 * Una página del historial completo de movimientos (FIN-05).
 *
 * La búsqueda, los filtros, el orden y el total los resuelve la base en una
 * sola consulta (`finance_movements_page`): así la pantalla puede mostrar un
 * cobro viejo y no solo los últimos 30. `hideExpenses` lo decide el servidor
 * con el interruptor de gastos, y la base no los cuenta en el total.
 */
export async function getMovementsPage(
  filters: MovementFilters,
  page: number,
): Promise<MovementsPage> {
  const empty: MovementsPage = {
    rows: [],
    total: 0,
    page: 0,
    pageSize: MOVEMENTS_PAGE_SIZE,
  };
  if (DEMO_MODE) return empty;
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new FinanceReadError("MOVEMENTS", "UNAVAILABLE");
  const safePage = Number.isFinite(page) && page > 0 ? Math.trunc(page) : 0;
  const { data, error } = await supabase
    .rpc("finance_movements_page", {
      p_search: filters.search,
      p_direction: filters.direction === "all" ? "" : filters.direction,
      p_status: filters.status === "all" ? "" : filters.status,
      p_currency: filters.currency === "all" ? "" : filters.currency,
      p_method: filters.method,
      p_hide_expenses: filters.hideExpenses === true,
      p_limit: MOVEMENTS_PAGE_SIZE,
      p_offset: safePage * MOVEMENTS_PAGE_SIZE,
    })
    .abortSignal(AbortSignal.timeout(15000));
  if (error) throw new FinanceReadError("MOVEMENTS", error.code);
  const parsed = parseMovementsPagePayload(data);
  if (!parsed) throw new FinanceReadError("MOVEMENTS", "INVALID");
  return {
    rows: parsed.rows.map((row) => mapTransaction(row) as MovementRow),
    total: parsed.total,
    page: safePage,
    pageSize: MOVEMENTS_PAGE_SIZE,
  };
}

/**
 * Vigencias que activó un cobro (FIN-01).
 *
 * Sirve para no dejar creer que anular una mensualidad la da de baja: el
 * dinero vuelve, la membresía sigue. Se lee antes de confirmar y se vuelve a
 * contar en el resultado. Un fallo de lectura devuelve lista vacía **solo**
 * porque la advertencia es informativa: la anulación no depende de esto y el
 * resultado nunca la usa para afirmar nada.
 */
export async function getVoidPlanImpact(
  transactionId: string,
): Promise<VoidPlanImpact[]> {
  if (DEMO_MODE) return [];
  const supabase = await getSupabaseServerClient();
  if (!supabase) return [];
  const { data, error } = await supabase
    .rpc("finance_void_plan_impact", { p_transaction: transactionId })
    .abortSignal(AbortSignal.timeout(15000));
  if (error) return [];
  return parseVoidPlanImpact(data);
}

/**
 * Estado de cuentas, métodos, categorías, transferencias y bitácora (FIN-03).
 *
 * Una sola llamada a `finance_accounts_state`: la base decide qué se ve según
 * el rol y el interruptor de saldos. Si la respuesta no tiene la forma
 * esperada se lanza el error en vez de devolver listas vacías, porque «no hay
 * cuentas» y «no pudimos leer» no son lo mismo.
 */
export async function getFinanceAccountsState(): Promise<AccountsState> {
  if (DEMO_MODE) {
    return {
      accounts: [],
      methods: [],
      categories: [],
      transfers: [],
      audit: [],
      canManage: false,
      balancesVisible: false,
      rules: { transferRule: "" },
    };
  }
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new FinanceReadError("ACCOUNTS", "UNAVAILABLE");
  const { data, error } = await supabase
    .rpc("finance_accounts_state", { p_limit: 20 })
    .abortSignal(AbortSignal.timeout(15000));
  if (error) throw new FinanceReadError("ACCOUNTS", error.code);
  const state = parseAccountsState(data);
  if (!state) throw new FinanceReadError("ACCOUNTS", "INVALID");
  return state;
}

export async function getCashierPermissions(): Promise<CashierPermissions> {
  if (DEMO_MODE) return CASHIER_PERMISSIONS_ALL;
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new FinanceReadError("CASHIER_PERMISSIONS", "UNAVAILABLE");
  const { data, error } = await supabase
    .rpc("cashier_permissions")
    .abortSignal(AbortSignal.timeout(15000));
  if (error) throw new FinanceReadError("CASHIER_PERMISSIONS", error.code);
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new FinanceReadError("CASHIER_PERMISSIONS", "INVALID");
  }
  return normalizeCashierPermissions(data);
}

/* ---- mappers snake_case → camelCase ---- */

function mapPaymentMethod(r: Record<string, unknown>): PaymentMethod {
  return {
    id: r.id as string,
    slug: r.slug as string,
    kind: (r.kind as string) ?? null,
    nameEs: r.name_es as string,
    nameEn: r.name_en as string,
    detailsEs: (r.details_es as string) ?? "",
    detailsEn: (r.details_en as string) ?? "",
    acceptsNio: r.accepts_nio as boolean,
    acceptsUsd: r.accepts_usd as boolean,
    icon: (r.icon as string) ?? "Wallet",
    isActive: r.is_active as boolean,
    sortOrder: Number(r.sort_order ?? 0),
  };
}

function mapExpenseCategory(r: Record<string, unknown>): ExpenseCategory {
  return {
    id: r.id as string,
    slug: r.slug as string,
    nameEs: r.name_es as string,
    nameEn: r.name_en as string,
    icon: (r.icon as string) ?? "Receipt",
    isActive: r.is_active === null ? null : (r.is_active as boolean),
    sortOrder: Number(r.sort_order ?? 0),
  };
}

function mapAccount(r: Record<string, unknown>): Account {
  return {
    id: r.id as string,
    slug: r.slug as string,
    name: r.name as string,
    kind: r.kind as Account["kind"],
    currency: r.currency as Currency,
    bankName: (r.bank_name as string) ?? null,
    accountNumber: (r.account_number as string) ?? null,
    holderName: (r.holder_name as string) ?? null,
    ...(r.balance !== undefined ? { balance: Number(r.balance) } : {}),
    isActive: r.is_active as boolean,
  };
}

function mapTransaction(r: Record<string, unknown>): Transaction {
  const member = r.member as { full_name?: string } | null;
  return {
    id: r.id as string,
    occurredAt: r.occurred_at as string,
    direction: r.direction as Transaction["direction"],
    status: r.status as Transaction["status"],
    amount: Number(r.amount ?? 0),
    currency: r.currency as Currency,
    fxRate: Number(r.fx_rate ?? 1),
    baseAmount: Number(r.base_amount ?? 0),
    paymentMethodId: (r.payment_method_id as string) ?? null,
    accountId: (r.account_id as string) ?? null,
    memberId: (r.member_id as string) ?? null,
    memberName:
      (r.client as { full_name?: string } | null)?.full_name ??
      member?.full_name ??
      null,
    invoiceId: (r.invoice_id as string) ?? null,
    expenseCategoryId: (r.expense_category_id as string) ?? null,
    concept: r.concept as string,
    notes: (r.notes as string) ?? null,
    createdBy: (r.created_by as string) ?? null,
    voidedReason: (r.voided_reason as string) ?? null,
  };
}

export { isSupabaseConfigured };

/** Semana actual, para los componentes de servidor. */
export function currentWeek(): WeekRange {
  return getWeekRange();
}

/** Personas con perfil para asignar roles (sólo administrador; la base lo exige). */
export async function getProfilesForRoles(): Promise<
  { id: string; fullName: string; role: string }[]
> {
  return checkedRead("PROFILES_ROLES", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return [];
    const { data, error } = await supabase
      .from("profiles")
      .select("id, full_name, role")
      .order("full_name", { nullsFirst: false })
      .limit(500)
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("PROFILES_ROLES", error.code);
    return (data ?? []).map((row) => ({
      id: row.id as string,
      fullName: (row.full_name as string | null) ?? "",
      role: row.role as string,
    }));
  });
}

export type TrainerAccessStatus = "pending" | "approved" | "rejected" | "revoked";

export interface TrainerAccessRow {
  id: string;
  trainerId: string;
  clientId: string;
  trainerName: string;
  clientName: string;
  status: TrainerAccessStatus;
  requestedVia: "trainer" | "cashier";
  reason: string | null;
  createdAt: string;
  decidedAt: string | null;
}

/** Sólo administrador (la base lo vuelve a comprobar). Sin teléfono, correo ni notas. */
/** Interruptores de caja guardados en staff_permissions. Sólo los lee el administrador. */
export async function getCashierPermissionsAdmin(): Promise<CashierPermissions> {
  return checkedRead("CASHIER_PERMISSIONS", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return CASHIER_PERMISSIONS_OFF;
    const { data, error } = await supabase
      .from("staff_permissions")
      .select("key, enabled")
      .in("key", Object.values(CASHIER_PERMISSION_KEYS))
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("CASHIER_PERMISSIONS", error.code);
    const enabledByKey = new Map(
      (data ?? []).map((row) => [row.key as string, row.enabled === true]),
    );
    return Object.fromEntries(
      CASHIER_PERMISSION_FIELDS.map((field) => [
        field,
        enabledByKey.get(CASHIER_PERMISSION_KEYS[field]) === true,
      ]),
    ) as unknown as CashierPermissions;
  });
}

/** Compatibilidad: el cierre del día ahora forma parte del mismo grupo. */
export async function getCashierDailyCloseAdmin(): Promise<boolean> {
  return (await getCashierPermissionsAdmin()).dailyClose;
}

export async function getTrainerAccessAdmin(): Promise<{
  enabled: boolean;
  requests: TrainerAccessRow[];
}> {
  return checkedRead("TRAINER_ACCESS", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return { enabled: false, requests: [] };
    const [flag, rows] = await Promise.all([
      supabase
        .from("staff_permissions")
        .select("enabled")
        .eq("key", "trainer_can_request_clients")
        .abortSignal(AbortSignal.timeout(15000))
        .maybeSingle(),
      supabase
        .from("trainer_client_access")
        .select(
          "id, trainer_id, client_id, status, requested_via, reason, created_at, decided_at, trainer:profiles!trainer_id(full_name), client:gym_clients!client_id(full_name)",
        )
        .order("created_at", { ascending: false })
        .limit(300)
        .abortSignal(AbortSignal.timeout(15000)),
    ]);
    if (flag.error) throw new DataReadError("TRAINER_ACCESS", flag.error.code);
    if (rows.error) throw new DataReadError("TRAINER_ACCESS", rows.error.code);
    return {
      enabled: flag.data?.enabled === true,
      requests: ((rows.data ?? []) as Array<Record<string, unknown>>).map((row) => {
        const trainer = row.trainer as unknown as { full_name: string | null } | null;
        const client = row.client as unknown as { full_name: string | null } | null;
        return {
          id: row.id as string,
          trainerId: row.trainer_id as string,
          clientId: row.client_id as string,
          trainerName: trainer?.full_name ?? "Sin nombre",
          clientName: client?.full_name ?? "Sin nombre",
          status: row.status as TrainerAccessStatus,
          requestedVia: row.requested_via as "trainer" | "cashier",
          reason: (row.reason as string | null) ?? null,
          createdAt: row.created_at as string,
          decidedAt: (row.decided_at as string | null) ?? null,
        };
      }),
    };
  });
}

export interface TrainerRosterRow {
  clientId: string;
  fullName: string;
  visits30d: number;
  visitedToday: boolean;
}

/** Entrenador: sólo sus clientes aprobados. La base no devuelve teléfono, correo ni notas. */
export async function getTrainerRoster(): Promise<TrainerRosterRow[]> {
  return checkedRead("TRAINER_ROSTER", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return [];
    const { data, error } = await supabase
      .rpc("trainer_roster")
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("TRAINER_ROSTER", error.code);
    return ((data ?? []) as Array<Record<string, unknown>>).map((row) => ({
      clientId: row.client_id as string,
      fullName: (row.full_name as string | null) ?? "Sin nombre",
      visits30d: Number(row.visits_30d ?? 0),
      visitedToday: row.visited_today === true,
    }));
  });
}

/** Lee si el administrador activó la búsqueda y los pedidos del entrenador. */
export async function getTrainerRequestEnabled(): Promise<boolean> {
  return checkedRead("TRAINER_FLAG", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return false;
    const { data, error } = await supabase
      .rpc("trainer_request_enabled")
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("TRAINER_FLAG", error.code);
    return data === true;
  });
}

/** Clientes activos que se pueden asignar: excluye fichas ligadas a cuentas de personal. */
export async function getAssignableClients(): Promise<{ id: string; fullName: string }[]> {
  return checkedRead("ASSIGNABLE_CLIENTS", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return [];
    const [clients, staff] = await Promise.all([
      supabase
        .from("gym_clients")
        .select("id, full_name, profile_id")
        .eq("status", "active")
        .order("full_name", { ascending: true })
        .limit(1000)
        .abortSignal(AbortSignal.timeout(15000)),
      getStaffProfiles(),
    ]);
    if (clients.error) throw new DataReadError("ASSIGNABLE_CLIENTS", clients.error.code);
    const staffIds = new Set(staff.map((p) => p.id));
    return ((clients.data ?? []) as Array<Record<string, unknown>>)
      .filter((row) => !(row.profile_id && staffIds.has(row.profile_id as string)))
      .map((row) => ({ id: row.id as string, fullName: (row.full_name as string | null) ?? "Sin nombre" }));
  });
}

/** Cuentas de personal (entrenador, caja, administrador). Sólo nombre y rol; sin contacto. */
export async function getStaffProfiles(): Promise<{ id: string; fullName: string; role: string }[]> {
  const profiles = await getProfilesForRoles();
  return profiles.filter((p) => p.role === "trainer" || p.role === "cashier" || p.role === "admin");
}

/** Bitácora de cambios de rol (sólo administrador con MFA; la base lo exige con is_admin). */
export async function getRoleChanges(): Promise<
  { id: number; targetId: string; oldRole: string; newRole: string; changedBy: string | null; changedAt: string }[]
> {
  return checkedRead("ROLE_CHANGES", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return [];
    const { data, error } = await supabase
      .from("role_changes")
      .select("id, target_id, old_role, new_role, changed_by, changed_at")
      .order("changed_at", { ascending: false })
      .limit(100)
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("ROLE_CHANGES", error.code);
    return (data ?? []).map((row) => ({
      id: Number(row.id),
      targetId: row.target_id as string,
      oldRole: row.old_role as string,
      newRole: row.new_role as string,
      changedBy: (row.changed_by as string | null) ?? null,
      changedAt: row.changed_at as string,
    }));
  });
}

/** Ficha formal del personal (staff_members). Sólo administrador con MFA; la base lo exige con is_admin. */
export async function getStaffMembers(): Promise<
  {
    profileId: string;
    fullName: string;
    nationalId: string;
    birthDate: string;
    phone: string;
    address: string;
    emergencyName: string;
    emergencyPhone: string;
    positionTitle: string;
    hiredOn: string;
    responsibilities: string;
    internalNotes: string;
    status: "activo" | "inactivo";
    deactivatedOn: string | null;
    deactivationReason: string | null;
  }[]
> {
  return checkedRead("STAFF_MEMBERS", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return [];
    const { data, error } = await supabase
      .from("staff_members")
      .select(
        "profile_id, full_name, national_id, birth_date, phone, address, emergency_name, emergency_phone, position_title, hired_on, responsibilities, internal_notes, status, deactivated_on, deactivation_reason",
      )
      .order("full_name")
      .limit(500)
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("STAFF_MEMBERS", error.code);
    return (data ?? []).map((row) => ({
      profileId: row.profile_id as string,
      fullName: row.full_name as string,
      nationalId: row.national_id as string,
      birthDate: row.birth_date as string,
      phone: row.phone as string,
      address: row.address as string,
      emergencyName: row.emergency_name as string,
      emergencyPhone: row.emergency_phone as string,
      positionTitle: row.position_title as string,
      hiredOn: row.hired_on as string,
      responsibilities: (row.responsibilities as string | null) ?? "",
      internalNotes: (row.internal_notes as string | null) ?? "",
      status: row.status as "activo" | "inactivo",
      deactivatedOn: (row.deactivated_on as string | null) ?? null,
      deactivationReason: (row.deactivation_reason as string | null) ?? null,
    }));
  });
}

/** Bitácora de personal (staff_audit). Sólo administrador con MFA; la base lo exige con is_admin. */
export async function getStaffAudit(): Promise<
  { id: number; profileId: string; action: string; changedFields: string[]; changedBy: string | null; changedAt: string }[]
> {
  return checkedRead("STAFF_AUDIT", async () => {
    const supabase = await getSupabaseServerClient();
    if (!supabase) return [];
    const { data, error } = await supabase
      .from("staff_audit")
      .select("id, profile_id, action, changed_fields, changed_by, changed_at")
      .order("changed_at", { ascending: false })
      .limit(100)
      .abortSignal(AbortSignal.timeout(15000));
    if (error) throw new DataReadError("STAFF_AUDIT", error.code);
    return (data ?? []).map((row) => ({
      id: Number(row.id),
      profileId: row.profile_id as string,
      action: row.action as string,
      changedFields: (row.changed_fields as string[] | null) ?? [],
      changedBy: (row.changed_by as string | null) ?? null,
      changedAt: row.changed_at as string,
    }));
  });
}
