import { NextResponse } from "next/server";
import { z } from "zod";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { clientIp, isHoneypotFilled } from "@/lib/antispam";
import { checkRateLimit, rateLimitHeaders, WRITE_RULES } from "@/lib/security/rate-limit";
import { sameOrigin } from "@/lib/security/same-origin";

export const dynamic = "force-dynamic";

const pagoSchema = z.object({
  public_id: z.string().trim().min(4).max(20),
  reference: z.string().trim().min(4, "reference").max(120),
  note: z.string().trim().max(300).optional().nullable(),
  /** Campo trampa: si viene completo, es un bot. */
  website: z.string().max(500).optional().nullable(),
});

/** POST /api/checkout/pago → informa el número de referencia del pago. */
export async function POST(request: Request) {
  if (!sameOrigin(request))
    return NextResponse.json({ error: "ORIGIN" }, { status: 403 });
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "INVALID" }, { status: 400 });
  }

  const parsed = pagoSchema.safeParse(payload);
  if (parsed.success && isHoneypotFilled(parsed.data.website)) {
    return NextResponse.json({ ok: true });
  }
  const limit = await checkRateLimit({
    scope: "checkout-pago",
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
  if (!supabase)
    return NextResponse.json({ error: "DEMO" }, { status: 503 });

  const { website: _website, ...data } = parsed.data;
  const { error } = await supabase.rpc("embudo_informar_pago", {
    p_public_id: data.public_id,
    p_reference: data.reference,
    p_note: data.note ?? null,
  });
  if (error) {
    const codigo = error.message?.trim() ?? "ERROR";
    const map: Record<string, number> = {
      REFERENCIA_INVALIDA: 422,
      ORDEN_NO_ENCONTRADA: 404,
      ORDEN_NO_PENDIENTE: 409,
    };
    return NextResponse.json({ error: map[codigo] ? codigo : "ERROR" }, { status: map[codigo] ?? 500 });
  }
  return NextResponse.json({ ok: true, status: "por_verificar" });
}
