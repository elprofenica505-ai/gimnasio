import { readData } from "@/lib/data/read-result";
import { readFinance } from "@/lib/finance/read-result";
import { getTrainerAccessAdmin } from "@/lib/data/queries";
import { DataUnavailable } from "@/components/ui/data-unavailable";
import { FinanceUnavailable } from "@/components/admin/finance-unavailable";
import { InteractiveBarChart } from "@/components/admin/interactive-chart";
import { FinanceKpis } from "@/components/admin/finance-kpis";
import type { Metadata } from "next";
import Link from "next/link";
import { canAccessPanel, isAdminRole } from "@/lib/auth/current-user";
import { LinkPending } from "@/components/ui/link-pending";
import { panelAccess, visibleModules, type PanelModule } from "@/lib/admin/modules";
import { Bell, CalendarCheck, CalendarDays, MessageSquare, ShieldAlert, UserPlus, Users, Wallet, Receipt, Zap } from "lucide-react";
import { formatMoney } from "@/lib/finance/format-money";
import { getDictionary } from "@/i18n/dictionaries";
import { isLocale, type Locale } from "@/i18n/config";
import { redirect } from "next/navigation";
import { SectionHeading } from "@/components/ui/section";
import { ButtonLink } from "@/components/ui/button";
import { CASHIER_PERMISSIONS_ALL, type CashierPermissions } from "@/lib/finance/cashier-permissions";
import {
  countMembers,
  getAllBookings,
  getCashierPermissions,
  getCashSummary,
  getContactMessages,
  getCurrentUser,
  getDailyCash,
  getMonthlyPnl,
  getSessionsForWeek,
} from "@/lib/data/queries";
import { demoAdminBookings, demoAdminMessages } from "@/lib/data/demo-admin";
import { formatDateNumeric, gymNow } from "@/lib/schedule";
import { DEMO_MODE } from "@/lib/supabase/env";
import { cn } from "@/lib/utils";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  return {
    title: "Panel de gestión",
    robots: { index: false, follow: false },
  };
}

const WEEKDAYS = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"];

export default async function PanelHomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale: rawLocale } = await params;
  const locale: Locale = isLocale(rawLocale) ? rawLocale : "es";
  const dict = getDictionary(locale);
  const demo = DEMO_MODE;
  const user = await getCurrentUser();

  if (!demo && !user) redirect(`/${locale}/ingresar`);

  // Un fallo de RLS/red o un perfil inexistente no es una denegación por rol.
  if (!demo && user && user.profileStatus !== "ready") {
    const es = locale === "es";
    return (
      <section className="container-x flex min-h-[70vh] flex-col items-center justify-center gap-5 py-24 text-center">
        <ShieldAlert className="size-8 text-alert" aria-hidden="true" />
        <h1 className="display-xl text-[1.75rem]">
          {es ? "No pudimos verificar tu perfil" : "We could not verify your profile"}
        </h1>
        <p className="max-w-lg text-fog">
          {es
            ? "Tu sesión está iniciada, pero no se pudo leer un perfil válido en public.profiles. No cambiamos tu rol ni habilitamos acceso sin verificarlo."
            : "You are signed in, but a valid public.profiles record could not be read. Your role was not changed and access remains protected."}
        </p>
        <p className="max-w-full break-all font-mono text-xs text-fog">
          ID: {user.id} ·{" "}
          {user.profileStatus === "missing"
            ? es ? "Perfil no visible o inexistente" : "Profile missing or not visible"
            : es ? "Error al leer el perfil" : "Profile read error"}
        </p>
      </section>
    );
  }

  // El entrenador tiene su propio módulo: "Mis clientes".
  if (!demo && user?.role === "trainer" && canAccessPanel(user)) redirect(`/${locale}/panel/entrenador`);

  if (!demo && !canAccessPanel(user)) {
    return (
      <section className="container-x flex min-h-[70vh] flex-col items-center justify-center py-24 text-center">
        <span className="grid size-14 place-items-center rounded-full border border-alert/40 bg-alert/10 text-alert">
          <ShieldAlert className="size-6" aria-hidden="true" />
        </span>
        <h1 className="display-xl mt-5 text-[1.75rem] sm:text-[2.25rem]">{dict.admin.noAccess}</h1>
        <p className="mt-3 max-w-md text-[0.9375rem] leading-relaxed text-fog">{dict.admin.noAccessHint}</p>
        <div className="mt-7">
          <ButtonLink href={`/${locale}/mi-cuenta`} variant="outline" size="lg">
            {dict.account.title}
          </ButtonLink>
        </div>
      </section>
    );
  }

  const role = user?.role ?? null;
  const access = panelAccess(role, demo);
  const modules = visibleModules(role, demo).filter((m) => m.id !== "inicio");

  // Cuenta de entrenador: sin módulos de gestión todavía.
  if (!demo && access === "none") {
    return (
      <TrainerNotice locale={locale} />
    );
  }

  /* ---------- Operación: reservas, clientes y mensajes ---------- */
  let bookingsRaw: Awaited<ReturnType<typeof getAllBookings>> = [];
  let messages: Awaited<ReturnType<typeof getContactMessages>> = [];
  let memberCount = 0;
  let operationError: string | null = null;

  if (demo) {
    bookingsRaw = [];
    messages = demoAdminMessages();
    memberCount = 942;
  } else {
    const result = await readData(() =>
      Promise.all([getAllBookings(), getContactMessages(), countMembers(), getSessionsForWeek()]),
    );
    if (!result.ok) {
      operationError = result.code;
    } else {
      [bookingsRaw, messages, memberCount] = [result.data[0], result.data[1], result.data[2]];
    }
  }

  const now = gymNow();
  const todayKey = formatDateNumeric(now, "es");
  const day = now.getDay();
  const startOfWeek = new Date(now.getTime() - (day === 0 ? 6 : day - 1) * 86_400_000);
  const weekDays = Array.from({ length: 7 }, (_, i) => new Date(startOfWeek.getTime() + i * 86_400_000));

  const activeBookings = demo
    ? demoAdminBookings().filter((b) => b.status !== "cancelled")
    : bookingsRaw.filter((b) => b.status !== "cancelled").map((b) => ({ startsAt: b.session.starts_at }));

  const bookingsToday = activeBookings.filter(
    (b) => formatDateNumeric(new Date(b.startsAt), "es") === todayKey,
  ).length;
  const bookingsWeek = activeBookings.filter((b) => new Date(b.startsAt) >= startOfWeek).length;
  const messagesWeek = messages.filter((m) => new Date(m.created_at) >= startOfWeek).length;

  const bookingsByDay = weekDays.map((d, i) => {
    const key = formatDateNumeric(d, "es");
    return {
      label: WEEKDAYS[i],
      value: activeBookings.filter((b) => formatDateNumeric(new Date(b.startsAt), "es") === key).length,
      highlight: key === todayKey,
    };
  });

  /* ---------- Administración: pendientes de entrenadores ---------- */
  let pendingTrainerRequests: number | null = null;
  if (!demo && isAdminRole(role)) {
    const access = await readData(() => getTrainerAccessAdmin());
    if (access.ok) pendingTrainerRequests = access.data.requests.filter((r) => r.status === "pending").length;
  }

  /* ---------- Finanzas: sólo caja y administración ---------- */
  let finance: Awaited<ReturnType<typeof readFinance<[Awaited<ReturnType<typeof getCashSummary>>, Awaited<ReturnType<typeof getMonthlyPnl>>]>>> | null = null;
  let cashierPermissions: CashierPermissions = CASHIER_PERMISSIONS_ALL;
  if (!demo && access !== "none") {
    const permissionResult = await readFinance(() => getCashierPermissions());
    if (!permissionResult.ok) {
      finance = permissionResult;
    } else {
      cashierPermissions = permissionResult.data;
      finance = await readFinance(() =>
        Promise.all([
          getCashSummary(),
          cashierPermissions.monthlyResult ? getMonthlyPnl(6) : Promise.resolve([]),
        ]),
      );
    }
  }

  const kpis = [
    { label: "Clientes", value: String(memberCount), hint: "Fichas activas", icon: Users },
    { label: "Reservas hoy", value: String(bookingsToday), hint: "Sin canceladas", icon: CalendarCheck },
    { label: "Reservas esta semana", value: String(bookingsWeek), hint: "Lunes a hoy", icon: CalendarDays },
    { label: "Mensajes esta semana", value: String(messagesWeek), hint: "Contacto del sitio", icon: MessageSquare },
  ];

  return (
    <>
      <section className="relative overflow-hidden border-b border-brand/25 bg-cloud pt-10 pb-8 sm:pt-12 sm:pb-10">
        <div className="absolute inset-0 bg-grid opacity-50" aria-hidden="true" />
        <div className="container-x relative">
          <SectionHeading
            eyebrow="Panel de gestión"
            title="Resumen del gimnasio"
            subtitle="Cifras clave del día y del mes. Cada módulo tiene su detalle en el menú superior."
          />
          <p className="mt-4 text-[0.8125rem] text-fog">
            {user ? (
              <>
                {user.fullName} · <span className="font-mono text-brand-300">{user.role}</span>
              </>
            ) : (
              <>{dict.demo.title}</>
            )}
          </p>
        </div>
      </section>

      <section className="py-8 sm:py-10">
        <div className="container-x flex flex-col gap-8">
          {demo ? (
            <p className="rounded-xl border border-brand/30 bg-brand/[0.06] px-4 py-3 text-[0.75rem] leading-relaxed text-mist">
              {dict.admin.demoNotice}
            </p>
          ) : null}

          {/* Indicadores */}
          {operationError ? (
            <DataUnavailable locale={locale} code={operationError} />
          ) : (
            <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
              {kpis.map((k) => (
                <div key={k.label} className="flex flex-col gap-3 rounded-2xl border border-line bg-card p-4">
                  <span className="grid size-9 place-items-center rounded-xl bg-brand/10 text-brand">
                    <k.icon className="size-4" aria-hidden />
                  </span>
                  <div>
                    <p className="font-display text-[1.75rem] leading-none text-ink tabular-nums">{k.value}</p>
                    <p className="mt-1.5 text-[0.75rem] font-semibold text-mist">{k.label}</p>
                    <p className="text-[0.6875rem] text-fog">{k.hint}</p>
                  </div>
                </div>
              ))}
            </div>
          )}

          {/* Finanzas del mes */}
          {demo ? (
            <p className="text-sm text-fog">
              En modo demo las cifras financieras no se calculan. Con Supabase conectado aparecen aquí.
            </p>
          ) : finance && !finance.ok ? (
            <FinanceUnavailable locale={locale} code={finance.code} message={finance.message} />
          ) : finance && finance.ok ? (
            <FinanceKpis summary={finance.data[0]} showMonthly={cashierPermissions.monthlyResult} />
          ) : null}

          {/* Hoy y pendientes: sólo administración */}
          {isAdminRole(role) && !demo ? (
            <AdminToday
              locale={locale}
              cash={finance && finance.ok ? finance.data[0] : null}
              pendingTrainerRequests={pendingTrainerRequests}
              recentMessages={messages.slice(0, 5).map((m) => ({ id: m.id, name: m.name, createdAt: m.created_at }))}
            />
          ) : null}

          {/* Gráficos interactivos */}
          <div className="grid gap-6 lg:grid-cols-2">
            <div className="min-w-0 rounded-2xl border border-line bg-card p-5">
              <InteractiveBarChart
                title="Reservas · esta semana"
                countUnit="reservas"
                emptyText="Todavía no hay reservas esta semana."
                series={[{ id: "bookings", label: "Reservas", tone: "brand", data: bookingsByDay.map((d) => ({ label: d.label, value: d.value })) }]}
                format="count"
              />
            </div>
            <div className="min-w-0 rounded-2xl border border-line bg-card p-5">
              {finance && finance.ok && cashierPermissions.charts && cashierPermissions.monthlyResult ? (
                <InteractiveBarChart
                  title="Finanzas · últimos 6 meses (NIO)"
                  emptyText="Sin movimientos financieros registrados."
                  format="nio-compact"
                  series={[
                    {
                      id: "net",
                      label: "Resultado",
                      tone: "ink",
                      data: finance.data[1].map((m) => ({ label: m.month.slice(0, 7), value: m.incomeNio - m.expenseNio })),
                    },
                    {
                      id: "income",
                      label: "Ingresos",
                      tone: "brand",
                      data: finance.data[1].map((m) => ({ label: m.month.slice(0, 7), value: m.incomeNio })),
                    },
                    {
                      id: "expense",
                      label: "Egresos",
                      tone: "alert",
                      data: finance.data[1].map((m) => ({ label: m.month.slice(0, 7), value: m.expenseNio })),
                    },
                  ]}
                />
              ) : (
                <p className="py-8 text-sm text-fog">
                  {demo
                    ? "Gráfico financiero disponible con Supabase conectado."
                    : finance && finance.ok
                      ? "Administración todavía no activó este gráfico financiero para caja."
                      : "El gráfico financiero no está disponible en este momento."}
                </p>
              )}
            </div>
          </div>

          {/* Módulos */}
          <div>
            <h2 className="mb-3 text-[0.6875rem] font-semibold tracking-[0.14em] text-fog uppercase">Módulos</h2>
            <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
              {modules.map((m) => (
                <ModuleCard key={m.id} module={m} locale={locale} />
              ))}
            </div>
          </div>
        </div>
      </section>
    </>
  );
}

function ModuleCard({ module, locale }: { module: PanelModule; locale: Locale }) {
  return (
    <div className={cn("flex flex-col rounded-2xl border border-line bg-card p-5")}>
      <Link href={`/${locale}${module.href}`} className="group flex items-center gap-2">
        <p className="text-[1rem] font-semibold text-ink group-hover:text-brand-300">{module.label} →</p>
        <LinkPending label={`Abriendo ${module.label}…`} />
      </Link>
      <p className="mt-1 text-[0.8125rem] leading-relaxed text-fog">{module.description}</p>
      {module.children.length > 0 ? (
        <ul className="mt-3 flex flex-col gap-1.5 border-t border-line pt-3">
          {module.children.map((c) => (
            <li key={c.id}>
              <Link href={`/${locale}${c.href}`} className="inline-flex items-center gap-1.5 text-[0.8125rem] text-mist hover:text-brand-300">
                {c.label}
                <LinkPending label={`Abriendo ${c.label}…`} />
              </Link>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function TrainerNotice({ locale }: { locale: Locale }) {
  const es = locale === "es";
  return (
    <section className="container-x flex min-h-[60vh] flex-col items-center justify-center gap-4 py-24 text-center">
      <h1 className="display-xl text-[1.75rem]">{es ? "Vista de entrenador en preparación" : "Trainer view in preparation"}</h1>
      <p className="max-w-lg text-fog">
        {es
          ? "Tu cuenta es de entrenador. La lista de tus clientes con asistencia se activará cuando se apruebe su ubicación en el menú. Mientras tanto no se muestran datos de gestión."
          : "Your account is a trainer account. Your client attendance list will appear once its menu location is approved."}
      </p>
    </section>
  );
}

/** Referencia a sesiones: el inicio no las usa todavía, se mantiene la lectura para la semana. */
export const _dashboardDataKeys = ["getSessionsForWeek"] as const;

const todayFormat = new Intl.DateTimeFormat("es-NI", {
  timeZone: "America/Managua",
  day: "2-digit",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
});

function AdminToday({
  locale,
  cash,
  pendingTrainerRequests,
  recentMessages,
}: {
  locale: Locale;
  cash: { incomeToday: number; expenseToday: number; netToday: number; txToday: number } | null;
  pendingTrainerRequests: number | null;
  recentMessages: { id: string; name: string; createdAt: string }[];
}) {
  const quick = [
    { href: "/panel/clientes", label: "Clientes y personal", icon: UserPlus },
    { href: "/panel/caja", label: "Caja", icon: Wallet },
    { href: "/panel/administracion/entrenadores", label: "Asignar cliente", icon: Zap },
    { href: "/panel/finanzas", label: "Finanzas", icon: Receipt },
  ];
  return (
    <div className="grid gap-4 lg:grid-cols-3">
      <div className="flex flex-col gap-3 rounded-2xl border border-line bg-card p-5">
        <p className="text-[0.6875rem] font-semibold tracking-[0.14em] text-fog uppercase">Caja de hoy</p>
        {cash ? (
          <dl className="grid grid-cols-3 gap-2">
            <div>
              <dt className="text-[0.6875rem] text-fog">Ingresos</dt>
              <dd className="font-display text-[1.125rem] text-brand tabular-nums">{formatMoney(cash.incomeToday, "NIO", { compact: true })}</dd>
            </div>
            <div>
              <dt className="text-[0.6875rem] text-fog">Egresos</dt>
              <dd className="font-display text-[1.125rem] text-alert tabular-nums">{formatMoney(cash.expenseToday, "NIO", { compact: true })}</dd>
            </div>
            <div>
              <dt className="text-[0.6875rem] text-fog">Saldo</dt>
              <dd className="font-display text-[1.125rem] text-ink tabular-nums">{formatMoney(cash.netToday, "NIO", { compact: true })}</dd>
            </div>
          </dl>
        ) : (
          <p className="text-sm text-fog">Caja no disponible en este momento.</p>
        )}
        <p className="text-[0.75rem] text-mist">{cash ? `${cash.txToday} movimiento${cash.txToday === 1 ? "" : "s"} hoy` : ""}</p>
      </div>

      <div className="flex flex-col gap-3 rounded-2xl border border-line bg-card p-5">
        <p className="text-[0.6875rem] font-semibold tracking-[0.14em] text-fog uppercase">Pendientes</p>
        <Link
          href={`/${locale}/panel/administracion/entrenadores`}
          className="flex items-center justify-between gap-3 rounded-xl bg-cloud px-4 py-3 hover:bg-brand/10"
        >
          <span className="flex items-center gap-2 text-[0.875rem] text-ink">
            <Bell className="size-4 text-brand" aria-hidden />
            Pedidos de entrenadores
          </span>
          <span className="font-display text-[1.25rem] text-ink tabular-nums">
            {pendingTrainerRequests ?? "—"}
          </span>
        </Link>
        <Link
          href={`/${locale}/panel/administracion/entrenadores`}
          className="text-[0.75rem] font-semibold text-brand hover:underline"
        >
          Revisar y asignar →
        </Link>
      </div>

      <div className="flex flex-col gap-3 rounded-2xl border border-line bg-card p-5">
        <p className="text-[0.6875rem] font-semibold tracking-[0.14em] text-fog uppercase">Accesos rápidos</p>
        <ul className="grid grid-cols-2 gap-2">
          {quick.map((q) => (
            <li key={q.href}>
              <Link
                href={`/${locale}${q.href}`}
                className="flex h-full items-center gap-2 rounded-xl border border-line px-3 py-2.5 text-[0.8125rem] font-semibold text-ink hover:border-brand hover:text-brand-300"
              >
                <q.icon className="size-4 text-brand" aria-hidden />
                {q.label}
              </Link>
            </li>
          ))}
        </ul>
      </div>

      <div className="flex flex-col gap-3 rounded-2xl border border-line bg-card p-5 lg:col-span-3">
        <p className="text-[0.6875rem] font-semibold tracking-[0.14em] text-fog uppercase">Últimos mensajes del sitio</p>
        {recentMessages.length === 0 ? (
          <p className="text-sm text-fog">Todavía no hay mensajes.</p>
        ) : (
          <ul className="divide-y divide-line">
            {recentMessages.map((m) => (
              <li key={m.id} className="flex items-center justify-between gap-3 py-2.5">
                <span className="flex min-w-0 items-center gap-2 text-[0.875rem] text-ink">
                  <MessageSquare className="size-4 shrink-0 text-fog" aria-hidden />
                  <span className="truncate">{m.name}</span>
                </span>
                <span className="shrink-0 text-[0.75rem] text-fog">{todayFormat.format(new Date(m.createdAt))}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
