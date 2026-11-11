"use client";

import { useEffect, useState } from "react";
import { siteConfig } from "@/config/site";
import { cn } from "@/lib/utils";

const KEY = "intro-v1";

type Fase = "fuera" | "montando" | "saliendo";

/**
 * La intro de entrada: una pesa girando con estallido neón volt y la marca
 * — y se retira sola. Reglas para que sea cine y no molestia:
 *  · dura ~2 segundos y se desvanece;
 *  · UNA vez por sesión (sessionStorage);
 *  · un toque/clic la salta;
 *  · con prefers-reduced-motion ni aparece.
 * Se monta sólo en la landing: entrar directo a /horarios no la dispara.
 */
export function IntroSplash() {
  // SSR y primer render: nada (sin destello). El gate decide tras hidratar.
  const [fase, setFase] = useState<Fase>("fuera");

  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce || window.sessionStorage.getItem(KEY)) return;
    window.sessionStorage.setItem(KEY, "1");
    // eslint-disable-next-line react-hooks/set-state-in-effect -- gate síncrono a propósito (storage + motion), patrón del carrito
    setFase("montando");
    const salir = setTimeout(() => setFase("saliendo"), 1900);
    const fuera = setTimeout(() => setFase("fuera"), 2600);
    return () => {
      clearTimeout(salir);
      clearTimeout(fuera);
    };
  }, []);

  if (fase === "fuera") return null;

  return (
    <button
      type="button"
      aria-label="Saltar la introducción"
      onClick={() => {
        if (fase === "montando") setFase("saliendo");
      }}
      className={cn(
        "fixed inset-0 z-[90] flex w-full flex-col items-center justify-center gap-8 bg-night",
        fase === "saliendo" && "intro-saliendo pointer-events-none",
      )}
    >
      <span className="relative grid place-items-center">
        {/* Onda neón que se expande */}
        <span
          className="intro-onda absolute size-52 rounded-full border-2 border-brand/60 sm:size-64"
          aria-hidden="true"
        />
        {/* La pesa girando */}
        <svg
          viewBox="0 0 120 120"
          className="intro-giro size-40 text-brand sm:size-52"
          aria-hidden="true"
          style={{ filter: "drop-shadow(0 0 22px rgba(200, 247, 59, 0.45))" }}
        >
          <circle cx="60" cy="60" r="54" fill="none" stroke="currentColor" strokeWidth="3" opacity="0.95" />
          <circle cx="60" cy="60" r="42" fill="#0c0c0e" stroke="currentColor" strokeWidth="2" opacity="0.5" />
          {[45, 135, 225, 315].map((a) => {
            const x = 60 + 30 * Math.cos((a * Math.PI) / 180);
            const y = 60 + 30 * Math.sin((a * Math.PI) / 180);
            return <circle key={a} cx={x} cy={y} r="3.5" fill="currentColor" opacity="0.9" />;
          })}
          <circle cx="60" cy="60" r="16" fill="none" stroke="currentColor" strokeWidth="3" />
          <circle cx="60" cy="60" r="5" fill="currentColor" />
        </svg>
      </span>

      <span className="intro-texto text-[0.875rem] font-bold text-white/85" style={{ letterSpacing: "0.35em" }}>
        {siteConfig.name.toUpperCase()}
      </span>
    </button>
  );
}
