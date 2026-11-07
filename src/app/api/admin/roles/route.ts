import { NextResponse } from "next/server";
import { z } from "zod";
import { isAdminRole } from "@/lib/auth/current-user";
import { getCurrentUser } from "@/lib/data/queries";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { sameOrigin } from "@/lib/security/same-origin";

export const dynamic = "force-dynamic";

const headers = { "Cache-Control": "private, no-store" };

const bodySchema = z.object({
  userId: z.string().uuid(),
  role: z.enum(["member", "cashier", "trainer", "admin"]),
});

const messages: Record<string, [string, number]> = {
  AUTH: ["Sólo un administrador con verificación en dos pasos puede asignar roles.", 403],
  SELF_ROLE_CHANGE: ["No podés cambiar tu propio rol. Pedile a otro administrador.", 409],
  NOT_FOUND: ["No encontramos esa cuenta.", 404],
  INVALID_ROLE: ["Rol no válido.", 422],
  LAST_ADMIN: ["No se puede quitar el último administrador.", 409],
  SUPERADMIN_PROTECTED: [
    "La cuenta del súper administrador está protegida por la base: no se otorga ni se quita desde el panel.",
    403,
  ],
};

/**
 * Asigna caja, entrenador, cliente o administrador. La regla vive en la base
 * (admin_set_role): valida MFA, impide cambiar el propio rol y deja bitácora.
 */
export async function POST(request: Request) {
  if (!sameOrigin(request))
    return NextResponse.json({ error: "ORIGIN" }, { status: 403, headers });
  const user = await getCurrentUser();
  if (!user || !isAdminRole(user.role) || user.mfa !== "ok") {
    return NextResponse.json(
      { error: "AUTH", message: messages.AUTH[0] },
      { status: 403, headers },
    );
  }

  const parsed = bodySchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json(
      { error: "INVALID_ROLE", message: messages.INVALID_ROLE[0] },
      { status: 422, headers },
    );
  }

  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    return NextResponse.json(
      { error: "UNAVAILABLE", message: "No hay conexión con la base de datos." },
      { status: 503, headers },
    );
  }

  const { error } = await supabase.rpc("admin_set_role", {
    p_id: parsed.data.userId,
    p_role: parsed.data.role,
  });

  if (error) {
    const code = /^[A-Z_]{3,30}$/.test(error.message ?? "") ? error.message : "UNKNOWN";
    const known = messages[code];
    if (known) {
      return NextResponse.json({ error: code, message: known[0] }, { status: known[1], headers });
    }
    console.error("[admin/roles] admin_set_role falló", { code: error.code });
    return NextResponse.json(
      { error: "UNKNOWN", message: "No se pudo cambiar el rol. No se modificó ninguna cuenta." },
      { status: 500, headers },
    );
  }

  return NextResponse.json({ ok: true, userId: parsed.data.userId, role: parsed.data.role }, { headers });
}
