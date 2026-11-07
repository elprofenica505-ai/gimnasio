export const categories = {
  client: "Clientes",
  friend: "Clientes amigos",
  family: "Clientes familia Power Box",
} as const;
export type ClientCategory = keyof typeof categories;
/**
 * Categoría real del cliente (CLI-02): sale de la vigencia y de las reglas
 * editables, no de la etiqueta histórica de arriba.
 */
export const calculatedCategories = {
  strong_gym: "Power Box",
  familia: "Familia",
  amigo: "Amigo",
  comun: "Común",
} as const;
export type CalculatedCategory = keyof typeof calculatedCategories;
export type ClientStatus = "active" | "frozen" | "cancelled";
export interface GymClient {
  id: string;
  client_number: number;
  profile_id: string | null;
  full_name: string;
  phone: string | null;
  email: string | null;
  category: ClientCategory;
  /** Categoría calculada o fijada a mano (CLI-02). */
  category_calc?: CalculatedCategory | null;
  category_source?: "auto" | "manual" | null;
  /** `false` cuando la categoría se calculó al leer y todavía no se guardó. */
  category_saved?: boolean | null;
  status: ClientStatus;
  plan_id: string | null;
  /** Fecha local en que se congeló la ficha; vacía si nunca se congeló. */
  frozen_since?: string | null;
  notes: string;
  joined_on: string;
  created_at: string;
  updated_at?: string;
  is_demo: boolean;
  plan_name?: string;
  visits_30?: number;
  last_visit?: string | null;
  /** Vigencia por acceso (gimnasio y boxeo) calculada en el servidor. */
  plan_validity?: PlanValidity | null;
}
export type PlanAccessState = "active" | "upcoming" | "expired" | "none";
export interface PlanAccess {
  /** "gym" o el id de la disciplina. */
  key: string;
  /** Nombre visible del acceso: «Gimnasio» o el nombre de la disciplina. */
  label: string;
  state: PlanAccessState;
  plan_id: string | null;
  starts_on: string | null;
  expires_on: string | null;
  days_left: number;
}
export interface PlanSegment {
  id: string;
  plan_id: string;
  access: "gym" | "class";
  class_id: string | null;
  class_name: string | null;
  started_on: string;
  expires_on: string;
  price: number | string | null;
  currency: string;
}
export interface PlanValidity {
  today: string;
  gym: PlanAccess;
  /** Una fila por disciplina con plan configurado o vigencia registrada. */
  classes: PlanAccess[];
  segments: PlanSegment[];
}
export interface Visit {
  id: string;
  visited_at: string;
  local_day: string;
  source: "qr" | "manual";
}
export interface ClientEvent {
  id: string;
  action: string;
  created_at: string;
  details: Record<string, string>;
}
export interface ClientPayment {
  id: string;
  occurred_at: string;
  concept: string;
  amount: number;
  currency: string;
  status: string;
}
export interface ClientDetail {
  client: GymClient;
  card: string;
  visits: Visit[];
  events: ClientEvent[];
  payments: ClientPayment[];
  balance: number | null;
  finance?: unknown;
  finance_layout?: "repository" | "bank_accounts_split" | "unsupported";
  balances?: {
    credit_nio: number;
    credit_usd: number;
    debt_nio: number;
    debt_usd: number;
  } | null;
  plan_validity?: PlanValidity | null;
}
export interface Directory {
  rows: GymClient[];
  total: number;
}
export interface CrmOptions {
  payments_enabled: boolean;
  finance_layout?: string;
  payment_block_reason?: string | null;
  plans: {
    id: string;
    name_es: string;
    slug?: string;
    period?: string;
    /** Tarifa NIO opcional; la base puede devolverla como número o texto. */
    price_nio?: number | string | null;
    /** Vigencia definida para el plan; vacía si el plan no genera periodo. */
    access?: "gym" | "class" | null;
    class_id?: string | null;
    class_name?: string | null;
    duration_days?: number | null;
    validity_currency?: "NIO" | "USD" | null;
    validity_amount?: number | string | null;
  }[];
  methods: {
    id: string;
    name_es: string;
    accepts_nio: boolean;
    accepts_usd: boolean;
  }[];
  accounts: { id: string; name: string; currency: string }[];
}
const CARD_PREFIX = "strong-gym:client:";
export function cardPayload(token: string) {
  return `${CARD_PREFIX}${token}`;
}
export function parseCard(value: string): string | null {
  const match = value
    .trim()
    .match(
      /^strong-gym:client:([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/i,
    );
  return match?.[1]?.toLowerCase() ?? null;
}
/** Métrica explícita, no un juicio de valor ni una etiqueta comercial. */
export function frequency(visits: number): string {
  if (!visits) return "Sin visitas en 30 días";
  return `${visits} día${visits === 1 ? "" : "s"} en 30 días · ≈ ${((visits * 7) / 30).toFixed(1)} por semana`;
}
