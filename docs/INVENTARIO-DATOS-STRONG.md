# Inventario: datos y marca de Strong en este repositorio

> Levantado el 3 de noviembre de 2026, antes de tocar nada, contrastando los
> documentos del kit (`TRASPASO-GIMNASIO-NUEVO.md`, `CLONAR-PARA-OTRO-GIMNASIO.md`)
> contra el código real. Las líneas son las verificadas en el commit `f066bca`.
>
> **Estrategia elegida y confirmada por el dueño: OPCIÓN A** (ver sección 6).

---

## 1 · Datos de Strong en SQL

### 1.1 Los cuatro seeds (se vacían en origen — Opción A)

| Archivo | Qué arrastra (líneas) |
|---|---|
| `supabase/migrations/00002_seed.sql` (138) | Marca en cabecera (1-11). 3 disciplinas reales con descripciones de Strong (18-47). Plan boxeo **US$20/mes** (77). 4 llamadas a `generate_week_sessions` que materializan **36 clases reales** (121-124). |
| `supabase/migrations/00003_datos_reales.sql` (357) | Cabecera con marca y grilla (1-32). Rojo `#d81a22` como color default (53-57). Grilla boxeo ma/mi/ju 06:00/17:30/20:00 entre marcas `PLANTILLA SEMANAL` (92-111). Salas «Área de boxeo / Sala de máquinas / Salón de clases» entre marcas `SALAS` (145-149). Borrado de 6 coaches ficticios `cch_diego`… (200). Reinserción de disciplinas (207-241) y planes con $20 (259-263). Mensajes `andrea.solis@example.com` / `kevin.ramirez@example.com` (315). Otras 4 llamadas de generación (324-327). Pie de verificación que espera 3/0/3/36 (334-357). |
| `supabase/migrations/00011_finance_seed.sql` (247) | Cabecera con marca (1-15). FX 36.50 (25). Cuentas dentro de métodos de pago: **BAC C$ 123-456789** (50-51), BAC US$ 987-654321 (55-56), LAFISE 555-444-333 (60-61), SINPE 8888-1234 (70-71), Tigo 8500-1234 (75-76), Claro 8500-5678 (80-81), wallet USDT `TQrX9wK...` (85-86). Sección 3: 5 cuentas, titular «Strong Fitness Gym S.A.» (127-137). **3 entrenadores con nombre y bio: Douglas Hernández, María Rodríguez, José Luis Pérez** (142-167). 13 transacciones con sueldos (18.000/16.000/15.000) y alquiler 25.000 (194-212). Caja abierta C$5.000 (223-224). |
| `supabase/migrations/00021_clients_seed.sql` (23) | 6 socios ficticios «Ejemplo · …» con `is_demo=true` (8-13) + visitas demo (16-21). |

### 1.2 Migraciones estructurales con datos de Strong
**(00057/00058/00072 no se editan: se neutralizan en el generador
`build-install-sql.mjs`. Las filas de 00020/00047/00001/00010/00012/00070
sí se sanearon en origen durante la ejecución — ver §8.)**

| Archivo | Qué arrastra (líneas) |
|---|---|
| `00057_pase_del_dia_tarifa.sql` | Tarifa inicial pase del día **C$40** (52-56). |
| `00058_tarifas_gimnasio_nio.sql` | En base vacía **inserta 2 planes con tarifa**: semanal C$150, quincenal C$280 (65-101). Relleno de tarifas 150/280/**560** (103-115). |
| `00072_grilla_horarios.sql` | §2 (67-87): siembra **9 slots de boxeo** (ma/mi/ju 06:00/17:30/20:00) en `class_schedule_slots` con salas de Strong. Dispara al reejecutar INSTALAR-BASE si existe una disciplina slug `boxeo`. |
| `00020_clients_crm.sql` | Fallback «Cliente Strong» en trigger (231, 239). |
| `00047_menores_consentimiento_aprobacion.sql` | Fallback «Cliente Strong» (98). |
| `00001_schema.sql` | Grilla de boxeo entre marcas (440-450) y salas (489-491) — contenido que reescribe `build-sql.mjs` desde `demo-sessions.ts`. Comentario con ejemplos de disciplinas (61). |

Nota: las redefiniciones de `generate_week_sessions` en **00072 (90) y 00075 (121)
ya no llevan grilla hardcodeada** — leen `class_schedule_slots`. La definición
final de la cadena es limpia; lo que «devuelve» la grilla es la siembra de 00072 §2
y las definiciones viejas (00001/00003), que son la última palabra en SETUP.sql y
ACTUALIZAR.sql respectivamente.

### 1.3 Lógica funcional atada al slug `boxeo` (NO se toca en esta fase)

`00067_vigencias_planes.sql` (117, 212-218, 803) y `00068_catalogo_planes.sql`
(83, 91, 110): el motor de vigencias trata el slug `boxeo` como plan de disciplina
en USD y el resto como gimnasio en NIO. Es semántica del catálogo de Strong, no
dato personal. Si el gimnasio nuevo usa otros slugs, recibe el tratamiento
genérico «gym/NIO». **Queda señalado para revisar cuando se definan los planes
del gimnasio nuevo (paso 5).**

### 1.4 Archivos generados (se regeneran, no se editan a mano)

| Archivo | Estado antes del desarme |
|---|---|
| `supabase/SETUP.sql` | BAC 123-456789 ×3, «Strong Fitness» ×14, «Cliente Strong» ×2, 36 clases, tarifas. |
| `supabase/ACTUALIZAR.sql` | Ídem (×3, ×13, ×2). |
| `supabase/FASE2.sql` | «Cliente Strong» ×2. |
| `supabase/INSTALAR-BASE.sql` | Sin nombres ni cuentas ✓, pero **con tarifas** (6024: `price_nio = 40`; 6177-6210: 150/280/560), la siembra de slots de 00072 y la grilla textual en las definiciones de 00001. |
| `supabase/PERSONALIZAR-GIMNASIO.sql` | Precios de Strong como ejemplo comentado (88-91: 40/150/280/560). |
| `supabase/COMPATIBILIDAD-CRM.sql`, `LECTURA-*.sql`, `COBROS-GASTOS.sql`, `PLAN-CUENTA.sql`, `SALDO-CLIENTE.sql`, `DEUDAS-ABONOS.sql`, `VUELTO-ABONOS.sql`, `SEGURIDAD-ACCESOS.sql` | Copias de migraciones estructurales; arrastran «Cliente Strong» donde aplica. |

Trampa confirmada: `PERSONALIZAR-GIMNASIO.sql` inserta los planes con
`on conflict do nothing` → **no pisa** los que 00058 ya insertó con tarifas de
Strong. Por eso la neutralización de 00057/00058/00072 en el generador es
obligatoria, no cosmética.

## 2 · Datos de Strong en el código web (modo demo)

| Archivo | Qué arrastra |
|---|---|
| `src/config/site.ts` | Nombre, razón social (25-28), URL de Vercel de Strong (32), teléfono 8449 1486 y WhatsApp (38-42), dirección Los Cedros km 28½, Villa El Carmen (45-49), link de Maps (52), Facebook (71), horarios de atención (84-92), moneda USD (67). |
| `src/lib/data/demo-content.ts` | 3 disciplinas (17-69) y **5 planes con tarifas reales**: Boxeo $20 (84), día C$40 (110), semana C$150 (134), quincena C$280 (158), mes C$560 (186). Galería y suplementos. |
| `src/lib/data/demo-sessions.ts` | **Grilla semanal** (38-64) — fuente de verdad de la que `build-sql.mjs` copia el SQL; horarios de atención de Strong en comentarios (20-22); salas (66-70). |
| `src/lib/data/demo-admin.ts` | 16 nombres ficticios + 4 mensajes demo (no son socios reales de Strong; se alimentan de la grilla y los planes de arriba). |

En producción sin Supabase el modo demo NO se activa (el build lo bloquea), pero
son datos de Strong viviendo en `src/`.

## 3 · Marca escrita a mano en `src/`

Los diez del documento `CLONAR-PARA-OTRO-GIMNASIO.md` §3.1 — con **tres rutas
corregidas porque el doc quedó viejo**:

| # | Archivo (ruta real) | Línea(s) |
|---|---|---|
| 1 | `src/i18n/dictionaries/es.ts` | 3, 168 (+4-13 y 52: dirección de Strong en descripciones/keywords/badge) |
| 2 | `src/i18n/dictionaries/en.ts` | 3, 165 (+4-13, 52) |
| 3 | `src/components/sections/hero.tsx` | 97-98 (mensaje de WhatsApp) |
| 4 | `src/components/sections/cta-band.tsx` | 43-44 |
| 5 | `src/components/layout/storm-transition.tsx` *(doc: `src/components/…`)* | 434 (emblema), 442 (texto) |
| 6 | `src/components/legal/legal-document.tsx` *(doc: `src/components/…`)* | 13 |
| 7 | `src/components/admin/master-export-button.tsx` | 7, 8, 90 |
| 8 | `src/components/admin/category-rules.tsx` | 29 |
| 9 | `src/lib/reports/workbook.ts` *(doc: `src/lib/finance/workbook.ts`, no existe)* | 27, 84 |
| 10 | `src/app/[locale]/layout.tsx` *(doc: `src/app/layout.tsx`, no existe)* | 99 (`themeColor #d81a22`) |
| + | `src/app/manifest.ts` | 22-23 (descripción con dirección), 33 (`theme_color`) |

Además (no están en el doc):

| Archivo | Línea(s) | Qué |
|---|---|---|
| `src/app/icon.svg` | 1-2 | Favicon = emblema de Strong |
| `src/app/[locale]/opengraph-image.tsx` | 73, 84, 98, 105 | «STRONG / FITNESS GYM / ENTRENÁ FUERTE AQUÍ CERCA» (teléfono y dirección vienen de site.ts ✓) |
| `src/components/layout/logo.tsx` | 43, 52 | «Strong» + «Fitness Gym» |
| `src/components/layout/brand-mark.tsx` | todo el SVG | Emblema (triángulo rojo + atleta) |
| `src/lib/auth/mfa-actions.ts` | 6 | `MFA_FACTOR_NAME = "Strong Gym"` (visible en la app de 2FA) |
| `src/lib/nutrition/consent.ts` | 5 | Consentimiento con la marca |
| `src/lib/legal/texts.ts` | 192, 211 | Cookie `strong-gym-locale` citada en el aviso legal |
| `src/lib/clients/category.ts` · `src/lib/crm/types.ts` | 3 · 4, 12 | Etiquetas «Strong Gym», «Clientes familia Strong» |
| `src/app/api/admin/categories/route.ts` | 61 | Mensaje de error con la marca |
| `src/lib/reports/export-filter.ts` | 145 | Nombre del archivo de reportes |
| `src/components/admin/import-tools.tsx` | 237, 296 | Plantilla CSV `plantilla-clientes-strong-gym.csv` |
| `src/components/crm/client-card.tsx` | 17, 26 | **Carnet impreso del socio: «STRONG FITNESS GYM»** |
| `src/components/crm/client-pass.tsx` | 35 | «Mi carnet Strong» |
| `src/components/crm/qr-scanner.tsx` | 137, 153 | «QR Strong», placeholder `strong-gym:client:…` |
| `src/components/sw-register.tsx` | 29 | Consola |
| `src/proxy.ts` | 41 | Página de error |
| `src/app/[locale]/panel/ayuda/page.tsx` | 172 | Ejemplo SQL con `#d81a22` y specialties |
| `src/app/api/admin/classes/catalog/route.ts` | 61 | Ejemplo de color en mensaje de error |

### Claves internas (regla del doc: NO se tocan)

Prefijo SQL `strong_gym_`, cookie `strong-gym-locale` (`src/i18n/config.ts:19`),
almacenamiento local `strong-gym:*` (movement-form 52/103, clients-panel
42/44/47/1706, debt-form 11/20, demo-banner 10, app-provider 126), prefijo QR
`strong-gym:client:` (`crm/types.ts:145,153`), base de CI
`strong_gym_test_concurrency`, lock `strong_gym_admin_schedule`. No son marca
visible. **Decisión pendiente de confirmación expresa: se dejan igual** (misma
lógica del prefijo SQL); las excepciones grises (texto legal que cita la cookie,
placeholder del scanner) se revisan en el paso de marca.

## 4 · Marca y datos en raíz, public/ y docs

- `package.json:2` → `"name": "strong-gym"`.
- `.env.example:2` y **:28** → `NEXT_PUBLIC_SITE_URL=https://strong-gym-gamma.vercel.app` (URL de Strong; si alguien lo copia, publica metadatos apuntando allá).
- `public/sw.js:1,19,36,170` → marca, `CACHE_VERSION = "strong-gym-v8"`, precaché de `emblema-strong.webp`, texto offline.
- `public/images/LEEME.md` → «fotos de Strong Fitness Gym» y link al repo de Strong.
- `README.md` (7 menciones), `DEPLOY.md` (8: proyecto Vercel `strong-gym`, repo).
- `docs/PENDIENTES-ACTUALES.md` (lista de pendientes de Strong, 1400+ líneas), `docs/AUTH-RECUPERACION.md` (6), `docs/REVISION-CORREO-AUTH.md` (3), `docs/VALIDACION-FINANCIERA-2026-10-17.md` (3, nombres de bases de prueba), y el resto de los docs con menciones sueltas. `docs/SQL-PENDIENTE/00031_personal_requiere_mfa.sql` = copia vieja con cabecera de Strong («PENDIENTE DE AUTORIZACIÓN…»).
- **Imágenes (27 archivos físicos; el doc cuenta «21» porque agrupa carpetas):** 15 fotos en `public/images/` (fachada, boxeo, sacos, cambio, grupo, pareja1, supl1, sala1, sala2, pesas, triceps, pantorrilla, abs, dip + `emblema.jpg` sin uso) + 12 de marca: `public/brand/emblema-strong.webp`, `public/icon-192.png`, `public/icon-512.png`, `public/apple-icon.png`, `public/icons/` (apple-touch-icon, icon-192, icon-512, maskable-512), `public/splash/` (4 tamaños).
- `scripts/build-icons.mjs` → **genera los 3 iconos raíz dibujando el emblema de Strong en código** (comentarios 4-6, función `emblema` 93+).
- `tests/cargando.test.mjs:226-279` → **fija la marca en pruebas**: exige `emblema-strong.webp` y `CACHE_VERSION = "strong-gym-v8"` (se actualiza junto con el paso de marca, no antes).
- `tests/*` y `scripts/test-*` usan orígenes ficticios `https://strong.test` / `strong.example` (internos, inofensivos).

## 5 · Acoples que condicionan el desarme (verificados)

1. **`scripts/build-sql.mjs`** lee `demo-sessions.ts` (exige 7 días, **tira error
   si la grilla queda vacía**, exige ≥1 sala), reescribe los bloques marcados de
   `00001`/`00003` (**tira error si faltan las marcas**) y embebe `00002`,
   `00011` y `00003` crudos en SETUP/ACTUALIZAR. El CI corre `--check`.
2. **`scripts/build-install-sql.mjs`** excluye 00002/00003/00021, corta 00011 en
   la línea exacta `--  3. CUENTAS DEL GIMNASIO` (**tira error si no está**) y
   aplica listas `NEUTRALIZAR`/`RENOMBRES` (no-op silencioso si el texto no está).
3. **26 suites PGlite** consumen `00002` como fixture vía
   `scripts/helpers/sql-test-db.mjs` (lista `first`) y referencian sus ids ~110
   veces (`cls_zumba` ×42, `pln_gimnasio` ×28, `cls_boxeo` ×26, `pln_boxeo` ×11,
   `pln_dia` ×8, `cls_musculacion` ×2).
4. **Aserciones que hoy prueban datos de Strong** (hay que reescribirlas a la
   verdad nueva, sin debilitar):
   - `test-sql.mjs`: «3 disciplinas» (101), «36 clases» (105), «boxeo cuesta 20»
     (110-115), «martes 06:00» (149), transformación 00003 (497-660), SETUP.sql
     completo (687-747), `pln_boxeo price 20` (586).
   - `test-crm-sql.mjs`: aplica `00021` (384) y cuenta demos (394).
   - `test-future-sessions-sql.mjs`: genera con la grilla de 00001 y espera 9
     (321, 364-375).
   - `test-access-hardening-sql.mjs:57`: toma «la última sesión» sembrada por 00002.
5. **NO se rompen** si la neutralización de 00072 es sólo en el generador:
   `test-op05-sql.mjs` (96-105: «9 horarios de Boxeo», firstRun === 9) y
   `test-op05-sessions-sql.mjs` (136: slots === 9) aplican la migración cruda.
6. **Las tarifas en pruebas vienen de las migraciones crudas 00057/00058**
   (helper `third`) y del precio del fixture `pln_boxeo` (20): `test-cli01`
   (135-142: C$40, C$560, US$20) y `test-cli06` (130-137) las afirman. Como la
   neutralización de tarifas es sólo en el generador (regla 1), esas suites
   siguen probando la mecánica del motor con los mismos valores.
7. `scripts/test-plan-void-sql.mjs` y `test-plan-usage-sql.mjs` arman bases
   propias (no usan el helper) → sin impacto.

## 6 · Estrategia confirmada (OPCIÓN A) y reglas

**Opción A del doc `TRASPASO-GIMNASIO-NUEVO.md` §4.2: vaciar el contenido de
Strong de los seeds dejando la estructura**, en vez de retirar los seeds y
reescribir `build-sql.mjs` entero (Opción B: más grande, rompe el `--check` del
CI y exige el mismo trabajo de fixtures).

Reglas expresas del dueño para el desarme:

1. **Las tarifas de 00057 y 00058 se neutralizan en el generador**
   (`build-install-sql.mjs`), nunca a mano en `INSTALAR-BASE.sql` (ese archivo
   se regenera y se pisa). Idem la siembra de grilla de 00072 §2.
2. **Grilla de boxeo:** `generate_week_sessions` se redefine en 00001, 00003,
   00072 y 00075. Se neutraliza la cadena completa (plantilla fuente +
   bloques marcados + siembra de 00072 en el generador), no solo 00001, o la
   grilla vuelve.
3. **No debilitar pruebas para que pasen.** Si una aserción pierde sentido, se
   para y se discute. Las que prueban datos de Strong se reescriben a la verdad
   nueva con la misma fuerza (instalación vacía, generador que no crea nada sin
   grilla, seeds que ya no siembran).

Plan de ejecución (paso 4) — **completo, ver §8**:

- [x] Fixture neutro `tests/fixtures/base-catalog.sql` (mismos ids que 00002,
      textos genéricos, sin generación de clases) + sesiones neutras explícitas.
- [x] `scripts/helpers/sql-test-db.mjs`: el fixture reemplaza a 00002.
- [x] Vaciar 00002, 00003 (conservando las marcas), 00011 (conservando la línea
      de corte) y 00021.
- [x] `src/lib/data/demo-sessions.ts` y `demo-content.ts` vacíos de datos Strong.
- [x] `scripts/build-sql.mjs`: tolerar grilla y salas vacías (sentinel SQL
      válido), cabeceras sin prometer datos.
- [x] `scripts/build-install-sql.mjs`: neutralizar 00057 (tarifa 40), 00058
      (catálogo con 150/280 + relleno 560) y 00072 §2 (siembra de grilla), con
      verificación dura (falla si el patrón no aparece).
- [x] `supabase/PERSONALIZAR-GIMNASIO.sql`: ejemplos de precio → `<<PRECIO>>`.
- [x] Reescribir las aserciones de `test-sql.mjs`, `test-crm-sql.mjs`,
      `test-future-sessions-sql.mjs` y lo que necesite `test-access-hardening`
      (fixture) a la verdad nueva.
- [x] Regenerar SETUP/ACTUALIZAR/FASE2/etc. e INSTALAR-BASE; portar los scripts
      npm `build:install` / `build:install:check`; agregar el check al CI.
- [x] Verificación final: greps de BAC/123-456789/Douglas/tarifas/grilla contra
      los artefactos generados + suites completas + typecheck + build.

## 7 · Pendientes que NO son del paso 4

- **Paso 5 (marca):** datos del gimnasio nuevo (nombre, razón social, dirección,
  Maps, teléfono, WhatsApp, correo, redes, horarios, moneda, logo, colores,
  precios, disciplinas) → `site.ts` + los ~25 archivos de la sección 3 +
  `sw.js`/`manifest`/`icon.svg`/`build-icons.mjs` + `tests/cargando.test.mjs` +
  README/DEPLOY/.env.example/package.json/LEEME.md. Revisar ahí la lógica
  slug `boxeo` de 00067/00068 (§1.3) contra los planes reales del gym nuevo.
- **Paso 6 (imágenes):** reemplazar los 27 archivos físicos (mismos nombres).
- **Docs históricos de Strong** (`PENDIENTES-ACTUALES.md` y otros): decidir si
  se archivan o se retiran; no afectan a la aplicación.
- **Claves internas** (§3): decisión por defecto «se dejan igual», pendiente de
  confirmación expresa.

## 8 · Desarme ejecutado (rama `arena/0d97aadd-gimnasio`, noviembre 2026)

Todo el plan de §6 está ejecutado y verificado. Lo que hay que saber además:

### 8.1 Hueco #4 (nuevo, encontrado durante la ejecución)

La wallet USDT `TQrX9wK…` vivía en los `details` del método de pago crypto de
`00011` (§1, no §3) y por eso el corte de la sección 3 NO la sacaba: aparecía
2 veces en `SETUP.sql`/`ACTUALIZAR.sql` y **2 veces en `INSTALAR-BASE.sql`
(líneas ~1464-1465)**, pese a que la cabecera del kit prometía cero datos.
Corregida en el origen (00011 §1 reescrito con detalles neutros) y cubierta
por el barrido automático (§8.2).

### 8.2 Barrido automático anti-datos ajenos

`scripts/helpers/prohibidas.mjs` lista las cadenas que no pueden aparecer en
ningún SQL generado (cuentas, wallets, tarifas 40/150/280/560, nombres,
correos, «Cliente Strong», «Strong Fitness», «Strong Gym», salas de la grilla
vieja, «SEED-GASTO», «Apertura inicial»). Lo usan **los dos generadores**:
`build-sql.mjs` valida cada origen sincronizado y cada artefacto armado, y
`build-install-sql.mjs` valida `INSTALAR-BASE.sql` antes de escribir o
comparar. Si una cadena sobrevive, la generación FALLA. Las claves técnicas
(`strong_gym_`, categoría `strong_gym`, slug `boxeo` de 00067/00068) no se
tocan y no chocan con el barrido (mayúsculas/espacios vs guion bajo).

### 8.3 Saneados en origen (fuera del plan original, justificados)

El plan decía «neutralizar en el generador», pero `build-sql.mjs` copia los
orígenes TAL CUAL a SETUP/ACTUALIZAR/FASE2, así que estos se sanearon en el
archivo fuente (comentarios y un fallback de texto; reversibles con git):

- Cabeceras: `00001:2`, `00010:2`, `00012:2` (marca → título neutro).
- Comentario `00070:74` («Strong Gym» → «categoría del gimnasio»).
- Fallback `'Cliente Strong'` → `'Cliente'` en `00020` (231, 239) y `00047` (98).
- `NEUTRALIZAR`/`RENOMBRES` de `build-install-sql.mjs` quedaron sin efecto y
  se eliminaron (el barrido de §8.2 cubre la verificación).

### 8.4 Arreglo técnico descubierto al vaciar

Un `CASE x ELSE … END` **sin ningún WHEN es SQL inválido**: al vaciar las
salas, `bloqueSalas` de `build-sql.mjs` generaba eso dentro de
`generate_week_sessions` y 00001 reventaba. Arreglado con un WHEN centinela
que no matchea nunca (`when null then null`). La grilla vacía usa su propio
centinela `(null::integer, null::time, null::text)`, que el loop descarta con
`if not found then continue`.

### 8.5 Aserciones tocadas (Regla 3 — para revisión del dueño)

Pre-aprobado: el plan de §6 autorizaba reescribir a la «verdad nueva» las
aserciones de `test-sql.mjs`, `test-crm-sql.mjs`, `test-future-sessions-sql.mjs`
y `test-access-hardening-sql.mjs`. Hecho: instalación vacía (0/0/0/0 + 10
métodos + 11 categorías + 0 cuentas/transacciones/cajas), sesiones propias de
cada suite, TZ martes 06:00→12:00 UTC con sesión propia, generador que crea 0
con plantilla vacía (member→AUTH intacto; «admin genera >0» pasa a «admin
puede ejecutarla y genera 0»), 00003-sanitizada-no-toca-nada, seed 00021 → 0
fichas, SETUP vacío + flujo book/cancel con clase propia.

Fuera de esa lista se tocaron tres cosas más (se señalan expresamente):

1. **`test-future-sessions-sql.mjs` (grants):** la suite ahora aplica 00072
   (la grilla de la plantilla base ya no existe; la real viene de
   `class_schedule_slots`). Desde 00072 el modelo REAL es: definer, cerrada a
   anon, ejecutable por authenticated **con guardia interna admin/staff**. El
   assert viejo (`!auth_exec`) describía el mundo anterior a 00072. Se adaptó
   al modelo real y se AGREGARON dos rechazos conductuales (cliente→`/AUTH/`,
   anónimo→`/permission denied/` llamando al generador directo): la prueba
   quedó más fuerte, no más débil.
2. **`tests/data-read.test.mjs:230`:** «sin configurar conserva demo local
   explícita» exigía `getClasses().length > 0` (pineaba el catálogo demo de
   Strong). Ahora exige que el fallback devuelva EXACTAMENTE lo declarado por
   el módulo local (`demo-content.ts`, vacío a propósito): ni tarjetas
   ficticias resucitadas ni error de conexión. Mismo sujeto, misma fuerza.
3. **`test-op05-classes-sql.mjs:229`:** re-guardaba `cls_boxeo` con el color
   hardcodeado `#d81a22` esperando `sin_cambios`; el fixture usa color neutro.
   La prueba es «guardar los MISMOS datos no cambia nada»: ahora lee los datos
   actuales de la base en vez de hardcodearlos. La aserción (`sin_cambios` +
   `is_active` + id) no cambió.

Además, `test-crm-sql.mjs` crea sus 2 cuentas de caja neutras inline (00011 ya
no siembra cuentas) y `test-access-hardening-sql.mjs` crea su propia sesión.

### 8.6 Verificación final (todo en verde en el sandbox)

- `npm run test:sql` completo (21 suites) + movements, plan-void, plan-usage,
  cash-session, roles A/B, trainer-access, cashier-close, progress,
  attendance, productos, cuentas, exercises: **PASS**.
- `npm run test:auth`: **1110/1110**. `test:metadata`, `test:finance:rsc`:
  PASS. `typecheck`, `lint`, `next build`: PASS.
- No ejecutables en el sandbox (ambientales; CI los corre):
  `test:finance:concurrency` (exige Postgres real; revisada por texto: no
  referencia catálogo) y `test:layout` (exige navegador Playwright; no toca
  datos demo).
- Generadores: `build:sql --check` y `build:install:check` PASS; greps de
  verificación sobre SETUP/ACTUALIZAR/FASE2/INSTALAR-BASE: 0 apariciones de
  cuentas, wallets, tarifas, nombres, grilla o marca de Strong.
