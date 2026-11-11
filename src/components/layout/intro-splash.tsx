"use client";

import { useEffect, useState } from "react";
import { siteConfig } from "@/config/site";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { BrandMark } from "@/components/layout/brand-mark";
import { cn } from "@/lib/utils";

const KEY = "intro-v5";

type Fase = "fuera" | "montando" | "saliendo";

/* Vibración háptica (Android; iOS la ignora en silencio — sin audio). */
function vibrar(patron: number | number[]) {
  try {
    navigator.vibrate?.(patron);
  } catch {
    // Sin vibración no pasa nada: el cine manda.
  }
}

/** Las tres tomas filmadas: exactamente los frames del storyboard aprobado. */
const TOMAS = [
  { src: "/images/intro/frag-forja.webp", clase: "intro-toma-a" },
  { src: "/images/intro/frag-explota.webp", clase: "intro-toma-b" },
  { src: "/images/intro/frag-ring.webp", clase: "intro-toma-c" },
] as const;

/** Cortes de cámara con flash: 1.3s, 2.5s y 3.68s (resolución en el logo). */
const CORTES = [
  { d: "1.3s" },
  { d: "2.5s" },
  { d: "3.68s" },
] as const;

/**
 * La intro de cine: el teaser filmado con los tres frames que el dueño
 * aprobó del storyboard (forja → explosión de fragmentos → el ring),
 * con cortes de cámara, barras de cine, grano y viñeta — y la resolución:
 * la luz quema la última foto y queda el logo volt real con la marca.
 * Reglas de cine sin molestia:
 *  · ~5.2 segundos, se retira sola con fundido;
 *  · UNA vez por sesión (sessionStorage);
 *  · un toque en cualquier lado la salta;
 *  · con prefers-reduced-motion ni aparece.
 * Se monta sólo en la landing.
 */
export function IntroSplash() {
  const { locale, dict } = useDictionary();
  // SSR y primer render: nada (sin destello). El gate decide tras hidratar.
  const [fase, setFase] = useState<Fase>("fuera");

  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce || window.sessionStorage.getItem(KEY)) return;
    window.sessionStorage.setItem(KEY, "1");
    // eslint-disable-next-line react-hooks/set-state-in-effect -- gate síncrono a propósito (storage + motion), patrón del carrito
    setFase("montando");

    // Precalienta los 3 frames (una intro no puede esperando al flash).
    for (const t of TOMAS) {
      const img = new Image();
      img.src = t.src;
    }

    // Vibración en los cortes y en la resolución (iOS la ignora: sin drama).
    const v1 = setTimeout(() => vibrar([50, 30, 60]), 1300);
    const v2 = setTimeout(() => vibrar([60, 40, 140]), 2500);
    const v3 = setTimeout(() => vibrar(40), 3680);
    const v4 = setTimeout(() => vibrar(30), 4780);
    const salir = setTimeout(() => setFase("saliendo"), 4950);
    const fuera = setTimeout(() => setFase("fuera"), 5650);

    return () => {
      clearTimeout(v1);
      clearTimeout(v2);
      clearTimeout(v3);
      clearTimeout(v4);
      clearTimeout(salir);
      clearTimeout(fuera);
    };
  }, []);

  if (fase === "fuera") return null;

  return (
    <button
      type="button"
      aria-label={locale === "es" ? "Saltar la introducción" : "Skip intro"}
      onClick={() => {
        if (fase === "montando") setFase("saliendo");
      }}
      className={cn(
        "fixed inset-0 z-[90] flex w-full items-center justify-center overflow-hidden bg-night",
        fase === "saliendo" && "intro-saliendo pointer-events-none",
      )}
    >
      {/* Las tres tomas filmadas */}
      <span aria-hidden="true">
        {TOMAS.map((t) => (
          <span
            key={t.src}
            className={cn("intro-toma", t.clase)}
            style={{ backgroundImage: `url(${t.src})` }}
          />
        ))}
      </span>

      {/* Flashes de cámara en los cortes */}
      <span aria-hidden="true">
        {CORTES.map((c) => (
          <span
            key={c.d}
            className="cine-flash absolute inset-0 z-30 bg-[radial-gradient(circle_at_center,rgba(255,255,255,0.85),rgba(200,247,59,0.5)_50%,transparent_75%)]"
            style={{ "--d": c.d } as React.CSSProperties}
          />
        ))}
      </span>

      {/* Viñeta: el foco manda al centro */}
      <span
        aria-hidden="true"
        className="absolute inset-0 z-20 bg-[radial-gradient(ellipse_at_center,transparent_52%,rgba(12,12,14,0.55)_100%)]"
      />

      {/* Grano de película */}
      <span
        aria-hidden="true"
        className="cine-grano absolute inset-0 z-20 mix-blend-overlay"
        style={{
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='120' height='120' filter='url(%23n)' opacity='0.5'/%3E%3C/svg%3E\")",
        }}
      />

      {/* Barras de cine */}
      <span
        aria-hidden="true"
        className="cine-barra absolute inset-x-0 top-0 z-30 h-[7vh] bg-night"
        style={{ "--dir": "-100%" } as React.CSSProperties}
      />
      <span
        aria-hidden="true"
        className="cine-barra absolute inset-x-0 bottom-0 z-30 h-[7vh] bg-night"
        style={{ "--dir": "100%" } as React.CSSProperties}
      />

      {/* Resolución: el logo real de la marca */}
      <span className="relative z-40 flex flex-col items-center px-6">
        <span className="relative grid place-items-center">
          <BrandMark className="cine-logo-in size-28 sm:size-40" />
        </span>
        <span
          className="display-xl cine-nombre mt-6 text-center text-[clamp(1.75rem,7.5vw,3.25rem)] leading-none text-white"
          aria-label={siteConfig.name}
        >
          {siteConfig.name.toUpperCase().split(" ").map((palabra, p) => (
            <span key={p} className={cn("mr-2 last:mr-0", palabra === "BOX" ? "text-brand" : "")}>
              {palabra}
            </span>
          ))}
        </span>
        <span
          className="cine-sub mt-4 max-w-[86vw] text-center text-[0.625rem] font-semibold text-white/60 sm:text-[0.8125rem]"
          style={{ letterSpacing: "0.42em" }}
        >
          {`${dict.hero.titleTop} ${dict.hero.titleAccent} ${dict.hero.titleBottom}`.toUpperCase()}
        </span>
      </span>

      {/* Quemado final de salida */}
      <span
        aria-hidden="true"
        className="cine-salida absolute inset-0 z-30 bg-[radial-gradient(circle_at_center,rgba(200,247,59,0.5),transparent_65%)]"
      />
    </button>
  );
}
