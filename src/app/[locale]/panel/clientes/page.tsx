import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { isLocale } from "@/i18n/config";
import { canAccessPanel, isAdminRole } from "@/lib/auth/current-user";
import { getCurrentUser, getStaffProfiles } from "@/lib/data/queries";
import { readData } from "@/lib/data/read-result";
import { StaffDirectory } from "@/components/crm/staff-directory";
import { DEMO_MODE } from "@/lib/supabase/env";
import { ClientsPanel } from "@/components/crm/clients-panel";
export const metadata: Metadata = {
  title: "Clientes y recepción",
  robots: { index: false, follow: false },
};
export default async function ClientsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const user = await getCurrentUser();
  if (!DEMO_MODE && !user) redirect(`/${locale}/ingresar`);
  if (!DEMO_MODE && !canAccessPanel(user))
    redirect(`/${locale}/mi-cuenta`);
  // El entrenador no ve la lista de clientes; sólo sus asignados en "Mis clientes".
  if (!DEMO_MODE && user?.role === "trainer") redirect(`/${locale}/panel/entrenador`);
  const staff = DEMO_MODE ? { ok: true as const, data: [] } : await readData(() => getStaffProfiles());
  const staffRows = staff.ok ? staff.data : [];
  return (
    <ClientsPanel
      isAdmin={isAdminRole(user?.role)}
      isDemo={DEMO_MODE}
      staffIds={staffRows.map((p) => p.id)}
      staffDirectory={
        <div className="pb-4">
          <StaffDirectory staff={staffRows} />
        </div>
      }
    />
  );
}
