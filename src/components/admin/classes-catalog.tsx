"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";

/** Fila de `public.classes` tal como la devuelve `admin_classes_catalog()`. */
export type AdminClass = {
  id: string;
  slug: string;
  name_es: string;
  name_en: string;
  description_es: string;
  description_en: string;
  intensity: "low" | "medium" | "high";
  duration_min: number;
  capacity: number;
  color: string;
  sort_order: number;
  is_active: boolean;
  slots_active: number;
  sessions_upcoming: number;
  plans: number;
};

export type ClassAudit = {
  id: number;
  class_id: string;
  class_name: string | null;
  action: "alta" | "edicion" | "baja" | "reactivacion";
  changed_fields: string[];
  changed_by_name: string;
  changed_at: string;
};

export type ClassesCatalog = {
  classes: AdminClass[];
  intensities: string[];
  audit: ClassAudit[];
};

const INTENSITY_LABEL = {
  low: "Baja",
  medium: "Media",
  high: "Alta",
} as const;

const FIELD_LABEL: Record<string, string> = {
  slug: "identificador",
  name_es: "nombre en español",
  name_en: "nombre en inglés",
  description_es: "descripción en español",
  description_en: "descripción en inglés",
  intensity: "intensidad",
  duration_min: "duración",
  capacity: "cupo",
  color: "color",
  sort_order: "orden",
};

const ACTION_LABEL: Record<ClassAudit["action"], string> = {
  alta: "la creó",
  edicion: "la editó",
  baja: "la suspendió",
  reactivacion: "la volvió a activar",
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

type Draft = {
  id: string | null;
  slug: string;
  nameEs: string;
  nameEn: string;
  descriptionEs: string;
  descriptionEn: string;
  intensity: AdminClass["intensity"];
  durationMin: string;
  capacity: string;
  color: string;
  sortOrder: string;
};

const emptyDraft = (classes: AdminClass[]): Draft => ({
  id: null,
  slug: "",
  nameEs: "",
  nameEn: "",
  descriptionEs: "",
  descriptionEn: "",
  intensity: "medium",
  durationMin: "60",
  capacity: "20",
  color: "#c8f73b",
  sortOrder: String(
    classes.reduce((max, item) => Math.max(max, item.sort_order), 0) + 10,
  ),
});

const fromClass = (item: AdminClass): Draft => ({
  id: item.id,
  slug: item.slug,
  nameEs: item.name_es,
  nameEn: item.name_en,
  descriptionEs: item.description_es,
  descriptionEn: item.description_en,
  intensity: item.intensity,
  durationMin: String(item.duration_min),
  capacity: String(item.capacity),
  color: item.color,
  sortOrder: String(item.sort_order),
});

/**
 * Disciplinas del gimnasio (OP-05). Crear acá una disciplina la deja disponible
 * para cargarle horarios y para venderle un plan. No borra nada: apagar una
 * disciplina es el mismo interruptor que usa Operación.
 */
export function ClassesCatalog({ initial }: { initial: ClassesCatalog }) {
  const [catalog, setCatalog] = useState<ClassesCatalog>(initial);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ tone: "ok" | "error"; text: string } | null>(
    null,
  );

  const set = <K extends keyof Draft>(key: K, value: Draft[K]) =>
    setDraft((current) => (current ? { ...current, [key]: value } : current));

  async function post(payload: unknown) {
    const res = await fetch("/api/admin/classes/catalog", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = (await res.json().catch(() => null)) as
      | { catalog?: ClassesCatalog | null; action?: string; message?: string }
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
        slug: draft.slug.trim().toLowerCase(),
        nameEs: draft.nameEs.trim(),
        nameEn: draft.nameEn.trim(),
        descriptionEs: draft.descriptionEs.trim(),
        descriptionEn: draft.descriptionEn.trim(),
        intensity: draft.intensity,
        durationMin: Number(draft.durationMin) || 0,
        capacity: Number(draft.capacity) || 0,
        color: draft.color.trim(),
        sortOrder: Number(draft.sortOrder) || 0,
      });
      if (!res.ok || !data?.catalog) {
        setNotice({
          tone: "error",
          text:
            data?.message ??
            "No se pudo guardar la disciplina. Recargá antes de repetir.",
        });
        return;
      }
      setCatalog(data.catalog);
      setNotice({
        tone: "ok",
        text:
          data.action === "sin_cambios"
            ? "No había nada para cambiar: quedó igual."
            : `«${draft.nameEs.trim()}» guardada. Ya podés cargarle horarios y venderle un plan.`,
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

  async function toggle(item: AdminClass) {
    if (busy) return;
    setBusy(true);
    setNotice(null);
    try {
      const { res, data } = await post({
        action: "set-active",
        id: item.id,
        isActive: !item.is_active,
        expectedIsActive: item.is_active,
      });
      if (!res.ok || !data?.catalog) {
        setNotice({
          tone: "error",
          text: data?.message ?? "No se pudo cambiar el estado de la disciplina.",
        });
        return;
      }
      setCatalog(data.catalog);
      setNotice({
        tone: "ok",
        text: item.is_active
          ? `«${item.name_es}» quedó apagada. No se ofrece en la web ni acepta reservas nuevas; lo que ya estaba reservado se conserva.`
          : `«${item.name_es}» quedó activa otra vez.`,
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

  return (
    <div className="space-y-6">
      <section className="rounded-2xl border border-brand/30 bg-brand/[0.06] p-4">
        <h2 className="text-base font-bold text-ink">Qué se puede hacer acá</h2>
        <p className="mt-1 text-[0.875rem] text-mist">
          Crear una disciplina nueva, como Zumba o Spinning, y corregir el nombre,
          la descripción, la duración, el cupo, la intensidad y el color de las que
          ya existen. Al guardarla queda disponible para cargarle horarios en
          <strong className="text-ink"> Horarios y clases</strong> y para venderle
          un plan en<strong className="text-ink"> Planes y modalidades</strong>.
        </p>
        <p className="mt-2 text-[0.8125rem] text-fog">
          No se borra ninguna disciplina: se apaga. Apagada deja de ofrecerse y no
          acepta reservas nuevas, pero conserva sus clases y sus reservas.
        </p>
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
          {catalog.classes.length === 0
            ? "Todavía no hay disciplinas."
            : `${catalog.classes.length} ${catalog.classes.length === 1 ? "disciplina" : "disciplinas"}, ${catalog.classes.filter((c) => c.is_active).length} ${catalog.classes.filter((c) => c.is_active).length === 1 ? "activa" : "activas"}.`}
        </p>
        <Button
          type="button"
          disabled={busy || !!draft}
          onClick={() => {
            setDraft(emptyDraft(catalog.classes));
            setNotice(null);
          }}
        >
          Agregar disciplina
        </Button>
      </div>

      {draft ? (
        <section className="space-y-4 rounded-2xl border border-brand/40 bg-card p-4">
          <h2 className="text-base font-bold text-ink">
            {draft.id ? "Editar disciplina" : "Nueva disciplina"}
          </h2>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="class-name-es">Nombre en español</label>
              <input
                id="class-name-es"
                className={`${input} mt-1`}
                value={draft.nameEs}
                maxLength={80}
                disabled={busy}
                onChange={(event) => set("nameEs", event.target.value)}
              />
            </div>
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="class-name-en">Nombre en inglés</label>
              <input
                id="class-name-en"
                className={`${input} mt-1`}
                value={draft.nameEn}
                maxLength={80}
                disabled={busy}
                onChange={(event) => set("nameEn", event.target.value)}
              />
            </div>
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="class-slug">Identificador</label>
              <input
                id="class-slug"
                className={`${input} mt-1`}
                value={draft.slug}
                maxLength={48}
                placeholder="zumba-tarde"
                disabled={busy || !!draft.id}
                onChange={(event) => set("slug", event.target.value.toLowerCase())}
                aria-describedby="class-slug-help"
              />
              <span id="class-slug-help" className="mt-1 block text-[0.75rem] text-fog">
                {draft.id
                  ? "El identificador no se cambia después de crear la disciplina: es lo que une sus clases y sus planes."
                  : "Solo minúsculas, números y guiones. Después no se puede cambiar."}
              </span>
            </div>
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="class-intensity">Intensidad</label>
              <select
                id="class-intensity"
                className={`${input} mt-1`}
                value={draft.intensity}
                disabled={busy}
                onChange={(event) =>
                  set("intensity", event.target.value as AdminClass["intensity"])
                }
              >
                {Object.entries(INTENSITY_LABEL).map(([value, label]) => (
                  <option key={value} value={value}>
                    {label}
                  </option>
                ))}
              </select>
            </div>
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="class-duration">Cuánto dura la clase (minutos)</label>
              <input
                id="class-duration"
                className={`${input} mt-1`}
                type="number"
                min={10}
                max={180}
                value={draft.durationMin}
                disabled={busy}
                onChange={(event) => set("durationMin", event.target.value)}
              />
            </div>
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="class-capacity">Cuántos pueden entrar</label>
              <input
                id="class-capacity"
                className={`${input} mt-1`}
                type="number"
                min={1}
                max={200}
                value={draft.capacity}
                disabled={busy}
                onChange={(event) => set("capacity", event.target.value)}
              />
            </div>
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="class-color">Color</label>
              <input
                id="class-color"
                className={`${input} mt-1 h-11`}
                type="color"
                value={draft.color}
                disabled={busy}
                onChange={(event) => set("color", event.target.value)}
              />
            </div>
            <div className="text-[0.8125rem] text-mist">
              <label htmlFor="class-order">Orden en las listas</label>
              <input
                id="class-order"
                className={`${input} mt-1`}
                type="number"
                min={0}
                max={9999}
                value={draft.sortOrder}
                disabled={busy}
                onChange={(event) => set("sortOrder", event.target.value)}
              />
            </div>
            <div className="text-[0.8125rem] text-mist sm:col-span-2">
              <label htmlFor="class-description-es">Descripción en español</label>
              <textarea
                id="class-description-es"
                className={`${input} mt-1`}
                rows={2}
                maxLength={400}
                value={draft.descriptionEs}
                disabled={busy}
                onChange={(event) => set("descriptionEs", event.target.value)}
              />
            </div>
            <div className="text-[0.8125rem] text-mist sm:col-span-2">
              <label htmlFor="class-description-en">Descripción en inglés</label>
              <textarea
                id="class-description-en"
                className={`${input} mt-1`}
                rows={2}
                maxLength={400}
                value={draft.descriptionEn}
                disabled={busy}
                onChange={(event) => set("descriptionEn", event.target.value)}
              />
            </div>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button type="button" disabled={busy} onClick={() => void save()}>
              Guardar disciplina
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
        {catalog.classes.map((item) => (
          <li
            key={item.id}
            className={`flex flex-wrap items-center justify-between gap-2 rounded-xl border px-3 py-2 ${
              item.is_active ? "border-line bg-paper" : "border-dashed border-line bg-card/60"
            }`}
          >
            <div className="min-w-0">
              <p className="flex flex-wrap items-center gap-2 font-semibold text-ink">
                <span
                  aria-hidden="true"
                  className="inline-block size-3 shrink-0 rounded-full"
                  style={{ backgroundColor: item.color }}
                />
                {item.name_es}
                {item.is_active ? null : (
                  <span className="rounded-full border border-line px-2 py-0.5 text-[0.6875rem] font-normal text-fog">
                    apagada
                  </span>
                )}
              </p>
              <p className="text-[0.8125rem] text-fog">
                {item.duration_min} min · {item.capacity}{" "}
                {item.capacity === 1 ? "lugar" : "lugares"} · intensidad{" "}
                {INTENSITY_LABEL[item.intensity].toLowerCase()} ·{" "}
                {item.slots_active === 0
                  ? "sin horarios fijos"
                  : `${item.slots_active} ${item.slots_active === 1 ? "horario fijo" : "horarios fijos"}`}
                {" · "}
                {item.sessions_upcoming === 0
                  ? "sin clases por delante"
                  : `${item.sessions_upcoming} ${item.sessions_upcoming === 1 ? "clase por delante" : "clases por delante"}`}
                {item.plans > 0
                  ? ` · ${item.plans} ${item.plans === 1 ? "plan la cobra" : "planes la cobran"}`
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
                  setDraft(fromClass(item));
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
                onClick={() => void toggle(item)}
              >
                {item.is_active ? "Apagar" : "Activar"}
              </Button>
            </div>
          </li>
        ))}
      </ul>

      {catalog.audit.length ? (
        <section className="space-y-2 rounded-2xl border border-line bg-card p-4">
          <h2 className="text-base font-bold text-ink">Últimos cambios</h2>
          <p className="text-[0.8125rem] text-fog">
            Queda registrado quién tocó cada disciplina y qué campos cambió.
          </p>
          <ul className="space-y-1">
            {catalog.audit.slice(0, 10).map((entry) => (
              <li key={entry.id} className="text-[0.8125rem] text-mist">
                {formatMoment(entry.changed_at)} ·{" "}
                {entry.changed_by_name || "Administración"}{" "}
                {ACTION_LABEL[entry.action]} ({entry.class_name ?? entry.class_id})
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
