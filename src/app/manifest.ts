import type { MetadataRoute } from "next";
import { siteConfig } from "@/config/site";

/**
 * Manifiesto PWA.
 *
 * El sitio se puede "instalar" en el celu porque cumple los requisitos de
 * una Web App Progresiva: tiene manifest válido, service worker y se sirve
 * por HTTPS. Los íconos grandes son la foto real del emblema del gimnasio
 * (la imagen del cartel iluminado del local); el SVG se conserva como
 * favicon en la pestaña del navegador.
 *
 * `purpose: "maskable"` cubre Android, que recorta los íconos a un círculo
 * con un margen de seguridad interno (el emblema ya tiene padding).
 * `background_color: "#0c0c0e"` coincide con el `paper` del tema oscuro,
 * así la pantalla de splash de Android no parpadea.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: siteConfig.name,
    short_name: siteConfig.shortName,
    description:
      "Gimnasio en Managua: pesas y máquinas, boxeo, bailoterapia y suplementos.",
    start_url: "/es",
    // Alcance sólo de la parte pública en español. Así los enlaces de correo
    // (p. ej. /api/auth/callback de recuperación) se abren en el navegador y
    // no dentro de la app instalada, que perdería el código del navegador.
    scope: "/es",
    display: "standalone",
    display_override: ["standalone", "browser"],
    orientation: "portrait",
    background_color: "#0c0c0e",
    theme_color: "#d81a22",
    lang: "es",
    dir: "ltr",
    categories: ["health", "fitness", "sports"],
    icons: [
      // SVG liviano para la pestaña y los lugares que acepten vectorial.
      { src: "/icon.svg", sizes: "any", type: "image/svg+xml" },
      // Foto real del emblema, en todos los tamaños que pide la spec.
      {
        src: "/icons/icon-192.png",
        sizes: "192x192",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icons/icon-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "any",
      },
      // `maskable` le da a Android el margen de seguridad para recortar
      // a círculo sin pisar el contenido.
      {
        src: "/icons/maskable-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable",
      },
      // Apple (iOS y iPadOS) ignoran el resto y piden este archivo.
      {
        src: "/icons/apple-touch-icon.png",
        sizes: "180x180",
        type: "image/png",
        purpose: "any",
      },
    ],
    shortcuts: [
      {
        name: "Horarios",
        short_name: "Horarios",
        description: "Reservá tu lugar en las clases de la semana.",
        url: "/es/horarios",
        icons: [{ src: "/icons/icon-192.png", sizes: "192x192" }],
      },
      {
        name: "Planes",
        short_name: "Planes",
        description: "Conocé los planes y precios del gimnasio.",
        url: "/es#planes",
        icons: [{ src: "/icons/icon-192.png", sizes: "192x192" }],
      },
    ],
  };
}
