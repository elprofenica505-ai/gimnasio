import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { SectionHeading } from "@/components/ui/section";
import { DataUnavailable } from "@/components/ui/data-unavailable";
import { ProgressForms, HeightCorrectionForm } from "@/components/progress/progress-forms";
import { readData } from "@/lib/data/read-result";
import { getCurrentUser } from "@/lib/data/queries";
import { getClientProgress, type ClientProgress } from "@/lib/data/progress-queries";
import { getClientAttendance } from "@/lib/data/attendance-queries";
import { AttendanceTable } from "@/components/attendance/attendance-table";
import { HashScroll } from "@/components/progress/hash-scroll";
import { NutritionCalculator } from "@/components/nutrition/nutrition-calculator";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { CLIENT_CATEGORY_LABEL } from "@/lib/clients/category";
import type { AttendanceData } from "@/lib/attendance/summary";
import { isLocale, type Locale } from "@/i18n/config";
import { DEMO_MODE } from "@/lib/supabase/env";
import { isStaffRole, isAdminRole } from "@/lib/auth/current-user";
import { BackLink } from "@/components/ui/back-link";
import { groupRoutineByDay, formatRest, formatSeries } from "@/lib/progress/routine-view";
import {
  addMonths, BMI_LABEL, bmi, bmiCategory, goalProgress, goalStartWeight, healthyWeightRange, managuaToday, GOAL_TYPES,
} from "@/lib/progress/rules";

type ProgressSearchParams = { vista?: string | string[] };

function isAttendanceView(query: ProgressSearchParams) {
  return (Array.isArray(query.vista) ? query.vista[0] : query.vista) === "asistencia";
}

export async function generateMetadata({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams?: Promise<ProgressSearchParams>;
}): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const attendanceOnly = isAttendanceView(searchParams ? await searchParams : {});
  return {
    title: attendanceOnly ? "Asistencia del cliente" : "Progreso del cliente",
    robots: { index: false, follow: false },
  };
}

const fmt1 = (n: number) => n.toLocaleString("es-NI", { minimumFractionDigits: 1, maximumFractionDigits: 1 });

export default async function ProgresoClientePage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string; id: string }>;
  searchParams?: Promise<ProgressSearchParams>;
}) {
  const { locale: rawLocale, id } = await params;
  const attendanceOnly = isAttendanceView(searchParams ? await searchParams : {});
  const locale: Locale = isLocale(rawLocale) ? rawLocale : "es";
  const user = await getCurrentUser();

  if (!DEMO_MODE && (!user || !isStaffRole(user.role) || user.mfa !== "ok")) {
    redirect(`/${locale}/panel`);
  }
  const canRecord = DEMO_MODE ? false : isStaffRole(user?.role);
  const canManage = DEMO_MODE ? false : isAdminRole(user?.role) || user?.role === "trainer";

  const result = DEMO_MODE || !/^[0-9a-f-]{36}$/i.test(id) ? null : await readData(() => getClientProgress(id));
  const data: ClientProgress | null = result && result.ok ? result.data : null;
  const attResult = DEMO_MODE || !/^[0-9a-f-]{36}$/i.test(id) ? null : await readData(() => getClientAttendance(id));
  const attendance = attResult && attResult.ok ? attResult.data : null;
  const today = managuaToday();
  // Categoría calculada en la base (00042). Si falla, no se muestra una categoría falsa.
  let category: string | null = null;
  if (!DEMO_MODE && data && !attendanceOnly) {
    const db = await getSupabaseServerClient();
    const { data: cat } = db ? await db.rpc("client_category", { p_client: id }) : { data: null };
    const key = (cat as { category?: string } | null)?.category;
    category = key && key in CLIENT_CATEGORY_LABEL ? CLIENT_CATEGORY_LABEL[key as keyof typeof CLIENT_CATEGORY_LABEL] : null;
  }

  return (
    <>
      <HashScroll />
      <section className="relative overflow-hidden border-b border-brand/25 bg-cloud pt-10 pb-8 sm:pt-12 sm:pb-10">
        <div className="container-x relative">
          <SectionHeading
            eyebrow={attendanceOnly ? "Módulo · Asistencia" : "Módulo · Progreso"}
            title={
              data
                ? data.clientName
                : attendanceOnly
                  ? "Asistencia del cliente"
                  : "Progreso del cliente"
            }
            subtitle={
              attendanceOnly
                ? "Visitas por día, semana y mes. Esta vista es solo de asistencia."
                : "Medidas, meta y rutina. Las mediciones se guardan para siempre; una corrección es una medición nueva."
            }
          />
        </div>
      </section>
      <section className="py-8 sm:py-10">
        <div className="container-x grid gap-6">
          <div className="flex flex-wrap gap-x-5 gap-y-2">
            <BackLink href={`/${locale}/panel/clientes`} hint="Clientes" />
            {attendanceOnly && data && (
              <a href={`/${locale}/panel/progreso/${id}`} className="text-sm text-brand-300 underline">
                Ver progreso y medidas
              </a>
            )}
          </div>
          {DEMO_MODE ? (
            <p className="rounded-xl border border-brand/30 bg-brand/[0.06] px-4 py-3 text-[0.8125rem] text-mist">
              Modo demo: el progreso requiere Supabase conectado. No se muestran datos.
            </p>
          ) : !id || !/^[0-9a-f-]{36}$/i.test(id) ? (
            <p className="text-mist">Cliente no válido.</p>
          ) : result && !result.ok ? (
            <DataUnavailable locale={locale} code={result.code} />
          ) : !data ? (
            <p className="rounded-xl border border-line bg-card p-4 text-mist">
              No encontramos este cliente o no tenés acceso. Si es un cliente nuevo, pedile al administrador que te lo asigne.
            </p>
          ) : (
            attendanceOnly ? (
              attResult && !attResult.ok ? (
                <section id="asistencia" className="rounded-2xl border border-line bg-card p-4 scroll-mt-24">
                  <p className="text-[0.875rem] text-mist">La asistencia no se pudo cargar en este momento. Intentá de nuevo más tarde.</p>
                </section>
              ) : (
                <AttendanceTable data={attendance} />
              )
            ) : (
              <>
                {category && <p className="rounded-xl border border-line bg-card px-4 py-3 text-[0.9rem] text-ink">Categoría: <strong>{category}</strong></p>}
                <ProgressView data={data} today={today} canRecord={canRecord} canManage={canManage} isAdmin={isAdminRole(user?.role)} attendance={attendance} attendanceFailed={!!(attResult && !attResult.ok)} />
                {canRecord && (<section className="grid gap-3"><h2 className="text-xl font-bold text-ink">Calculadora, plan nutricional y rutina</h2><NutritionCalculator mode="staff" clientId={data.clientId} isAdmin={isAdminRole(user?.role)} /></section>)}
              </>
            )
          )}
        </div>
      </section>
    </>
  );
}

function ProgressView({
  data, today, canRecord, canManage, isAdmin, attendance, attendanceFailed,
}: { data: ClientProgress; today: string; canRecord: boolean; canManage: boolean; isAdmin: boolean; attendance: AttendanceData | null; attendanceFailed: boolean }) {
  const last = data.measurements[0];
  const withHeight = data.measurements.find((m) => m.heightCm !== null);
  const height = data.fichaHeightCm ?? withHeight?.heightCm ?? null;
  const first = data.measurements[data.measurements.length - 1];
  const current = last?.weightKg ?? null;
  const index = current !== null && height ? bmi(current, height) : null;
  const range = height ? healthyWeightRange(height) : null;
  const progress = data.goal
    ? goalProgress({
        goalType: data.goal.goalType,
        startWeightKg: goalStartWeight(data.measurements, data.goal.startsOn),
        currentWeightKg: current,
        targetWeightKg: data.goal.targetWeightKg,
      })
    : null;
  const goalLabel = data.goal ? GOAL_TYPES.find((g) => g.key === data.goal?.goalType)?.label : null;
  const routineGroups = data.routine ? groupRoutineByDay(data.routine.exercises) : [];

  return (
    <>
      {isAdmin && <HeightCorrectionForm clientId={data.clientId} currentHeight={height} />}
      {(canRecord || canManage) && (
        <details className="rounded-2xl border border-brand/30 bg-card p-4">
          <summary className="cursor-pointer text-lg font-bold text-ink">
            + Registrar medición{canManage ? ", cambiar meta o rutina" : ""}
          </summary>
          <div className="mt-4">
            <ProgressForms
              clientId={data.clientId}
              canRecord={canRecord}
              canManage={canManage}
              today={today}
              maxTargetDate={addMonths(today, 12)}
            />
          </div>
        </details>
      )}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Peso actual" value={current !== null ? `${fmt1(current)} kg` : "Sin datos"} sub={last ? `Medido el ${last.measuredOn}` : "Registra la primera medición"} />
        <Stat label="IMC (OMS)" value={index !== null ? fmt1(index) : "Sin datos"} sub={index !== null ? BMI_LABEL[bmiCategory(index)] : "Hace falta altura"} />
        <Stat label="Peso sano para su altura" value={range ? `${fmt1(range[0])} a ${fmt1(range[1])} kg` : "Sin datos"} sub={range ? "IMC de 18.5 a 24.9" : "Hace falta altura"} />
        <Stat label="Avance de la meta" value={progress?.percent !== null && progress?.percent !== undefined ? `${progress.percent} %` : progress ? statusText(progress.status) : "Sin meta"} sub={goalLabel ?? "Sin meta activa"} />
      </div>

      {attendanceFailed ? (
        <section id="asistencia" className="rounded-2xl border border-line bg-card p-4 scroll-mt-24">
          <p className="text-[0.875rem] text-mist">La asistencia no se pudo cargar en este momento. Intentá de nuevo más tarde.</p>
        </section>
      ) : (
        <AttendanceTable data={attendance} />
      )}
      <section className="rounded-2xl border border-line bg-card p-4">
        <h2 className="mb-2 text-lg font-bold text-ink">Meta activa</h2>
        {data.goal ? (
          <p className="text-sm text-fog">
            {goalLabel}{data.goal.otherLabel ? `: ${data.goal.otherLabel}` : ""} · inicio {data.goal.startsOn} · fecha límite {data.goal.targetDate}
            {data.goal.targetWeightKg !== null ? ` · peso objetivo ${fmt1(data.goal.targetWeightKg)} kg` : ""}.
            <br />Revisiones cada 3 meses: {[3, 6, 9, 12].map((m) => addMonths(data.goal!.startsOn, m)).filter((d) => d <= data.goal!.targetDate).join(", ") || "ninguna todavía"}.
          </p>
        ) : (
          <p className="text-sm text-fog">Este cliente no tiene una meta activa.</p>
        )}
      </section>

      <section className="rounded-2xl border border-line bg-card p-4">
        <h2 className="mb-2 text-lg font-bold text-ink">Rutina activa</h2>
        {data.routine ? (
          <>
            <p className="text-sm text-fog">
              <span className="font-semibold text-ink">{data.routine.name}</span> · desde {data.routine.startsOn}
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              {data.routine.days.map((d) => (
                <span key={d} className="rounded-full border border-brand/40 bg-brand/[0.08] px-3 py-1 text-xs font-semibold text-ink">{d}</span>
              ))}
            </div>
            <div className="mt-4 grid gap-4 lg:grid-cols-2">
              {routineGroups.map((g) => (
                <div key={g.day} className="min-w-0 rounded-xl border border-line p-3">
                  <h3 className="font-semibold text-ink">{g.day}</h3>
                  {g.focus && <p className="text-xs text-fog">{g.focus}</p>}
                  <div className="mt-2 overflow-x-auto">
                    <table className="w-full min-w-[320px] text-left text-sm text-ink">
                      <thead className="text-xs uppercase tracking-wide text-fog">
                        <tr><th className="py-2 pr-3">Ejercicio</th><th className="pr-3">Series</th><th className="pr-3">Reps / tiempo</th><th className="pr-3">Descanso</th></tr>
                      </thead>
                      <tbody>
                        {g.items.map((it, i) => (
                          <tr key={i} className="border-t border-line">
                            <td className="py-2 pr-3">{it.name}</td>
                            <td className="pr-3">{formatSeries(it.series)}</td>
                            <td className="pr-3">{it.reps ?? "—"}</td>
                            <td className="pr-3">{formatRest(it.restSec)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              ))}
            </div>
          </>
        ) : (
          <p className="text-sm text-fog">Sin rutina activa.</p>
        )}
      </section>

      <section className="rounded-2xl border border-line bg-card p-4">
        <h2 className="mb-2 text-lg font-bold text-ink">Historial de mediciones</h2>
        {data.measurements.length === 0 ? (
          <p className="text-sm text-fog">Todavía no hay mediciones.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[640px] text-left text-sm text-ink">
              <thead className="text-fog">
                <tr>
                  <th className="py-2 pr-3">Fecha</th><th className="pr-3">Peso kg</th><th className="pr-3">IMC</th>
                  <th className="pr-3">Cintura</th><th className="pr-3">Pecho</th><th className="pr-3">Bíceps rel.</th>
                  <th className="pr-3">Bíceps con.</th><th className="pr-3">Antebrazo</th><th className="pr-3">Glúteo</th>
                  <th className="pr-3">Muslo</th><th className="pr-3">Pantorrilla</th>
                </tr>
              </thead>
              <tbody>
                {data.measurements.map((m) => {
                  const h = m.heightCm ?? height;
                  const idx = h ? bmi(m.weightKg, h) : null;
                  const cell = (v: number | null) => (v === null ? "—" : fmt1(v));
                  return (
                    <tr key={m.id} className="border-t border-line">
                      <td className="py-2 pr-3">{m.measuredOn}</td>
                      <td className="pr-3">{fmt1(m.weightKg)}</td>
                      <td className="pr-3">{idx !== null ? fmt1(idx) : "—"}</td>
                      <td className="pr-3">{cell(m.values.cintura_cm)}</td>
                      <td className="pr-3">{cell(m.values.pecho_cm)}</td>
                      <td className="pr-3">{cell(m.values.biceps_relajado_cm)}</td>
                      <td className="pr-3">{cell(m.values.biceps_contraido_cm)}</td>
                      <td className="pr-3">{cell(m.values.antebrazo_cm)}</td>
                      <td className="pr-3">{cell(m.values.gluteo_cm)}</td>
                      <td className="pr-3">{cell(m.values.muslo_cm)}</td>
                      <td className="pr-3">{cell(m.values.pantorrilla_cm)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            <p className="mt-2 text-xs text-fog">Un guion (—) significa que la medida no se tomó. No es cero.</p>
          </div>
        )}
      </section>

    </>
  );
}

function statusText(status: string): string {
  if (status === "sin_datos") return "Sin datos";
  if (status === "en_rango") return "En rango";
  if (status === "fuera_de_rango") return "Fuera de rango";
  if (status === "manual") return "Revisión manual";
  return status;
}

function Stat({ label, value, sub }: { label: string; value: string; sub: string }) {
  return (
    <div className="min-w-0 rounded-2xl border border-line bg-card p-4">
      <p className="text-xs uppercase tracking-wide text-fog">{label}</p>
      <p className="mt-1 text-xl font-bold text-ink">{value}</p>
      <p className="mt-1 text-xs text-fog">{sub}</p>
    </div>
  );
}
