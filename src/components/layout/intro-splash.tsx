"use client";

import { useEffect, useRef, useState } from "react";
import { siteConfig } from "@/config/site";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { BrandMark } from "@/components/layout/brand-mark";
import { cn } from "@/lib/utils";

const KEY = "intro-v3";

type Fase = "fuera" | "montando" | "saliendo";

/* ── Vibración (Android; iOS la ignora: falla en silencio) ─────────────── */
function vibrar(patron: number | number[]) {
  try {
    navigator.vibrate?.(patron);
  } catch {
    // Sin vibración no pasa nada: el flash y el sonido cuentan la historia.
  }
}

/* ── Sonido «transformer» sintetizado con WebAudio (sin archivos) ────────
   Impacto: golpe grave + chispa metálica de ruido + anillo de tres
   frecuencias que cuelan como máquina. Cierre: servo corto + clic. Si el
   navegador bloquea el audio sin gesto (la norma), se arma para sonar al
   primer toque dentro de la intro. */
function crearContextoAudio(): AudioContext | null {
  const AC =
    window.AudioContext ??
    (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!AC) return null;
  try {
    return new AC();
  } catch {
    return null;
  }
}

function sonidoImpacto(ctx: AudioContext) {
  try {
    const t = ctx.currentTime;
    const master = ctx.createGain();
    master.gain.value = 0.22;
    master.connect(ctx.destination);

    // Golpe grave que cae (el "¡PUM!" del cuerpo).
    const grave = ctx.createOscillator();
    grave.type = "sine";
    grave.frequency.setValueAtTime(210, t);
    grave.frequency.exponentialRampToValueAtTime(52, t + 0.28);
    const gGrave = ctx.createGain();
    gGrave.gain.setValueAtTime(0.9, t);
    gGrave.gain.exponentialRampToValueAtTime(0.001, t + 0.32);
    grave.connect(gGrave).connect(master);
    grave.start(t);
    grave.stop(t + 0.34);

    // Chispa metálica: ruido blanco con caída, filtrado agudo.
    const dur = 0.15;
    const ruido = ctx.createBuffer(1, Math.floor(ctx.sampleRate * dur), ctx.sampleRate);
    const canal = ruido.getChannelData(0);
    for (let i = 0; i < canal.length; i++) {
      canal[i] = (Math.random() * 2 - 1) * (1 - i / canal.length);
    }
    const chispa = ctx.createBufferSource();
    chispa.buffer = ruido;
    const agudo = ctx.createBiquadFilter();
    agudo.type = "highpass";
    agudo.frequency.value = 950;
    const gChispa = ctx.createGain();
    gChispa.gain.value = 0.75;
    chispa.connect(agudo).connect(gChispa).connect(master);
    chispa.start(t);

    // Anillo de máquina: tres metales que se apagan como transformer.
    [620, 935, 1185].forEach((f, i) => {
      const metal = ctx.createOscillator();
      metal.type = "triangle";
      metal.frequency.value = f;
      const gMetal = ctx.createGain();
      gMetal.gain.setValueAtTime(0.3 / (i + 1), t + 0.02);
      gMetal.gain.exponentialRampToValueAtTime(0.001, t + 0.6);
      metal.connect(gMetal).connect(master);
      metal.start(t + 0.02);
      metal.stop(t + 0.65);
    });
  } catch {
    // El audio nunca rompe la intro.
  }
}

function sonidoCierre(ctx: AudioContext) {
  try {
    const t = ctx.currentTime;
    const master = ctx.createGain();
    master.gain.value = 0.14;
    master.connect(ctx.destination);

    // Servo corto que sube (el guante "se encaja").
    const servo = ctx.createOscillator();
    servo.type = "square";
    servo.frequency.setValueAtTime(280, t);
    servo.frequency.exponentialRampToValueAtTime(860, t + 0.12);
    const gServo = ctx.createGain();
    gServo.gain.setValueAtTime(0.5, t);
    gServo.gain.exponentialRampToValueAtTime(0.001, t + 0.14);
    servo.connect(gServo).connect(master);
    servo.start(t);
    servo.stop(t + 0.16);

    // Clic de cierre.
    const clic = ctx.createOscillator();
    clic.type = "sine";
    clic.frequency.value = 1400;
    const gClic = ctx.createGain();
    gClic.gain.setValueAtTime(0.5, t + 0.1);
    gClic.gain.exponentialRampToValueAtTime(0.001, t + 0.18);
    clic.connect(gClic).connect(master);
    clic.start(t + 0.1);
    clic.stop(t + 0.2);
  } catch {
    // Silencio elegante.
  }
}

const CHISPAS = [
  { left: "calc(50% - 70px)", top: "60%", size: 4, delay: 0.56 },
  { left: "calc(50% - 34px)", top: "56%", size: 3, delay: 0.68 },
  { left: "calc(50% + 8px)", top: "62%", size: 5, delay: 0.6 },
  { left: "calc(50% + 46px)", top: "58%", size: 3, delay: 0.78 },
  { left: "calc(50% + 84px)", top: "63%", size: 4, delay: 0.72 },
  { left: "calc(50% - 8px)", top: "54%", size: 3, delay: 0.9 },
  { left: "calc(50% + 26px)", top: "64%", size: 4, delay: 0.98 },
] as const;

/**
 * La intro de estudio v3: POWER/BOX entran a golpes (flash + chispas +
 * vibración + sonido en el impacto) y el texto SE TRANSFORMA en el guante
 * volt de la marca, que aterriza con halo vivo y su servo de cierre.
 * Reglas de cine sin molestia:
 *  · ~2.5 segundos, se retira sola con fundido;
 *  · UNA vez por sesión (sessionStorage);
 *  · un toque en cualquier lado la salta (y dispara sonido/vibración si el
 *    navegador los tenía bloqueados);
 *  · con prefers-reduced-motion ni aparece.
 * Se monta sólo en la landing.
 */
export function IntroSplash() {
  const { locale, dict } = useDictionary();
  // SSR y primer render: nada (sin destello). El gate decide tras hidratar.
  const [fase, setFase] = useState<Fase>("fuera");
  const audioRef = useRef<AudioContext | null>(null);
  const impactoPendiente = useRef(false);

  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce || window.sessionStorage.getItem(KEY)) return;
    window.sessionStorage.setItem(KEY, "1");
    // eslint-disable-next-line react-hooks/set-state-in-effect -- gate síncrono a propósito (storage + motion), patrón del carrito
    setFase("montando");

    const tocarImpacto = () => {
      vibrar([60, 40, 140]);
      const ctx = audioRef.current ?? crearContextoAudio();
      audioRef.current = ctx;
      if (ctx) {
        if (ctx.state === "running") {
          sonidoImpacto(ctx);
        } else {
          // Bloqueado sin gesto: queda armado para el primer toque.
          impactoPendiente.current = true;
        }
      }
    };
    const tocarCierre = () => {
      vibrar(35);
      if (audioRef.current?.state === "running") sonidoCierre(audioRef.current);
    };

    const tImpacto = setTimeout(tocarImpacto, 520);
    const tCierre = setTimeout(tocarCierre, 1650);
    const salir = setTimeout(() => setFase("saliendo"), 2600);
    const fuera = setTimeout(() => setFase("fuera"), 3350);

    // Un toque dentro de la intro: salta la espera Y suelta lo bloqueado.
    const alTocar = () => {
      vibrar(40);
      if (impactoPendiente.current && audioRef.current) {
        impactoPendiente.current = false;
        sonidoImpacto(audioRef.current);
      }
    };
    window.addEventListener("pointerdown", alTocar, { once: true });

    return () => {
      clearTimeout(tImpacto);
      clearTimeout(tCierre);
      clearTimeout(salir);
      clearTimeout(fuera);
      window.removeEventListener("pointerdown", alTocar);
      void audioRef.current?.close().catch(() => {});
      audioRef.current = null;
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
      <span aria-hidden="true" className="intro-tick absolute top-5 left-5 size-7 border-t-2 border-l-2 border-brand/40" />
      <span aria-hidden="true" className="intro-tick absolute top-5 right-5 size-7 border-t-2 border-r-2 border-brand/40" />
      <span aria-hidden="true" className="intro-tick absolute bottom-5 left-5 size-7 border-b-2 border-l-2 border-brand/40" />
      <span aria-hidden="true" className="intro-tick absolute right-5 bottom-5 size-7 border-r-2 border-b-2 border-brand/40" />

      {/* Línea de escaneo que barre la pantalla */}
      <span
        aria-hidden="true"
        className="intro-escaneo absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-brand to-transparent"
      />

      {/* Chispas que suben del impacto */}
      <span aria-hidden="true">
        {CHISPAS.map((c, i) => (
          <span
            key={i}
            className="intro-chispa absolute rounded-full bg-brand shadow-[0_0_10px_rgba(200,247,59,0.9)]"
            style={{
              left: c.left,
              top: c.top,
              width: c.size,
              height: c.size,
              animationDelay: `${c.delay}s`,
            }}
          />
        ))}
      </span>

      {/* FLASH de pantalla en el impacto (blanco→volt→transparente) */}
      <span
        aria-hidden="true"
        className="intro-flash absolute inset-0 z-20 bg-[radial-gradient(circle_at_center,rgba(255,255,255,0.92),rgba(200,247,59,0.55)_45%,transparent_72%)]"
      />

      {/* La marca: entra a golpes y se transforma en el guante */}
      <div className="intro-golpe relative z-10 flex flex-col items-center px-6">
        <div className="intro-texto-fuera flex flex-col items-center">
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
        </div>

        <div className="flex flex-col items-center">
          <span className="relative grid place-items-center">
            <span aria-hidden="true" className="intro-halo absolute size-44 rounded-full bg-brand/25 blur-2xl" />
            <BrandMark className="intro-logo-in size-28 sm:size-36" />
          </span>
          <span className="intro-barra mt-6 h-[3px] w-[min(72vw,26rem)] origin-left bg-brand" />
          <span
            className="intro-sub mt-6 max-w-[86vw] text-center text-[0.625rem] font-semibold text-white/60 sm:text-[0.8125rem]"
            style={{ letterSpacing: "0.42em" }}
          >
            {sub}
          </span>
        </div>
      </div>
    </button>
  );
}
