import { NextResponse } from "next/server";
import { z } from "zod";
import { isAdminRole, isStaffRole } from "@/lib/auth/current-user";
import { getCurrentUser } from "@/lib/data/queries";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { sameOrigin } from "@/lib/security/same-origin";

export const dynamic = "force-dynamic";

const headers = { "Cache-Control": "private, no-store" };

/**
 * Categorías automáticas (CLI-02). Las reglas las cambia solo el administrador
 * con segundo factor; la lectura de la categoría de un cliente la puede hacer
 * el personal con acceso a la ficha. La vigencia sale de `payment_plans`.
 */
const category = z.enum(["strong_gym", "familia", "amigo", "comun"]);

const ruleSchema = z
  .object({
    category,
    sort_order: z.number().int().min(1).max(999),
    is_active: z.boolean(),
    is_fallback: z.boolean(),
    requires_validity: z.boolean(),
    forbids_validity: z.boolean(),
    validity_days_min: z.number().int().min(0).max(3660),
    requires_purchase_window_days: z.number().int().min(1).max(3650).nullable(),
    visits_min: z.number().int().min(0).max(1000),
    visits_window_days: z.number().int().min(1).max(365),
  })
  .strict();

const bodySchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("save"), rules: z.array(ruleSchema).length(4) }).strict(),
  z
    .object({
      action: z.literal("refresh"),
      clientId: z.string().uuid().nullable().optional(),
    })
    .strict(),
  z
    .object({
      action: z.literal("set-override"),
      clientId: z.string().uuid(),
      category,
      reason: z.string().trim().min(4).max(200),
    })
    .strict(),
  z
    .object({
      action: z.literal("clear-override"),
      clientId: z.string().uuid(),
      reason: z.string().trim().min(4).max(200),
    })
    .strict(),
]);

const messages: Record<string, [string, number]> = {
  AUTH: ["Solo un administrador con verificación en dos pasos puede cambiar las categorías.", 403],
  INVALID_CATEGORY: ["Elegí una categoría válida: Power Box, Familia, Amigo o Común.", 422],
  INVALID_REASON: ["Escribí el motivo, entre 4 y 200 caracteres.", 422],
  INVALID_RULES: ["Las cuatro categorías tienen que venir completas y con una sola de reserva.", 422],
  INVALID_ORDER: ["El orden debe estar entre 1 y 999.", 422],
  INVALID_FALLBACK: ["La categoría de reserva tiene que ser Común.", 422],
  INVALID_VALIDITY_RULE: ["Una regla no puede exigir y prohibir vigencia a la vez.", 422],
  INVALID_VALIDITY_DAYS: ["Los días de vigencia deben estar entre 0 y 3660.", 422],
  INVALID_PURCHASE_WINDOW: ["Los días de compra deben estar entre 1 y 3650, o vacío.", 422],
  INVALID_VISITS: ["Las visitas mínimas deben estar entre 0 y 1000.", 422],
  INVALID_VISITS_WINDOW: ["La ventana de visitas debe estar entre 1 y 365 días.", 422],
  NOT_FOUND: ["No encontramos ese cliente. Recargá antes de reintentar.", 404],
};

function failure(error: { code?: string; message?: string }) {
  const match = Object.hasOwn(messages, error.message ?? "")
    ? messages[error.message!]
    : null;
  if (match)
    return NextResponse.json(
      { error: error.message, message: match[0] },
      { status: match[1], headers },
    );
  console.error("[admin/categories] error", error.code, error.message);
  return NextResponse.json(
    {
      error: "UNKNOWN",
      message: "No se pudo leer o guardar la categoría. Recargá antes de repetir.",
    },
    { status: 503, headers },
  );
}

export async function GET(request: Request) {
  const user = await getCurrentUser();
  const staff = !!user && isStaffRole(user.role) && user.mfa === "ok";
  const admin = !!user && isAdminRole(user.role) && user.mfa === "ok";
  const client = new URL(request.url).searchParams.get("client");
  const supabase = await getSupabaseServerClient();
  if (!supabase)
    return NextResponse.json(
      { error: "UNAVAILABLE", message: "No hay conexión con la base de datos." },
      { status: 503, headers },
    );

  if (client) {
    if (!staff)
      return NextResponse.json(
        { error: "AUTH", message: "Necesitás acceso a la ficha con segundo factor." },
        { status: 403, headers },
      );
    if (!z.string().uuid().safeParse(client).success)
      return NextResponse.json({ error: "INVALID_CLIENT" }, { status: 422, headers });
    const { data, error } = await supabase
      .rpc("client_category", { p_client: client })
      .abortSignal(AbortSignal.timeout(15000));
    if (error) return failure(error);
    if (!data)
      return NextResponse.json(
        { error: "NOT_FOUND", message: "No se pudo calcular la categoría de este cliente." },
        { status: 404, headers },
      );
    return NextResponse.json(data, { headers });
  }

  if (!admin)
    return NextResponse.json(
      { error: "AUTH", message: messages.AUTH[0] },
      { status: 403, headers },
    );
  const { data, error } = await supabase
    .rpc("admin_category_rules")
    .abortSignal(AbortSignal.timeout(15000));
  if (error) return failure(error);
  return NextResponse.json(data, { headers });
}

export async function POST(request: Request) {
  if (!sameOrigin(request))
    return NextResponse.json({ error: "ORIGIN" }, { status: 403, headers });

  const user = await getCurrentUser();
  if (!user || !isAdminRole(user.role) || user.mfa !== "ok")
    return NextResponse.json(
      { error: "AUTH", message: messages.AUTH[0] },
      { status: 403, headers },
    );

  const parsed = bodySchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    const issue = parsed.error.issues[0]?.message ?? "INVALID_RULES";
    return failure({ message: issue });
  }
  const body = parsed.data;

  const supabase = await getSupabaseServerClient();
  if (!supabase)
    return NextResponse.json(
      { error: "UNAVAILABLE", message: "No hay conexión con la base de datos." },
      { status: 503, headers },
    );

  if (body.action === "save") {
    const { data, error } = await supabase
      .rpc("admin_save_category_rules", { p_rules: body.rules })
      .abortSignal(AbortSignal.timeout(15000));
    if (error) return failure(error);
    const applied = await supabase
      .rpc("client_category_apply", { p_client: null })
      .abortSignal(AbortSignal.timeout(20000));
    if (applied.error) return failure(applied.error);
    return NextResponse.json({ ok: true, ...(data as object), applied: applied.data }, { headers });
  }

  if (body.action === "refresh") {
    const { data, error } = await supabase
      .rpc("client_category_apply", { p_client: body.clientId ?? null })
      .abortSignal(AbortSignal.timeout(20000));
    if (error) return failure(error);
    return NextResponse.json({ ok: true, applied: data }, { headers });
  }

  if (body.action === "set-override") {
    const { data, error } = await supabase
      .rpc("crm_set_client_category", {
        p_client: body.clientId,
        p_category: body.category,
        p_reason: body.reason,
      })
      .abortSignal(AbortSignal.timeout(15000));
    if (error) return failure(error);
    return NextResponse.json({ ok: true, ...(data as object) }, { headers });
  }

  const { data, error } = await supabase
    .rpc("crm_clear_client_category", {
      p_client: body.clientId,
      p_reason: body.reason,
    })
    .abortSignal(AbortSignal.timeout(15000));
  if (error) return failure(error);
  return NextResponse.json({ ok: true, ...(data as object) }, { headers });
}
