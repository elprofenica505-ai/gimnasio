import type { Metadata } from "next";
import { Boxing } from "@/components/sections/boxing";
import { ClassesGrid } from "@/components/sections/classes-grid";
import { Coaches } from "@/components/sections/coaches";
import { Community } from "@/components/sections/community";
import { Contact } from "@/components/sections/contact";
import { CtaBand } from "@/components/sections/cta-band";
import { Faq } from "@/components/sections/faq";
import { Features } from "@/components/sections/features";
import { Gallery } from "@/components/sections/gallery";
import { Hero } from "@/components/sections/hero";
import { Marquee } from "@/components/sections/marquee";
import { Plans } from "@/components/sections/plans";
import { Rules } from "@/components/sections/rules";
import { Supplements } from "@/components/sections/supplements";
import { Testimonials } from "@/components/sections/testimonials";
import { LeadCapture } from "@/components/sections/lead-capture";
import { MemberSummary } from "@/components/account/member-summary";
import { getDictionary } from "@/i18n/dictionaries";
import { isLocale } from "@/i18n/config";
import { homeJsonLd, serializeJsonLd } from "@/lib/structured-data";
import { fotoDisponible } from "@/components/ui/gym-photo";
import { getPublicDisciplineState } from "@/lib/data/public-discipline-state";
import { selectPublicDisciplineText } from "@/lib/public-disciplines";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = getDictionary(locale);
  const { visibility } = await getPublicDisciplineState();

  return {
    title: { absolute: dict.meta.title },
    description: selectPublicDisciplineText(visibility, {
      both: dict.meta.description,
      boxingOnly: dict.meta.descriptionBoxingOnly,
      danceOnly: dict.meta.descriptionDanceOnly,
      weightsOnly: dict.meta.descriptionWeightsOnly,
    }),
  };
}

export default async function HomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const safeLocale = isLocale(locale) ? locale : "es";
  const dict = getDictionary(safeLocale);
  const { activeClassSlugs, visibility } = await getPublicDisciplineState();

  return (
    <>
      <script
        type="application/ld+json"
        // Datos estructurados para Google (negocio local)
        dangerouslySetInnerHTML={{
          __html: serializeJsonLd(homeJsonLd(safeLocale, dict, visibility)),
        }}
      />

      <Hero
        fachada={fotoDisponible("/images/fachada.jpg")}
        showBoxing={visibility.showBoxing}
        showZumba={visibility.showZumba}
      />
      <Marquee
        locale={safeLocale}
        showBoxing={visibility.showBoxing}
        showZumba={visibility.showZumba}
      />
      <Features
        locale={safeLocale}
        showBoxing={visibility.showBoxing}
        showZumba={visibility.showZumba}
      />
      {visibility.showBoxing ? <Boxing locale={safeLocale} /> : null}
      <ClassesGrid locale={safeLocale} />
      <Plans locale={safeLocale} activeClassSlugs={activeClassSlugs} />
      <LeadCapture locale={safeLocale} />
      <Supplements locale={safeLocale} />
      <Gallery locale={safeLocale} />
      <Community locale={safeLocale} />
      <Testimonials locale={safeLocale} />
      <Coaches locale={safeLocale} showBoxing={visibility.showBoxing} />
      <Rules locale={safeLocale} />
      <Faq
        locale={safeLocale}
        showBoxing={visibility.showBoxing}
        showZumba={visibility.showZumba}
      />
      <Contact
        locale={safeLocale}
        showBoxing={visibility.showBoxing}
        showZumba={visibility.showZumba}
      />
      <CtaBand locale={safeLocale} />
    </>
  );
}
