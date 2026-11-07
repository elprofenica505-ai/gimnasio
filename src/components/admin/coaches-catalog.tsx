"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";

/** Fila de `coaches` tal como la devuelve `admin_coaches_catalog()`. */
export type AdminCoach = {
  id: string;
  full_name: string;
  specialty: string;
  specialties: string[];
  specialty_labels: string[];
  is_active: boolean;
  slots_active: number;
  sessions_upcoming: number;
  sessions_unassigned: number;
};

export type CoachAudit = {
  id: number;
  coach_id: string;
  coach_name: string | null;
  action: "alta" | "edicion" | "baja" | "reactivacion";
  changed_fields: string[];
  changed_by_name: string;
  changed_at: string;
};

export type CoachClass = {
  id: string;
  slug: string;
  name_es: string;
  is_active: boolean;
};

export type CoachesCatalog = {
  coaches: AdminCoach[];
  classes: CoachClass[];
  audit: CoachAudit[];
};

const FIELD_LABEL: Record<string, string> = {
  full_name: "nombre",
  specialty: "especialidad",
  specialties: "disciplinas que dicta",
};

const ACTION_LABEL: Record<CoachAudit["action"], string> = {
  alta: "lo agregó",
  edicion: "lo editó",
  baja: "lo dio de baja",
  reactivacion: "lo volvió a activar",
};

const input =
  "w-full rounded-lg border border-line bg-paper px-3 py-2 text-ink disabled:opacity-60";

const formatMoment = (value: string) =>
  new Intl.DateTimeFormat("es-NI", {
    timeZone: "America/Managua",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(value));

const plural = (count: number, one: string, many: string) =>
  `${count} ${count === 1 ? one : many}`;

type Draft = {
  id: string | null;
  fullName: string;
  specialty: string;
  specialties: string[];
};

const emptyDraft = (): Draft => ({
  id: null,
  fullName: "",
  specialty: "",
  specialties: [],
});

const fromCoach = (coach: AdminCoach): Draft => ({
  id: coach.id,
  fullName: coach.full_name,
  specialty: coach.specialty,
  specialties: [...coach.specialties],
});

/**
 * Entrenadores del gimnasio (OP-05). Quién está en la plantilla y qué
 * disciplinas dicta cada uno. Esas disciplinas son las que usa el calendario
 * para asignar entrenador cuando un horario no lo tiene puesto.
 */
export function CoachesCatalog({ initial }: { initial: CoachesCatalog }) {
  const [catalog, setCatalog] = useState<CoachesCatalog>(initial);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ tone: "ok" | "error"; text: string } | null>(
    null,
  );

  const set = <K extends keyof Draft>(key: K, value: Draft[K]) =>
    setDraft((current) => (current ? { ...current, [key]: value } : current));

  const toggleSpecialty = (slug: string) =>
    setDraft((current) =>
      current
        ? {
            ...current,
            specialties: current.specialties.includes(slug)
              ? current.specialties.filter((item) => item !== slug)
              : [...current.specialties, slug],
          }
        : current,
    );

  async function post(payload: unknown) {
    const res = await fetch("/api/admin/coaches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = (await res.json().catch(() => null)) as
      | { catalog?: CoachesCatalog | null; action?: string; changed?: boolean; message?: string }
      | null;
    return { res, data };
  }

  async function save() {
    if (!draft || busy) return;
    setBusy(true);
    setNotice(null);
    try {
      const { res, data } = await post({
        action: "save",
        id: draft.id,
        fullName: draft.fullName.trim(),
        specialty: draft.specialty.trim(),
        specialties: draft.specialties,
      });
      if (!res.ok || !data?.catalog) {
        setNotice({
          tone: "error",
          text:
            data?.message ??
            "No se pudo guardar el entrenador. Recargá antes de repetir.",
        });
        return;
      }
      setCatalog(data.catalog);
      const name = draft.fullName.trim();
      setNotice({
        tone: "ok",
        text:
          data.action === "sin_cambios"
            ? "No había nada para cambiar: quedó igual."
            : draft.id
              ? `«${name}» guardado. Sus disciplinas ya cuentan para asignar clases.`
              : `«${name}» agregado a la plantilla. Ya se le pueden asignar horarios y clases.`,
      });
      setDraft(null);
    } catch {
      setNotice({
        tone: "error",
        text: "No se pudo confirmar el guardado. Recargá antes de repetir; no se duplicó nada.",
      });
    } finally {
      setBusy(false);
    }
  }

  async function toggle(coach: AdminCoach) {
    if (busy) return;
    setBusy(true);
    setNotice(null);
    try {
      const { res, data } = await post({
        action: "set-active",
        id: coach.id,
        isActive: !coach.is_active,
        expectedIsActive: coach.is_active,
      });
      if (!res.ok || !data?.catalog) {
        setNotice({
          tone: "error",
          text: data?.message ?? "No se pudo cambiar el estado del entrenador.",
        });
        return;
      }
      setCatalog(data.catalog);
      const upcoming =
        typeof (data as { sessions_upcoming?: number }).sessions_upcoming === "number"
          ? (data as { sessions_upcoming: number }).sessions_upcoming
          : coach.sessions_upcoming;
      setNotice({
        tone: "ok",
        text: coach.is_active
          ? upcoming > 0
            ? `«${coach.full_name}» quedó dado de baja: no se le pueden asignar horarios nuevos. Sus ${plural(upcoming, "clase ya programada sigue", "clases ya programadas siguen")} con él; si hay que cambiarlas, se hace clase por clase o con un sustituto.`
            : `«${coach.full_name}» quedó dado de baja. No se borró nada: se puede volver a activar.`
          : `«${coach.full_name}» quedó activo otra vez.`,
      });
    } catch {
      setNotice({
        tone: "error",
        text: "No se pudo cambiar el estado. Revisá la conexión antes de repetir.",
      });
    } finally {
      setBusy(false);
    }
  }

  const active = catalog.coaches.filter((coach) => coach.is_active);
  const unassigned = catalog.coaches.reduce(
    (sum, coach) => sum + coach.sessions_unassigned,
    0,
  );

  return (
    <div className="space-y-6">
      <section className="rounded-2xl border border-brand/30 bg-brand/[0.06] p-4">
        <h2 className="text-base font-bold text-ink">Qué se puede hacer acá</h2>
        <p className="mt-1 text-[0.875rem] text-mist">
          Armar la plantilla: quién entrena en el gimnasio y{" "}
          <strong className="text-ink">qué disciplinas dicta cada uno</strong>. Con
          eso, al cargar un horario en
          <strong className="text-ink"> Horarios y clases</strong> ya podés elegir al
          entrenador, y cuando un horario no lo tiene puesto, el calendario le asigna
          el primero de la plantilla que dicte esa disciplina.
        </p>
        <p className="mt-2 text-[0.8125rem] text-fog">
          No se borra ningún entrenador: se da de baja. Sus clases ya programadas
          quedan como están y se pueden reasignar con un sustituto.
        </p>
        {unassigned > 0 ? (
          <p className="mt-2 rounded-xl border border-line bg-paper px-3 py-2 text-[0.8125rem] text-mist">
            Hay {plural(unassigned, "clase por delante", "clases por delante")} de
            disciplinas que sí tienen entrenador en la plantilla pero todavía sin
            entrenador asignado. Se resuelven desde{" "}
            <strong className="text-ink">Horarios y clases</strong>, con el botón
            «Pasar a las clases ya creadas» de cada horario.
          </p>
        ) : null}
      </section>

      {notice ? (
        <p
          role={notice.tone === "error" ? "alert" : "status"}
          className={`rounded-xl border px-4 py-3 text-[0.875rem] ${
            notice.tone === "error"
              ? "border-red-400/40 bg-red-400/10 text-red-200"
              : "border-brand/30 bg-brand/[0.06] text-mist"
          }`}
        >
          {notice.text}
        </p>
      ) : null}

      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-[0.875rem] text-mist">
          {catalog.coaches.length === 0
            ? "Todavía no hay entrenadores."
            : `${plural(catalog.coaches.length, "entrenador", "entrenadores")}, ${active.length} ${active.length === 1 ? "activo" : "activos"}.`}
        </p>
        <Button
          type="button"
          disabled={busy || !!draft}
          onClick={() => {
            setDraft(emptyDraft());
            setNotice(null);
          }}
        >
          Agregar entrenador
        </Button>
      </div>

      {draft ? (
        <section className="space-y-4 rounded-2xl border border-brand/40 bg-card p-4">
          <h2 className="text-base font-bold text-ink">
            {draft.id ? "Editar entrenador" : "Nuevo entrenador"}
          </h2>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="coach-name">Nombre completo</label>
              <input
                id="coach-name"
                className={`${input} mt-1`}
                value={draft.fullName}
                maxLength={80}
                disabled={busy}
                onChange={(event) => set("fullName", event.target.value)}
              />
            </div>
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="coach-specialty">Especialidad (como se muestra)</label>
              <input
                id="coach-specialty"
                className={`${input} mt-1`}
                value={draft.specialty}
                maxLength={80}
                placeholder="Ejemplo: Boxeo y acondicionamiento"
                disabled={busy}
                onChange={(event) => set("specialty", event.target.value)}
              />
              <span className="mt-1 block text-[0.75rem] text-fog">
                Es el texto que se lee en la web. No cambia a quién se le asignan
                las clases.
              </span>
            </div>
          </div>
          <fieldset className="text-[0.8125rem] text-mist">
            <legend className="font-semibold text-ink">
              Disciplinas que dicta
            </legend>
            <p className="mt-1 text-[0.75rem] text-fog">
              Marcá las disciplinas que este entrenador puede dar. Se eligen de la
              lista, no se escriben: así no quedan nombres que no existan.
            </p>
            <div className="mt-2 flex flex-wrap gap-2">
              {catalog.classes.map((item) => {
                const checked = draft.specialties.includes(item.slug);
                return (
                  <label
                    key={item.id}
                    className={`inline-flex cursor-pointer items-center gap-2 rounded-full border px-3 py-1.5 text-[0.8125rem] ${
                      checked
                        ? "border-brand bg-brand/10 text-ink"
                        : "border-line bg-paper text-mist"
                    }`}
                  >
                    <input
                      type="checkbox"
                      className="size-4 accent-[var(--color-brand,#c8f73b)]"
                      checked={checked}
                      disabled={busy}
                      onChange={() => toggleSpecialty(item.slug)}
                    />
                    {item.name_es}
                    {item.is_active ? "" : " (apagada)"}
                  </label>
                );
              })}
            </div>
            {draft.specialties.length === 0 ? (
              <p className="mt-2 text-[0.75rem] text-fog">
                Sin disciplinas, el calendario no le va a asignar clases solo: igual
                se le puede poner a mano en un horario.
              </p>
            ) : null}
          </fieldset>
          <div className="flex flex-wrap gap-2">
            <Button type="button" disabled={busy} onClick={() => void save()}>
              Guardar entrenador
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={busy}
              onClick={() => setDraft(null)}
            >
              Cancelar
            </Button>
          </div>
        </section>
      ) : null}

      <ul className="space-y-2">
        {catalog.coaches.map((coach) => (
          <li
            key={coach.id}
            className={`rounded-xl border px-3 py-2 ${
              coach.is_active ? "border-line bg-paper" : "border-dashed border-line bg-card/60"
            }`}
          >
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div className="min-w-0">
                <p className="flex flex-wrap items-center gap-2 font-semibold text-ink">
                  {coach.full_name}
                  {coach.is_active ? null : (
                    <span className="rounded-full border border-line px-2 py-0.5 text-[0.6875rem] font-normal text-fog">
                      dado de baja
                    </span>
                  )}
                </p>
                {coach.specialty ? (
                  <p className="text-[0.8125rem] text-fog">{coach.specialty}</p>
                ) : null}
                <p className="mt-1 text-[0.8125rem] text-mist">
                  {coach.specialties.length === 0
                    ? "Sin disciplinas marcadas"
                    : `Dicta: ${(coach.specialty_labels.length
                        ? coach.specialty_labels
                        : coach.specialties
                      ).join(", ")}`}
                </p>
                <p className="text-[0.8125rem] text-fog">
                  {coach.slots_active === 0
                    ? "sin horarios fijos"
                    : `${plural(coach.slots_active, "horario fijo", "horarios fijos")}`}
                  {" · "}
                  {coach.sessions_upcoming === 0
                    ? "sin clases por delante"
                    : `${plural(coach.sessions_upcoming, "clase por delante", "clases por delante")}`}
                  {coach.sessions_unassigned > 0
                    ? ` · ${plural(coach.sessions_unassigned, "clase sin asignar", "clases sin asignar")} en sus horarios`
                    : ""}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={busy || !!draft}
                  onClick={() => {
                    setDraft(fromCoach(coach));
                    setNotice(null);
                  }}
                >
                  Editar
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={busy}
                  onClick={() => void toggle(coach)}
                >
                  {coach.is_active ? "Dar de baja" : "Activar"}
                </Button>
              </div>
            </div>
          </li>
        ))}
      </ul>

      {catalog.audit.length ? (
        <section className="space-y-2 rounded-2xl border border-line bg-card p-4">
          <h2 className="text-base font-bold text-ink">Últimos cambios</h2>
          <p className="text-[0.8125rem] text-fog">
            Queda registrado quién tocó cada entrenador y qué campos cambió.
          </p>
          <ul className="space-y-1">
            {catalog.audit.slice(0, 10).map((entry) => (
              <li key={entry.id} className="text-[0.8125rem] text-mist">
                {formatMoment(entry.changed_at)} · {entry.changed_by_name || "Administración"}{" "}
                {ACTION_LABEL[entry.action]} ({entry.coach_name ?? entry.coach_id})
                {entry.changed_fields.length
                  ? `: ${entry.changed_fields
                      .map((field) => FIELD_LABEL[field] ?? field)
                      .join(", ")}`
                  : ""}
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </div>
  );
}
