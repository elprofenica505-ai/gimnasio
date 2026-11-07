import { NextResponse } from "next/server";
import { z } from "zod";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { clientIp, isHoneypotFilled } from "@/lib/antispam";
import { checkRateLimit, rateLimitHeaders, WRITE_RULES } from "@/lib/security/rate-limit";
import { sameOrigin } from "@/lib/security/same-origin";

export const dynamic = "force-dynamic";

const itemSchema = z.object({
  product_id: z.string().uuid("product_id"),
  qty: z.number().int().min(1).max(10),
});

const checkoutSchema = z.object({
  full_name: z.string().trim().min(2, "full_name").max(120),
  phone: z.string().trim().min(6, "phone").max(40),
  email: z.string().trim().email("email").max(120).optional().nullable(),
  plan_id: z.string().trim().max(60).optional().nullable(),
  pay_method: z.string().trim().max(40).optional().nullable(),
  items: z.array(itemSchema).max(20).optional().default([]),
  /** Campo trampa: si viene completo, es un bot. */
  website: z.string().max(500).optional().nullable(),
});

/** POST /api/checkout → crea la orden (el total lo calcula la base). */
export async function POST(request: Request) {
  if (!sameOrigin(request))
    return NextResponse.json({ error: "ORIGIN" }, { status: 403 });
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "INVALID" }, { status: 400 });
  }

  const parsed = checkoutSchema.safeParse(payload);
  if (parsed.success && isHoneypotFilled(parsed.data.website)) {
    // Robot: OK sin pistas, no se guarda nada.
    return NextResponse.json({ ok: true });
  }
  const limit = await checkRateLimit({
    scope: "checkout",
    raw: clientIp(request),
    rule: WRITE_RULES.publicForm,
  });
  if (!limit.allowed) {
    return NextResponse.json(
      { error: "RATE_LIMIT", retryAfterSeconds: limit.retryAfterSeconds },
      { status: 429, headers: rateLimitHeaders(limit.retryAfterSeconds) },
    );
  }
  if (!parsed.success) {
    return NextResponse.json(
      { error: "INVALID", fields: parsed.error.issues.map((i) => i.path.join(".")) },
      { status: 422 },
    );
  }

  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    return NextResponse.json(
      { error: "DEMO", message: "Esta acción requiere Supabase conectado." },
      { status: 503 },
    );
  }

  const { website: _website, ...data } = parsed.data;
  const { data: orden, error } = await supabase.rpc("embudo_crear_orden", {
    p_payload: {
      full_name: data.full_name,
      phone: data.phone,
      email: data.email ?? null,
      plan_id: data.plan_id || null,
      pay_method: data.pay_method || null,
      items: data.items,
    },
  });
  if (error) {
    const codigo = error.message?.trim() ?? "ERROR";
    const map: Record<string, number> = {
      NOMBRE_INVALIDO: 422,
      TELEFONO_INVALIDO: 422,
      PLAN_NO_DISPONIBLE: 422,
      ORDEN_VACIA: 422,
    };
    return NextResponse.json(
      { error: map[codigo] ? codigo : "ERROR", message: error.message },
      { status: map[codigo] ?? 500 },
    );
  }
  return NextResponse.json({ ok: true, orden });
}

/** GET /api/checkout?public_id=PB… → estado inocuo de la orden. */
export async function GET(request: Request) {
  const publicId = new URL(request.url).searchParams.get("public_id")?.trim();
  if (!publicId || publicId.length > 20)
    return NextResponse.json({ error: "INVALID" }, { status: 400 });
  const supabase = await getSupabaseServerClient();
  if (!supabase)
    return NextResponse.json({ error: "DEMO" }, { status: 503 });
  const { data: estado, error } = await supabase.rpc("embudo_estado_orden", {
    p_public_id: publicId,
  });
  if (error) return NextResponse.json({ error: "NO_ENCONTRADA" }, { status: 404 });
  return NextResponse.json({ ok: true, estado });
}
