"use client";

import Image from "next/image";
import { ChevronDown, MapPin, MessageCircle } from "lucide-react";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { ButtonLink } from "@/components/ui/button";
import { Reveal } from "@/components/ui/reveal";
import { whatsappLink } from "@/config/site";
import {
  selectPublicDisciplineText,
  type PublicDisciplineVisibility,
} from "@/lib/public-disciplines";

/**
 * Portada: la foto real de la fachada de noche, con la banderola roja
 * encendida. Es el único bloque "negro" junto con la cinta y el pie,
 * igual que el cartel del local.
 *
 * Si la foto todavía no está subida, el degradado rojo/negro de abajo
 * sostiene el diseño solo: nunca se ve un hueco blanco.
 */
export function Hero({
  fachada = false,
  showBoxing = true,
  showZumba = true,
}: { fachada?: boolean } & Partial<PublicDisciplineVisibility>) {
  const { dict, locale } = useDictionary();
  const visibility = { showBoxing, showZumba };
  const subtitle = selectPublicDisciplineText(visibility, {
    both: dict.hero.subtitle,
    boxingOnly: dict.hero.subtitleBoxingOnly,
    danceOnly: dict.hero.subtitleDanceOnly,
    weightsOnly: dict.hero.subtitleWeightsOnly,
  });
  // El orden del diccionario es: días, clases de boxeo, apertura y boxeo/mes.
  const stats = dict.hero.stats.filter(
    (_, index) => showBoxing || (index !== 1 && index !== 3),
  );

  return (
    <section className="relative isolate overflow-hidden bg-night">
      {/* Fondo */}
      <div className="absolute inset-0 -z-10">
        <div className="absolute inset-0 bg-[radial-gradient(1100px_600px_at_15%_100%,#7a0f14_0%,transparent_62%)]" />

        {fachada ? (
          <Image
            src="/images/fachada.jpg"
            alt=""
            fill
            priority
            sizes="100vw"
            className="object-cover object-center opacity-70"
          />
        ) : null}

        <div className="absolute inset-0 bg-gradient-to-b from-night/85 via-night/60 to-night" />
        <div className="absolute inset-0 bg-gradient-to-r from-night via-night/75 to-transparent" />
        <div className="absolute inset-0 bg-grid-dark opacity-50" />
      </div>

      <div className="container-x">
        <div className="flex min-h-[calc(100svh-4rem)] flex-col justify-center py-14 sm:py-20 lg:min-h-[44rem] lg:py-24">
          <div className="max-w-3xl">
            {/* Dónde estamos */}
            <Reveal>
              <span className="inline-flex items-center gap-2 rounded-full border border-brand/45 bg-brand/15 py-1.5 pr-4 pl-1.5 text-[0.75rem] font-semibold text-white backdrop-blur-sm sm:text-[0.8125rem]">
                <span className="grid size-6 place-items-center rounded-full bg-brand text-onbrand">
                  <MapPin className="size-3.5" aria-hidden="true" />
                </span>
                {dict.hero.badge}
              </span>
            </Reveal>

            {/* Título */}
            <Reveal delay={80}>
              <h1 className="display-xl mt-6 text-[3.25rem] leading-[0.86] sm:text-[4.5rem] lg:text-[6.5rem] xl:text-[7.5rem]">
                <span className="block text-white">{dict.hero.titleTop}</span>
                <span className="block text-gradient-brand">{dict.hero.titleAccent}</span>
                <span className="block text-white/35">{dict.hero.titleBottom}</span>
              </h1>
            </Reveal>

            {/* Bajada */}
            <Reveal delay={160}>
              <p className="mt-6 max-w-xl text-[0.9375rem] leading-relaxed text-white/75 sm:mt-8 sm:text-base">
                {subtitle}
              </p>
            </Reveal>

            {/* Botones */}
            <Reveal delay={240}>
              <div className="mt-8 flex flex-col gap-3 sm:flex-row sm:items-center">
                <ButtonLink
                  href={whatsappLink(
                    locale === "es"
                    ? "Hola, quiero información de Power Box Gym."
                    : "Hi, I would like information about Power Box Gym.",
                  )}
                  target="_blank"
                  rel="noopener noreferrer"
                  size="lg"
                  className="w-full sm:w-auto"
                >
                  <MessageCircle className="size-4.5" aria-hidden="true" />
                  {dict.hero.primary}
                </ButtonLink>

                <ButtonLink
                  href={`/${locale}#galeria`}
                  variant="outline-dark"
                  size="lg"
                  className="w-full sm:w-auto"
                >
                  {dict.hero.secondary}
                </ButtonLink>
              </div>
            </Reveal>

            {/* Datos reales del gimnasio */}
            <Reveal delay={320}>
              <dl
                className={`mt-12 grid max-w-2xl grid-cols-2 gap-x-6 gap-y-7 border-t border-white/15 pt-8 sm:gap-x-4 ${showBoxing ? "sm:grid-cols-4" : "sm:grid-cols-2"}`}
              >
                {stats.map((stat) => (
                  <div key={stat.label}>
                    <dt className="sr-only">{stat.label}</dt>
                    <dd>
                      <span className="display-xl block text-[1.75rem] text-brand sm:text-[2rem]">
                        {stat.value}
                      </span>
                      <span className="mt-1 block text-[0.75rem] leading-snug text-white/55">
                        {stat.label}
                      </span>
                    </dd>
                  </div>
                ))}
              </dl>
            </Reveal>
          </div>
        </div>
      </div>

      {/* Indicador de scroll */}
      <div className="hidden justify-center pb-6 lg:flex">
        <a
          href="#por-que"
          className="flex flex-col items-center gap-2 text-[0.6875rem] tracking-[0.2em] text-white/50 uppercase transition-colors hover:text-brand"
        >
          {dict.hero.scroll}
          <ChevronDown className="size-4 animate-bounce" aria-hidden="true" />
        </a>
      </div>
    </section>
  );
}
