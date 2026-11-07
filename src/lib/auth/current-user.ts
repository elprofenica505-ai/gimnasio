import type { SupabaseClient } from "@supabase/supabase-js";

export type ProfileStatus = "ready" | "missing" | "error";
export type UserRole = "member" | "cashier" | "trainer" | "admin" | "superadmin";

export type MfaState =
  | "not_required" // member: MFA no aplica al acceso del panel
  | "enroll" // staff sin factor TOTP verificado: debe registrarlo
  | "verify" // staff con factor registrado: debe ingresar el código
  | "ok" // sesión AAL2: acceso permitido
  | "unavailable"; // no se pudo leer el nivel de sesión: bloqueado

export interface AalLevels {
  currentLevel?: unknown;
  nextLevel?: unknown;
}

/** Personal del gimnasio: administrador, caja o entrenador. Todos requieren MFA (aal2). */
export function isStaffRole(role: unknown): boolean {
  return role === "admin" || role === "cashier" || role === "trainer" || role === "superadmin";
}

/** Caja y administración: cobros, abonos, gastos, cuentas y datos de contacto. */
export function isFinanceRole(role: unknown): boolean {
  return role === "admin" || role === "cashier" || role === "superadmin";
}

/** Sólo administrador: reportes, importación, planes, horarios y asignación de roles.
 * El súper administrador (dueño del aplicativo) tiene todo eso y su cuenta es
 * intocable desde el panel: la protege la base (00100). */
export function isAdminRole(role: unknown): boolean {
  return role === "admin" || role === "superadmin";
}

/** Sólo el dueño del aplicativo. La base impide otorgar o quitar este rol desde la app. */
export function isSuperAdminRole(role: unknown): boolean {
  return role === "superadmin";
}

export function mfaStateFromLevels(
  role: unknown,
  levels: AalLevels | null | undefined,
): MfaState {
  if (!isStaffRole(role)) return "not_required";
  if (!levels || typeof levels !== "object" || Array.isArray(levels)) {
    return "unavailable";
  }
  if (levels.currentLevel === "aal2") return "ok";
  if (levels.currentLevel === "aal1" && levels.nextLevel === "aal2") return "verify";
  if (levels.currentLevel === "aal1" && levels.nextLevel === "aal1") return "enroll";
  return "unavailable";
}

/**
 * Código TOTP: exactamente un string primitivo de 6 dígitos.
 * No convertir arrays, números ni objetos: RegExp.test() los pasaría a texto
 * y una entrada como ["123456"] podría colarse como si fuera escalar.
 */
export function isTotpCode(value: unknown): value is string {
  return typeof value === "string" && /^\d{6}$/.test(value);
}

export interface AuthUser {
  id: string;
  email: string;
  fullName: string;
  // Un perfil que no se pudo leer NO equivale a un cliente sin permisos.
  role: UserRole | null;
  // Estado de MFA de la sesión actual; sólo aplica a admin/staff.
  mfa: MfaState;
  profileStatus: ProfileStatus;
  phone: string | null;
  planId: string | null;
  createdAt: string;
  isDemo: false;
}

/** Misma regla para el guard del servidor y la navegación del cliente.
 * Personal sólo entra con MFA verificado (AAL2); cualquier otro estado bloquea. */
/** Cobros, abonos y gastos: sólo caja o administración con MFA verificado.
 * El entrenador tiene acceso al panel, pero no a movimientos ni deudas. */
export function canManageFinance(
  user: { role: unknown; mfa?: unknown } | null | undefined,
): boolean {
  return canAccessPanel(user) && isFinanceRole(user?.role);
}

export function canAccessPanel(
  user: { role: unknown; mfa?: unknown } | null | undefined,
): boolean {
  return isStaffRole(user?.role) && user?.mfa === "ok";
}

/** Sólo usa la identidad verificada y public.profiles; nunca roles del JWT/metadata/email. */
export async function resolveCurrentUser(supabase: SupabaseClient): Promise<AuthUser | null> {
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) return null;

  const result: AuthUser = {
    id: user.id,
    email: user.email ?? "",
    fullName: (user.user_metadata?.full_name as string | undefined) ?? user.email?.split("@")[0] ?? "Cliente",
    role: null,
    mfa: "unavailable",
    profileStatus: "error",
    phone: null,
    planId: null,
    createdAt: user.created_at,
    isDemo: false,
  };

  try {
    const { data: profile, error } = await supabase
      .from("profiles")
      .select("id, email, full_name, role, phone, plan_id, created_at")
      .eq("id", user.id)
      .maybeSingle();

    if (error) {
      // No registrar tokens, cookies, claves ni el contenido del perfil.
      console.error("[auth/profile] No se pudo leer public.profiles", { code: error.code });
      return result;
    }
    if (!profile) return { ...result, profileStatus: "missing" };
    if (!["member", "cashier", "trainer", "admin"].includes(profile.role)) {
      console.error("[auth/profile] Rol inválido en public.profiles");
      return result;
    }

    const mfa = isStaffRole(profile.role)
      ? await readSessionMfa(supabase, profile.role)
      : "not_required";

    return {
      ...result,
      email: user.email ?? profile.email ?? "",
      fullName: profile.full_name ?? result.fullName,
      role: profile.role,
      mfa,
      profileStatus: "ready",
      phone: profile.phone ?? null,
      planId: profile.plan_id ?? null,
      createdAt: profile.created_at ?? user.created_at,
    };
  } catch {
    console.error("[auth/profile] Falló la conexión al leer public.profiles");
    return result;
  }
}

/** Nivel de la sesión que valida el servidor; cualquier fallo queda bloqueado. */
async function readSessionMfa(supabase: SupabaseClient, role: unknown): Promise<MfaState> {
  try {
    const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error) return "unavailable";
    return mfaStateFromLevels(role, data);
  } catch {
    return "unavailable";
  }
}
