import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { ShieldAlert } from "lucide-react";
import { SectionHeading } from "@/components/ui/section";
import { ArmInbox, type ArmCanal, type ArmHilo } from "@/components/admin/arm-inbox";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { DEMO_MODE } from "@/lib/supabase/env";
import { canAccessPanel } from "@/lib/auth/current-user";
import { getCurrentUser } from "@/lib/data/queries";
import { isLocale, type Locale } from "@/i18n/config";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  await params;
  return { title: "Asistente · Bandeja", robots: { index: false, follow: false } };
}

/**
 * ARM · bandeja del personal (panel → Operación → Asistente). Conversaciones
 * de la web (visitantes) y de Mi cuenta (socios) en un solo lugar, con los
 * interruptores de canal: interno encendido; WhatsApp y correo se activan
 * después de la firma.
 */
export default async function AsistentePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale: rawLocale } = await params;
  const locale: Locale = isLocale(rawLocale) ? rawLocale : "es";
  const user = await getCurrentUser();
  if (!DEMO_MODE && !user) redirect(`/${locale}/ingresar`);
  if (!DEMO_MODE && !canAccessPanel(user)) {
    redirect(`/${locale}/panel`);
  }

  const db = await getSupabaseServerClient();
  if (!db || DEMO_MODE) {
    return (
      <section className="container-x py-16">
        <SectionHeading title="Asistente" subtitle="Requiere Supabase conectado." />
      </section>
    );
  }

  const [hilos, canales] = await Promise.all([
    db
      .from("arm_threads")
      .select(
        "id,channel,locale,status,user_id,full_name,phone,email,lead_id,client_id,staff_unread,visitor_unread,last_message,last_message_at,created_at",
      )
      .order("last_message_at", { ascending: false, nullsFirst: false })
      .limit(100),
    db.from("arm_channels").select("channel,enabled,note,updated_at").order("channel"),
  ]);

  const hilosListo = hilos.error ? [] : (hilos.data as ArmHilo[]);
  const canalesListo: ArmCanal[] = canales.error
    ? []
    : (canales.data as ArmCanal[]);

  const pendientes = hilosListo.filter((h) => h.staff_unread > 0).length;

  return (
    <section className="container-x py-10 sm:py-14">
      <SectionHeading
        title="Asistente"
        subtitle={
          pendientes > 0
            ? `${hilosListo.length} conversación${hilosListo.length === 1 ? "" : "es"} · ${pendientes} sin leer`
            : "Conversaciones de la web y de Mi cuenta, en un solo lugar."
        }
      />
      {hilos.error ? (
        <div className="mt-6 flex items-center gap-2 rounded-xl border border-line bg-card px-4 py-3 text-sm text-fog" role="alert">
          <ShieldAlert className="size-4 shrink-0" aria-hidden="true" />
          No pudimos leer las conversaciones ({String(hilos.error.message)}).
        </div>
      ) : (
        <div className="mt-6">
          <ArmInbox hilos={hilosListo} canales={canalesListo} />
        </div>
      )}
    </section>
  );
}
