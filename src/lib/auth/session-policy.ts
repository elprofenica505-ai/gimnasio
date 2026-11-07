/**
 * Cierre automático por inactividad según el rol.
 * - Administración y caja: 15 minutos sin actividad.
 * - Entrenador y clientes: sin cierre automático; cierran sesión manualmente.
 * La regla vive en el navegador: si la pestaña no responde, el cierre ocurre al volver.
 */
export const ADMIN_CASHIER_INACTIVITY_MS = 15 * 60 * 1000;

/** Sólo administración y caja tienen cierre automático por inactividad (el súper administrador también: es administración). */
export function inactivityLimitMs(role: "member" | "cashier" | "trainer" | "admin" | "superadmin" | null | undefined): number | null {
  return role === "admin" || role === "cashier" || role === "superadmin" ? ADMIN_CASHIER_INACTIVITY_MS : null;
}

export function isInactive(lastActivityMs: number, nowMs: number, limitMs: number | null): boolean {
  return limitMs !== null && nowMs - lastActivityMs >= limitMs;
}
