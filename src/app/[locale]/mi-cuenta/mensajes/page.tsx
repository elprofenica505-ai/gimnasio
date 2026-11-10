import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { SectionHeading } from "@/components/ui/section";
import { ArmChat } from "@/components/arm/arm-chat";
import { getDictionary } from "@/i18n/dictionaries";
import { isLocale, type Locale } from "@/i18n/config";
import { getCurrentUser } from "@/lib/data/queries";
import { DEMO_MODE } from "@/lib/supabase/env";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = getDictionary(locale);
  return {
    title: dict.arm.mensajesTitulo,
    description: dict.arm.mensajesSubtitulo,
    robots: { index: false, follow: false },
  };
}

/**
 * ARM · canal interno, cara de socio: la conversación del «Mensajes» de
 * Mi cuenta. Lo que el socio escribe acá cae directo en la bandeja del
 * personal (panel → Operación → Asistente). Sin bot de por medio: al socio
 * le contesta una persona.
 */
export default async function MensajesPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale: rawLocale } = await params;
  const locale: Locale = isLocale(rawLocale) ? rawLocale : "es";
  const dict = getDictionary(locale);

  const user = await getCurrentUser();
  if (!DEMO_MODE && !user) redirect(`/${locale}/ingresar`);

  return (
    <section className="container-x py-10 sm:py-14">
      <SectionHeading title={dict.arm.mensajesTitulo} subtitle={dict.arm.mensajesSubtitulo} />
      <div className="mx-auto mt-6 max-w-2xl">
        <ArmChat locale={locale} variante="pagina" />
      </div>
    </section>
  );
}
