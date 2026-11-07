import { readData } from "@/lib/data/read-result";
import { DataUnavailable } from "@/components/ui/data-unavailable";
import { Check, Sparkles } from "lucide-react";
import { getDictionary } from "@/i18n/dictionaries";
import type { Locale } from "@/i18n/config";
import { formatPrice, whatsappLink } from "@/config/site";
import { getPlans } from "@/lib/data/queries";
import { formatMoney } from "@/lib/finance/format-money";
import { Section, SectionHeading } from "@/components/ui/section";
import { Reveal } from "@/components/ui/reveal";
import { ButtonLink } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import {
  isPlanVisibleForDisciplines,
  publicDisciplineVisibility,
} from "@/lib/public-disciplines";

export async function Plans({
  locale,
  activeClassSlugs,
}: {
  locale: Locale;
  activeClassSlugs?: string[];
}) {
  const dict = getDictionary(locale);
  const result = await readData(() => getPlans());
  if (!result.ok)
    return (
      <Section id="planes">
        <DataUnavailable locale={locale} code={result.code} />
      </Section>
    );
  const visibility = publicDisciplineVisibility(activeClassSlugs);
  const plans = result.data.filter((plan) =>
    isPlanVisibleForDisciplines(plan.slug, visibility),
  );
  // Orden fijo del diccionario: el tercer beneficio menciona el área de boxeo.
  const included = dict.plans.included.map((item, index) =>
    !visibility.showBoxing && index === 2 ? dict.plans.changingRoom : item,
  );

  return (
    <Section id="planes" className="border-b border-line">
      <SectionHeading
        eyebrow={dict.nav.plans}
        title={dict.plans.title}
        subtitle={dict.plans.subtitle}
      />

      {plans.length === 0 && (
        <p className="mt-10 text-fog">
          {locale === "es"
            ? "No hay planes publicados por el momento."
            : "No plans are currently published."}
        </p>
      )}
      <div className="mt-10 grid gap-5 sm:mt-14 sm:grid-cols-2 lg:grid-cols-3">
        {plans.map((plan, index) => {
          const name = locale === "es" ? plan.name_es : plan.name_en;
          const tagline = locale === "es" ? plan.tagline_es : plan.tagline_en;
          const features =
            locale === "es" ? plan.features_es : plan.features_en;

          // La tarifa NIO está separada del precio histórico en USD. Si un
          // plan trae una tarifa válida en córdobas, esa es la que se publica.
          const nioPrice =
            plan.price_nio === null || plan.price_nio === undefined
              ? null
              : Number(plan.price_nio);
          const price =
            nioPrice !== null && Number.isFinite(nioPrice) && nioPrice > 0
              ? formatMoney(nioPrice, "NIO")
              : formatPrice(plan.price);
          const visibleFeatures = price
            ? features.filter(
                (feature) =>
                  feature !== "Consultá el precio por WhatsApp" &&
                  feature !== "Ask for the price on WhatsApp",
              )
            : features;
          const period =
            plan.period === "session"
              ? dict.plans.session
              : plan.period === "week"
                ? dict.plans.week
                : plan.period === "fortnight"
                  ? dict.plans.fortnight
                  : dict.plans.month;

          return (
            <Reveal key={plan.id} delay={index * 70} className="h-full">
              <article
                className={cn(
                  "relative flex h-full flex-col rounded-3xl border p-6 transition-all duration-300 sm:p-7",
                  plan.is_popular
                    ? "glow-brand border-brand/50 bg-gradient-to-b from-brand-soft to-card"
                    : "border-line bg-card shadow-[0_18px_50px_-38px_rgba(216,26,34,0.45)] hover:border-brand/40",
                )}
              >
                {plan.is_popular ? (
                  <span className="absolute -top-3 left-6 inline-flex items-center gap-1.5 rounded-full bg-brand px-3 py-1 text-[0.625rem] font-bold tracking-[0.12em] text-onbrand uppercase">
                    <Sparkles className="size-3" aria-hidden="true" />
                    {dict.plans.popular}
                  </span>
                ) : null}

                <h3 className="display-xl text-[1.5rem] leading-none text-ink">
                  {name}
                </h3>

                <p className="mt-2 min-h-10 text-[0.8125rem] leading-snug text-fog">
                  {tagline}
                </p>

                {/* Si el gimnasio todavía no publicó el precio mostramos
                    "Consultar" en vez de inventar un número. */}
                <p className="mt-6 flex items-baseline gap-1.5">
                  <span
                    className={cn(
                      "display-xl leading-none",
                      price ? "text-[2.75rem]" : "text-[1.75rem]",
                      plan.is_popular ? "text-brand-300" : "text-ink",
                    )}
                  >
                    {price ?? dict.plans.consult}
                  </span>
                  {price ? (
                    <span className="text-[0.75rem] text-fog">{period}</span>
                  ) : null}
                </p>

                <ul className="mt-6 flex flex-1 flex-col gap-3 border-t border-line pt-6">
                  {visibleFeatures.map((feature) => (
                    <li key={feature} className="flex items-start gap-2.5">
                      <Check
                        className="mt-0.5 size-4 shrink-0 text-brand"
                        strokeWidth={2.75}
                        aria-hidden="true"
                      />
                      <span className="text-[0.8125rem] leading-snug text-mist">
                        {feature}
                      </span>
                    </li>
                  ))}
                </ul>

                {plan.price_nio !== null && plan.price_nio !== undefined ? (
                  <div className="mt-7 flex flex-col gap-2">
                    <ButtonLink
                      href={`/${locale}/checkout?plan=${plan.id}`}
                      variant="primary"
                      size="md"
                      className="w-full"
                    >
                      {locale === "es" ? "Comprar ahora" : "Buy now"}
                    </ButtonLink>
                    <ButtonLink
                      href={whatsappLink(
                        locale === "es"
                          ? `Hola, me interesa el plan ${name}.`
                          : `Hi, I am interested in the ${name} plan.`,
                      )}
                      target="_blank"
                      rel="noopener noreferrer"
                      variant="outline"
                      size="md"
                      className="w-full"
                    >
                      {locale === "es" ? "Preguntar por WhatsApp" : "Ask on WhatsApp"}
                    </ButtonLink>
                  </div>
                ) : (
                  <ButtonLink
                    href={whatsappLink(
                      locale === "es"
                        ? `Hola, me interesa el plan ${name}.`
                        : `Hi, I am interested in the ${name} plan.`,
                    )}
                    target="_blank"
                    rel="noopener noreferrer"
                    variant={plan.is_popular ? "primary" : "outline"}
                    size="md"
                    className="mt-7 w-full"
                  >
                    {price ? dict.plans.choose : dict.plans.ask}
                  </ButtonLink>
                )}
              </article>
            </Reveal>
          );
        })}
      </div>

      {/* Qué incluyen todos los planes */}
      <Reveal delay={120} className="mt-8">
        <div className="rounded-2xl border border-line bg-card p-6 sm:p-7">
          <p className="text-[0.8125rem] font-semibold tracking-[0.14em] text-mist uppercase">
            {dict.plans.allIncluded}
          </p>

          <ul className="mt-4 grid gap-x-8 gap-y-3 sm:grid-cols-2 lg:grid-cols-4">
            {included.map((item) => (
              <li key={item} className="flex items-start gap-2.5">
                <Check
                  className="mt-0.5 size-4 shrink-0 text-brand"
                  strokeWidth={2.75}
                  aria-hidden="true"
                />
                <span className="text-[0.8125rem] leading-snug text-fog">
                  {item}
                </span>
              </li>
            ))}
          </ul>

          <p className="mt-5 border-t border-line pt-4 text-[0.75rem] text-fog">
            {dict.plans.note}
          </p>
        </div>
      </Reveal>
    </Section>
  );
}
