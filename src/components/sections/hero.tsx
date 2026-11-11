"use client";

import Image from "next/image";
import {
  ChevronDown,
  Clock,
  Dumbbell,
  MapPin,
  MessageCircle,
  ShoppingBag,
} from "lucide-react";
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
        <div className="absolute inset-0 bg-[radial-gradient(1100px_600px_at_15%_100%,#22330a_0%,transparent_62%)]" />

        {/* Auroras: luz viva detrás del título — nivel Vercel/Linear. */}
        <div
          className="aurora-a absolute -top-24 right-[-12%] size-[26rem] rounded-full bg-brand/25 blur-[100px]"
          aria-hidden="true"
        />
        <div
          className="aurora-b absolute bottom-[-10rem] left-[-12%] size-[30rem] rounded-full bg-[#3d7a2f]/30 blur-[110px]"
          aria-hidden="true"
        />

        {fachada ? (
          <Image
            src="/images/fachada.jpg"
            alt=""
            fill
            priority
            sizes="100vw"
            className="object-cover object-center opacity-90 brightness-110 saturate-125"
          />
        ) : null}

        {/* Velos livianos: la foto del gym SE VE; el texto sigue mandando. */}
        <div className="absolute inset-0 bg-gradient-to-b from-night/70 via-night/45 to-night" />
        <div className="absolute inset-0 bg-gradient-to-r from-night/90 via-night/55 to-transparent" />
        <div className="absolute inset-0 bg-grid-dark opacity-50" />
      </div>

      <div className="container-x">
        {/* En ordenador: dos columnas — el texto manda a la izquierda y un
            panel de cifras llena el vacío a la derecha. En móvil, apilado. */}
        <div className="grid min-h-[calc(100svh-4rem)] items-center gap-10 py-14 sm:py-20 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] lg:py-24">
          <div className="max-w-3xl">
            {/* Dónde estamos */}
            <Reveal>
              <span className="inline-flex items-center gap-2 rounded-full border border-brand/45 bg-brand/15 py-1.5 pr-4 pl-1.5 text-[0.75rem] font-semibold text-white sm:text-[0.8125rem]">
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
                <span className="titulo-brillo block text-gradient-brand">{dict.hero.titleAccent}</span>
                <span className="block text-white/35">{dict.hero.titleBottom}</span>
              </h1>
            </Reveal>

            {/* Bajada */}
            <Reveal delay={160}>
              <p className="mt-6 max-w-xl text-[0.9375rem] leading-relaxed text-white/75 sm:mt-8 sm:text-base">
                {subtitle}
              </p>
            </Reveal>

            {/* Botones: el primario convierte (precios), el secundario captura
                (lead). El WhatsApp pasa a acceso directo: sirve a quien ya
                decidió hablar, no al que recién aterriza. */}
            <Reveal delay={240}>
              <div className="mt-8 flex flex-col gap-3 sm:flex-row sm:items-center">
                <ButtonLink
                  href={`/${locale}#planes`}
                  size="lg"
                  className="cta-energia w-full sm:w-auto"
                >
                  {dict.hero.primary}
                </ButtonLink>

                <ButtonLink
                  href={`/${locale}#interesado`}
                  variant="outline-dark"
                  size="lg"
                  className="w-full sm:w-auto"
                >
                  {dict.hero.secondary}
                </ButtonLink>
              </div>

              {/* Accesos directos: la primera pantalla ofrece todo sin scroll. */}
              <nav
                aria-label={
                  locale === "es" ? "Accesos directos" : "Quick links"
                }
                className="mt-4 flex flex-wrap items-center gap-2"
              >
                {(
                  [
                    { href: `/${locale}/horarios`, label: dict.hero.quick.horarios, Icon: Clock },
                    { href: `/${locale}#clases`, label: dict.hero.quick.clases, Icon: Dumbbell },
                    { href: `/${locale}#tienda`, label: dict.hero.quick.tienda, Icon: ShoppingBag },
                  ] as const
                ).map(({ href, label, Icon }) => (
                  <a
                    key={href}
                    href={href}
                    className="inline-flex items-center gap-1.5 rounded-full border border-white/20 bg-white/5 px-3.5 py-1.5 text-[0.8125rem] font-semibold text-white/80 transition-colors hover:border-brand/50 hover:bg-brand/10 hover:text-brand"
                  >
                    <Icon className="size-3.5" aria-hidden="true" />
                    {label}
                  </a>
                ))}
                <a
                  href={whatsappLink(
                    locale === "es"
                      ? "Hola, quiero información de Power Box Gym."
                      : "Hi, I would like information about Power Box Gym.",
                  )}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1.5 rounded-full border border-white/20 bg-white/5 px-3.5 py-1.5 text-[0.8125rem] font-semibold text-white/80 transition-colors hover:border-brand/50 hover:bg-brand/10 hover:text-brand"
                >
                  <MessageCircle className="size-3.5" aria-hidden="true" />
                  {dict.hero.quick.whatsapp}
                </a>
              </nav>

              {/* Microcopio de confianza: la promesa que SÍ cumplimos. */}
              <p className="mt-4 text-[0.8125rem] leading-relaxed text-white/60">
                {dict.hero.garantia}
              </p>
            </Reveal>

            {/* Datos reales del gimnasio (móvil/tablet) */}
            <Reveal delay={320}>
              <dl
                className={`mt-12 grid max-w-2xl grid-cols-2 gap-x-6 gap-y-7 border-t border-white/15 pt-8 sm:gap-x-4 lg:hidden ${showBoxing ? "sm:grid-cols-4" : "sm:grid-cols-2"}`}
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

          {/* Panel de cifras (ordenador): vidrio esmerilado 2×2, llena el
              vacío derecho y muestra las fortalezas de un vistazo. */}
          <Reveal delay={200} className="hidden lg:block">
            <dl className="grid grid-cols-2 gap-px overflow-hidden rounded-3xl border border-white/10 bg-white/[0.06] backdrop-blur-md">
              {stats.map((stat) => (
                <div key={stat.label} className="bg-night/50 px-6 py-7">
                  <dt className="sr-only">{stat.label}</dt>
                  <dd>
                    <span className="display-xl block text-[2.25rem] text-brand">{stat.value}</span>
                    <span className="mt-1.5 block text-[0.75rem] leading-snug text-white/55">
                      {stat.label}
                    </span>
                  </dd>
                </div>
              ))}
            </dl>
          </Reveal>
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
