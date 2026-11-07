import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

/**
 * «Cargando»: que la app nunca se vea congelada.
 *
 * Lo que pedía el dueño: al tocar un módulo, una tarjeta o al entrar después
 * del segundo factor, la pantalla se quedaba quieta y no había ninguna figura
 * que confirmara que estaba trabajando; la gente tocaba dos veces.
 *
 * Lo que el gimnasio pidió, después de dos intentos:
 *   1. **Nada** de esqueletos grises que borren letras e imágenes (se probó y se
 *      rechazó: daba sensación de pausa).
 *   2. Una **capa de fuego a pantalla completa** que cubra la interfaz durante
 *      la espera entre módulos y se retire sola al terminar (FireTransition).
 *   3. Un ícono de llama dentro de la tarjeta o módulo tocado (LinkPending),
 *      para saber cuál de todos está abriendo.
 *
 * Las pruebas de abajo fijan las tres cosas.
 */
const source = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("la capa de tormenta está montada en el layout", () => {
  const layout = source("src/app/[locale]/layout.tsx");
  assert.match(layout, /<StormTransition \/>/);
  assert.match(layout, /@\/components\/layout\/storm-transition/);
  // El fuego se retiró a pedido del gimnasio: ahora son rayos de tormenta.
  assert.equal(existsSync(new URL("../src/components/layout/fire-transition.tsx", import.meta.url)), false);
  assert.equal(existsSync(new URL("../public/fire", import.meta.url)), false);

  const css = source("src/app/globals.css");
  assert.match(css, /@keyframes storm-strike/);
  assert.match(css, /@keyframes storm-sky-flash/);
  assert.match(css, /@keyframes storm-progress/);
  assert.match(css, /rgb\(125 211 252/);

  const storm = source("src/components/layout/storm-transition.tsx");
  assert.match(storm, /Cargando…/);
  assert.match(storm, /role="status"/);
  assert.match(storm, /aria-live="polite"/);
  assert.match(storm, /storm-bolt/);
  assert.match(storm, /storm-progress/);
  assert.match(storm, /storm-flash/);
});

test("la capa cubre toda la interfaz y no se queda pegada", () => {
  const css = source("src/app/globals.css");
  assert.match(css, /\.storm-overlay \{[^}]*position: fixed/);
  assert.match(css, /\.storm-overlay \{[^}]*inset: 0/);
  assert.match(css, /\.storm-overlay \{[^}]*z-index: 80/);
  // Cubre de verdad: sin transparencia que deje ver la pantalla a medio pintar.
  assert.match(css, /\.storm-overlay \{[^}]*opacity: 0/);
  assert.match(css, /\.storm-overlay\[data-state="shown"\] \{\s*opacity: 1;/);

  const storm = source("src/components/layout/storm-transition.tsx");
  // Se apaga sola si la pantalla nueva no llega.
  assert.match(storm, /GIVE_UP_MS = 8_000/);
  // Dura un mínimo y se desvanece: ni parpadeo ni corte seco.
  assert.match(storm, /MIN_VISIBLE_MS = 1_100/);
  assert.match(storm, /FADE_OUT_MS = 320/);
  // Y no aparece si la pantalla abre al instante: primero espera 120 ms.
  assert.match(storm, /SHOW_DELAY_MS = 120/);
  assert.match(storm, /setTimeout\(reveal, SHOW_DELAY_MS\)/);
  // Mientras cubre no deja tocar dos veces.
  assert.match(css, /\.storm-overlay \{[^}]*pointer-events: auto/);
  // Nada de filtros de desenfoque: en Android dejan manchas de GPU.
  assert.doesNotMatch(css, /\.storm-(overlay|stage|s)ky[^}]*backdrop-filter/);
  assert.doesNotMatch(storm, /backdrop-blur/);
});

test("la animación respeta «reducir movimiento» sin congelarse", () => {
  const css = source("src/app/globals.css");
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
  // Con la opción activada no hay barridos…
  assert.match(css, /\.storm-stage,\s*\n\s*\.storm-clouds,\s*\n\s*\.storm-progress-fill \{\s*\n\s*animation: none/);
  // …pero la tormenta late: una imagen fija parecía que la app se colgó.
  assert.match(css, /\.storm-bolt,\s*\n\s*\.storm-flash \{\s*\n\s*animation: storm-calm/);
  assert.match(css, /@keyframes storm-calm/);
});

test("la capa no rompe la navegación ni cambia de pantalla por su cuenta", () => {
  const bar = source("src/components/layout/storm-transition.tsx");
  // Observa el toque: nunca cancela el enlace ni cambia la navegación.
  assert.doesNotMatch(bar, /preventDefault\(\)/);
  assert.doesNotMatch(bar, /router\.push/);
  // Ignora lo que no es una pantalla nueva de esta app.
  assert.match(bar, /url\.origin !== window\.location\.origin/);
  assert.match(bar, /anchor\.target/);
  assert.match(bar, /hasAttribute\("download"\)/);
  // Si la dirección no cambia, se apaga sola.
  assert.match(bar, /GIVE_UP_MS/);
  assert.match(bar, /setTimeout\(\(\) => \{[\s\S]{0,120}fadeOut\(\);[\s\S]{0,20}\}, giveUpAfter\)/);
  // «Atrás» con la misma ruta no se queda colgado los 8 s completos.
  assert.match(bar, /start\(null, POPSTATE_GIVE_UP_MS\)/);
  assert.match(bar, /POPSTATE_GIVE_UP_MS = 3_000/);
});

test("la tarjeta tocada muestra su propio ícono de carga", () => {
  const link = source("src/components/ui/link-pending.tsx");
  assert.match(link, /useLinkStatus/);
  assert.match(link, /if \(!pending\) return null/);

  // Navegación del panel y tarjetas del inicio del panel.
  assert.match(source("src/components/admin/panel-nav.tsx"), /<LinkPending/);
  assert.match(source("src/app/[locale]/panel/page.tsx"), /<LinkPending/);
});

test("cambiar de pantalla NO vacía la vista ni la deja en gris", () => {
  // El esqueleto gris se quitó a pedido del gimnasio: parecía una pausa.
  for (const path of [
    "../src/app/[locale]/loading.tsx",
    "../src/app/[locale]/panel/loading.tsx",
  ]) {
    assert.equal(
      existsSync(new URL(path, import.meta.url)),
      false,
      `volvió a aparecer ${path}: no debe vaciar la pantalla al navegar`,
    );
  }
  // Y no queda ningún bloque gris de relleno en el código de avisos.
  const spinner = source("src/components/ui/spinner.tsx");
  assert.doesNotMatch(spinner, /animate-pulse/);
  assert.doesNotMatch(spinner, /LoadingSkeleton/);
});

test("los botones que esperan respuesta avisan y no se pueden tocar dos veces", () => {
  const button = source("src/components/ui/button.tsx");
  assert.match(button, /loading\?: boolean/);
  assert.match(button, /disabled=\{disabled \|\| loading\}/);
  assert.match(button, /aria-busy=\{loading \|\| undefined\}/);
  assert.match(button, /<Spinner size="sm" \/>/);

  // Entrada con correo, contraseña y segundo factor.
  assert.match(source("src/components/auth/auth-form.tsx"), /Loader2 className="size-4 animate-spin"/);
  assert.match(source("src/components/auth/mfa-setup.tsx"), /<Button type="submit" loading=\{busy\}/);
  assert.match(source("src/components/auth/recovery-form.tsx"), /<Button type="submit" loading=\{busy\}/);
});

test("los paneles que leen datos muestran la llama, no un texto solo", () => {
  assert.match(source("src/components/admin/cash-session-panel.tsx"), /title="Leyendo la caja…"/);
  assert.match(source("src/components/products/product-manager.tsx"), /title="Cargando productos…"/);
  assert.match(source("src/components/nutrition/nutrition-calculator.tsx"), /LoadingBlock/);
  // El aviso lleva la llama y la cinta de brasas, sin tapar la tarjeta.
  assert.match(source("src/components/ui/spinner.tsx"), /fire-flame/);
  assert.match(source("src/components/ui/link-pending.tsx"), /fire-flame/);
  // El arqueo avisa mientras abre y mientras cierra.
  const cash = source("src/components/admin/cash-session-panel.tsx");
  assert.match(cash, /Abriendo la caja…/);
  assert.match(cash, /Cerrando la caja…/);
  assert.match(cash, /aria-busy=/);
});

test("los rayos se mueven de verdad: caen, ramifican y destellan", () => {
  const css = source("src/app/globals.css");
  const storm = source("src/components/layout/storm-transition.tsx");

  // Tres rayos con geometría propia, generada con semilla: el servidor y el
  // celular dibujan exactamente el mismo rayo (si no, React se queja al hidratar).
  assert.match(storm, /const BOLTS: readonly Bolt\[\]/);
  assert.match(storm, /function seeded\(seed: number\)/);
  assert.match(storm, /makeBolt\(7, 72, 66, 76, 11, 9, 3\.2, 0\)/);
  // El rayo principal cae apenas aparece: el aviso dura poco más de un segundo.
  assert.match(storm, /3\.2, 0\)/);
  assert.match(storm, /makeBolt\(23,/);
  assert.match(storm, /makeBolt\(41,/);
  // Cada rayo tiene sus ramificaciones.
  assert.match(storm, /branches\.push\(boltPath\(/);
  assert.match(storm, /\{\[bolt\.main, \.\.\.bolt\.branches\]\.map/);

  // El rayo cae en golpes rápidos y el resto del tiempo está a oscuras.
  const strike = css.slice(css.indexOf("@keyframes storm-strike"), css.indexOf("@keyframes storm-sky-flash"));
  assert.match(strike, /7% \{\s*\n\s*opacity: 1;/);
  assert.match(strike, /9% \{\s*\n\s*opacity: 0\.25;/);
  // Y después queda un resplandor que se apaga, como un relámpago real.
  assert.match(strike, /30% \{\s*\n\s*opacity: 0\.7;/);
  assert.match(strike, /55% \{\s*\n\s*opacity: 0;/);

  // El cielo destella aparte, así el efecto se siente como tormenta.
  const flash = css.slice(css.indexOf("@keyframes storm-sky-flash"), css.indexOf("@keyframes storm-drift"));
  assert.match(flash, /6% \{\s*\n\s*opacity: 0\.9;/);
  // Y las nubes se desplazan despacio.
  assert.match(css, /@keyframes storm-drift/);

  // La barra de carga se mueve mientras se espera.
  assert.match(css, /@keyframes storm-progress/);
  assert.match(css, /\.storm-progress-fill \{[^}]*animation: storm-progress/);

  // Dura lo suficiente para que el ojo vea caer un rayo.
  assert.match(storm, /MIN_VISIBLE_MS = 1_100/);
});

test("la tormenta no usa filtros de desenfoque en ninguna pieza", () => {
  const css = source("src/app/globals.css");
  const storm = source("src/components/layout/storm-transition.tsx");
  // Sin comentarios: ahí sí se nombran los filtros, para explicar que no van.
  const code = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const block = code.slice(code.indexOf(".storm-overlay {"), code.indexOf(".fire-line {"));
  assert.doesNotMatch(block, /blur\(/);
  assert.doesNotMatch(block, /backdrop-filter/);
  assert.doesNotMatch(block, /[{;]\s*filter:/);
  // El brillo del rayo sale de trazos superpuestos, no de un filtro.
  assert.match(css, /\.storm-stroke--halo \{[^}]*stroke-width: 17/);
  assert.match(css, /\.storm-stroke--core \{[^}]*stroke: #ffffff/);
  // El emblema tampoco lleva sombra difusa.
  assert.doesNotMatch(storm.replace(/\/\*[\s\S]*?\*\//g, ""), /drop-shadow/);
});

test("la capa es opaca: la pantalla vieja no se transparenta", () => {
  const css = source("src/app/globals.css");
  const overlay = css.slice(css.indexOf(".storm-overlay {"), css.indexOf(".storm-overlay[data-state"));
  // Degradado con colores sólidos, sin alfa: tapa de verdad.
  assert.match(overlay, /background: radial-gradient\(120% 90% at 50% 115%, #070708 0%/);
  // Negro de verdad: el fondo termina en negro puro, sin azul.
  assert.match(overlay, /#000000 80%, #000000 100%/);
  assert.doesNotMatch(overlay, /#101a2e|#0a1020|#0d0d12/);
  assert.doesNotMatch(overlay, /rgb\([^)]*\/ 0\.\d+\)/);
});

test("el emblema, el nombre y la barra son los del cartel del gimnasio", () => {
  const storm = source("src/components/layout/storm-transition.tsx");
  const css = source("src/app/globals.css");

  // El emblema es la imagen del guante rojo de la marca.
  assert.match(storm, /src="\/brand\/emblema\.webp"/);
  assert.match(storm, /className="storm-emblem"/);
  assert.ok(existsSync(path.join("public", "brand", "emblema.webp")), "falta la imagen del emblema");

  // Nombre en serif plateado y «Cargando…» en dorado, con las letras separadas.
  assert.match(css, /\.storm-title \{[^}]*font-family: ui-serif/);
  assert.match(css, /\.storm-title \{[^}]*color: #c4c2be/);
  assert.match(css, /\.storm-loading \{[^}]*color: #e3ab4c/);
  assert.match(css, /\.storm-loading \{[^}]*letter-spacing: 0\.34em/);

  // La barra: riel oscuro y tramo dorado, más gruesa que una línea.
  assert.match(css, /\.storm-progress \{[^}]*height: 0\.5625rem/);
  assert.match(css, /\.storm-progress-fill \{[^}]*#f7c95c/);

  // El emblema queda guardado para que aparezca aunque no haya red.
  const sw = source("public/sw.js");
  assert.match(sw, /"\/brand\/emblema-strong\.webp"/);
  assert.match(sw, /"\/sounds\/trueno\.mp3"/);
  assert.match(sw, /CACHE_VERSION = "power-box-v10"/);
});

test("el trueno suena con el rayo, y sólo el trueno", () => {
  const storm = source("src/components/layout/storm-transition.tsx");

  // El archivo existe y es liviano: un trueno, no una canción.
  const sound = path.join("public", "sounds", "trueno.mp3");
  assert.ok(existsSync(sound), "falta public/sounds/trueno.mp3");
  const size = statSync(sound).size;
  assert.ok(size > 4_000, `el trueno suena a nada (${size} bytes)`);
  assert.ok(size < 40_000, `el trueno pesa demasiado (${size} bytes)`);

  // Los «tics» de app se retiraron a pedido del gimnasio: el silencio entre
  // truenos es deliberado, no un olvido. Si alguien los devuelve, esta prueba
  // avisa de que hay que preguntar primero.
  assert.ok(!existsSync(path.join("public", "sounds", "toque.mp3")), "volvieron los tics de app");
  assert.doesNotMatch(storm, /TAP_SOURCES|toque2?\.mp3/);

  // Suena DENTRO del toque: fuera de él, iPhone y Android lo bloquean.
  const start = storm.slice(storm.indexOf("const start = ("), storm.indexOf("const onClick ="));
  assert.match(start, /playStormSound\(\)/);
  assert.match(storm, /const THUNDER_SRC = "\/sounds\/trueno\.mp3"/);

  // Sin amontonarse, sin sonar en segundo plano y sin depender de «reducir
  // movimiento» (esa opción apaga el movimiento, no el audio).
  const thunder = storm.slice(storm.indexOf("function playStormSound"), storm.indexOf("type Phase"));
  assert.match(thunder, /THUNDER_GAP_MS/);
  assert.match(thunder, /document\.hidden/);
  assert.doesNotMatch(thunder, /prefers-reduced-motion/);

  // Guardado en el caché para que suene sin señal.
  const sw = source("public/sw.js");
  assert.match(sw, /"\/sounds\/trueno\.mp3"/);
  assert.doesNotMatch(sw, /toque2?\.mp3/);
  assert.match(sw, /CACHE_VERSION = "power-box-v10"/);
});
