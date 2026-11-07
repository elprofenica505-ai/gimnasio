import { NextResponse, type NextRequest } from "next/server";
import { LOCALE_COOKIE, defaultLocale, detectLocale, isLocale } from "@/i18n/config";
import { CONFIGURATION_UNAVAILABLE } from "@/lib/supabase/env";
import { updateSession } from "@/lib/supabase/proxy-client";

/**
 * Decide a qué idioma mandar al usuario: primero la cookie
 * (elección explícita), después el idioma del navegador.
 */
function pickLocale(request: NextRequest): string {
  const fromCookie = request.cookies.get(LOCALE_COOKIE)?.value;
  if (isLocale(fromCookie)) return fromCookie;
  return detectLocale(request.headers.get("accept-language")) ?? defaultLocale;
}

export default async function proxy(request: NextRequest) {
  const { pathname, search } = request.nextUrl;

  if (CONFIGURATION_UNAVAILABLE && pathname !== "/" &&
      !/^\/(es|en)\/?$/.test(pathname) && !/\/opengraph-image$/.test(pathname) &&
      !pathname.startsWith("/_next/") && !pathname.startsWith("/_vercel/")) {
    const headers = {
      "Cache-Control": "private, no-store",
      "Retry-After": "60",
      "X-Robots-Tag": "noindex",
    };
    if (pathname.startsWith("/api/")) {
      return NextResponse.json({
        error: "CONFIGURATION_UNAVAILABLE",
        message: "Servicio temporalmente no disponible; no se guardó información.",
      }, { status: 503, headers });
    }
    const english = pathname.startsWith("/en/");
    const title = english ? "Service temporarily unavailable" : "Servicio temporalmente no disponible";
    const detail = english
      ? "Configuration requires attention. No demo or operations are enabled."
      : "La configuración requiere revisión. No se activó una demo ni se habilitaron operaciones.";
    // Sólo constantes traducidas; nunca interpolar entradas ni configuración.
    return new NextResponse(`<!doctype html><html lang="${english ? "en" : "es"}">
      <head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
      <title>Power Box Gym — ${title}</title></head>
      <body style="background:#090909;color:#eee;font-family:sans-serif;padding:3rem">
      <h1>${title}</h1><p>${detail}</p></body></html>`, {
      status: 503, headers: { ...headers, "Content-Type": "text/html; charset=utf-8" },
    });
  }

  const segments = pathname.split("/").filter(Boolean);
  const firstSegment = segments[0];
  const hasLocale = isLocale(firstSegment);

  // 1) La raíz redirige al idioma detectado conservando querystring y hash
  //    (ej: /?week=2026-W42 → /es?week=2026-W42).
  if (pathname === "/") {
    const locale = pickLocale(request);
    const url = request.nextUrl.clone();
    url.pathname = `/${locale}`;
    const response = NextResponse.redirect(url);
    response.cookies.set(LOCALE_COOKIE, locale, {
      path: "/",
      maxAge: 60 * 60 * 24 * 365,
      sameSite: "lax",
    });
    return updateSession(request, response);
  }

  // 2) Si no empieza con un idioma válido (y no es un asset o API),
  //    lo mandamos al idioma preferido con la misma ruta.
  //    Ojo con los archivos: cualquier ruta que termine en extensión
  //    (logo.png, trueno.mp3, sw.js…) es un archivo, no una pantalla. Si se
  //    le antepone el idioma, el archivo no existe y el pedido se pierde.
  const isSystemPath =
    pathname.startsWith("/api") ||
    pathname.startsWith("/_next") ||
    pathname.startsWith("/_vercel") ||
    pathname === "/robots.txt" ||
    pathname === "/sitemap.xml" ||
    pathname === "/manifest.webmanifest" ||
    pathname === "/favicon.ico" ||
    /\.[a-zA-Z0-9]+$/.test(pathname) ||
    /\.[a-zA-Z0-9]+$/.test(firstSegment ?? "");

  if (!hasLocale && !isSystemPath) {
    const locale = pickLocale(request);
    const url = request.nextUrl.clone();
    url.pathname = `/${locale}${pathname}`;
    return NextResponse.redirect(url);
  }

  const response = NextResponse.next();
  if (CONFIGURATION_UNAVAILABLE) response.headers.set("Cache-Control", "private, no-store");

  // 3) Recordamos el idioma que el usuario está navegando.
  if (hasLocale) {
    response.cookies.set(LOCALE_COOKIE, firstSegment, {
      path: "/",
      maxAge: 60 * 60 * 24 * 365,
      sameSite: "lax",
    });
  }

  // 4) Refrescamos la sesión de Supabase (si está configurado).
  return updateSession(request, response);
}

export const config = {
  matcher: [
    /*
     * Todas las rutas menos:
     *  - archivos de Next (_next/static, _next/image)
     *  - archivos estáticos de /public
     */
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|avif|ico|woff|woff2|ttf|otf|txt|xml|webmanifest|mp3|m4a|ogg|wav|mp4|webm|pdf)$).*)",
  ],
};
