import { ArrowUpRight, MapPin, MessageCircle } from "lucide-react";
import { getDictionary } from "@/i18n/dictionaries";
import type { Locale } from "@/i18n/config";
import { mapsLink, siteConfig, whatsappLink } from "@/config/site";
import { ButtonLink } from "@/components/ui/button";
import { Reveal } from "@/components/ui/reveal";

/** Banda roja de llamada a la acción, justo antes del pie. */
export function CtaBand({ locale }: { locale: Locale }) {
  const dict = getDictionary(locale);

  return (
    <section className="relative overflow-hidden bg-brand text-onbrand">
      <div className="absolute inset-0 bg-gradient-to-br from-brand via-brand to-brand-700" />
      <div className="absolute inset-0 bg-grid-dark opacity-30" />
      <div
        className="absolute -top-24 -right-16 size-72 rounded-full bg-white/15 blur-3xl"
        aria-hidden="true"
      />

      <div className="container-x relative py-14 sm:py-16 lg:py-20">
        <div className="flex flex-col gap-8 lg:flex-row lg:items-center lg:justify-between">
          <Reveal>
            <p className="text-[0.6875rem] font-bold tracking-[0.2em] text-white/70 uppercase">
              {siteConfig.name}
            </p>

            <h2 className="display-xl mt-3 max-w-2xl text-[2rem] leading-[0.92] text-white sm:text-[2.75rem] lg:text-[3.25rem]">
              {dict.cta.freeTrial}
            </h2>

            <p className="mt-4 flex max-w-xl items-start gap-2 text-[0.9375rem] leading-relaxed text-white/85">
              <MapPin className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
              {siteConfig.address.street}, {siteConfig.address.city}
            </p>
          </Reveal>

          <Reveal delay={120} className="shrink-0">
            <div className="flex flex-col gap-3 sm:flex-row lg:flex-col xl:flex-row">
              <ButtonLink
                href={whatsappLink(
                  locale === "es"
                    ? "Hola, quiero información de Power Box Gym."
                    : "Hi, I would like information about Power Box Gym.",
                )}
                target="_blank"
                rel="noopener noreferrer"
                variant="dark"
                size="lg"
              >
                <MessageCircle className="size-4.5" aria-hidden="true" />
                {dict.cta.whatsapp}
              </ButtonLink>

              <a
                href={mapsLink()}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex h-13 items-center justify-center gap-2 rounded-full border border-white/40 px-7 text-[0.9375rem] font-semibold text-white transition-colors hover:border-white hover:bg-white/10"
              >
                {dict.cta.directions}
                <ArrowUpRight className="size-4" aria-hidden="true" />
              </a>
            </div>
          </Reveal>
        </div>
      </div>
    </section>
  );
}
