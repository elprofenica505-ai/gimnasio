/**
 * ============================================================
 *  POWER BOX GYM — datos del gimnasio
 * ============================================================
 *  Todos los datos "de negocio" están acá: nombre, dirección,
 *  teléfono, redes, horarios y moneda. Cambiá lo que necesites
 *  y el sitio entero se actualiza.
 *
 *  Los campos en `null` son datos que todavía no tenemos
 *  confirmados: la web los oculta sola en vez de inventarlos.
 */

/** Un tramo de atención: de `opens` a `closes`, hora local del gimnasio. */
export interface OpeningSlot {
  opens: string;
  closes: string;
}

export const siteConfig = {
  /**
   * Marca de quien desarrolló el sistema (pie de página: «Desarrollado por …»).
   * Para cambiarla sin tocar el código, define NEXT_PUBLIC_DEVELOPER_BRAND en Vercel y vuelve a publicar.
   */
  developerBrand: process.env.NEXT_PUBLIC_DEVELOPER_BRAND || "El Profe Nica 505",
  name: "Power Box Gym",
  shortName: "Power Box",
  /** Razón social. Si no hay una distinta, se usa el nombre comercial. */
  legalName: "Power Box Gym",
  /** Dominio propio. Mientras no haya uno, se usa la URL del hosting. */
  domain: null as string | null,
  /** URL pública confirmada del hosting, también para builds sin variables de Vercel. */
  productionUrl: "https://gimnasio-wheat.vercel.app",

  /** Email de contacto. Null = el sitio muestra WhatsApp en su lugar. */
  contactEmail: null as string | null,

  /** Número visible, tal como lo da el gimnasio. */
  phone: "8827 6908",
  /** El mismo número en formato internacional. */
  phoneIntl: "+505 8827 6908",
  /** Sólo dígitos, con código de país. Se usa para el link de WhatsApp. */
  whatsapp: "50588276908",

  address: {
    street: "Calle principal (dirección por confirmar)",
    city: "Managua",
    region: "Managua",
    country: "Nicaragua",
    /** Sin código postal confirmado. */
    postalCode: null as string | null,
  },

  /** Ubicación exacta en Google Maps (link que compartió el gimnasio). */
  mapsUrl: null as string | null,
  /** Coordenadas. Null = no las publicamos en los datos estructurados. */
  geo: null as { lat: number; lng: number } | null,

  /**
   * Zona horaria del gimnasio. Se usa para calcular "hoy" y para
   * mostrar los horarios de las clases.
   */
  timezone: "America/Managua",
  /** Diferencia con UTC en minutos (Managua = UTC-6). Sin DST. */
  utcOffsetMinutes: -360,

  /** Moneda de los planes. */
  currency: { code: "USD", symbol: "$", decimals: 0 },

  social: {
    /** Pendiente: el gimnasio todavía no pasó la página de Facebook. */
    facebook: null as string | null,
    /** Pendiente: el gimnasio todavía no pasó el usuario de Instagram. */
    instagram: null as string | null,
    tiktok: null as string | null,
    youtube: null as string | null,
  },

  /**
   * Horario de atención, por día de la semana (0 = lunes … 6 = domingo).
   * Un día sin tramos está CERRADO. El domingo no se abre.
   */
  openingHours: [
    [{ opens: "06:00", closes: "20:00" }], // Lunes
    [{ opens: "06:00", closes: "20:00" }], // Martes
    [{ opens: "06:00", closes: "20:00" }], // Miércoles
    [{ opens: "06:00", closes: "20:00" }], // Jueves
    [{ opens: "06:00", closes: "20:00" }], // Viernes
    [{ opens: "08:00", closes: "13:00" }], // Sábado
    [], // Domingo: CERRADO
  ] as readonly (readonly OpeningSlot[])[],

  /** Cuántas horas antes de una clase se puede cancelar sin penalidad. */
  cancellationWindowHours: 3,

  /** Si el gimnasio regala la primera clase. Sin confirmar: apagado. */
  freeTrialClass: false,
} as const;

export type SiteConfig = typeof siteConfig;

/** Dirección completa en una línea. */
export function fullAddress(): string {
  const { street, city, region, country } = siteConfig.address;
  return `${street}, ${city}, ${region}, ${country}`;
}

/** URL pública/canónica. Un Preview no debe convertirse en el dominio público. */
export function getSiteUrl(): string {
  const fromEnv = process.env.NEXT_PUBLIC_SITE_URL?.trim();
  if (fromEnv) {
    const host = new URL(fromEnv).hostname.toLowerCase();
    const local = host === "localhost" || host.endsWith(".localhost") ||
      host === "127.0.0.1" || host === "[::1]";
    // Evita publicar localhost si se copió el antiguo .env.example a producción.
    if (process.env.NODE_ENV !== "production" || !local) return fromEnv.replace(/\/$/, "");
  }
  if (process.env.VERCEL_PROJECT_PRODUCTION_URL) {
    return `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`;
  }
  if (siteConfig.domain) return `https://${siteConfig.domain}`;
  return process.env.NODE_ENV === "development"
    ? "http://localhost:3000"
    : siteConfig.productionUrl;
}

export function whatsappLink(message?: string): string {
  const base = `https://wa.me/${siteConfig.whatsapp}`;
  return message ? `${base}?text=${encodeURIComponent(message)}` : base;
}

/** Link para abrir la ubicación en la app de mapas. */
export function mapsLink(): string {
  if (siteConfig.mapsUrl) return siteConfig.mapsUrl;
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(fullAddress())}`;
}

/** Mapa embebido. Busca por dirección: no necesitamos inventar coordenadas. */
export function mapsEmbedUrl(): string {
  if (siteConfig.geo) {
    const { lat, lng } = siteConfig.geo;
    return `https://www.google.com/maps?q=${lat},${lng}&z=15&output=embed`;
  }
  return `https://www.google.com/maps?q=${encodeURIComponent(fullAddress())}&z=14&output=embed`;
}

/**
 * Formatea un precio en la moneda configurada (USD).
 * Si el plan todavía no tiene precio publicado devuelve null, y la
 * tarjeta muestra "Consultar" en vez de un número inventado.
 */
export function formatPrice(value: number | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  const { symbol, decimals } = siteConfig.currency;
  const formatted = value.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
  return `${symbol}${formatted}`;
}

/* ------------------------------------------------------------
   Horarios: utilidades para mostrarlos y saber si está abierto
   ------------------------------------------------------------ */

const DAY_NAMES_ES = [
  "Lunes",
  "Martes",
  "Miércoles",
  "Jueves",
  "Viernes",
  "Sábado",
  "Domingo",
] as const;

const DAY_NAMES_EN = [
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
  "Sunday",
] as const;

/** Nombres de día tal como los espera schema.org. */
export const SCHEMA_DAYS = DAY_NAMES_EN;

export function dayName(dayIndex: number, locale: string): string {
  return locale === "es" ? DAY_NAMES_ES[dayIndex] : DAY_NAMES_EN[dayIndex];
}

/** "06:00 — 21:00" o "08:00 — 12:00 y 13:00 — 18:00". Vacío = cerrado. */
export function formatDaySlots(
  slots: readonly OpeningSlot[],
  locale: string,
): string {
  if (slots.length === 0) return locale === "es" ? "Cerrado" : "Closed";
  const join = locale === "es" ? " y " : " and ";
  return slots.map((slot) => `${slot.opens} — ${slot.closes}`).join(join);
}

/**
 * Agrupa los días con el mismo horario para mostrarlos compactos:
 * "Lunes a viernes · 06:00 — 21:00".
 */
export function openingHoursSummary(
  locale: string,
): { days: string; hours: string }[] {
  const rows: { days: string; hours: string }[] = [];
  const to = locale === "es" ? " a " : " to ";

  let groupStart = 0;
  const key = (i: number) => JSON.stringify(siteConfig.openingHours[i]);

  for (let i = 1; i <= 7; i++) {
    if (i < 7 && key(i) === key(groupStart)) continue;

    const slots = siteConfig.openingHours[groupStart];
    const days =
      i - 1 === groupStart
        ? dayName(groupStart, locale)
        : `${dayName(groupStart, locale)}${to}${dayName(i - 1, locale).toLowerCase()}`;

    rows.push({ days, hours: formatDaySlots(slots, locale) });
    groupStart = i;
  }

  return rows;
}

/** ¿Está abierto el gimnasio en este momento? */
export function isOpenAt(date: Date): boolean {
  // getDay(): 0 = domingo. Nuestra tabla arranca en lunes.
  const dayIndex = (date.getDay() + 6) % 7;
  const minutes = date.getHours() * 60 + date.getMinutes();

  return siteConfig.openingHours[dayIndex].some((slot) => {
    const [oh, om] = slot.opens.split(":").map(Number);
    const [ch, cm] = slot.closes.split(":").map(Number);
    return minutes >= oh * 60 + om && minutes < ch * 60 + cm;
  });
}
