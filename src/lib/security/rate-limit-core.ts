import { createHash } from "node:crypto";

/**
 * Parte pura del límite de abuso (SEG-07): lo que se puede probar sin
 * servidor. El resto —hablar con la base y armar la respuesta HTTP— vive en
 * `rate-limit.ts`.
 *
 * Antes el contador vivía en la memoria de **cada instancia**: con dos
 * instancias —o después de un despliegue, que arranca procesos nuevos— el
 * conteo volvía a cero. Ahora cuenta la base y el límite es el mismo para
 * todas.
 */

export type RateRule = { limit: number; windowMs: number };

export type LimitDecision = {
  allowed: boolean;
  /** Segundos que faltan para reintentar (0 si pasa). */
  retryAfterSeconds: number;
  /** De dónde salió la decisión: base compartida o memoria de esta instancia. */
  source: "shared" | "memory";
};

/**
 * Hash estable de la llave. El prefijo del scope y la sal evitan que dos rutas
 * compartan contador aunque la llave coincida. Lo que se guarda en la base es
 * este hash: **nunca** una IP ni un correo.
 */
export function hashKey(scope: string, raw: string, salt = "strong-gym"): string {
  return createHash("sha256").update(`${salt}:${scope}:${raw}`).digest("hex").slice(0, 60);
}

/**
 * Lee la respuesta de `rate_limit_hit`. Si viene rara (base vieja, RPC que
 * devuelve otra cosa) se devuelve `null` y quien llama usa el respaldo en
 * memoria: un límite mal leído no puede convertirse en una app trabada.
 */
export function parseDecision(value: unknown): LimitDecision | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  if (typeof row.allowed !== "boolean") return null;
  const retry = Number(row.retry_after_seconds);
  return {
    allowed: row.allowed,
    retryAfterSeconds: row.allowed
      ? 0
      : Math.max(1, Math.min(Number.isFinite(retry) ? retry : 60, 86_400)),
    source: "shared",
  };
}

/** Segundos de la ventana, con un mínimo de uno. */
export function windowSeconds(rule: RateRule): number {
  return Math.max(1, Math.round(rule.windowMs / 1000));
}

/** Texto para la persona que se pasó de rápido (el número va en la interfaz). */
export function retryText(template: string, retryAfterSeconds: number): string {
  return template.replace("{seconds}", String(Math.max(1, Math.round(retryAfterSeconds))));
}

/**
 * Reglas por tipo de ruta. Son deliberadamente holgadas: frenan a un robot o a
 * alguien martillando el botón, no a una persona trabajando.
 */
export const WRITE_RULES = {
  /** Formularios públicos: pocos y separados en el tiempo. */
  publicForm: { limit: 5, windowMs: 10 * 60 * 1000 },
  /** Mensajes del chat del asistente (ARM): conversar es normal, martillar no. */
  chat: { limit: 40, windowMs: 10 * 60 * 1000 },
  /** Reservar o cancelar una clase desde la cuenta. */
  booking: { limit: 30, windowMs: 10 * 60 * 1000 },
  /** Registrar medidas y progreso. */
  progress: { limit: 60, windowMs: 10 * 60 * 1000 },
  /** Cobros, gastos, ventas y demás movimientos de dinero. */
  finance: { limit: 120, windowMs: 10 * 60 * 1000 },
  /** Permisos de entrenador: consultas del buscador. */
  access: { limit: 60, windowMs: 10 * 60 * 1000 },
} as const satisfies Record<string, RateRule>;
