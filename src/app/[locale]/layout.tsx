import "@fontsource-variable/inter";
import "@fontsource/anton";
import "../globals.css";

import type { Metadata, Viewport } from "next";
import { notFound } from "next/navigation";
import { DemoBanner } from "@/components/layout/demo-banner";
import { SiteFooter } from "@/components/layout/site-footer";
import { SiteShell } from "@/components/layout/site-shell";
import { DayBoundary } from "@/components/layout/day-boundary";
import { StormTransition } from "@/components/layout/storm-transition";
import { SwRegister } from "@/components/sw-register";
import { AppProvider } from "@/components/providers/app-provider";
import { DictionaryProvider } from "@/components/providers/dictionary-provider";
import { Toaster } from "@/components/ui/toaster";
import { getSiteUrl, siteConfig } from "@/config/site";
import { getDictionary } from "@/i18n/dictionaries";
import { isLocale, locales, type Locale } from "@/i18n/config";
import { getCurrentUser } from "@/lib/data/queries";
import { getPublicDisciplineState } from "@/lib/data/public-discipline-state";
import { selectPublicDisciplineText } from "@/lib/public-disciplines";
import { DEMO_MODE, CONFIGURATION_UNAVAILABLE } from "@/lib/supabase/env";

export function generateStaticParams() {
  return locales.map((locale) => ({ locale }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const siteUrl = getSiteUrl();
  const metadataBase = new URL(siteUrl);
  if (!isLocale(locale)) return { metadataBase };

  const dict = getDictionary(locale);
  const { visibility } = await getPublicDisciplineState();
  const description = selectPublicDisciplineText(visibility, {
    both: dict.meta.description,
    boxingOnly: dict.meta.descriptionBoxingOnly,
    danceOnly: dict.meta.descriptionDanceOnly,
    weightsOnly: dict.meta.descriptionWeightsOnly,
  });

  return {
    metadataBase,
    title: {
      default: dict.meta.title,
      template: `%s | ${siteConfig.name}`,
    },
    description,
    keywords: dict.meta.keywords,
    applicationName: siteConfig.name,
    alternates: {
      canonical: `${siteUrl}/${locale}`,
      languages: {
        es: `${siteUrl}/es`,
        en: `${siteUrl}/en`,
        "x-default": `${siteUrl}/es`,
      },
    },
    openGraph: {
      type: "website",
      siteName: siteConfig.name,
      title: dict.meta.title,
      description,
      url: `${siteUrl}/${locale}`,
      locale: locale === "es" ? "es_NI" : "en_US",
    },
    twitter: {
      card: "summary_large_image",
      title: dict.meta.title,
      description,
    },
    robots: { index: !CONFIGURATION_UNAVAILABLE, follow: !CONFIGURATION_UNAVAILABLE },
    // El manifest se declara en `manifest.ts`; acá referenciamos los
    // íconos y el app-capable de iOS. appleWebApp hace que Safari
    // muestre "Añadir a pantalla de inicio" y abra la app en modo
    // standalone (sin barra de Safari).
    appleWebApp: {
      capable: true,
      title: siteConfig.shortName,
      statusBarStyle: "black-translucent",
    },
    icons: {
      icon: [
        { url: "/icon.svg", type: "image/svg+xml" },
        { url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
        { url: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
      ],
      apple: [{ url: "/icons/apple-touch-icon.png", sizes: "180x180" }],
    },
  };
}

export const viewport: Viewport = {
  themeColor: "#0c0c0e",
  width: "device-width",
  initialScale: 1,
  colorScheme: "dark",
  viewportFit: "cover",
};

/**
 * Splash screens de iOS: cada iPhone (y iPad) usa el que coincide con su
 * tamaño exacto. iOS los lee de `<link rel="apple-touch-startup-image">`
 * en el `<head>`; los metemos como tags sueltos en el `<body>` abajo.
 * El status bar queda translúcido para que la franja superior del splash
 * se vea como parte de la app.
 */

/**
 * El sitio se renderiza por request (no estático) porque el header y las
 * páginas privadas dependen de la sesión del usuario. En Vercel esto sigue
 * siendo rápido: Next cachea el resultado de las consultas públicas.
 */
export const dynamic = "force-dynamic";

export default async function LocaleLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();

  const dict = getDictionary(locale as Locale);
  if (CONFIGURATION_UNAVAILABLE) {
    return <html lang={locale}><body><main className="min-h-screen bg-paper px-6 py-24 text-ink">
      <h1 className="text-2xl font-bold">{locale === "en" ? "Service temporarily unavailable" : "Servicio temporalmente no disponible"}</h1>
      <p className="mt-4">{locale === "en" ? "Configuration requires attention. No demo or operations are enabled." : "La configuración requiere revisión. No se activó una demo ni se habilitaron operaciones."}</p>
    </main></body></html>;
  }
  const user = await getCurrentUser();
  const { visibility } = await getPublicDisciplineState();

  return (
    <html lang={locale} suppressHydrationWarning>
      <head>
        {/* Splash screens de iOS (uno por tamaño de pantalla).
            iOS los lee sólo si están acá, no sirven desde Next metadata. */}
        <link
          rel="apple-touch-startup-image"
          href="/splash/splash-640x1136.png"
          media="(device-width: 320px) and (device-height: 568px) and (-webkit-device-pixel-ratio: 2)"
        />
        <link
          rel="apple-touch-startup-image"
          href="/splash/splash-750x1334.png"
          media="(device-width: 375px) and (device-height: 667px) and (-webkit-device-pixel-ratio: 2)"
        />
        <link
          rel="apple-touch-startup-image"
          href="/splash/splash-1242x2208.png"
          media="(device-width: 414px) and (device-height: 736px) and (-webkit-device-pixel-ratio: 3)"
        />
        <link
          rel="apple-touch-startup-image"
          href="/splash/splash-1125x2436.png"
          media="(device-width: 375px) and (device-height: 812px) and (-webkit-device-pixel-ratio: 3)"
        />
      </head>
      <body className="min-h-dvh bg-paper text-ink antialiased">
        <DictionaryProvider dict={dict} locale={locale as Locale}>
          <AppProvider initialUser={user} isDemo={DEMO_MODE}>
            <a
              href="#contenido"
              className="sr-only focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-[100] focus:rounded-full focus:bg-brand focus:px-4 focus:py-2 focus:text-sm focus:font-semibold focus:text-onbrand"
            >
              {locale === "es" ? "Saltar al contenido" : "Skip to content"}
            </a>

            <SiteShell
              banner={DEMO_MODE ? <DemoBanner /> : null}
              bookCtaEnabled={visibility.showBoxing}
              footer={
                <SiteFooter
                  locale={locale as Locale}
                  showBoxing={visibility.showBoxing}
                  showZumba={visibility.showZumba}
                />
              }
            >
              {children}
            </SiteShell>
            <Toaster />
            {/* Mientras se abre otra pantalla, una capa de fuego a pantalla
                completa cubre la espera y se retira sola al terminar. */}
            <StormTransition />
            {/* OP-07: cuando cambia el día en Managua, las pantallas abiertas
                se refrescan solas, sin recargar ni perder lo escrito. */}
            <DayBoundary />
            {/* Registra el service worker. Solo se monta en producción
                (`process.env.NODE_ENV === "production"`) y si el navegador
                lo soporta, así que en dev local no interferimos. */}
            <SwRegister />
          </AppProvider>
        </DictionaryProvider>
      </body>
    </html>
  );
}
