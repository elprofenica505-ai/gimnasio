"use client";

import type { SupabaseClient } from "@supabase/supabase-js";
import { isTotpCode, mfaStateFromLevels, type MfaState } from "./current-user";

export const MFA_FACTOR_NAME = "Power Box Gym";

export type MfaActionError = "code" | "unavailable";
export type MfaActionResult = { ok: true } | { ok: false; error: MfaActionError };

export interface TotpEnrollment {
  factorId: string;
  qrCode: string;
  secret: string;
}

/** Solo strings primitivos no vacíos; nunca arrays ni objetos convertibles. */
function isScalarString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

/** IDs de factor/desafío: un único string acotado y sin espacios. */
function isScalarId(value: unknown): value is string {
  return isScalarString(value) && value.length <= 128 && !/\s/.test(value);
}

/** Lee el estado real de la sesión; no confía en metadata ni en el rol del JWT. */
export async function readMfaState(
  client: SupabaseClient,
  role: unknown,
): Promise<MfaState> {
  try {
    const { data, error } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error) return "unavailable";
    return mfaStateFromLevels(role, data);
  } catch {
    return "unavailable";
  }
}

/**
 * Crea un factor TOTP nuevo. Antes elimina factores TOTP sin verificar que
 * quedaron de intentos anteriores, para no acumular registros pendientes.
 */
export async function startTotpEnrollment(
  client: SupabaseClient,
): Promise<TotpEnrollment | MfaActionError> {
  try {
    const { data: list, error: listError } = await client.auth.mfa.listFactors();
    if (listError || !list) return "unavailable";
    const allFactors: unknown = list.all ?? [];
    if (!Array.isArray(allFactors)) return "unavailable";
    for (const factor of allFactors) {
      if (factor?.factor_type === "totp" && factor.status === "unverified") {
        if (!isScalarId(factor.id)) return "unavailable";
        await client.auth.mfa.unenroll({ factorId: factor.id });
      }
    }
    const { data, error } = await client.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: MFA_FACTOR_NAME,
    });
    const qrCode: unknown = data?.totp?.qr_code;
    const secret: unknown = data?.totp?.secret;
    if (
      error ||
      !isScalarId(data?.id) ||
      data.type !== "totp" ||
      !isScalarString(qrCode) ||
      !isScalarString(secret)
    ) {
      return "unavailable";
    }
    return {
      factorId: data.id,
      qrCode,
      secret,
    };
  } catch {
    return "unavailable";
  }
}

/** Factor TOTP verificado de la cuenta, o null si no hay ninguno. */
export async function verifiedTotpFactorId(
  client: SupabaseClient,
): Promise<string | null | "unavailable"> {
  try {
    const { data, error } = await client.auth.mfa.listFactors();
    if (error || !data) return "unavailable";
    const totpFactors: unknown = data.totp ?? [];
    if (!Array.isArray(totpFactors)) return "unavailable";
    const factor = totpFactors.find((f) => f?.status === "verified");
    if (!factor) return null;
    return isScalarId(factor.id) ? factor.id : "unavailable";
  } catch {
    return "unavailable";
  }
}

/** Desafío + verificación del código. Al éxito Supabase sube la sesión a AAL2. */
export async function verifyTotpCode(
  client: SupabaseClient,
  factorId: unknown,
  code: unknown,
): Promise<MfaActionResult> {
  // Frontera en tiempo de ejecución: TypeScript no protege llamadas desde JS,
  // JSON o superficies sin tipar. Nada que no sea un único string llega al SDK.
  if (!isTotpCode(code)) return { ok: false, error: "code" };
  if (!isScalarId(factorId)) return { ok: false, error: "unavailable" };
  try {
    const { data: challenge, error: challengeError } = await client.auth.mfa.challenge({ factorId });
    if (challengeError || !challenge || !isScalarId(challenge.id)) {
      return { ok: false, error: "unavailable" };
    }
    const { error } = await client.auth.mfa.verify({
      factorId,
      challengeId: challenge.id,
      code,
    });
    if (error) return { ok: false, error: "code" };
    return { ok: true };
  } catch {
    return { ok: false, error: "unavailable" };
  }
}
