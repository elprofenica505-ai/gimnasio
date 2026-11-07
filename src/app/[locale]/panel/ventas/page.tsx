import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { canAccessPanel, isFinanceRole } from "@/lib/auth/current-user";
import { ShieldAlert } from "lucide-react";
import { SectionHeading } from "@/components/ui/section";
import { VentasPanel, type OrdenRow, type LeadRow } from "@/components/admin/ventas-panel";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { DEMO_MODE } from "@/lib/supabase/env";
import { getCurrentUser } from "@/lib/data/queries";
import { isLocale, type Locale } from "@/i18n/config";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  await params;
  return { title: "Ventas online", robots: { index: false, follow: false } };
}

export default async function VentasPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale: rawLocale } = await params;
  const locale: Locale = isLocale(rawLocale) ? rawLocale : "es";
  const user = await getCurrentUser();
  if (!DEMO_MODE && !user) redirect(`/${locale}/ingresar`);
  if (!DEMO_MODE && (!canAccessPanel(user) || !isFinanceRole(user?.role))) {
    redirect(`/${locale}/panel`);
  }

  const db = await getSupabaseServerClient();
  if (!db || DEMO_MODE) {
    return (
      <section className="container-x py-16">
        <SectionHeading title="Ventas online" subtitle="Requiere Supabase conectado." />
      </section>
    );
  }

  const [ordenes, leads, config] = await Promise.all([
    db
      .from("embudo_orders")
      .select("id,public_id,status,full_name,phone,email,plan_name,plan_amount,plan_currency,items,total,currency,pay_method,pay_reference,pay_notified_at,confirmed_at,created_at")
      .order("created_at", { ascending: false })
      .limit(100),
    db
      .from("embudo_leads")
      .select("id,full_name,phone,email,source,interest,stage,note,client_id,order_id,last_touch,created_at")
      .order("last_touch", { ascending: false })
      .limit(200),
    db.from("embudo_config").select("key,value").eq("key", "instrucciones").maybeSingle(),
  ]);

  const ordenesListo = ordenes.error ? [] : (ordenes.data as OrdenRow[]);
  const leadsListo = leads.error ? [] : (leads.data as LeadRow[]);
  const instrucciones = config.data?.value ?? null;

  return (
    <section className="container-x py-10 sm:py-14">
      <SectionHeading
        title="Ventas online"
        subtitle="Órdenes de la web por verificar y seguimiento de interesados."
      />
      <VentasPanel
        ordenes={ordenesListo}
        leads={leadsListo}
        instruccionesInicial={instrucciones}
        errorCarga={ordenes.error ? String(ordenes.error.message) : null}
      />
    </section>
  );
}
