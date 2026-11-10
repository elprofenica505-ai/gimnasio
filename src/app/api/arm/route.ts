import { NextResponse } from "next/server";
import { z } from "zod";
import { isSupabaseConfigured } from "@/lib/supabase/env";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { clientIp, isHoneypotFilled } from "@/lib/antispam";
import { checkRateLimit, rateLimitHeaders, WRITE_RULES } from "@/lib/security/rate-limit";
import { sameOrigin } from "@/lib/security/same-origin";
import { responderArm, type ArmEstado, type ArmLocale } from "@/lib/arm/brain";
import { cargarConocimiento } from "@/lib/arm/knowledge";

export const dynamic = "force-dynamic";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const mensajeSchema = z.object({
  /** Token anónimo del navegador (uuid que genera el propio dispositivo). */
  token: z.string().regex(UUID_RE, "token"),
  text: z.string().trim().min(1, "text").max(1000, "text"),
  locale: z.enum(["es", "en"]).optional().default("es"),
  /** Campo trampa: si viene completo, es un bot. */
  website: z.string().max(500).optional().nullable(),
});

const historialSchema = z.object({
  token: z.string().regex(UUID_RE, "token"),
  locale: z.enum(["es", "en"]).optional().default("es"),
  /** Al abrir el chat, el visitante ya «vio» lo pendiente. */
  leer: z.enum(["1"]).optional(),
});

async function canalActivo(db: NonNullable<Awaited<ReturnType<typeof getSupabaseServerClient>>>) {
  const { data } = await db
    .from("arm_channels")
    .select("enabled")
    .eq("channel", "interno")
    .maybeSingle();
  return data?.enabled === true;
}

/** GET /api/arm?token=… → ¿canal encendido? + historial del hilo. */
export async function GET(request: Request) {
  const url = new URL(request.url);
  const parsed = historialSchema.safeParse({
    token: url.searchParams.get("token") ?? "",
    locale: url.searchParams.get("locale") ?? "es",
    leer: url.searchParams.get("leer") ?? undefined,
  });
  if (!parsed.success) {
    return NextResponse.json({ error: "INVALID" }, { status: 400 });
  }
  if (!isSupabaseConfigured) {
    return NextResponse.json({ enabled: false, mensajes: [], contacto: {} });
  }
  const db = await getSupabaseServerClient();
  if (!db) return NextResponse.json({ error: "UNAVAILABLE" }, { status: 503 });

  const enabled = await canalActivo(db);
  if (!enabled) {
    return NextResponse.json({ enabled: false, mensajes: [], contacto: {} });
  }

  if (parsed.data.leer === "1") {
    await db.rpc("arm_marcar_leida_visitante", { p_token: parsed.data.token });
  }

  const { data: hilo } = await db.rpc("arm_historial", { p_token: parsed.data.token });
  return NextResponse.json({
    enabled: true,
    mensajes: hilo?.mensajes ?? [],
    contacto: hilo?.contacto ?? {},
  });
}

/**
 * POST /api/arm → una vuelta de la conversación:
 * guardar el mensaje del visitante, pensar la respuesta con el cerebro
 * (leyendo la base), dejarla en el hilo y devolverla.
 */
export async function POST(request: Request) {
  if (!sameOrigin(request)) return NextResponse.json({ error: "ORIGIN" }, { status: 403 });
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "INVALID" }, { status: 400 });
  }

  const parsed = mensajeSchema.safeParse(payload);
  if (parsed.success && isHoneypotFilled(parsed.data.website)) {
    return NextResponse.json({ ok: true });
  }
  if (!parsed.success) {
    return NextResponse.json(
      { error: "INVALID", fields: parsed.error.issues.map((i) => i.path.join(".")) },
      { status: 422 },
    );
  }
  if (!isSupabaseConfigured) {
    return NextResponse.json({ error: "DEMO" }, { status: 503 });
  }

  const limit = await checkRateLimit({
    scope: "arm",
    raw: clientIp(request),
    rule: WRITE_RULES.chat,
  });
  if (!limit.allowed) {
    return NextResponse.json(
      { error: "RATE_LIMIT", retryAfterSeconds: limit.retryAfterSeconds },
      { status: 429, headers: rateLimitHeaders(limit.retryAfterSeconds) },
    );
  }

  const db = await getSupabaseServerClient();
  if (!db) return NextResponse.json({ error: "UNAVAILABLE" }, { status: 503 });

  if (!(await canalActivo(db))) {
    return NextResponse.json({ error: "CANAL_APAGADO" }, { status: 503 });
  }

  const { token, text, locale } = parsed.data;

  // 1) Hilo (crea o reutiliza; si hay sesión de socio, lo amarra a su cuenta).
  const { error: errorHilo } = await db.rpc("arm_hilo_visitante", {
    p_token: token,
    p_locale: locale,
  });
  if (errorHilo) {
    const codigo = errorHilo.message?.trim() ?? "";
    if (codigo === "CANAL_APAGADO") {
      return NextResponse.json({ error: "CANAL_APAGADO" }, { status: 503 });
    }
    return NextResponse.json({ error: "ERROR" }, { status: 500 });
  }

  // 2) El mensaje del visitante entra al hilo.
  const { error: errorEnvio } = await db.rpc("arm_enviar_visitante", {
    p_token: token,
    p_text: text,
  });
  if (errorEnvio) {
    return NextResponse.json({ error: "ERROR" }, { status: 500 });
  }

  // 3) Lo que ya sabemos del contacto (capturas a medias de mensajes previos).
  const { data: hiloData } = await db.rpc("arm_historial", { p_token: token });
  const contacto = (hiloData?.contacto ?? {}) as {
    full_name?: string | null;
    phone?: string | null;
    email?: string | null;
    socio?: boolean | null;
  };
  const estado: ArmEstado = { nombre: contacto.full_name, telefono: contacto.phone };

  // 4) El cerebro piensa con la base en la mano.
  const conocimiento = await cargarConocimiento(db, locale as ArmLocale);
  const salida = responderArm(text, conocimiento, estado, locale as ArmLocale);

  // 5) Contacto: completo → lead del embudo; a medias → anotado para retomar.
  let capturado = false;
  const nombre = salida.captura?.nombre ?? estado.nombre ?? null;
  const telefono = salida.captura?.telefono ?? estado.telefono ?? null;
  if (salida.captura?.nombre && salida.captura?.telefono) {
    const { data: vinculo, error: errorVinculo } = await db.rpc("arm_vincular_contacto", {
      p_token: token,
      p_full_name: salida.captura.nombre,
      p_phone: salida.captura.telefono,
      p_email: contacto.email ?? null,
    });
    capturado = !errorVinculo && Boolean(vinculo?.ok);
  } else if (salida.captura?.nombre || salida.captura?.telefono) {
    await db.rpc("arm_anotar_contacto", {
      p_token: token,
      p_full_name: salida.captura?.nombre ?? null,
      p_phone: salida.captura?.telefono ?? null,
    });
  }

  // 6) Visita o socio: al socio el bot no le contesta (responde el personal).
  if (contacto.socio) {
    return NextResponse.json({ socio: true, capturado: false });
  }

  const { error: errorBot } = await db.rpc("arm_responder_asistente", {
    p_token: token,
    p_text: salida.reply,
  });
  if (errorBot) {
    return NextResponse.json({ error: "ERROR" }, { status: 500 });
  }

  return NextResponse.json({
    reply: salida.reply,
    sugerencias: salida.sugerencias,
    acciones: salida.acciones,
    capturado,
  });
}
