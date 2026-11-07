import { getDictionary } from "@/i18n/dictionaries";
import type { Locale } from "@/i18n/config";
import { getProductsPublic } from "@/lib/data/queries";
import { readData } from "@/lib/data/read-result";
import { formatCórdobas } from "@/lib/cart";
import { Section, SectionHeading } from "@/components/ui/section";
import { Reveal } from "@/components/ui/reveal";
import { AddToCartButton } from "@/components/cart/add-to-cart-button";

/**
 * Tienda: productos reales del gimnasio (activos, con precio en
 * córdobas). El visitante los agrega al carrito SIN registrarse; los
 * datos se piden recién al generar la orden y el precio lo confirma la
 * base. Sin productos publicados, la sección se calla sola.
 */
export async function Store({ locale }: { locale: Locale }) {
  const dict = getDictionary(locale);
  const es = locale === "es";
  const result = await readData(() => getProductsPublic());
  if (!result.ok || result.data.length === 0) return null;

  return (
    <Section id="tienda" className="border-b border-line bg-cloud">
      <SectionHeading
        eyebrow={es ? "Tienda" : "Store"}
        title={es ? "Suplementos y más" : "Supplements and more"}
        subtitle={
          es
            ? "Precios reales, sin vueltas: agregá al carrito y pagás al generar tu orden."
            : "Real prices, no runaround: add to cart and pay when you place your order."
        }
      />
      <div className="mt-10 grid gap-5 sm:grid-cols-2 sm:mt-14 lg:grid-cols-3">
        {result.data.map((p, index) => (
          <Reveal key={p.id} delay={index * 60}>
            <article className="flex h-full flex-col overflow-hidden rounded-3xl border border-line bg-card">
              {p.image_data ? (
                // eslint-disable-next-line @next/next/no-img-element -- fotos subidas por el gimnasio (data URI JPEG ya comprimida)
                <img
                  src={p.image_data}
                  alt={p.name}
                  loading="lazy"
                  className="aspect-[4/3] w-full object-cover"
                />
              ) : (
                <div
                  className="grid aspect-[4/3] w-full place-items-center bg-paper text-fog"
                  aria-hidden="true"
                >
                  <span className="eyebrow">{p.category}</span>
                </div>
              )}
              <div className="flex flex-1 flex-col gap-3 p-5">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <h3 className="font-bold text-ink">{p.name}</h3>
                    <p className="text-[0.8125rem] text-fog">{p.category}</p>
                  </div>
                  <p className="display-xl text-xl text-brand">{formatCórdobas(Number(p.price))}</p>
                </div>
                <div className="mt-auto pt-2">
                  <AddToCartButton
                    item={{
                      productId: p.id,
                      name: p.name,
                      price: Number(p.price),
                      qty: 1,
                      image: p.image_data,
                    }}
                    label={dict.cart.add}
                    addedLabel={dict.cart.added}
                  />
                </div>
              </div>
            </article>
          </Reveal>
        ))}
      </div>
    </Section>
  );
}
