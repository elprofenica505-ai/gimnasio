import type { LegalDocument } from "@/lib/legal/texts";
import { SectionHeading } from "@/components/ui/section";

/** Página legal: texto con secciones numeradas y aviso de borrador visible. */
export function LegalDocumentView({ doc, locale }: { doc: LegalDocument; locale: "es" | "en" }) {
  const draftNote = locale === "en"
    ? "Draft text pending legal review. Final wording may change."
    : "Texto en borrador, pendiente de revisión legal. La redacción final puede cambiar.";
  return (
    <>
      <section className="relative overflow-hidden border-b border-brand/25 bg-cloud pt-10 pb-8 sm:pt-12 sm:pb-10">
        <div className="container-x relative">
          <SectionHeading eyebrow="Power Box Gym" title={doc.title} subtitle={doc.intro} />
        </div>
      </section>
      <section className="py-8 sm:py-10">
        <div className="container-x grid max-w-3xl gap-6">
          <p className="rounded-xl border border-brand/30 bg-brand/[0.06] px-4 py-3 text-[0.8125rem] text-mist">{draftNote}</p>
          {doc.sections.map((s) => (
            <article key={s.title} className="grid gap-2">
              <h2 className="text-lg font-bold text-ink">{s.title}</h2>
              {s.paragraphs.map((t, i) => (<p key={i} className="text-[0.95rem] leading-relaxed text-mist">{t}</p>))}
              {s.items && (
                <ul className="list-disc pl-5 text-[0.95rem] leading-relaxed text-mist">
                  {s.items.map((t, i) => (<li key={i}>{t}</li>))}
                </ul>
              )}
            </article>
          ))}
        </div>
      </section>
    </>
  );
}
