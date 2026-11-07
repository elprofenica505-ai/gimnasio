"use client";

import { useMemo, useState } from "react";

export interface RoleProfile {
  id: string;
  fullName: string;
  role: string;
}

const ROLE_LABELS: Record<string, string> = {
  member: "Cliente",
  cashier: "Cajero",
  trainer: "Entrenador",
  admin: "Administrador",
  staff: "Personal anterior (sin acceso)",
  superadmin: "Súper administrador (dueño del aplicativo)",
};

const SELECTABLE = ["member", "cashier", "trainer", "admin"] as const;

/**
 * Asignación de roles. Cada cambio pasa por POST /api/admin/roles y la base
 * valida MFA, impide cambiar el propio rol y guarda bitácora.
 */
export function RolesManager({
  profiles,
  currentUserId,
}: {
  profiles: RoleProfile[];
  currentUserId: string;
}) {
  const [rows, setRows] = useState(profiles);
  const [query, setQuery] = useState("");
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ tone: "ok" | "error"; text: string } | null>(null);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? rows.filter((r) => r.fullName.toLowerCase().includes(q)) : rows;
  }, [rows, query]);

  async function save(profile: RoleProfile) {
    const role = drafts[profile.id] ?? profile.role;
    if (role === profile.role) return;
    setBusy(profile.id);
    setNotice(null);
    try {
      const response = await fetch("/api/admin/roles", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ userId: profile.id, role }),
      });
      const body = (await response.json().catch(() => null)) as { message?: string } | null;
      if (!response.ok) {
        setNotice({ tone: "error", text: body?.message ?? "No se pudo cambiar el rol." });
        return;
      }
      setRows((prev) => prev.map((r) => (r.id === profile.id ? { ...r, role } : r)));
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[profile.id];
        return next;
      });
      setNotice({
        tone: "ok",
        text: `${profile.fullName || "La cuenta"} ahora tiene rol ${ROLE_LABELS[role] ?? role}.`,
      });
    } catch {
      setNotice({ tone: "error", text: "Sin conexión. No se cambió ningún rol." });
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <label className="flex w-full max-w-sm flex-col gap-1.5 text-[0.75rem] font-semibold text-fog">
          Buscar por nombre
          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="h-10 rounded-xl border border-line bg-card px-3 text-[0.875rem] text-ink"
            placeholder="Nombre de la persona"
          />
        </label>
        <p className="text-[0.75rem] text-fog">
          Caja cobra y registra gastos. Entrenador ve sólo nombre y asistencia. Cliente no tiene acceso al panel.
        </p>
      </div>

      {notice ? (
        <p
          role={notice.tone === "error" ? "alert" : "status"}
          className={
            notice.tone === "error"
              ? "rounded-xl border border-alert/40 bg-alert/10 px-4 py-3 text-[0.8125rem] text-alert"
              : "rounded-xl border border-brand/30 bg-brand/[0.06] px-4 py-3 text-[0.8125rem] text-mist"
          }
        >
          {notice.text}
        </p>
      ) : null}

      <div className="overflow-x-auto rounded-2xl border border-line">
        <table className="w-full min-w-[32rem] text-left text-[0.875rem]">
          <thead className="bg-cloud text-[0.6875rem] font-semibold tracking-[0.12em] text-fog uppercase">
            <tr>
              <th scope="col" className="px-4 py-3">Nombre</th>
              <th scope="col" className="px-4 py-3">Rol actual</th>
              <th scope="col" className="px-4 py-3">Nuevo rol</th>
              <th scope="col" className="px-4 py-3"><span className="sr-only">Acción</span></th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((profile) => {
              const isSelf = profile.id === currentUserId;
              // La cuenta del súper administrador (dueño del aplicativo) es
              // intocable desde el panel: lo garantiza la base (00100).
              const protegido = profile.role === "superadmin";
              const draft = drafts[profile.id] ?? profile.role;
              const options = SELECTABLE.includes(profile.role as (typeof SELECTABLE)[number])
                ? SELECTABLE
                : [...SELECTABLE, profile.role as (typeof SELECTABLE)[number]];
              return (
                <tr key={profile.id} className="border-t border-line">
                  <td className="px-4 py-3 text-ink">
                    {profile.fullName || "Sin nombre"}
                    {isSelf ? <span className="ml-2 text-[0.6875rem] text-fog">(tú)</span> : null}
                    {protegido ? (
                      <span className="ml-2 rounded-full border border-ok/50 bg-ok/10 px-2 py-0.5 text-[0.6875rem] font-semibold text-ok">
                        protegida
                      </span>
                    ) : null}
                  </td>
                  <td className="px-4 py-3 text-mist">{ROLE_LABELS[profile.role] ?? profile.role}</td>
                  <td className="px-4 py-3">
                    <label className="sr-only" htmlFor={`role-${profile.id}`}>
                      Nuevo rol de {profile.fullName || "la cuenta"}
                    </label>
                    <select
                      id={`role-${profile.id}`}
                      value={draft}
                      disabled={isSelf || protegido || busy === profile.id}
                      onChange={(e) => setDrafts((prev) => ({ ...prev, [profile.id]: e.target.value }))}
                      className="h-9 rounded-lg border border-line bg-card px-2 text-[0.8125rem] text-ink disabled:opacity-50"
                    >
                      {options.map((r) => (
                        <option key={r} value={r}>
                          {ROLE_LABELS[r] ?? r}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <button
                      type="button"
                      onClick={() => save(profile)}
                      disabled={isSelf || protegido || busy === profile.id || draft === profile.role}
                      className="h-9 rounded-full bg-brand px-4 text-[0.8125rem] font-semibold text-onbrand disabled:opacity-40"
                    >
                      {busy === profile.id ? "Guardando…" : "Guardar"}
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {filtered.length === 0 ? (
          <p className="px-4 py-8 text-center text-sm text-fog">No hay cuentas con ese nombre.</p>
        ) : null}
      </div>
    </div>
  );
}
