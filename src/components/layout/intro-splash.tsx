"use client";

import { useEffect, useState } from "react";
import { siteConfig } from "@/config/site";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { cn } from "@/lib/utils";

const KEY = "intro-v2";

type Fase = "fuera" | "montando" | "saliendo";

/**
 * La intro de estudio: tipografía cinética. «POWER» y «BOX» entran a golpes
 * (blur-slam), «BOX» aterriza con onda expansiva de puñetazo y un
 * micro-temblor de pantalla; la barra volt se barre debajo y el eslogan
 * aparece con aire. Reglas de cine sin molestia:
 *  · ~2 segundos, se retira sola con fundido;
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
    const salir = setTimeout(() => setFase("saliendo"), 2050);
    const fuera = setTimeout(() => setFase("fuera"), 2750);
    return () => {
      clearTimeout(salir);
      clearTimeout(fuera);
    };
  }, []);

  if (fase === "fuera") return null;

  // POWER / BOX en la calle grande; el resto del nombre abajo, con aire.
  const palabras = siteConfig.name.split(" ");
  const linea1 = (palabras[0] ?? "POWER").toUpperCase();
  const linea2 = (palabras[1] ?? "BOX").toUpperCase();
  const resto = palabras.slice(2).join(" ");
  const sub = resto
    ? resto
        .toUpperCase()
        .split("")
        .join(" ")
    : `${dict.hero.titleTop} ${dict.hero.titleAccent} ${dict.hero.titleBottom}`.toUpperCase();

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
      {/* Visor de cámara: cuatro marcas en las esquinas */}
      <span
        aria-hidden="true"
        className="intro-tick absolute top-5 left-5 size-7 border-t-2 border-l-2 border-brand/40"
      />
      <span
        aria-hidden="true"
        className="intro-tick absolute top-5 right-5 size-7 border-t-2 border-r-2 border-brand/40"
      />
      <span
        aria-hidden="true"
        className="intro-tick absolute bottom-5 left-5 size-7 border-b-2 border-l-2 border-brand/40"
      />
      <span
        aria-hidden="true"
        className="intro-tick absolute right-5 bottom-5 size-7 border-r-2 border-b-2 border-brand/40"
      />

      {/* Línea de escaneo que barre la pantalla */}
      <span
        aria-hidden="true"
        className="intro-escaneo absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-brand to-transparent"
      />

      {/* La marca, entrando a golpes */}
      <div className="intro-golpe flex flex-col items-center px-6">
        <span
          className="display-xl intro-slida text-center text-[clamp(3.25rem,15vw,8rem)] leading-[0.88] text-white"
          style={{ animationDelay: "0.35s" }}
        >
          {linea1}
        </span>
        <span
          className="display-xl intro-slida relative text-center text-[clamp(3.25rem,15vw,8rem)] leading-[0.88] text-brand"
          style={{ animationDelay: "0.52s" }}
        >
          {linea2}
          {/* Onda expansiva del impacto */}
          <span
            aria-hidden="true"
            className="intro-onda-puno absolute top-1/2 left-1/2 -z-10 size-56 rounded-full border-2 border-brand/70"
          />
        </span>

        <span className="intro-barra mt-6 h-[3px] w-[min(72vw,26rem)] origin-left bg-brand" />
        <span
          className="intro-sub mt-6 max-w-[86vw] text-center text-[0.625rem] font-semibold text-white/60 sm:text-[0.8125rem]"
          style={{ letterSpacing: "0.42em" }}
        >
          {sub}
        </span>
      </div>
    </button>
  );
}
