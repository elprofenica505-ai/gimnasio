"use client";

import { useEffect, useRef, useState } from "react";
import { siteConfig } from "@/config/site";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { BrandMark } from "@/components/layout/brand-mark";
import { cn } from "@/lib/utils";

const KEY = "intro-v7";
/** El video termina en negro a los ~3.54s; el logo entra a los 3.2s. */
const LOGO_ENTRA_S = 3.2;

type Fase = "fuera" | "cine" | "logo" | "saliendo";

/* Vibración háptica: los navegadores SOLO la permiten después de un toque
 * del usuario (sticky activation — política de Chrome/Android e iOS).
 * Por eso se dispara en el toque, nunca al cargar: prometer vibración en
 * el arranque es imposible, y acá no mentimos. */
function vibrar(patron: number | number[]) {
  try {
    navigator.vibrate?.(patron);
  } catch {
    // Sin vibración no pasa nada.
  }
}

/**
 * La intro de CINE: reproduce un VIDEO REAL (public/video/intro.mp4, 30fps,
 * fabricado con los tres frames aprobados del storyboard: forja → explosión
 * → el ring, con zooms de cámara, cortes con flash, grano y letterbox).
 * Al fundirse el video a negro entra el logo real en el DOM y, tras un
 * aire, todo se funde y revela la portada.
 * Reglas de cine sin molestia:
 *  · ~5.5 segundos totales, se retira sola;
 *  · UNA vez por sesión (sessionStorage);
 *  · un toque la salta (y ahí sí vibra: ya hay gesto del usuario);
 *  · con prefers-reduced-motion ni aparece;
 *  · si el video no puede cargar, entra directo a la tarjeta del logo
 *    (nunca un slideshow roto).
 * Se monta sólo en la landing.
 */
export function IntroSplash() {
  const { locale, dict } = useDictionary();
  // SSR y primer render: nada (sin destello). El gate decide tras hidratar.
  const [fase, setFase] = useState<Fase>("fuera");
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const arrancóRef = useRef(false);

  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce || window.sessionStorage.getItem(KEY)) return;
    window.sessionStorage.setItem(KEY, "1");
    // eslint-disable-next-line react-hooks/set-state-in-effect -- gate síncrono a propósito (storage + motion), patrón del carrito
    setFase("cine");
  }, []);

  // Red de seguridad: si el video no arrancó (red lenta, autoplay bloqueado
  // en algún navegador exótico), entramos directo a la tarjeta del logo.
  useEffect(() => {
    if (fase !== "cine") return;
    const red = setTimeout(() => {
      if (!arrancóRef.current) setFase("logo");
    }, 1800);
    return () => clearTimeout(red);
  }, [fase]);

  // Anti-trabas: si el video se queda sin avanzar (buffering largo en red
  // floja), NO congelamos la intro — la saltamos elegante al logo.
  useEffect(() => {
    if (fase !== "cine") return;
    const video = videoRef.current;
    if (!video) return;
    let ultima = -1;
    const reloj = setInterval(() => {
      const t = video.currentTime;
      if (t === ultima && !video.ended) {
        setFase("logo");
      }
      ultima = t;
    }, 1200);
    return () => clearInterval(reloj);
  }, [fase]);

  useEffect(() => {
    if (fase !== "logo") return;
    const salir = setTimeout(() => setFase("saliendo"), 1500);
    const fuera = setTimeout(() => setFase("fuera"), 2200);
    return () => {
      clearTimeout(salir);
      clearTimeout(fuera);
    };
  }, [fase]);

  if (fase === "fuera") return null;

  return (
    <button
      type="button"
      aria-label={locale === "es" ? "Saltar la introducción" : "Skip intro"}
      onPointerDown={() => {
        // El toque es gesto real: acá la vibración SÍ está permitida.
        vibrar([60, 40, 140]);
        if (fase === "cine" || fase === "logo") setFase("saliendo");
      }}
      className={cn(
        "fixed inset-0 z-[90] flex w-full items-center justify-center overflow-hidden bg-night",
        fase === "saliendo" && "intro-saliendo pointer-events-none",
      )}
    >
      {/* La película (autoPlay silenciado es política-amigable en todos los
          navegadores, incluido iOS con playsInline). */}
      {fase !== "logo" ? (
        <video
          ref={videoRef}
          className="intro-video"
          src="/video/intro.mp4"
          poster="/images/intro/frag-forja.webp"
          muted
          autoPlay
          playsInline
          preload="auto"
          disablePictureInPicture
          aria-hidden="true"
          onPlaying={() => {
            arrancóRef.current = true;
          }}
          onCanPlay={() => {
            // Algunos navegadores necesitan el empujón explícito (muted lo
            // permite sin gesto en todos los modernos).
            void videoRef.current?.play().catch(() => {});
          }}
          onEnded={() => setFase("logo")}
          onTimeUpdate={() => {
            const t = videoRef.current?.currentTime ?? 0;
            if (t >= LOGO_ENTRA_S) setFase("logo");
          }}
          onError={() => setFase("logo")}
        />
      ) : null}

      {/* La resolución sobre el negro: el logo REAL de la marca */}
      {fase === "logo" || fase === "saliendo" ? (
        <span className="relative z-10 flex flex-col items-center px-6">
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
      ) : null}
    </button>
  );
}
