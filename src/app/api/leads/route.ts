import { NextResponse } from "next/server";
import { z } from "zod";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { clientIp, isHoneypotFilled } from "@/lib/antispam";
import { checkRateLimit, rateLimitHeaders, WRITE_RULES } from "@/lib/security/rate-limit";
import { sameOrigin } from "@/lib/security/same-origin";

export const dynamic = "force-dynamic";

const leadSchema = z.object({
  full_name: z.string().trim().min(2, "full_name").max(120),
  phone: z.string().trim().min(6, "phone").max(40),
  email: z.string().trim().email("email").max(120).optional().nullable(),
  interest: z.string().trim().max(120).optional().nullable(),
  source: z.enum(["landing", "whatsapp"]).optional().default("landing"),
  /** Campo trampa: si viene completo, es un bot. */
  website: z.string().max(500).optional().nullable(),
});

/**
 * POST /api/leads → captura de interesados de la landing.
 * No compra todavía: queda en el pipeline del CRM para seguimiento.
 */
export async function POST(request: Request) {
  if (!sameOrigin(request))
    return NextResponse.json({ error: "ORIGIN" }, { status: 403 });
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "INVALID" }, { status: 400 });
  }

  const parsed = leadSchema.safeParse(payload);
  if (parsed.success && isHoneypotFilled(parsed.data.website)) {
    return NextResponse.json({ ok: true });
  }
  const limit = await checkRateLimit({
    scope: "leads",
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
  const { error } = await supabase.rpc("embudo_guardar_lead", {
    p_payload: {
      full_name: data.full_name,
      phone: data.phone,
      email: data.email ?? null,
      interest: data.interest ?? null,
      source: data.source,
    },
  });
  if (error) {
    const codigo = error.message?.trim() ?? "ERROR";
    const map: Record<string, number> = { LEAD_INVALIDO: 422 };
    return NextResponse.json({ error: map[codigo] ? codigo : "ERROR" }, { status: map[codigo] ?? 500 });
  }
  return NextResponse.json({ ok: true });
}
