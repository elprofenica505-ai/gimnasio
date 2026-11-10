"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Loader2, MessageCircle, Send, X } from "lucide-react";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { cn } from "@/lib/utils";

type Rol = "visitante" | "asistente" | "staff";

interface ArmMsg {
  role: Rol;
  text: string;
  local?: boolean;
}

interface ArmAccion {
  etiqueta: string;
  url: string;
}

const STORAGE_KEY = "arm-token";

function nuevoToken(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  // Navegador viejo: uuid v4 casero (el server valida el formato).
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

/**
 * La conversación del ARM. «burbuja»: flotante en la web pública para
 * visitantes. «página»: embebida en Mi cuenta para socios (sus mensajes
 * llegan a la bandeja del personal, sin bot de por medio).
 */
export function ArmChat({ locale, variante }: { locale: string; variante: "burbuja" | "pagina" }) {
  const { dict } = useDictionary();
  const arm = dict.arm;
  const [abierto, setAbierto] = useState(variante === "pagina");
  const [mensajes, setMensajes] = useState<ArmMsg[]>([]);
  const [sugerencias, setSugerencias] = useState<string[]>([]);
  const [acciones, setAcciones] = useState<ArmAccion[]>([]);
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [texto, setTexto] = useState("");
  const [enviando, setEnviando] = useState(false);
  const tokenRef = useRef<string | null>(null);
  const finalRef = useRef<HTMLDivElement | null>(null);

  const cargar = useCallback(
    async (leer: boolean) => {
      const token = tokenRef.current;
      if (!token) return;
      try {
        const res = await fetch(`/api/arm?token=${encodeURIComponent(token)}&locale=${locale}${leer ? "&leer=1" : ""}`, { cache: "no-store" });
        if (!res.ok) {
          setEnabled(false);
          return;
        }
        const data = (await res.json()) as { enabled: boolean; mensajes?: ArmMsg[] };
        setEnabled(data.enabled);
        const historial = (data.mensajes ?? []) as ArmMsg[];
        setMensajes(
          historial.length > 0
            ? historial
            : [{ role: "asistente", text: arm.saludo, local: true }],
        );
        setSugerencias(
          historial.length > 0
            ? []
            : [arm.sugerencias.precios, arm.sugerencias.horarios, arm.sugerencias.clases, arm.sugerencias.humano],
        );
      } catch {
        setEnabled(false);
      }
    },
    [locale, arm],
  );

  useEffect(() => {
    let token = window.localStorage.getItem(STORAGE_KEY);
    if (!token || !/^[0-9a-f-]{36}$/i.test(token)) {
      token = nuevoToken();
      window.localStorage.setItem(STORAGE_KEY, token);
    }
    tokenRef.current = token;
    if (variante === "pagina") {
      // Carga inicial del historial: los setState corren tras el await de fetch.
      // eslint-disable-next-line react-hooks/set-state-in-effect -- carga inicial asíncrona
      void cargar(true);
    }
  }, [cargar, variante]);

  useEffect(() => {
    if (variante === "burbuja" && abierto && enabled === null) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- carga al abrir la burbuja
      void cargar(true);
    }
  }, [abierto, variante, enabled, cargar]);

  useEffect(() => {
    finalRef.current?.scrollIntoView({ block: "end", behavior: "smooth" });
  }, [mensajes, abierto]);

  async function enviar(consulta: string) {
    const limpio = consulta.trim();
    const token = tokenRef.current;
    if (!limpio || !token || enviando) return;
    setEnviando(true);
    setTexto("");
    setMensajes((m) => [...m, { role: "visitante", text: limpio }]);
    setSugerencias([]);
    setAcciones([]);
    try {
      const res = await fetch("/api/arm", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token, text: limpio, locale }),
      });
      if (!res.ok) {
        setEnabled(false);
        setMensajes((m) => [...m, { role: "asistente", text: arm.noDisponible }]);
        return;
      }
      const data = (await res.json()) as {
        reply?: string;
        sugerencias?: string[];
        acciones?: ArmAccion[];
        socio?: boolean;
      };
      if (data.socio) {
        setMensajes((m) => [...m, { role: "asistente", text: arm.recibido }]);
        return;
      }
      setMensajes((m) => [...m, { role: "asistente", text: data.reply ?? arm.noDisponible }]);
      setSugerencias(data.sugerencias ?? []);
      setAcciones(data.acciones ?? []);
    } catch {
      setMensajes((m) => [...m, { role: "asistente", text: arm.error }]);
    } finally {
      setEnviando(false);
    }
  }

  if (variante === "burbuja" && !abierto) {
    return (
      <button
        type="button"
        onClick={() => setAbierto(true)}
        aria-label={arm.burbuja}
        className="fixed bottom-4 right-4 z-50 flex size-14 items-center justify-center rounded-full bg-brand text-onbrand shadow-lg shadow-black/40 transition-transform hover:scale-105 sm:bottom-6 sm:right-6 print:hidden"
      >
        <MessageCircle className="size-6" aria-hidden="true" />
      </button>
    );
  }

  const conversacion = (
    <div className={cn("flex flex-col", variante === "pagina" ? "h-[70vh] min-h-[420px]" : "h-[min(70vh,540px)]")}>
      <header className={cn("flex items-center gap-2 border-b border-line px-4 py-3", variante === "pagina" ? "" : "rounded-t-2xl bg-card")}>
        <span className="flex size-8 items-center justify-center rounded-full bg-brand/15 text-brand-300">
          <MessageCircle className="size-4" aria-hidden="true" />
        </span>
        <div className="min-w-0 flex-1">
          <p className="text-[0.9375rem] font-bold text-ink">{arm.titulo}</p>
          <p className="truncate text-[0.6875rem] text-fog">{arm.subtitulo}</p>
        </div>
        {variante === "burbuja" ? (
          <button
            type="button"
            onClick={() => setAbierto(false)}
            aria-label={arm.cerrar}
            className="rounded-full p-1.5 text-fog hover:bg-cloud hover:text-ink"
          >
            <X className="size-4" aria-hidden="true" />
          </button>
        ) : null}
      </header>

      <div className="flex-1 space-y-2.5 overflow-y-auto px-4 py-4">
        {mensajes.map((m, i) => (
          <div
            key={i}
            className={cn(
              "max-w-[85%] whitespace-pre-line rounded-2xl px-3.5 py-2.5 text-[0.875rem] leading-relaxed",
              m.role === "visitante"
                ? "ml-auto bg-brand text-onbrand"
                : "mr-auto border border-line bg-card text-ink",
            )}
          >
            {m.text}
          </div>
        ))}
        {enviando ? (
          <div className="mr-auto flex items-center gap-2 rounded-2xl border border-line bg-card px-3.5 py-2.5 text-[0.8125rem] text-fog">
            <Loader2 className="size-3.5 animate-spin" aria-hidden="true" />
            {arm.pensando}
          </div>
        ) : null}
        <div ref={finalRef} />
      </div>

      {(sugerencias.length > 0 || acciones.length > 0) && (
        <div className="flex flex-wrap gap-1.5 px-4 pb-2">
          {acciones.map((a) => (
            <a
              key={a.url + a.etiqueta}
              href={a.url}
              target={a.url.startsWith("http") ? "_blank" : undefined}
              rel={a.url.startsWith("http") ? "noreferrer" : undefined}
              className="rounded-full border border-brand/40 bg-brand/10 px-3 py-1.5 text-[0.75rem] font-semibold text-brand-300 hover:bg-brand/20"
            >
              {a.etiqueta}
            </a>
          ))}
          {sugerencias.map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => void enviar(s)}
              className="rounded-full border border-line px-3 py-1.5 text-[0.75rem] text-fog hover:border-brand/40 hover:text-ink"
            >
              {s}
            </button>
          ))}
        </div>
      )}

      {enabled === false ? (
        <div className="border-t border-line px-4 py-3">
          <a
            href={arm.whatsappHref}
            target="_blank"
            rel="noreferrer"
            className="flex items-center justify-center gap-2 rounded-xl bg-brand px-4 py-2.5 text-[0.875rem] font-bold text-onbrand"
          >
            <MessageCircle className="size-4" aria-hidden="true" />
            {arm.whatsapp}
          </a>
        </div>
      ) : (
        <form
          className="flex items-end gap-2 border-t border-line p-3"
          onSubmit={(e) => {
            e.preventDefault();
            void enviar(texto);
          }}
        >
          <textarea
            value={texto}
            onChange={(e) => setTexto(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                void enviar(texto);
              }
            }}
            rows={1}
            maxLength={1000}
            placeholder={arm.placeholder}
            aria-label={arm.placeholder}
            className="max-h-28 flex-1 resize-none rounded-xl border border-line bg-paper px-3.5 py-2.5 text-[0.875rem] text-ink placeholder:text-fog focus:border-brand/50 focus:outline-none"
          />
          <button
            type="submit"
            disabled={enviando || texto.trim().length === 0}
            aria-label={arm.enviar}
            className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-brand text-onbrand disabled:opacity-40"
          >
            <Send className="size-4" aria-hidden="true" />
          </button>
        </form>
      )}
    </div>
  );

  if (variante === "pagina") {
    return <div className="rounded-2xl border border-line bg-paper">{conversacion}</div>;
  }

  return (
    <div className="fixed bottom-4 right-4 z-50 w-[min(92vw,380px)] overflow-hidden rounded-2xl border border-line bg-paper shadow-2xl shadow-black/50 sm:bottom-6 sm:right-6 print:hidden">
      {conversacion}
    </div>
  );
}
