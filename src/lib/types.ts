/** Tipos compartidos entre la capa de datos demo y Supabase. */

export type Intensity = "low" | "medium" | "high";

export type BookingStatus = "confirmed" | "cancelled" | "attended" | "no_show";

export type SessionStatus = "scheduled" | "cancelled";

export type UserRole = "member" | "cashier" | "trainer" | "admin" | "superadmin";

export interface GymClass {
  id: string;
  slug: string;
  name_es: string;
  name_en: string;
  description_es: string;
  description_en: string;
  intensity: Intensity;
  duration_min: number;
  capacity: number;
  /** Color de acento en hex, para las etiquetas. */
  color: string;
  sort_order: number;
  is_active: boolean;
}

export interface Coach {
  id: string;
  slug: string;
  name: string;
  role_es: string;
  role_en: string;
  bio_es: string;
  bio_en: string;
  /** Slugs de las disciplinas que dicta. */
  specialties: string[];
  initials: string;
  color: string;
  sort_order: number;
  is_active: boolean;
}

export interface Plan {
  id: string;
  slug: string;
  name_es: string;
  name_en: string;
  tagline_es: string;
  tagline_en: string;
  /** Precio en USD. `null` = todavía no publicado: la web muestra "Consultar". */
  price: number | null;
  /**
   * Tarifa opcional en córdobas (NIO), separada del precio histórico en USD.
   * La usan las tarifas de pesas y máquinas para recepción y para mostrar C$
   * en la web. Puede venir como texto desde la base; quien la muestre debe
   * convertirla.
   */
  price_nio?: number | string | null;
  /** Cada cuánto se paga: "month" | "week" | "fortnight" | "session" */
  period: "month" | "week" | "fortnight" | "session";
  features_es: string[];
  features_en: string[];
  is_popular: boolean;
  sort_order: number;
  is_active: boolean;
}

/** Una clase con fecha y hora concretas. */
export interface Session {
  id: string;
  class_id: string;
  coach_id: string | null;
  /** ISO 8601 en UTC. */
  starts_at: string;
  ends_at: string;
  capacity: number;
  room: string;
  status: SessionStatus;
}

/** Sesión ya "resuelta": incluye la clase y el profe. */
export interface SessionDetail extends Session {
  gymClass: GymClass;
  coach: Coach | null;
  bookedCount: number;
  spotsLeft: number;
}

export interface Booking {
  id: string;
  session_id: string;
  user_id: string;
  status: BookingStatus;
  created_at: string;
  cancelled_at: string | null;
}

export interface BookingDetail extends Booking {
  session: SessionDetail;
}

export interface Profile {
  id: string;
  full_name: string;
  email: string;
  phone: string | null;
  role: UserRole;
  plan_id: string | null;
  created_at: string;
}

export interface ContactMessage {
  id: string;
  name: string;
  email: string;
  phone: string | null;
  subject: string;
  message: string;
  locale: string;
  is_read: boolean;
  created_at: string;
}

/** Semana del calendario: lunes a domingo. */
export interface WeekRange {
  /** Lunes de la semana, a las 00:00 en la zona del gimnasio. */
  start: Date;
  /** Domingo de la semana, a las 23:59:59 en la zona del gimnasio. */
  end: Date;
  /** Clave ISO de la semana, ej: "2026-W42". */
  key: string;
}
