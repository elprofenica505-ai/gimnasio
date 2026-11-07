"use client";

import { useMemo, useState } from "react";
import { Button } from "@/components/ui/button";

/** Regla tal como la devuelve `admin_category_rules()`. */
export type CategoryRule = {
  category: "strong_gym" | "familia" | "amigo" | "comun";
  sort_order: number;
  is_active: boolean;
  is_fallback: boolean;
  requires_validity: boolean;
  forbids_validity: boolean;
  validity_days_min: number;
  requires_purchase_window_days: number | null;
  visits_min: number;
  visits_window_days: number;
  updated_at: string;
};

type Catalog = {
  rules: CategoryRule[];
  counts: Record<string, number>;
  pending: number;
  history: { changed_at: string; rules: unknown }[];
};

const LABELS: Record<CategoryRule["category"], string> = {
  strong_gym: "Power Box",
  familia: "Familia",
  amigo: "Amigo",
  comun: "Común",
};

const HINTS: Record<CategoryRule["category"], string> = {
  strong_gym: "El cliente que más gasta: vigencia larga y compra de productos.",
  familia: "Tiene alguna vigencia activa, de gimnasio o de una disciplina.",
  amigo: "No tiene vigencia, pero viene seguido.",
  comun: "No cumple nada de lo anterior. Es también la categoría de reserva.",
};

const numberOrNull = (value: string) => {
  const raw = value.trim();
  if (raw === "") return null;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? Math.trunc(parsed) : null;
};

/**
 * Reglas de la categoría automática (CLI-02). Los números y el orden se
 * guardan en la base: cambiarlos no requiere código ni despliegue.
 */
export function CategoryRules({ initial }: { initial: Catalog }) {
  const [catalog, setCatalog] = useState<Catalog>(initial);
  const [draft, setDraft] = useState<CategoryRule[]>(initial.rules);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ tone: "ok" | "error"; text: string } | null>(
    null,
  );

  const dirty = useMemo(
    () => JSON.stringify(draft) !== JSON.stringify(catalog.rules),
    [draft, catalog.rules],
  );

  const update = (category: CategoryRule["category"], patch: Partial<CategoryRule>) =>
    setDraft((current) =>
      current.map((rule) => (rule.category === category ? { ...rule, ...patch } : rule)),
    );

  async function send(body: unknown, okText: string) {
    setBusy(true);
    setNotice(null);
    try {
      const res = await fetch("/api/admin/categories", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = (await res.json().catch(() => null)) as
        | (Catalog & { message?: string })
        | { message?: string }
        | null;
      if (!res.ok) {
        setNotice({
          tone: "error",
          text: data?.message ?? "No se pudo guardar. Recargá antes de repetir.",
        });
        return false;
      }
      setNotice({ tone: "ok", text: okText });
      await reload();
      return true;
    } catch {
      setNotice({
        tone: "error",
        text: "No se pudo guardar. Revisá la conexión y recargá antes de repetir.",
      });
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function reload() {
    const res = await fetch("/api/admin/categories", { cache: "no-store" });
    if (!res.ok) return;
    const data = (await res.json()) as Catalog;
    setCatalog(data);
    setDraft(data.rules);
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center gap-2 rounded-xl border border-line bg-card p-4">
        {(["strong_gym", "familia", "amigo", "comun"] as const).map((key) => (
          <span
            key={key}
            className="rounded-full border border-line bg-paper/60 px-3 py-1 text-[0.8125rem] text-ink"
          >
            {LABELS[key]}:{" "}
            <strong className="font-semibold">{catalog.counts[key] ?? 0}</strong>
          </span>
        ))}
        {catalog.pending > 0 ? (
          <span className="rounded-full border border-brand/50 bg-brand/10 px-3 py-1 text-[0.8125rem] text-brand-300">
            Sin calcular todavía: <strong>{catalog.pending}</strong>
          </span>
        ) : null}
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={busy}
          onClick={() =>
            send(
              { action: "refresh" },
              "Categorías recalculadas con la vigencia de hoy.",
            )
          }
        >
          Recalcular todos
        </Button>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        {draft.map((rule) => (
          <section
            key={rule.category}
            className="space-y-3 rounded-2xl border border-line bg-card p-4"
          >
            <header className="flex items-start justify-between gap-3">
              <div>
                <h3 className="text-lg font-bold text-ink">{LABELS[rule.category]}</h3>
                <p className="text-[0.8125rem] text-fog">{HINTS[rule.category]}</p>
              </div>
              <label className="flex shrink-0 items-center gap-2 text-[0.8125rem] text-mist">
                <input
                  type="checkbox"
                  className="size-4 accent-brand"
                  checked={rule.is_active}
                  disabled={busy || rule.is_fallback}
                  onChange={(event) =>
                    update(rule.category, { is_active: event.target.checked })
                  }
                />
                Activa
              </label>
            </header>

            <div className="flex flex-wrap items-end gap-3">
              <label className="text-[0.8125rem] text-mist">
                <span className="mb-1 block">Orden</span>
                <input
                  type="number"
                  min={1}
                  max={999}
                  value={rule.sort_order}
                  disabled={busy}
                  onChange={(event) =>
                    update(rule.category, {
                      sort_order: Number(event.target.value) || 1,
                    })
                  }
                  className="w-20 rounded-lg border border-line bg-paper px-2 py-1 text-ink"
                />
              </label>
              <p className="pb-1 text-[0.75rem] text-fog">
                Menor número gana si cumple dos reglas.
              </p>
            </div>

            {rule.is_fallback ? (
              <p className="rounded-lg border border-line bg-paper/60 px-3 py-2 text-[0.8125rem] text-mist">
                Es la categoría de reserva: se aplica cuando ninguna otra cumple.
              </p>
            ) : (
              <>
                <label className="flex items-start gap-2 text-[0.875rem] text-ink">
                  <input
                    type="checkbox"
                    className="mt-0.5 size-4 shrink-0 accent-brand"
                    checked={rule.requires_validity}
                    disabled={busy}
                    onChange={(event) =>
                      update(rule.category, {
                        requires_validity: event.target.checked,
                        forbids_validity: event.target.checked
                          ? false
                          : rule.forbids_validity,
                      })
                    }
                  />
                  <span>Exige vigencia activa</span>
                </label>
                {rule.requires_validity ? (
                  <label className="ml-6 block text-[0.8125rem] text-mist">
                    Días comprados como mínimo
                    <input
                      type="number"
                      min={0}
                      max={3660}
                      value={rule.validity_days_min}
                      disabled={busy}
                      onChange={(event) =>
                        update(rule.category, {
                          validity_days_min: numberOrNull(event.target.value) ?? 0,
                        })
                      }
                      className="ml-2 w-20 rounded-lg border border-line bg-paper px-2 py-1 text-ink"
                    />
                  </label>
                ) : null}

                <label className="flex items-start gap-2 text-[0.875rem] text-ink">
                  <input
                    type="checkbox"
                    className="mt-0.5 size-4 shrink-0 accent-brand"
                    checked={rule.requires_purchase_window_days !== null}
                    disabled={busy}
                    onChange={(event) =>
                      update(rule.category, {
                        requires_purchase_window_days: event.target.checked ? 90 : null,
                      })
                    }
                  />
                  <span>Exige compra de producto</span>
                </label>
                {rule.requires_purchase_window_days !== null ? (
                  <label className="ml-6 block text-[0.8125rem] text-mist">
                    En los últimos
                    <input
                      type="number"
                      min={1}
                      max={3650}
                      value={rule.requires_purchase_window_days}
                      disabled={busy}
                      onChange={(event) =>
                        update(rule.category, {
                          requires_purchase_window_days:
                            numberOrNull(event.target.value) ?? 1,
                        })
                      }
                      className="mx-2 w-20 rounded-lg border border-line bg-paper px-2 py-1 text-ink"
                    />
                    días
                  </label>
                ) : null}

                <label className="flex items-start gap-2 text-[0.875rem] text-ink">
                  <input
                    type="checkbox"
                    className="mt-0.5 size-4 shrink-0 accent-brand"
                    checked={rule.forbids_validity}
                    disabled={busy || rule.requires_validity}
                    onChange={(event) =>
                      update(rule.category, {
                        forbids_validity: event.target.checked,
                        requires_validity: event.target.checked
                          ? false
                          : rule.requires_validity,
                      })
                    }
                  />
                  <span>Solo si NO tiene vigencia</span>
                </label>

                <div className="flex flex-wrap items-end gap-2 text-[0.8125rem] text-mist">
                  <label>
                    Visitas mínimas
                    <input
                      type="number"
                      min={0}
                      max={1000}
                      value={rule.visits_min}
                      disabled={busy}
                      onChange={(event) =>
                        update(rule.category, {
                          visits_min: numberOrNull(event.target.value) ?? 0,
                        })
                      }
                      className="ml-2 w-20 rounded-lg border border-line bg-paper px-2 py-1 text-ink"
                    />
                  </label>
                  <label>
                    en los últimos
                    <input
                      type="number"
                      min={1}
                      max={365}
                      value={rule.visits_window_days}
                      disabled={busy}
                      onChange={(event) =>
                        update(rule.category, {
                          visits_window_days: numberOrNull(event.target.value) ?? 30,
                        })
                      }
                      className="mx-2 w-20 rounded-lg border border-line bg-paper px-2 py-1 text-ink"
                    />
                    días
                  </label>
                </div>
              </>
            )}
          </section>
        ))}
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <Button
          type="button"
          disabled={busy || !dirty}
          onClick={() =>
            send(
              {
                action: "save",
                rules: draft.map((rule) => ({
                  category: rule.category,
                  sort_order: rule.sort_order,
                  is_active: rule.is_active,
                  is_fallback: rule.is_fallback,
                  requires_validity: rule.requires_validity,
                  forbids_validity: rule.forbids_validity,
                  validity_days_min: rule.validity_days_min,
                  requires_purchase_window_days: rule.requires_purchase_window_days,
                  visits_min: rule.visits_min,
                  visits_window_days: rule.visits_window_days,
                })),
              },
              "Reglas guardadas. Las fichas se recalculan solas al abrirlas; para actualizar todo el listado de una vez usá «Recalcular todos».",
            )
          }
        >
          Guardar reglas
        </Button>
        {dirty ? (
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onClick={() => setDraft(catalog.rules)}
          >
            Descartar cambios
          </Button>
        ) : null}
        {notice ? (
          <p
            role={notice.tone === "error" ? "alert" : "status"}
            className={`text-[0.875rem] ${notice.tone === "error" ? "text-red-300" : "text-brand-300"}`}
          >
            {notice.text}
          </p>
        ) : null}
      </div>
    </div>
  );
}
