"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ArrowLeft,
  BadgeCheck,
  CheckCircle2,
  Loader2,
  MessageCircle,
  Send,
  User,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";

export interface ArmHilo {
  id: string;
  channel: string;
  locale: string;
  status: "abierta" | "cerrada";
  user_id: string | null;
  full_name: string | null;
  phone: string | null;
  email: string | null;
  lead_id: string | null;
  client_id: string | null;
  staff_unread: number;
  visitor_unread: number;
  last_message: string | null;
  last_message_at: string | null;
  created_at: string;
}

export interface ArmCanal {
  channel: string;
  enabled: boolean;
  note: string;
  updated_at: string;
}

interface ArmMensaje {
  id: string;
  role: "visitante" | "asistente" | "staff";
  text: string;
  created_at: string;
}

const NOMBRE_CANAL: Record<string, string> = {
  interno: "Chat web",
  whatsapp: "WhatsApp",
  correo: "Correo",
};

function hora(value: string | null): string {
  if (!value) return "";
  return new Date(value).toLocaleString("es-NI", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * Bandeja unificada del asistente: hilos de la web y de socios, respuesta
 * directa del personal (RPC arm_responder_staff) y los interruptores de
 * canal. Sólo el canal «interno» se toca por ahora: WhatsApp y correo
 * quedan reservados para después de la firma.
 */
export function ArmInbox({ hilos, canales }: { hilos: ArmHilo[]; canales: ArmCanal[] }) {
  const [seleccion, setSeleccion] = useState<string | null>(null);
  const [mensajes, setMensajes] = useState<ArmMensaje[]>([]);
  const [cargando, setCargando] = useState(false);
  const [texto, setTexto] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [estadoCanales, setEstadoCanales] = useState<ArmCanal[]>(canales);
  const [aviso, setAviso] = useState<string | null>(null);

  const hilo = useMemo(() => hilos.find((h) => h.id === seleccion) ?? null, [hilos, seleccion]);

  const cargarMensajes = useCallback(async (id: string, marcarLeido: boolean) => {
    const db = getSupabaseBrowserClient();
    if (!db) return;
    setCargando(true);
    const { data } = await db
      .from("arm_messages")
      .select("id,role,text,created_at")
      .eq("thread_id", id)
      .order("created_at", { ascending: true })
      .limit(300);
    setMensajes((data as ArmMensaje[]) ?? []);
    setCargando(false);
    if (marcarLeido) {
      await db.from("arm_threads").update({ staff_unread: 0 }).eq("id", id);
    }
  }, []);

  useEffect(() => {
    if (!seleccion) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- el spinner va sincrónico a propósito; el resto tras el await
    void cargarMensajes(seleccion, true);
  }, [seleccion, cargarMensajes]);

  async function responder() {
    const limpio = texto.trim();
    if (!limpio || !hilo || enviando) return;
    const db = getSupabaseBrowserClient();
    if (!db) return;
    setEnviando(true);
    setAviso(null);
    const { error } = await db.rpc("arm_responder_staff", {
      p_thread_id: hilo.id,
      p_text: limpio,
    });
    if (error) {
      setAviso(`No se pudo responder (${String(error.message)}).`);
    } else {
      setTexto("");
      await cargarMensajes(hilo.id, false);
    }
    setEnviando(false);
  }

  async function cambiarEstado(status: "abierta" | "cerrada") {
    if (!hilo) return;
    const db = getSupabaseBrowserClient();
    if (!db) return;
    const { error } = await db
      .from("arm_threads")
      .update({ status, updated_at: new Date().toISOString() })
      .eq("id", hilo.id);
    if (error) {
      setAviso(`No se pudo cambiar el estado (${String(error.message)}).`);
    } else {
      setAviso(status === "cerrada" ? "Conversación cerrada." : "Conversación reabierta.");
    }
  }

  async function alternarCanal(canal: ArmCanal) {
    if (canal.channel !== "interno") return; // post-firma
    const db = getSupabaseBrowserClient();
    if (!db) return;
    const nuevo = !canal.enabled;
    setEstadoCanales((cs) => cs.map((c) => (c.channel === canal.channel ? { ...c, enabled: nuevo } : c)));
    const { error } = await db
      .from("arm_channels")
      .update({ enabled: nuevo, updated_at: new Date().toISOString() })
      .eq("channel", canal.channel);
    if (error) {
      setEstadoCanales((cs) => cs.map((c) => (c.channel === canal.channel ? { ...c, enabled: canal.enabled } : c)));
      setAviso(`No se pudo ${nuevo ? "encender" : "apagar"} el canal (${String(error.message)}).`);
    } else {
      setAviso(nuevo ? "Chat web ENCENDIDO: la burbuja ya está visible en la web." : "Chat web APAGADO: la burbuja desaparece de la web.");
    }
  }

  return (
    <div className="space-y-6">
      {/* Interruptores de canal */}
      <div className="rounded-2xl border border-line bg-card p-4">
        <p className="text-[0.8125rem] font-bold text-ink">Canales del asistente</p>
        <div className="mt-3 grid gap-2 sm:grid-cols-3">
          {estadoCanales.map((c) => {
            const fijo = c.channel !== "interno";
            return (
              <div
                key={c.channel}
                className={cn(
                  "rounded-xl border p-3",
                  c.enabled ? "border-brand/40 bg-brand/[0.06]" : "border-line bg-paper",
                )}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="text-[0.875rem] font-semibold text-ink">
                    {NOMBRE_CANAL[c.channel] ?? c.channel}
                  </span>
                  <button
                    type="button"
                    onClick={() => void alternarCanal(c)}
                    disabled={fijo}
                    aria-label={`${c.enabled ? "Apagar" : "Encender"} ${NOMBRE_CANAL[c.channel] ?? c.channel}`}
                    className={cn(
                      "relative h-6 w-11 shrink-0 rounded-full transition-colors",
                      c.enabled ? "bg-brand" : "bg-cloud",
                      fijo && "cursor-not-allowed opacity-50",
                    )}
                  >
                    <span
                      className={cn(
                        "absolute top-0.5 size-5 rounded-full bg-paper shadow transition-all",
                        c.enabled ? "left-[1.375rem]" : "left-0.5",
                      )}
                    />
                  </button>
                </div>
                <p className="mt-1.5 text-[0.6875rem] leading-relaxed text-fog">
                  {c.note || (fijo ? "Disponible tras la firma." : "")}
                </p>
              </div>
            );
          })}
        </div>
        {aviso ? <p className="mt-3 text-[0.75rem] text-mist" role="status">{aviso}</p> : null}
      </div>

      <div className="grid gap-4 lg:grid-cols-[minmax(280px,380px)_1fr]">
        {/* Lista de hilos */}
        <ul className={cn("space-y-2", hilo && "hidden lg:block")}>
          {hilos.length === 0 ? (
            <li className="rounded-2xl border border-line bg-card px-5 py-8 text-center text-[0.875rem] text-fog">
              Todavía no hay conversaciones. Cuando alguien escriba al asistente, aparece acá.
            </li>
          ) : null}
          {hilos.map((h) => (
            <li key={h.id}>
              <button
                type="button"
                onClick={() => setSeleccion(h.id)}
                className={cn(
                  "w-full rounded-2xl border px-4 py-3 text-left transition-colors",
                  seleccion === h.id ? "border-brand/50 bg-brand/[0.06]" : "border-line bg-card hover:border-brand/30",
                )}
              >
                <div className="flex items-center gap-2">
                  <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-cloud text-fog">
                    {h.user_id ? <BadgeCheck className="size-4" aria-hidden="true" /> : <User className="size-4" aria-hidden="true" />}
                  </span>
                  <span className="min-w-0 flex-1 truncate text-[0.875rem] font-semibold text-ink">
                    {h.full_name ?? (h.user_id ? "Socio" : "Visitante web")}
                  </span>
                  {h.staff_unread > 0 ? (
                    <span className="rounded-full bg-brand px-2 py-0.5 text-[0.6875rem] font-bold text-onbrand">
                      {h.staff_unread}
                    </span>
                  ) : null}
                </div>
                <p className="mt-1 truncate text-[0.75rem] text-fog">{h.last_message ?? "—"}</p>
                <p className="mt-0.5 text-[0.6875rem] text-fog">
                  {hora(h.last_message_at || h.created_at)}
                  {h.status === "cerrada" ? " · cerrada" : ""}
                </p>
              </button>
            </li>
          ))}
        </ul>

        {/* Conversación */}
        {hilo ? (
          <div className="flex h-[70vh] min-h-[440px] flex-col rounded-2xl border border-line bg-card">
            <header className="flex items-center gap-2 border-b border-line px-4 py-3">
              <button
                type="button"
                onClick={() => setSeleccion(null)}
                aria-label="Volver a la lista"
                className="rounded-full p-1.5 text-fog hover:bg-cloud hover:text-ink lg:hidden"
              >
                <ArrowLeft className="size-4" aria-hidden="true" />
              </button>
              <div className="min-w-0 flex-1">
                <p className="truncate text-[0.9375rem] font-bold text-ink">
                  {hilo.full_name ?? (hilo.user_id ? "Socio" : "Visitante web")}
                  {hilo.phone ? <span className="ml-2 font-normal text-fog">{hilo.phone}</span> : null}
                </p>
                <p className="text-[0.6875rem] text-fog">
                  {hilo.user_id ? "Socio (desde Mi cuenta)" : "Visitante de la web"} · {NOMBRE_CANAL[hilo.channel] ?? hilo.channel}
                  {hilo.lead_id ? " · lead creado" : ""}
                  {hilo.client_id ? " · cliente vinculado" : ""}
                </p>
              </div>
              <button
                type="button"
                onClick={() => void cambiarEstado(hilo.status === "abierta" ? "cerrada" : "abierta")}
                className="rounded-full border border-line px-3 py-1 text-[0.75rem] text-fog hover:border-brand/40 hover:text-ink"
              >
                {hilo.status === "abierta" ? "Cerrar" : "Reabrir"}
              </button>
            </header>

            <div className="flex-1 space-y-2.5 overflow-y-auto px-4 py-4">
              {cargando ? (
                <div className="flex items-center gap-2 text-[0.8125rem] text-fog">
                  <Loader2 className="size-4 animate-spin" aria-hidden="true" /> Cargando…
                </div>
              ) : mensajes.length === 0 ? (
                <p className="text-[0.875rem] text-fog">Sin mensajes en este hilo.</p>
              ) : (
                mensajes.map((m) => (
                  <div
                    key={m.id}
                    className={cn(
                      "max-w-[80%] whitespace-pre-line rounded-2xl px-3.5 py-2.5 text-[0.875rem] leading-relaxed",
                      m.role === "staff"
                        ? "ml-auto bg-brand text-onbrand"
                        : m.role === "asistente"
                          ? "mr-auto border border-line bg-paper text-fog"
                          : "mr-auto border border-line bg-paper text-ink",
                    )}
                  >
                    {m.text}
                  </div>
                ))
              )}
            </div>

            <form
              className="flex items-end gap-2 border-t border-line p-3"
              onSubmit={(e) => {
                e.preventDefault();
                void responder();
              }}
            >
              <textarea
                value={texto}
                onChange={(e) => setTexto(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && !e.shiftKey) {
                    e.preventDefault();
                    void responder();
                  }
                }}
                rows={1}
                maxLength={1000}
                placeholder="Respondé como el equipo…"
                aria-label="Respuesta del personal"
                className="max-h-28 flex-1 resize-none rounded-xl border border-line bg-paper px-3.5 py-2.5 text-[0.875rem] text-ink placeholder:text-fog focus:border-brand/50 focus:outline-none"
              />
              <button
                type="submit"
                disabled={enviando || texto.trim().length === 0}
                aria-label="Enviar respuesta"
                className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-brand text-onbrand disabled:opacity-40"
              >
                <Send className="size-4" aria-hidden="true" />
              </button>
            </form>
          </div>
        ) : (
          <div className={cn("hidden items-center justify-center rounded-2xl border border-line bg-card px-6 py-16 text-center lg:flex", "flex-col gap-3")}>
            <MessageCircle className="size-8 text-fog" aria-hidden="true" />
            <p className="max-w-sm text-[0.875rem] text-mist">
              Elegí una conversación para leerla y responder. Las no leídas traen el número en verde.
            </p>
            <p className="flex items-center gap-1.5 text-[0.75rem] text-fog">
              <CheckCircle2 className="size-3.5" aria-hidden="true" /> Todo lo que el visitante deje con nombre y teléfono cae como lead en Ventas online.
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
