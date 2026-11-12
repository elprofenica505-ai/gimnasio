"use client";

import { useEffect, useRef, useState } from "react";
import { siteConfig } from "@/config/site";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { cn } from "@/lib/utils";

/**
 * ============================================================
 *  Intro «EL ENSAMBLE» — efecto 100% real del propio app
 * ============================================================
 *  Nada de fotos ni videos: las PIEZAS reales del emblema (el mismo SVG
 *  del header: dos mitades del puño, pulgar y muñequera) vuelan hasta el
 *  centro y se acoplan, las costuras se COSAN solas, y un sistema de
 *  PARTÍCULAS en canvas (dibujado en vivo, cuadro a cuadro) acompaña todo:
 *  polvo volt flotando, ráfagas cuando cada pieza aterriza y atracción
 *  hacia el guante en el cierre. Al final se arma el nombre letra a letra.
 *
 *  Por qué se siente parte del app: usa la geometría y el volt de la marca,
 *  y la imagen final ES el logo que vive en toda la página.
 *
 *  Reglas (todas aprendidas con el dueño):
 *   · UNA vez por DISPOSITIVO (localStorage), no por sesión;
 *   · ~3.5 segundos, saltable con un toque;
 *   · con prefers-reduced-motion ni aparece;
 *   · SIN sonido; vibración sólo si la sesión ya tiene un toque del
 *     usuario (política de los navegadores — nunca se promete de más);
 *   · sólo en la landing; si la pestaña abre en segundo plano, se salta.
 */

const KEY = "intro-ensamble-v1";

type Fase = "fuera" | "activa" | "saliendo";

/* Delays de vuelo de cada pieza (s). El aterrizaje ≈ delay + 0.8. */
const PIEZAS_VARS = [
  { "--d": "0.5s", "--x": "-130px", "--y": "-95px", "--r": "-150deg" },
  { "--d": "0.85s", "--x": "140px", "--y": "-75px", "--r": "160deg" },
  { "--d": "1.15s", "--x": "-150px", "--y": "70px", "--r": "-115deg" },
  { "--d": "1.45s", "--x": "125px", "--y": "95px", "--r": "125deg" },
] as const;

/** Centro de cada pieza en unidades del viewBox (0–100). */
const CENTROS_PIEZA = [
  { cx: 38, cy: 41 }, // mitad izquierda del puño
  { cx: 62, cy: 41 }, // mitad derecha
  { cx: 22, cy: 50 }, // pulgar
  { cx: 53, cy: 77 }, // muñequera
];

const ATERRAJIZES_MS = [1300, 1650, 1950, 2250];
const CONVERGE_MS = 2300;
const FIN_LIENZO_MS = 3400;

interface Particula {
  x: number;
  y: number;
  vx: number;
  vy: number;
  vida: number; // 0..1 restante
  tam: number;
  converger: boolean;
}

/** Intenta vibrar: sólo funciona si ya hubo un gesto del usuario en la
 *  sesión (política del navegador). Falla en silencio — nunca promete. */
function vibrar(patron: number | number[]) {
  try {
    navigator.vibrate?.(patron);
  } catch {
    // Sin vibración no pasa nada: la luz cuenta la historia.
  }
}

type FrVars = React.CSSProperties & Record<`--${string}`, string | number>;

export function IntroEnsamble() {
  const { locale, dict } = useDictionary();
  const [fase, setFase] = useState<Fase>("fuera");
  const lienzoRef = useRef<HTMLCanvasElement | null>(null);
  const guanteRef = useRef<SVGSVGElement | null>(null);

  // El gate: decide UNA vez por dispositivo, respetando reduced-motion.
  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce || window.localStorage.getItem(KEY) || document.hidden) return;
    window.localStorage.setItem(KEY, "1");
    // eslint-disable-next-line react-hooks/set-state-in-effect -- gate síncrono a propósito (storage + motion), patrón del carrito
    setFase("activa");
  }, []);

  // El lienzo: partículas dibujadas en vivo durante toda la intro.
  useEffect(() => {
    if (fase !== "activa") return;
    const lienzo = lienzoRef.current;
    if (!lienzo) return;
    const ctx = lienzo.getContext("2d");
    if (!ctx) return;

    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    let ancho = 0;
    let alto = 0;
    const ajustar = () => {
      ancho = window.innerWidth;
      alto = window.innerHeight;
      lienzo.width = Math.round(ancho * dpr);
      lienzo.height = Math.round(alto * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    ajustar();
    window.addEventListener("resize", ajustar);

    const particulas: Particula[] = [];
    const inicio = performance.now();
    let raf = 0;
    const VOLT = (a: number) => `rgba(200,247,59,${a})`;

    const spawnAmbiente = (n: number) => {
      for (let i = 0; i < n; i++) {
        particulas.push({
          x: Math.random() * ancho,
          y: Math.random() * alto,
          vx: (Math.random() - 0.5) * 12,
          vy: -6 - Math.random() * 14,
          vida: 0.35 + Math.random() * 0.4,
          tam: 0.8 + Math.random() * 1.6,
          converger: false,
        });
      }
    };
    const spawnRafaga = (x: number, y: number, n: number, fuerza: number) => {
      for (let i = 0; i < n; i++) {
        const ang = Math.random() * Math.PI * 2;
        const v = fuerza * (0.4 + Math.random() * 0.6);
        particulas.push({
          x,
          y,
          vx: Math.cos(ang) * v,
          vy: Math.sin(ang) * v,
          vida: 0.9,
          tam: 1 + Math.random() * 1.8,
          converger: false,
        });
      }
    };

    const centroGuante = (): DOMRect => {
      const r = guanteRef.current?.getBoundingClientRect();
      if (r) return r;
      // Reserva antes del primer layout: cuadrado centrado aproximado.
      const lado = 140;
      return {
        width: lado,
        height: lado,
        top: (alto - lado) / 2,
        left: (ancho - lado) / 2,
        x: (ancho - lado) / 2,
        y: (alto - lado) / 2,
        bottom: (alto + lado) / 2,
        right: (ancho + lado) / 2,
        toJSON: () => ({}),
      } as DOMRect;
    };

    // Ráfagas programadas: cada aterrizaje de pieza dispara la suya,
    // medida sobre el rectángulo real del guante (no coordenadas inventadas).
    const disparos = ATERRAJIZES_MS.map((t, i) =>
      setTimeout(() => {
        const r = centroGuante();
        const p = CENTROS_PIEZA[i];
        spawnRafaga(r.left + (r.width * p.cx) / 100, r.top + (r.height * p.cy) / 100, 16, 90);
      }, t),
    );
    const pulso = setTimeout(() => vibrar([45, 35, 120]), CONVERGE_MS);
    const salir = setTimeout(() => setFase("saliendo"), 3150);
    const fuera = setTimeout(() => setFase("fuera"), 3850);

    const cuadro = (ahora: number) => {
      const t = ahora - inicio;

      // Estela: pintamos el negro translúcido del propio fondo.
      ctx.fillStyle = "rgba(12,12,14,0.30)";
      ctx.fillRect(0, 0, ancho, alto);
      ctx.globalCompositeOperation = "lighter";

      // El caos inicial se siembra en el primer medio segundo.
      if (t < 500 && Math.random() < 0.55) spawnAmbiente(3);

      const r = centroGuante();
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      const converger = t >= CONVERGE_MS;
      const fin = t >= FIN_LIENZO_MS;

      for (let i = particulas.length - 1; i >= 0; i--) {
        const p = particulas[i];
        if (converger && !p.converger && Math.random() < 0.2) p.converger = true;
        if (p.converger) {
          // Atracción al guante: el caos se ordena en el cierre.
          const dx = cx - p.x;
          const dy = cy - p.y;
          const d = Math.hypot(dx, dy) || 1;
          p.vx += (dx / d) * 2.4;
          p.vy += (dy / d) * 2.4;
          p.vida -= 0.012;
          if (d < 22) p.vida = 0;
        } else {
          p.vx *= 0.985;
          p.vy *= 0.985;
          p.vida -= 0.006;
        }
        p.x += p.vx * 0.016 * 60;
        p.y += p.vy * 0.016 * 60;
        if (p.vida <= 0 || p.x < -20 || p.x > ancho + 20 || p.y < -20 || p.y > alto + 20) {
          particulas.splice(i, 1);
          continue;
        }
        const alpha = Math.min(0.85, p.vida) * (p.converger ? 0.95 : 0.6);
        ctx.fillStyle = VOLT(alpha);
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.tam, 0, Math.PI * 2);
        ctx.fill();
      }

      ctx.globalCompositeOperation = "source-over";
      if (!fin) raf = requestAnimationFrame(cuadro);
    };
    raf = requestAnimationFrame(cuadro);

    const alTocar = () => vibrar([50, 30, 80]);
    window.addEventListener("pointerdown", alTocar, { once: true });

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", ajustar);
      window.removeEventListener("pointerdown", alTocar);
      for (const d of disparos) clearTimeout(d);
      clearTimeout(pulso);
      clearTimeout(salir);
      clearTimeout(fuera);
    };
  }, [fase]);

  if (fase === "fuera") return null;

  const letras: { ch: string; volt: boolean; d: number }[] = [];
  let iLetra = 0;
  for (const palabra of siteConfig.name.toUpperCase().split(" ")) {
    for (const ch of palabra) {
      letras.push({ ch, volt: palabra === "BOX", d: 2.6 + iLetra * 0.045 });
      iLetra += 1;
    }
    iLetra += 1; // el espacio también corre el reloj
  }

  return (
    <button
      type="button"
      aria-label={locale === "es" ? "Saltar la introducción" : "Skip intro"}
      onPointerDown={() => {
        if (fase === "activa") setFase("saliendo");
      }}
      className={cn(
        "fixed inset-0 z-[90] flex w-full items-center justify-center overflow-hidden bg-night",
        fase === "saliendo" && "ens-saliendo pointer-events-none",
      )}
    >
      {/* Las partículas vivas: polvo, ráfagas y convergencia */}
      <canvas ref={lienzoRef} className="absolute inset-0 size-full" aria-hidden="true" />

      {/* Visor de cámara: cuatro marcas en las esquinas */}
      <span aria-hidden="true" className="ens-marca absolute top-5 left-5 size-7 border-t-2 border-l-2 border-brand/40" />
      <span aria-hidden="true" className="ens-marca absolute top-5 right-5 size-7 border-t-2 border-r-2 border-brand/40" />
      <span aria-hidden="true" className="ens-marca absolute bottom-5 left-5 size-7 border-b-2 border-l-2 border-brand/40" />
      <span aria-hidden="true" className="ens-marca absolute right-5 bottom-5 size-7 border-r-2 border-b-2 border-brand/40" />

      {/* El guante que se ensambla + el nombre que se arma */}
      <div className="relative z-10 flex flex-col items-center px-6">
        <span className="relative grid place-items-center">
          {/* Pulso de luz del ensamble */}
          <span
            aria-hidden="true"
            className="ens-anillo absolute top-1/2 left-1/2 size-44 rounded-full border-2 border-brand/70 sm:size-52"
          />
          {/* El emblema real, pieza por pieza (mismas formas que BrandMark) */}
          <svg
            ref={guanteRef}
            viewBox="0 0 100 100"
            className="size-32 drop-shadow-[0_0_14px_rgba(200,247,59,0.4)] sm:size-44"
            aria-hidden="true"
          >
            <g className="ens-pieza" style={PIEZAS_VARS[0] as FrVars}>
              <rect x="26" y="16" width="24" height="50" rx="12" fill="#c8f73b" />
            </g>
            <g className="ens-pieza" style={PIEZAS_VARS[1] as FrVars}>
              <rect x="50" y="16" width="24" height="50" rx="12" fill="#c8f73b" />
            </g>
            <g className="ens-pieza" style={PIEZAS_VARS[2] as FrVars}>
              <ellipse cx="22" cy="50" rx="10" ry="13" fill="#c8f73b" />
            </g>
            <g className="ens-pieza" style={PIEZAS_VARS[3] as FrVars}>
              <rect x="40" y="70" width="26" height="14" rx="6" fill="#c8f73b" />
            </g>
            {/* Las costuras se cosen solas al cerrarse el puño */}
            <path
              className="ens-costura"
              d="M36 38 C29 46 29 56 36 64"
              stroke="#0c0c0e"
              strokeWidth="4"
              strokeLinecap="round"
              fill="none"
            />
            <path
              className="ens-costura"
              style={{ animationDelay: "2.42s" }}
              d="M44 72 h18"
              stroke="#0c0c0e"
              strokeWidth="3"
              strokeLinecap="round"
              fill="none"
            />
          </svg>
        </span>

        <p
          className="display-xl mt-7 text-center text-[clamp(1.75rem,7.5vw,3.25rem)] leading-none text-white"
          aria-label={siteConfig.name}
        >
          {letras.map((l, i) => (
            <span
              key={i}
              aria-hidden="true"
              className={cn("ens-letra", l.volt && "text-brand")}
              style={{ "--d": `${l.d}s` } as FrVars}
            >
              {l.ch}
            </span>
          ))}
        </p>

        <span
          className="ens-sub mt-5 max-w-[86vw] text-center text-[0.625rem] font-semibold text-white/60 sm:text-[0.8125rem]"
          style={{ letterSpacing: "0.42em" }}
        >
          {`${dict.hero.titleTop} ${dict.hero.titleAccent} ${dict.hero.titleBottom}`.toUpperCase()}
        </span>
      </div>
    </button>
  );
}
