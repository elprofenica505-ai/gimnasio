import { ArrowRight, Banknote, ClipboardCheck, Zap } from "lucide-react";
import { getDictionary } from "@/i18n/dictionaries";
import { ButtonLink } from "@/components/ui/button";
import { Reveal } from "@/components/ui/reveal";
import { Section, SectionHeading } from "@/components/ui/section";
import type { Locale } from "@/i18n/config";

const PASOS = [
  { Icon: ClipboardCheck, t: "s1t", d: "s1d" },
  { Icon: Banknote, t: "s2t", d: "s2d" },
  { Icon: Zap, t: "s3t", d: "s3d" },
] as const;

/**
 * El flujo de compra en 3 pasos, arriba de todo: la secuencia lógica que la
 * página ya cumple de verdad (elegir plan → pagar online → activación el
 * mismo día) pero VISIBLE. Le dice al visitante a dónde ir y por qué confiar.
 */
export function Pasos({ locale }: { locale: Locale }) {
  const p = getDictionary(locale).pasos;

  return (
    <Section id="como-funciona" className="border-b border-line">
      <SectionHeading eyebrow={p.eyebrow} title={p.title} subtitle={p.subtitle} />
      <div className="mt-10 grid gap-4 sm:grid-cols-3">
        {PASOS.map(({ Icon, t, d }, i) => (
          <Reveal key={t} delay={i * 90}>
            <div className="relative h-full rounded-3xl border border-line bg-card p-6">
              <span
                className="absolute top-5 right-5 text-[2.25rem] leading-none font-black text-line select-none"
                aria-hidden="true"
              >
                {i + 1}
              </span>
              <span className="grid size-11 place-items-center rounded-2xl bg-brand/15 text-brand-300">
                <Icon className="size-5" aria-hidden="true" />
              </span>
              <h3 className="mt-4 text-[1.0625rem] font-bold text-white">{p[t]}</h3>
              <p className="mt-1.5 text-[0.875rem] leading-relaxed text-fog">{p[d]}</p>
            </div>
          </Reveal>
        ))}
      </div>
      <Reveal delay={280}>
        <div className="mt-8 flex justify-center">
          <ButtonLink href={`/${locale}#planes`} size="md">
            {p.cta}
            <ArrowRight className="size-4" aria-hidden="true" />
          </ButtonLink>
        </div>
      </Reveal>
    </Section>
  );
}
