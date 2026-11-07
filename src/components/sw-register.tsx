"use client";

import { useEffect } from "react";

/**
 * Registra el service worker que vive en /sw.js.
 *
 * - Solo en producción (en dev el navegador cachea de más y hace
 *   debugging imposible).
 * - Si el navegador no soporta SW (todavía quedan algunos viejos en
 *   iOS), no hace nada.
 * - Si falla el registro (red, CSP), tampoco pasa nada: la app sigue
 *   funcionando normal, simplemente no abre offline.
 */
export function SwRegister() {
  useEffect(() => {
    if (process.env.NODE_ENV !== "production") return;
    if (typeof window === "undefined") return;
    if (!("serviceWorker" in navigator)) return;

    // Lo registramos después de que cargue la página, así no bloqueamos
    // el primer render.
    const onLoad = () => {
      navigator.serviceWorker
        .register("/sw.js", { scope: "/" })
        .catch((err) => {
          // Silencioso: el service worker es una mejora progresiva, no
          // un requisito para que la app funcione.
          console.warn("[Power Box Gym] SW no se pudo registrar:", err.message);
        });
    };

    if (document.readyState === "complete") {
      onLoad();
    } else {
      window.addEventListener("load", onLoad, { once: true });
    }

    return () => {
      window.removeEventListener("load", onLoad);
    };
  }, []);

  return null;
}
