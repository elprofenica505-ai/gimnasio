"use client";

import { useEffect, useState } from "react";
import { siteConfig } from "@/config/site";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { cn } from "@/lib/utils";

const KEY = "intro-v4";

type Fase = "fuera" | "montando" | "saliendo";

/* Vibración háptica (Android; iOS la ignora en silencio — sin audio). */
function vibrar(patron: number | number[]) {
  try {
    navigator.vibrate?.(patron);
  } catch {
    // Sin vibración no pasa nada: la luz cuenta la historia.
  }
}

/** Vars de animación por pieza (--d retardo, --x/--y origen, --r giro). */
type FrVars = React.CSSProperties & Record<`--${string}`, string | number>;

/** Las 4 piezas reales del emblema, cada una con su vuelo de llegada. */
const PIEZAS: FrVars[] = [
  // Mitad izquierda del puño
  { "--d": "0.55s", "--x": "-130px", "--y": "-95px", "--r": "-150deg" },
  // Mitad derecha del puño
  { "--d": "0.78s", "--x": "140px", "--y": "-75px", "--r": "160deg" },
  // Pulgar
  { "--d": "1.02s", "--x": "-150px", "--y": "70px", "--r": "-115deg" },
  // Muñequera
  { "--d": "1.24s", "--x": "125px", "--y": "95px", "--r": "125deg" },
];

/** Fragmentos chicos que cruzan hacia el centro y se desvanecen. */
const CHISPAS: { left: string; top: string; size: number; vars: FrVars }[] = [
  { left: "8%", top: "18%", size: 5, vars: { "--x": "34vw", "--y": "22vh", "--r": "220deg", "--d": "0.5s" } },
  { left: "88%", top: "24%", size: 4, vars: { "--x": "-30vw", "--y": "18vh", "--r": "-200deg", "--d": "0.66s" } },
  { left: "16%", top: "78%", size: 6, vars: { "--x": "30vw", "--y": "-24vh", "--r": "180deg", "--d": "0.82s" } },
  { left: "82%", top: "72%", size: 4, vars: { "--x": "-32vw", "--y": "-20vh", "--r": "-240deg", "--d": "0.98s" } },
  { left: "45%", top: "6%", size: 4, vars: { "--x": "3vw", "--y": "26vh", "--r": "160deg", "--d": "1.1s" } },
  { left: "55%", top: "90%", size: 5, vars: { "--x": "-4vw", "--y": "-28vh", "--r": "-170deg", "--d": "1.22s" } },
  { left: "4%", top: "48%", size: 4, vars: { "--x": "38vw", "--y": "-6vh", "--r": "210deg", "--d": "1.34s" } },
  { left: "93%", top: "52%", size: 5, vars: { "--x": "-36vw", "--y": "4vh", "--r": "-190deg", "--d": "1.44s" } },
  { left: "30%", top: "10%", size: 3, vars: { "--x": "14vw", "--y": "30vh", "--r": "140deg", "--d": "1.55s" } },
  { left: "68%", top: "84%", size: 3, vars: { "--x": "-12vw", "--y": "-30vh", "--r": "-150deg", "--d": "1.65s" } },
];

/**
 * La intro «FRAGMENTOS» (concepto elegido de los storyboards): los rayos de
 * luz abren el telón, las PIEZAS reales del guante vuelan desde todos los
 * bordes y se acoplan con rebote, las costuras se cosen solas, un pulso de
 * luz + vibración sella el ensamble y el nombre se arma letra a letra.
 * Estallido suave de salida. Sin sonido (decisión explícita).
 * Reglas de cine sin molestia:
 *  · ~5 segundos, se retira sola;
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

    // El «click» del ensamble (2.42s en el CSS): pulso + vibración seca.
    const tAcople = setTimeout(() => vibrar([60, 40, 140]), 2420);
    // Estallido suave de salida: micro-vibración de cortesía.
    const tSalida = setTimeout(() => vibrar(30), 4500);
    const salir = setTimeout(() => setFase("saliendo"), 4550);
    const fuera = setTimeout(() => setFase("fuera"), 5250);

    return () => {
      clearTimeout(tAcople);
      clearTimeout(tSalida);
      clearTimeout(salir);
      clearTimeout(fuera);
    };
  }, []);

  if (fase === "fuera") return null;

  // El nombre completo, letra por letra; «BOX» en volt.
  const letras: { ch: string; volt: boolean; d: number }[] = [];
  let iLetra = 0;
  for (const palabra of siteConfig.name.toUpperCase().split(" ")) {
    for (const ch of palabra) {
      letras.push({ ch, volt: palabra === "BOX", d: 2.9 + iLetra * 0.065 });
      iLetra += 1;
    }
    iLetra += 1; // el espacio también corre el reloj
  }

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
      <span aria-hidden="true" className="intro-tick absolute top-5 left-5 size-7 border-t-2 border-l-2 border-brand/40" />
      <span aria-hidden="true" className="intro-tick absolute top-5 right-5 size-7 border-t-2 border-r-2 border-brand/40" />
      <span aria-hidden="true" className="intro-tick absolute bottom-5 left-5 size-7 border-b-2 border-l-2 border-brand/40" />
      <span aria-hidden="true" className="intro-tick absolute right-5 bottom-5 size-7 border-r-2 border-b-2 border-brand/40" />

      {/* Rayos volumétricos cruzando el negro */}
      <span
        aria-hidden="true"
        className="intro-rayo absolute top-1/2 left-1/2 h-[150vmax] w-[16vmax] -translate-x-1/2 -translate-y-1/2 bg-gradient-to-b from-transparent via-brand/12 to-transparent blur-2xl"
        style={{ "--a": "-18deg", transformOrigin: "center" } as FrVars}
      />
      <span
        aria-hidden="true"
        className="intro-rayo absolute top-1/2 left-1/2 h-[150vmax] w-[9vmax] -translate-x-1/2 -translate-y-1/2 bg-gradient-to-b from-transparent via-brand/10 to-transparent blur-2xl"
        style={{ "--a": "22deg", animationDelay: "0.25s", transformOrigin: "center" } as FrVars}
      />

      {/* Línea de escaneo de apertura */}
      <span
        aria-hidden="true"
        className="intro-escaneo absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-brand to-transparent"
      />

      {/* Fragmentos chicos que cruzan y se desvanecen */}
      <span aria-hidden="true">
        {CHISPAS.map((c, i) => (
          <span
            key={i}
            className="fr-chispa absolute rounded-full bg-brand shadow-[0_0_10px_rgba(200,247,59,0.85)]"
            style={{ left: c.left, top: c.top, width: c.size, height: c.size, ...c.vars }}
          />
        ))}
      </span>

      {/* Centro: el guante que se ensambla + el nombre que se arma */}
      <div className="relative z-10 flex flex-col items-center px-6">
        <span className="relative grid place-items-center">
          {/* Pulso de luz del ensamble */}
          <span
            aria-hidden="true"
            className="fr-anillo absolute top-1/2 left-1/2 size-40 rounded-full border-2 border-brand/70 sm:size-48"
          />
          {/* El emblema, pieza por pieza (mismas formas que BrandMark) */}
          <svg
            viewBox="0 0 100 100"
            className="fr-logo size-28 sm:size-40"
            aria-hidden="true"
          >
            <g className="fr-pieza" style={PIEZAS[0]}>
              <rect x="26" y="16" width="24" height="50" rx="12" fill="#c8f73b" />
            </g>
            <g className="fr-pieza" style={PIEZAS[1]}>
              <rect x="50" y="16" width="24" height="50" rx="12" fill="#c8f73b" />
            </g>
            <g className="fr-pieza" style={PIEZAS[2]}>
              <ellipse cx="22" cy="50" rx="10" ry="13" fill="#c8f73b" />
            </g>
            <g className="fr-pieza" style={PIEZAS[3]}>
              <rect x="40" y="70" width="26" height="14" rx="6" fill="#c8f73b" />
            </g>
            {/* Las costuras se cosen solas cuando el puño ya está cerrado */}
            <path
              className="fr-costura"
              d="M36 38 C29 46 29 56 36 64"
              stroke="#0c0c0e"
              strokeWidth="4"
              strokeLinecap="round"
              fill="none"
            />
            <path
              className="fr-costura"
              style={{ animationDelay: "2.42s" }}
              d="M44 72 h18"
              stroke="#0c0c0e"
              strokeWidth="3"
              strokeLinecap="round"
              fill="none"
            />
          </svg>
        </span>

        {/* El nombre se arma letra a letra (BOX en volt) */}
        <p
          className="display-xl mt-7 text-center text-[clamp(1.75rem,7.5vw,3.25rem)] leading-none text-white"
          aria-label={siteConfig.name}
        >
          {letras.map((l, i) => (
            <span
              key={i}
              aria-hidden="true"
              className={cn("fr-letra", l.volt && "text-brand")}
              style={{ "--d": `${l.d}s` } as FrVars}
            >
              {l.ch}
            </span>
          ))}
        </p>

        <span
          className="fr-sub mt-5 max-w-[86vw] text-center text-[0.625rem] font-semibold text-white/60 sm:text-[0.8125rem]"
          style={{ letterSpacing: "0.42em" }}
        >
          {`${dict.hero.titleTop} ${dict.hero.titleAccent} ${dict.hero.titleBottom}`.toUpperCase()}
        </span>
      </div>

      {/* Estallido suave de salida */}
      <span
        aria-hidden="true"
        className="fr-salida-luz absolute inset-0 z-20 bg-[radial-gradient(circle_at_center,rgba(200,247,59,0.5),transparent_65%)]"
      />
    </button>
  );
}
