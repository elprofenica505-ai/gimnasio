import type { Coach, GymClass, Plan } from "@/lib/types";

/**
 * ============================================================
 *  Contenido del gimnasio — VACÍO (instalación nueva)
 * ============================================================
 *  Se usa cuando Supabase todavía no está conectado (modo demo).
 *  Este repositorio es de un gimnasio NUEVO: no hereda disciplinas,
 *  planes ni precios del gimnasio anterior, así que las listas van
 *  vacías hasta que el dueño pase los datos reales (paso 5 de la
 *  personalización) o se carguen en Supabase desde el panel.
 *
 *  REGLA: acá no hay datos inventados. Lo que el gimnasio
 *  todavía no confirmó queda vacío y la web muestra «Consultar»
 *  o el estado vacío correspondiente.
 * ============================================================
 */

export const demoClasses: GymClass[] = [];

/**
 * Entrenadores. Vacíos hasta que el gimnasio pase los nombres
 * reales: preferimos no mostrar la sección antes que inventar
 * personas. Cargalos acá (o en Supabase) y la sección "Nuestro
 * equipo" aparece sola.
 */
export const demoCoaches: Coach[] = [];

/** Planes y precios: vacíos hasta la personalización del gimnasio. */
export const demoPlans: Plan[] = [];

/**
 * Galería de instalaciones. Las fotos viven en /public/images y se
 * reemplazan por las del gimnasio nuevo con los mismos nombres de
 * archivo (paso 6). Si cambiás una, mantené el mismo nombre.
 */
export const demoGallery = [
  { key: "sala2", src: "/images/sala2.jpg" },
  { key: "pesas", src: "/images/pesas.jpg" },
  { key: "sala1", src: "/images/sala1.jpg" },
  { key: "triceps", src: "/images/triceps.jpg" },
  { key: "pantorrilla", src: "/images/pantorrilla.jpg" },
  { key: "abs", src: "/images/abs.jpg" },
  { key: "dip", src: "/images/dip.jpg" },
] as const;

/** Suplementos y ropa que se venden en el local (genéricos). */
export const demoSupplements = [
  "proteina",
  "creatina",
  "preentreno",
  "aminoacidos",
  "ganador",
  "ropa",
] as const;

export type SupplementKey = (typeof demoSupplements)[number];
