import { Suspense } from "react";
import type { Metadata } from "next";
import { CheckoutFlow } from "@/components/checkout/checkout-flow";
import { getPlans } from "@/lib/data/queries";
import { readData } from "@/lib/data/read-result";
import { isLocale, type Locale } from "@/i18n/config";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const es = !isLocale(locale) || locale === "es";
  return {
    title: es ? "Comprar membresía" : "Buy a membership",
    robots: { index: false, follow: false },
  };
}

export default async function CheckoutPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale: rawLocale } = await params;
  const locale: Locale = isLocale(rawLocale) ? rawLocale : "es";
  const result = await readData(() => getPlans());
  // Sólo los planes NIO con precio publicado entran al checkout online
  // (el mismo criterio que valida la base en embudo_crear_orden).
  const planes = result.ok
    ? result.data
        .filter((p) => p.is_active && p.price_nio !== null && p.price_nio !== undefined)
        .map((p) => ({
          id: p.id,
          slug: p.slug,
          nombre: locale === "es" ? p.name_es : p.name_en,
          periodo: p.period as string,
          precio: Number(p.price_nio),
        }))
    : [];

  return (
    <Suspense
      fallback={
        <section className="container-x flex min-h-[60vh] items-center justify-center text-fog">
          …
        </section>
      }
    >
      <CheckoutFlow locale={locale} planes={planes} />
    </Suspense>
  );
}
