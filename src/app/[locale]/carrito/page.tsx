import type { Metadata } from "next";
import { CartView } from "@/components/cart/cart-view";
import { isLocale } from "@/i18n/config";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const es = !isLocale(locale) || locale === "es";
  return {
    title: es ? "Tu carrito" : "Your cart",
    robots: { index: false, follow: false },
  };
}

/** Carrito del visitante: sin cuenta; los datos se piden al pagar. */
export default async function CarritoPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale: rawLocale } = await params;
  const locale = isLocale(rawLocale) ? rawLocale : "es";
  return <CartView locale={locale} />;
}
