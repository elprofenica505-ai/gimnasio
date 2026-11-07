import { FinanceUnavailable } from "@/components/admin/finance-unavailable";
import { FinanceKpis } from "@/components/admin/finance-kpis";
import { MiniBar } from "@/components/admin/cash-panel";
import { readFinance } from "@/lib/finance/read-result";
import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { isFinanceRole, isAdminRole } from "@/lib/auth/current-user";
import { visibleModules } from "@/lib/admin/modules";
import { getDictionary } from "@/i18n/dictionaries";
import { isLocale, type Locale } from "@/i18n/config";
import { SectionHeading } from "@/components/ui/section";
import { CASHIER_PERMISSIONS_ALL } from "@/lib/finance/cashier-permissions";
import {
  getCashierPermissions,
  getCashSummary,
  getCurrentUser,
  getDailyCash,
  getMonthlyPnl,
} from "@/lib/data/queries";
import { DEMO_MODE } from "@/lib/supabase/env";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  return {
    title: "Finanzas",
    robots: { index: false, follow: false },
  };
}

export default async function FinanzasPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale: rawLocale } = await params;
  const locale: Locale = isLocale(rawLocale) ? rawLocale : "es";
  const dict = getDictionary(locale);
  const demo = DEMO_MODE;
  const user = await getCurrentUser();

  if (!demo && !isFinanceRole(user?.role)) {
    redirect(`/${locale}/panel`);
  }

  const permissionResult = demo
    ? { ok: true as const, data: CASHIER_PERMISSIONS_ALL }
    : await readFinance(() => getCashierPermissions());
  const permissions = permissionResult.ok ? permissionResult.data : null;
  const children = (visibleModules(user?.role, demo).find((m) => m.id === "finanzas")?.children ?? []).filter(
    (child) =>
      permissions &&
      (child.id !== "cuentas" || permissions.receivables) &&
      (child.id !== "gastos" || permissions.expenses) &&
      (child.id !== "reportes" || permissions.dailyClose || isAdminRole(user?.role)),
  );

  const result = demo
    ? null
    : !permissionResult.ok
      ? permissionResult
      : await readFinance(() =>
          Promise.all([
            getCashSummary(),
            permissions?.charts ? getDailyCash(14) : Promise.resolve([]),
            permissions?.monthlyResult ? getMonthlyPnl(6) : Promise.resolve([]),
          ]),
        );

  return (
    <>
      <section className="relative overflow-hidden border-b border-brand/25 bg-cloud pt-10 pb-8 sm:pt-12 sm:pb-10">
        <div className="container-x relative">
          <SectionHeading
            eyebrow="Módulo · Finanzas"
            title="Caja, cobros y gastos"
            subtitle={dict.admin.subtitle}
          />
        </div>
      </section>

      <section className="py-8 sm:py-10">
        <div className="container-x flex flex-col gap-8">
          {demo ? (
            <p className="rounded-xl border border-brand/30 bg-brand/[0.06] px-4 py-3 text-[0.75rem] leading-relaxed text-mist">
              Modo demo: las cifras financieras aparecen con Supabase conectado. No se muestran importes inventados.
            </p>
          ) : result && !result.ok ? (
            <FinanceUnavailable locale={locale} code={result.code} message={result.message} />
          ) : result && result.ok ? (
            <>
              <FinanceKpis summary={result.data[0]} showMonthly={permissions?.monthlyResult === true} />

              {permissions?.charts ? (
                <div className="grid gap-6 lg:grid-cols-2">
                  <div className="rounded-2xl border border-line bg-card p-5">
                    <MiniBar
                      label="Ingresos por día · últimos 14 días (NIO)"
                      data={result.data[1].map((d) => ({ label: d.day.slice(5), value: d.incomeNio }))}
                    />
                  </div>
                  {permissions.monthlyResult ? (
                    <div className="rounded-2xl border border-line bg-card p-5">
                      <div className="grid gap-6 sm:grid-cols-2">
                        <MiniBar
                          label="Ingresos por mes (NIO)"
                          data={result.data[2].map((m) => ({ label: m.month.slice(0, 7), value: m.incomeNio }))}
                        />
                        <MiniBar
                          label="Egresos por mes (NIO)"
                          data={result.data[2].map((m) => ({ label: m.month.slice(0, 7), value: m.expenseNio }))}
                        />
                      </div>
                    </div>
                  ) : null}
                </div>
              ) : null}
            </>
          ) : null}

          <div>
            <h2 className="mb-3 text-[0.6875rem] font-semibold tracking-[0.14em] text-fog uppercase">Submódulos</h2>
            <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
              {children.map((c) => (
                <Link
                  key={c.id}
                  href={`/${locale}${c.href}`}
                  className="rounded-2xl border border-line bg-card p-5 transition-colors hover:border-brand"
                >
                  <p className="text-[1rem] font-semibold text-ink">{c.label} →</p>
                </Link>
              ))}
            </div>
          </div>
        </div>
      </section>
    </>
  );
}
