import { NextResponse } from "next/server";
import { z } from "zod";
import { isAdminRole } from "@/lib/auth/current-user";
import { getCurrentUser } from "@/lib/data/queries";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { sameOrigin } from "@/lib/security/same-origin";

export const dynamic = "force-dynamic";

const headers = { "Cache-Control": "private, no-store" };

/**
 * Catálogo de disciplinas (OP-05). Solo administrador con MFA.
 * Crear o editar una disciplina no borra nada y no cambia su estado: prender y
 * apagar sigue siendo el interruptor que ya usa Operación.
 */
const classSchema = z
  .object({
    id: z.string().min(1).max(64).nullable().optional(),
    slug: z
      .string()
      .trim()
      .min(2)
      .max(48)
      .regex(/^[a-z0-9]+(-[a-z0-9]+)*$/),
    nameEs: z.string().trim().min(2).max(80),
    nameEn: z.string().trim().min(2).max(80),
    descriptionEs: z.string().trim().max(400),
    descriptionEn: z.string().trim().max(400),
    intensity: z.enum(["low", "medium", "high"]),
    durationMin: z.number().int().min(10).max(180),
    capacity: z.number().int().min(1).max(200),
    color: z.string().regex(/^#[0-9a-f]{6}$/i),
    sortOrder: z.number().int().min(0).max(9999),
  })
  .strict();

const bodySchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("save"), ...classSchema.shape }).strict(),
  z
    .object({
      action: z.literal("set-active"),
      id: z.string().min(1).max(160),
      isActive: z.boolean(),
      expectedIsActive: z.boolean(),
    })
    .strict(),
]);

const messages: Record<string, [string, number]> = {
  AUTH: [
    "Solo un administrador con verificación en dos pasos puede cambiar las disciplinas.",
    403,
  ],
  INVALID_NAME: ["Escribí un nombre de entre 2 y 80 caracteres, en español y en inglés.", 422],
  INVALID_SLUG: ["El identificador solo admite minúsculas, números y guiones.", 422],
  INVALID_DESCRIPTION: ["La descripción no puede pasar de 400 caracteres.", 422],
  INVALID_INTENSITY: ["Elegí la intensidad: baja, media o alta.", 422],
  INVALID_DURATION: ["La duración de la clase debe estar entre 10 y 180 minutos.", 422],
  INVALID_CAPACITY: ["El cupo debe estar entre 1 y 200 personas.", 422],
  INVALID_COLOR: ["El color tiene que ser un código como #c8f73b.", 422],
  INVALID_ORDER: ["El orden debe estar entre 0 y 9999.", 422],
  CLASS_EXISTS: ["Ya existe una disciplina con ese identificador. Elegí otro.", 409],
  NOT_FOUND: ["No encontramos esa disciplina. Recargá antes de reintentar.", 404],
  INVALID_ACTIVE_STATE: [
    "Ese estado de la disciplina no es válido. No se cambió nada.",
    422,
  ],
  STALE_ACTIVE_STATE: [
    "Otra persona ya cambió esta disciplina. Revisá su estado actual antes de volver a tocarla.",
    409,
  ],
  INVALID_BODY: ["Revisá los datos de la disciplina y volvé a intentar.", 422],
};

function reply(body: unknown, status = 200) {
  return NextResponse.json(body, { status, headers });
}

const SETUP_CODES = new Set(["PGRST202", "42883", "42P01"]);

function failure(error: { code?: string; message?: string }) {
  if (error.code && SETUP_CODES.has(error.code)) {
    console.error("[admin/classes] setup", error.code, error.message);
    return reply(
      {
        error: "SETUP_REQUIRED",
        message:
          "La administración de disciplinas está desactualizada en la base. No se guardó nada.",
      },
      503,
    );
  }
  const known = Object.hasOwn(messages, error.message ?? "")
    ? messages[error.message!]
    : null;
  if (known) return reply({ error: error.message, message: known[0] }, known[1]);
  console.error("[admin/classes] error", error.code, error.message);
  return reply(
    {
      error: "UNKNOWN",
      message: "No se pudo guardar la disciplina. Quedó como estaba; recargá antes de reintentar.",
    },
    503,
  );
}


async function requireAdmin() {
  const user = await getCurrentUser();
  return !!user && isAdminRole(user.role) && user.mfa === "ok";
}

export async function GET() {
  if (!(await requireAdmin()))
    return reply({ error: "AUTH", message: messages.AUTH[0] }, 403);
  const supabase = await getSupabaseServerClient();
  if (!supabase)
    return reply(
      { error: "UNAVAILABLE", message: "No hay conexión con la base de datos." },
      503,
    );
  const { data, error } = await supabase
    .rpc("admin_classes_catalog")
    .abortSignal(AbortSignal.timeout(15000));
  if (error) return failure(error);
  return reply(data);
}

export async function POST(request: Request) {
  if (!sameOrigin(request)) return reply({ error: "ORIGIN" }, 403);
  if (!(await requireAdmin()))
    return reply({ error: "AUTH", message: messages.AUTH[0] }, 403);

  const parsed = bodySchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success)
    return reply(
      {
        error: "INVALID_BODY",
        message:
          parsed.error.issues[0]?.message === "INVALID_SLUG" ||
          parsed.error.issues[0]?.path[0] === "slug"
            ? messages.INVALID_SLUG[0]
            : messages.INVALID_BODY[0],
      },
      422,
    );

  const supabase = await getSupabaseServerClient();
  if (!supabase)
    return reply(
      { error: "UNAVAILABLE", message: "No hay conexión con la base de datos." },
      503,
    );

  if (parsed.data.action === "set-active") {
    const { data, error } = await supabase
      .rpc("admin_set_class_active", {
        p_class_id: parsed.data.id,
        p_is_active: parsed.data.isActive,
        p_expected_is_active: parsed.data.expectedIsActive,
      })
      .abortSignal(AbortSignal.timeout(15000));
    if (error) return failure(error);
    const catalog = await supabase
      .rpc("admin_classes_catalog")
      .abortSignal(AbortSignal.timeout(15000));
    return reply({
      ok: true,
      classId: parsed.data.id,
      isActive: parsed.data.isActive,
      catalog: catalog.error ? null : catalog.data,
    });
  }

  const d = parsed.data;
  const { data, error } = await supabase
    .rpc("admin_save_class", {
      p_id: d.id ?? null,
      p_slug: d.slug,
      p_name_es: d.nameEs,
      p_name_en: d.nameEn,
      p_description_es: d.descriptionEs,
      p_description_en: d.descriptionEn,
      p_intensity: d.intensity,
      p_duration: d.durationMin,
      p_capacity: d.capacity,
      p_color: d.color.toLowerCase(),
      p_sort_order: d.sortOrder,
    })
    .abortSignal(AbortSignal.timeout(15000));
  if (error) return failure(error);
  if (!data || typeof data !== "object" || !("class" in data))
    return reply(
      {
        error: "UNKNOWN",
        message: "No pudimos confirmar la disciplina guardada. Recargá antes de repetir.",
      },
      503,
    );

  const catalog = await supabase
    .rpc("admin_classes_catalog")
    .abortSignal(AbortSignal.timeout(15000));
  return reply({
    ok: true,
    action: (data as { action: string }).action,
    changedFields: (data as { changed_fields: string[] }).changed_fields,
    class: (data as { class: unknown }).class,
    catalog: catalog.error ? null : catalog.data,
  });
}
