/* Service Worker de Power Box Gym.
 *
 * Estrategia:
 *   - Assets estáticos (imágenes, JS, CSS, fuentes): cache-first. Si el
 *     archivo está en caché, se sirve desde ahí; si no, se baja de la
 *     red y se guarda. El navegador puede llegar a tener cientos de KB
 *     en caché, que es lo que hace que la app abra instantánea aún sin
 *     red.
 *   - Páginas HTML: red con fallback a la pantalla offline. No guardar
 *     HTML personalizado: incluso el inicio contiene menú y sesión.
 *     Sólo las pantallas /es/offline y /en/offline admiten caché.
 *   - API y Supabase: nunca se cachean. Reservar, cancelar, login y
 *     todo lo que toca la base de datos va SIEMPRE por la red; si
 *     falla, la app muestra el error y se acabó.
 *
 * Versión del caché: cambiarla fuerza al SW a descartar todo el
 * caché viejo en la próxima activación.
 */
const CACHE_VERSION = "power-box-v13";
const ASSET_CACHE = `${CACHE_VERSION}-assets`;
const PAGE_CACHE = `${CACHE_VERSION}-pages`;

const PRECACHE_ASSETS = [
  "/es/offline",
  "/en/offline",
  "/icon.svg",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/icons/maskable-512.png",
  "/icons/apple-touch-icon.png",
  "/splash/splash-1125x2436.png",
  "/splash/splash-1242x2208.png",
  "/splash/splash-750x1334.png",
  "/splash/splash-640x1136.png",
  // Emblema de la pantalla de carga (tiene que estar antes del primer toque).
  "/brand/emblema-strong.webp",
  // Trueno de la pantalla de carga (12 KB).
  "/sounds/trueno.mp3",
  // Imágenes reales del gimnasio (las que usa la página).
  "/images/fachada.jpg",
  "/images/grupo.jpg",
  "/images/pesas.jpg",
  "/images/sala1.jpg",
  "/images/sala2.jpg",
  "/images/pareja1.jpg",
  "/images/cambio.jpg",
  "/images/boxeo.jpg",
  "/images/sacos.jpg",
  "/images/abs.jpg",
  "/images/triceps.jpg",
  "/images/pantorrilla.jpg",
  "/images/dip.jpg",
  "/images/supl1.jpg",
];

/* Sólo cacheamos páginas de nuestro propio sitio; cualquier otro origen
   (Supabase, Google Fonts, etc.) va por la red sin cachear. */
const isSameOrigin = (url) => url.origin === self.location.origin;

const isAsset = (req) => {
  const dest = req.destination;
  return (
    dest === "image" ||
    dest === "script" ||
    dest === "style" ||
    dest === "font" ||
    dest === "manifest"
  );
};

const isNavigation = (req) => req.mode === "navigate";

self.addEventListener("install", (event) => {
  // Tomamos el control apenas se instala, sin esperar a que se cierren
  // las pestañas viejas. Así la primera visita offline ya funciona.
  event.waitUntil(
    (async () => {
      const cache = await caches.open(ASSET_CACHE);
      // addAll falla si UNA URL falla. Usamos individual para que la
      // SW se instale aunque falte una imagen puntual.
      await Promise.all(
        PRECACHE_ASSETS.map((url) =>
          cache.add(url).catch(() => {
            // Si un asset no existe todavía, lo dejamos fuera de la
            // precarga; igual lo cachearemos la primera vez que el
            // usuario lo pida.
          }),
        ),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  // Limpiamos caches de versiones viejas.
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((k) => !k.startsWith(CACHE_VERSION))
          .map((k) => caches.delete(k)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;

  // Sólo GET.
  if (req.method !== "GET") return;
  // Sólo mismo origen (no cacheamos Supabase ni nada externo).
  const url = new URL(req.url);
  if (!isSameOrigin(url)) return;
  // El manifest, el SW y los endpoints de Next no se tocan.
  if (url.pathname === "/sw.js" || url.pathname.startsWith("/api/")) return;

  if (isNavigation(req)) {
    event.respondWith(networkFirstPage(req));
  } else if (isAsset(req)) {
    event.respondWith(cacheFirstAsset(req));
  }
  // RSC/prefetch y otros requests: red normal, nunca un HTML cacheado.
});

async function cacheFirstAsset(req) {
  const cache = await caches.open(ASSET_CACHE);
  const cached = await cache.match(req);
  if (cached) {
    // Refresco en background (stale-while-revalidate) para que la
    // próxima vez tenga la versión nueva.
    fetch(req)
      .then((res) => {
        if (res && res.ok) cache.put(req, res.clone());
      })
      .catch(() => {});
    return cached;
  }
  try {
    const res = await fetch(req);
    if (res && res.ok) cache.put(req, res.clone());
    return res;
  } catch (err) {
    // Sin red y sin caché: mejor un 504 honesto que un fallo raro.
    return new Response("", { status: 504, statusText: "Offline" });
  }
}

async function networkFirstPage(req) {
  const cache = await caches.open(PAGE_CACHE);
  try {
    const res = await fetch(req);
    if (res && res.ok && /^\/(es|en)\/offline$/.test(new URL(req.url).pathname)) {
      await cache.put(req, res.clone());
    }
    return res;
  } catch (err) {
    // No devolver una sesión/denegación anterior de /panel o /mi-cuenta.
    // Fallback: la página offline del idioma correcto (si la podemos
    // deducir) o genérica.
    const acceptLang = req.headers.get("accept-language") || "";
    const isEn = acceptLang.toLowerCase().startsWith("en");
    const offlineUrl = isEn ? "/en/offline" : "/es/offline";
    const offline = await cache.match(offlineUrl);
    if (offline) return offline;
    return new Response(
      "<h1>Sin conexión</h1><p>Volvé a conectarte a internet para usar Power Box Gym.</p>",
      { status: 503, headers: { "content-type": "text/html; charset=utf-8" } },
    );
  }
}
