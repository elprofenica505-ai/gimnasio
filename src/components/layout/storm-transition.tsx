"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { usePathname } from "next/navigation";
import Image from "next/image";

/**
 * Transición de tormenta a pantalla completa.
 *
 * El problema: al cambiar de módulo, Next tiene que renderizar la pantalla en el
 * servidor y en el celular se ve un instante de quietud. Esa pausa parece que la
 * app se colgó y la gente toca otra vez.
 *
 * Lo que hace: cubre **toda** la interfaz con una noche de tormenta —cielo
 * oscuro, nubes que se mueven, relámpagos que caen y el destello que ilumina
 * todo— junto al emblema, «Cargando…» y la barra de carga. Se retira sola
 * cuando la pantalla nueva está lista.
 *
 * Los rayos son trazos en zigzag dibujados en SVG, con ramificaciones, cada uno
 * con su propio ritmo: el rayo principal cae, el cielo destella, y a los pocos
 * instantes otro rayo cae en otro lado. Es el efecto de una tormenta, no una
 * imagen con destellos de brillo.
 *
 * Se enciende **sólo si de verdad hay espera**: espera 120 ms antes de
 * aparecer. Una vez encendida dura al menos 1.1 s —tiempo suficiente para ver
 * caer uno o dos rayos— y se apaga en 320 ms.
 *
 * Reglas que respeta:
 *   · Se activa con un toque en un enlace interno, con «atrás» del navegador o
 *     al volver desde otra app.
 *   · No se queda pegada: si la pantalla nueva no llega en 8 segundos, se apaga.
 *   · Mientras cubre no deja tocar lo de abajo: no se abre dos veces.
 *   · No usa `filter` ni `backdrop-filter`: en celulares Android eso deja
 *     manchas y borrones de GPU. Todo son degradados, trazos y movimientos.
 */

/** Espera antes de mostrar la capa: si la pantalla abre antes, ni se ve. */
const SHOW_DELAY_MS = 120;
/**
 * Mínimo en pantalla una vez visible. No es capricho: con menos de un segundo
 * el ojo no alcanza a ver caer un rayo y la capa parece una imagen fija.
 */
const MIN_VISIBLE_MS = 1_100;
/** Desvanecido de salida. */
const FADE_OUT_MS = 320;
/** Si la pantalla nueva no llega, se apaga sola. */
const GIVE_UP_MS = 8_000;
/** «Atrás» con la misma ruta no debe quedarse colgada los 8 s completos. */
const POPSTATE_GIVE_UP_MS = 3_000;
/** Cada cuánto se mira si la dirección ya cambió. */
const POLL_MS = 160;

/**
 * Generador pseudoaleatorio con semilla.
 *
 * Los rayos tienen que ser los mismos en el servidor y en el celular: si se
 * sortearan al dibujar, React encontraría dos árboles distintos y se quejaría
 * al hidratar. Con semilla, la geometría es idéntica siempre.
 */
function seeded(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Un rayo en zigzag, en coordenadas de 0 a 100 (por ciento de la pantalla).
 *
 * Se baja en tramos: en cada paso el trazo se corre a un lado y vuelve, que es
 * lo que le da el quiebre del relámpago. Al final se afina hasta un punto.
 */
function boltPath(
  rnd: () => number,
  from: [number, number],
  to: [number, number],
  steps: number,
  jitter: number,
): string {
  const points: Array<[number, number]> = [from];
  for (let i = 1; i < steps; i += 1) {
    const t = i / steps;
    const x = from[0] + (to[0] - from[0]) * t + (rnd() - 0.5) * jitter;
    const y = from[1] + (to[1] - from[1]) * t;
    points.push([x, y]);
  }
  points.push(to);
  return points
    .map(([x, y], index) => `${index === 0 ? "M" : "L"} ${x.toFixed(2)} ${y.toFixed(2)}`)
    .join(" ");
}

type Bolt = {
  /** Trazo principal. */
  main: string;
  /** Ramificaciones que salen del principal. */
  branches: string[];
  /** Espera entre descargas, en segundos. */
  dur: number;
  /** Desfase para que no caigan todos a la vez. */
  delay: number;
};

/** Un rayo con sus ramificaciones. */
function makeBolt(
  seed: number,
  x: number,
  endX: number,
  endY: number,
  steps: number,
  jitter: number,
  dur: number,
  delay: number,
): Bolt {
  const rnd = seeded(seed);
  const from: [number, number] = [x, -6];
  const to: [number, number] = [endX, endY];
  const main = boltPath(rnd, from, to, steps, jitter);

  const branches: string[] = [];
  const count = 2 + Math.floor(rnd() * 2);
  for (let b = 0; b < count; b += 1) {
    const t = 0.25 + rnd() * 0.55;
    const startX = from[0] + (to[0] - from[0]) * t + (rnd() - 0.5) * jitter * 0.6;
    const startY = from[1] + (to[1] - from[1]) * t;
    const dir = rnd() > 0.5 ? 1 : -1;
    const length = 8 + rnd() * 16;
    const end: [number, number] = [
      startX + dir * length,
      startY + 6 + rnd() * 14,
    ];
    branches.push(boltPath(rnd, [startX, startY], end, 4 + Math.floor(rnd() * 3), jitter * 0.8));
  }

  return { main, branches, dur, delay };
}

/** Los tres rayos: uno largo a la derecha del emblema y dos laterales cortos. */
const BOLTS: readonly Bolt[] = [
  // El principal cae apenas aparece la capa: como el aviso dura poco más de un
  // segundo, el rayo tiene que golpear dentro de ese rato.
  makeBolt(7, 72, 66, 76, 11, 9, 3.2, 0),
  makeBolt(23, 18, 11, 52, 8, 6, 3.7, -1.3),
  makeBolt(41, 84, 90, 46, 8, 6, 4.1, -2.4),
];

/** Un enlace que lleva a otra pantalla de esta misma app. */
function navigationTarget(event: MouseEvent): string | null {
  if (event.defaultPrevented) return null;
  // Sólo el toque normal: nada de Ctrl/Cmd, botón del medio ni rueda.
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
    return null;
  const target = event.target;
  if (!(target instanceof Element)) return null;
  const anchor = target.closest("a");
  if (!anchor) return null;
  if (anchor.target && anchor.target !== "_self") return null;
  if (anchor.hasAttribute("download")) return null;
  const href = anchor.getAttribute("href");
  if (!href) return null;

  let url: URL;
  try {
    url = new URL(href, window.location.href);
  } catch {
    return null;
  }
  if (url.origin !== window.location.origin) return null;
  // Mismo destino exacto (o sólo un ancla): no hay pantalla que esperar.
  const here = `${window.location.pathname}${window.location.search}`;
  if (`${url.pathname}${url.search}` === here) return null;
  return `${url.pathname}${url.search}`;
}

/**
 * Sonido de la transición: el trueno.
 *
 * Sólo suena el estruendo que acompaña al rayo; **los demás toques van en
 * silencio**. Se probaron «tics» de app para confirmar cada toque y al gimnasio
 * no le gustaron, así que se retiraron: menos es más, y el navegador queda
 * limpio de ruido.
 *
 * Lo que **no** se puede perder:
 *  - **Se dispara dentro del toque**, no después. iPhone y Android sólo dejan
 *    sonar el audio que nace de un gesto; si se pide un instante más tarde, el
 *    navegador lo bloquea sin avisar y la pantalla queda muda.
 *  - **No depende de «reducir movimiento»**: esa opción apaga el movimiento,
 *    no el sonido; colgarlo de ahí dejaba muda a media app.
 *  - **No se amontona**: si alguien navega rápido, el trueno entra cada tanto
 *    y no cinco veces seguidas.
 * Si el teléfono está en silencio o el archivo no baja, la animación sigue
 * igual: el sonido es un adorno, nunca un requisito.
 */
const THUNDER_SRC = "/sounds/trueno.mp3";
/** Entre trueno y trueno. */
const THUNDER_GAP_MS = 18_000;
const THUNDER_VOLUME = 0.55;

let thunder: HTMLAudioElement | null = null;
let lastThunderAt = 0;

/** El audio del trueno, creado una sola vez y colgado del documento. */
function thunderAudio(): HTMLAudioElement | null {
  if (typeof window === "undefined") return null;
  if (!thunder) {
    thunder = new Audio(THUNDER_SRC);
    thunder.preload = "auto";
    thunder.volume = THUNDER_VOLUME;
    // Colgado del documento, oculto: iPhone viejo se niega a reproducir un
    // audio que no está en la página.
    thunder.style.display = "none";
    document.body.appendChild(thunder);
  }
  return thunder;
}

/** Deja el trueno cargando desde el principio: son 12 KB. */
function warmSound() {
  thunderAudio();
}

/** Suena el trueno. Se llama SIEMPRE dentro del toque. */
function playStormSound() {
  if (typeof document === "undefined" || document.hidden) return;
  const audio = thunderAudio();
  if (!audio) return;
  const now = Date.now();
  if (now - lastThunderAt < THUNDER_GAP_MS) return;
  lastThunderAt = now;
  try {
    audio.currentTime = 0;
  } catch {
    // Algunos navegadores no dejan mover el cursor antes de cargar: da igual.
  }
  void audio.play().catch(() => {
    // No sonó: se suelta el freno para que el próximo toque lo reintente.
    lastThunderAt = 0;
  });
}

type Phase = "idle" | "shown" | "leaving";

/** Un rayo dibujado: tres trazos superpuestos dan el brillo sin ningún filtro. */
function LightningBolt({ bolt }: { bolt: Bolt }) {
  return (
    <g
      className="storm-bolt"
      style={{ "--bolt-dur": `${bolt.dur}s`, "--bolt-delay": `${bolt.delay}s` } as CSSProperties}
    >
      {[bolt.main, ...bolt.branches].map((d, index) => (
        <g key={`stroke-${index}`}>
          <path d={d} className="storm-stroke storm-stroke--halo" />
          <path d={d} className="storm-stroke storm-stroke--glow" />
          <path d={d} className="storm-stroke storm-stroke--core" />
        </g>
      ))}
    </g>
  );
}

export function StormTransition() {
  const [phase, setPhase] = useState<Phase>("idle");
  const pathname = usePathname();
  // Los tiempos y el destino viven en refs: así el efecto no se vuelve a montar
  // en cada cambio de estado ni pierde un toque por culpa de un cierre viejo.
  const phaseRef = useRef<Phase>("idle");
  /** Ruta que había cuando se encendió: cuando cambie, la pantalla ya llegó. */
  const startedPath = useRef<string | null>(null);
  /** Última ruta que vio React. Se lee al encender, sin volver a montar nada. */
  const pathnameRef = useRef<string | null>(pathname ?? null);
  /** El apagado del efecto principal, para poder llamarlo desde fuera. */
  const hideRef = useRef<() => void>(() => {});

  // El trueno se deja cargando desde el principio: así el primer golpe no
  // llega tarde ni se queda mudo por no haber terminado de bajar.
  useEffect(() => {
    warmSound();
  }, []);

  useEffect(() => {
    let target: string | null = null;
    let shownAt = 0;
    let revealTimer: ReturnType<typeof setTimeout> | null = null;
    let poll: ReturnType<typeof setInterval> | null = null;
    let giveUp: ReturnType<typeof setTimeout> | null = null;
    let hideDelay: ReturnType<typeof setTimeout> | null = null;
    let fadeTimer: ReturnType<typeof setTimeout> | null = null;

    const clearTimers = () => {
      if (revealTimer) clearTimeout(revealTimer);
      if (poll) clearInterval(poll);
      if (giveUp) clearTimeout(giveUp);
      if (hideDelay) clearTimeout(hideDelay);
      if (fadeTimer) clearTimeout(fadeTimer);
      revealTimer = poll = giveUp = hideDelay = fadeTimer = null;
    };

    const goIdle = () => {
      clearTimers();
      target = null;
      startedPath.current = null;
      phaseRef.current = "idle";
      setPhase("idle");
    };

    const fadeOut = () => {
      if (phaseRef.current !== "shown") return goIdle();
      if (poll) clearInterval(poll);
      if (giveUp) clearTimeout(giveUp);
      if (revealTimer) clearTimeout(revealTimer);
      poll = giveUp = revealTimer = null;
      phaseRef.current = "leaving";
      setPhase("leaving");
      fadeTimer = setTimeout(goIdle, FADE_OUT_MS);
    };

    /** La pantalla nueva ya tomó el control: se retira, respetando el mínimo. */
    const hide = () => {
      // Todavía no se había mostrado: fue tan rápido que no hace falta enseñarla.
      if (phaseRef.current !== "shown") return goIdle();
      if (hideDelay) return;
      const remaining = MIN_VISIBLE_MS - (Date.now() - shownAt);
      hideDelay = setTimeout(fadeOut, Math.max(0, remaining));
    };
    hideRef.current = hide;

    const reveal = () => {
      revealTimer = null;
      if (phaseRef.current !== "idle") return;
      phaseRef.current = "shown";
      shownAt = Date.now();
      setPhase("shown");
    };

    /**
     * `destination` es la dirección del enlace tocado. Con «atrás» no la
     * sabemos (el navegador ya cambió la barra de direcciones), así que se pasa
     * `null` y el apagado lo resuelve el cambio de ruta de React.
     */
    const start = (destination: string | null, giveUpAfter = GIVE_UP_MS) => {
      // Dentro del mismo toque: así el navegador deja sonar el sonido.
      playStormSound();
      // Si venía saliendo, se reinicia limpio para la pantalla nueva.
      if (phaseRef.current === "leaving") goIdle();
      if (phaseRef.current === "shown") return;
      clearTimers();
      target = destination;
      // La ruta del hook todavía es la vieja: cuando cambie, se apaga.
      startedPath.current = pathnameRef.current;

      // Se vigila desde el primer instante: si la pantalla llega antes del
      // retardo, no se muestra nada.
      poll = setInterval(() => {
        if (target === null) return;
        const here = `${window.location.pathname}${window.location.search}`;
        if (here === target) hide();
      }, POLL_MS);
      giveUp = setTimeout(() => {
        hideDelay = null;
        fadeOut();
      }, giveUpAfter);
      revealTimer = setTimeout(reveal, SHOW_DELAY_MS);
    };

    const onClick = (event: MouseEvent) => {
      const destination = navigationTarget(event);
      if (destination) start(destination);
    };
    // «Atrás» y «adelante» no disparan un toque, y el navegador ya cambió la
    // dirección antes de avisar: la pantalla nueva se detecta por el cambio de
    // ruta. Si esa ruta no cambia (sólo cambió la consulta), no se le deja
    // colgada los 8 segundos completos.
    const onPopState = () => start(null, POPSTATE_GIVE_UP_MS);
    // Al volver de otra app, o si el navegador restaura la página, se apaga.
    const onShow = () => goIdle();

    document.addEventListener("click", onClick, true);
    window.addEventListener("popstate", onPopState);
    window.addEventListener("pageshow", onShow);

    return () => {
      document.removeEventListener("click", onClick, true);
      window.removeEventListener("popstate", onPopState);
      window.removeEventListener("pageshow", onShow);
      clearTimers();
    };
  }, []);

  // La pantalla nueva ya se dibujó: la ruta del hook cambió. Esto es lo que
  // apaga la capa cuando se vuelve con «atrás», donde no hay enlace que seguir.
  useEffect(() => {
    pathnameRef.current = pathname ?? null;
    if (startedPath.current === null) return;
    if (pathname && pathname !== startedPath.current) hideRef.current();
  }, [pathname]);

  if (phase === "idle") return null;

  return (
    <div
      className="storm-overlay"
      data-state={phase}
      role="status"
      aria-live="polite"
      aria-label="Cargando la pantalla"
    >
      {/* La tormenta: cielo con nubes, tres rayos que caen y el destello que
          ilumina la pantalla. Todo son degradados, trazos y movimientos. */}
      <div className="storm-stage" aria-hidden="true">
        <div className="storm-sky" />
        <div className="storm-clouds" />

        <svg className="storm-bolts" viewBox="0 0 100 100" preserveAspectRatio="none" focusable="false">
          {BOLTS.map((bolt, index) => (
            <LightningBolt key={`bolt-${index}`} bolt={bolt} />
          ))}
        </svg>

        <div className="storm-flash" />
        <div className="storm-horizon" />
      </div>

      <div className="storm-content">
        <span className="storm-halo" aria-hidden="true" />
        {/* El emblema del gimnasio: guante rojo. Va como imagen fija para
            que no dependa de ningún dibujo que haya que recalcular en cada
            visita. Sin `drop-shadow`: es un filtro, y en Android los filtros
            dejan manchas. */}
        <Image
          src="/brand/emblema.webp"
          alt=""
          width={408}
          height={444}
          priority
          sizes="(max-width: 640px) 48vw, 12rem"
          className="storm-emblem"
        />
        <p className="storm-title">Power Box Gym</p>
        <p className="storm-loading">Cargando…</p>
        {/* Barra de carga: el tramo dorado recorre el riel mientras se espera. */}
        <span className="storm-progress" aria-hidden="true">
          <span className="storm-progress-fill" />
        </span>
      </div>
    </div>
  );
}
