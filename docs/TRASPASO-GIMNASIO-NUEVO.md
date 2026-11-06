# Traspaso: crear el gimnasio nuevo a partir de Strong Gym

> **Este documento existe para que cualquier sesión nueva —o cualquier persona—
> sepa exactamente en qué punto estamos, sin tener que leer el chat anterior.**

Última actualización: 3 de noviembre de 2026.

---

## 1 · Qué se está haciendo

Strong Gym es un sistema completo de gestión de gimnasio: socios, cobros,
caja, reservas, clases, entrenadores, progreso, nutrición, productos,
biblioteca de ejercicios y panel de administración con roles.

Se necesita una **segunda instalación idéntica** para otro gimnasio, con:

- **Todos los módulos, sin quitar ninguno.** Funcionalidad idéntica.
- **Todos los datos vacíos**: cero socios, cero cobros, cero reservas.
- **Sin un solo dato de Strong**: ni cuentas bancarias, ni tarifas, ni
  entrenadores, ni horarios.
- **Cambiando sólo**: nombre, razón social, dirección, Google Maps, teléfono,
  WhatsApp, redes, horarios de atención, moneda, logo e imágenes del local.

## 2 · La decisión ya tomada

**Dos repositorios separados, dos proyectos de Supabase, dos proyectos de
Vercel.** No hay multiinquilino, no hay `gym_id`, no hay base compartida.

- `elprofenica505-ai/Strong-Gym` → el gimnasio original.
- `elprofenica505-ai/gimnasio` → el gimnasio nuevo (nombre a confirmar).

Se eligió así porque cada gimnasio puede pedir módulos distintos y porque
separa la responsabilidad legal de los datos.

## 3 · Qué está hecho

En `Strong-Gym`, rama `arena/5fabb7bb-strong-gym`, commit `ebc3f9b`:

| Archivo | Qué es |
|---|---|
| `supabase/INSTALAR-BASE.sql` | 18 730 líneas. La base completa: 82 de las 85 migraciones. Tablas, RLS, funciones, disparadores, permisos y límites de abuso. Sin datos de nadie. |
| `supabase/PERSONALIZAR-GIMNASIO.sql` | Dueño como admin, las dos cajas de efectivo, cuatro planes base y los precios. |
| `scripts/build-install-sql.mjs` | Genera el SQL anterior desde `supabase/migrations/`. `--check` falla si quedó viejo. |
| `docs/CLONAR-PARA-OTRO-GIMNASIO.md` | Qué es idéntico, qué cambia, cómo viaja la biblioteca de ejercicios. |
| `docs/TRASPASO-GIMNASIO-NUEVO.md` | Este documento. |

Comandos: `npm run build:install` y `npm run build:install:check`.

### Verificado dentro de `INSTALAR-BASE.sql`

> **Corrección (auditoría de este repo, noviembre 2026):** esta lista del
> traspaso estaba incompleta. El `INSTALAR-BASE.sql` del kit SÍ arrastraba las
> tarifas de 00057/00058 (C$40/150/280/560), la siembra de la grilla de boxeo
> de 00072 §2 y la wallet USDT `TQrX9wK…` dentro de los detalles de un método
> de pago de 00011 (huecos #3 y #4 del inventario). Todo quedó neutralizado en
> el generador de este repo, con barrido automático de verificación
> (`scripts/helpers/prohibidas.mjs`): si algo de eso vuelve, la generación falla.
>
> **Y la corrección más grande (hueco #5):** el archivo nunca fue aplicable
> sobre una base vacía. Desde 00024 las migraciones exigen el esquema
> financiero *split* (`bank_accounts`), que no existe en ninguna migración del
> repo: la base real de Strong se construyó por fuera. Resuelto con la
> opción A (decisión del dueño, 2026-11-05): el generador reemplaza
> 00010/00011 por los artefactos de `supabase/instalacion/` (esquema *split*
> + siembra genérica adaptada), `npm run test:instalar` pasa aplicando el
> INSTALAR-BASE completo en PGlite limpia, y el §2 de este
> PERSONALIZAR-GIMNASIO.sql ahora crea las dos cajas en `bank_accounts`
> (antes las insertaba en `accounts`, tabla del modelo histórico que en la
> instalación nueva no existe). **La puerta de comparación quedó cerrada
> (2026-11-05):** la segunda corrida real en Strong, ya con el diagnóstico
> nuevo (precisión/escala numérica + tabla `sessions`), destapó dos
> precisiones faltantes (`coaches.monthly_salary` `numeric(12,2)`,
> `payment_methods.fee_pct` `numeric(5,2)` — corregidas) y una diferencia
> ACEPTADA: Strong real perdió `sessions_coach_id_fkey` (drift histórico) y
> la instalación nueva la conserva fiel al repo. Veredicto: **cero
> diferencias no ambientales y no aceptadas** en el alcance del
> diagnóstico — las 14 tablas que lista (6 del modelo split, 2 financieras
> de la cadena, `coaches`, `sessions` y 4 centinelas repository), sus
> índices/constraints/políticas, 2 enums, la vista y las firmas de
> funciones. NO «el esquema es idéntico»: las migraciones crean 52 tablas
> y el diagnóstico no cubre las otras 38. Comando y detalle en
> `docs/INVENTARIO-DATOS-STRONG.md` §8.7.2/§8.7.3.

- 0 cuentas bancarias (se neutralizaron BAC, LAFISE, Tigo y Claro).
- 0 nombres de personas.
- 0 socios de ejemplo.
- 0 apariciones de la palabra «Strong».
- 82 bloques de migración, 78 `begin` / 78 `commit` balanceados.
- Fuera del archivo: `00002_seed.sql`, `00003_datos_reales.sql`,
  `00021_clients_seed.sql`, y de `00011` todo lo que va de la sección 3
  en adelante.

## 4 · Qué falta

### 4.1 Traer el kit al repo nuevo — ✅ HECHO

El repo `gimnasio` se clonó **antes** de que existiera el kit, así que no lo
tenía. Se copió con (ya ejecutado en la rama `arena/0d97aadd-gimnasio`):

```bash
cd gimnasio
git remote add strong https://github.com/elprofenica505-ai/Strong-Gym.git
git fetch strong
git checkout strong/arena/5fabb7bb-strong-gym -- \
  supabase/INSTALAR-BASE.sql supabase/PERSONALIZAR-GIMNASIO.sql \
  scripts/build-install-sql.mjs \
  docs/CLONAR-PARA-OTRO-GIMNASIO.md docs/TRASPASO-GIMNASIO-NUEVO.md
```

### 4.2 Desarmar las trampas del repo nuevo — ✅ HECHO (Opción A)

Elegida y ejecutada la **Opción A**: vaciar el contenido de Strong dejando la
estructura (los seeds siguen existiendo para `build-sql.mjs`; nadie los retira).
Detalle completo y verificado en `docs/INVENTARIO-DATOS-STRONG.md` (§6 y §8).
Resumen:

| Qué | Estado |
|---|---|
| `00002_seed.sql` | Vaciada: cabecera + plantilla comentada + guía de admin. Cero datos. |
| `00003_datos_reales.sql` | §1-§3 se conservan (precio opcional, color de marca, generador con marcas para `build-sql.mjs`); §4-§9 ANULADOS con explicación. |
| `00011_finance_seed.sql` | Sólo métodos de pago y categorías de gasto genéricos. Cuentas, coaches, transacciones y caja: ANULADOS. **Incluida la wallet USDT `TQrX9wK…` que se colaba en `INSTALAR-BASE.sql` (hueco #4 del inventario).** |
| `00021_clients_seed.sql` | Shell vacío idempotente. |
| `demo-sessions.ts` / `demo-content.ts` | Plantilla semanal vacía (7 días sin clases), sin salas, sin disciplinas/planes/coaches. Galería y suplementos quedan para los pasos 5-6. |
| `build-sql.mjs` | Tolera grilla/salas vacías (centinela SQL válido), cabeceras neutras y **barrido anti-datos ajenos** de todos los generados. |
| `build-install-sql.mjs` | Recortes obligatorios por texto de 00057 (C$40), 00058 (150/280/560) y 00072 §2 (siembra de la grilla de boxeo) — los orígenes NO se editan — más el mismo barrido final. |
| Orígenes saneados | Cabeceras 00001/00010/00012, comentario 00070 y fallback «Cliente Strong»→«Cliente» en 00020/00047. |
| Pruebas | Fixture neutro `tests/fixtures/base-catalog.sql` reemplaza a 00002 en todas las suites; aserciones que pineaban datos de Strong reescritas a la verdad nueva (instalación vacía) sin perder fuerza. |

Resultado verificado: `SETUP.sql`, `ACTUALIZAR.sql`, `FASE2.sql`,
`INSTALAR-BASE.sql` y los acompañantes salen con **cero** cuentas, tarifas,
nombres, grilla o marca de Strong. En CI se agregaron `npm run build:install` y
`build:install:check` junto al `build:sql --check` existente.

### 4.3 Personalizar el gimnasio nuevo

Pendiente de que el dueño pase los datos:

- Nombre comercial y razón social.
- Dirección y **link de Google Maps**.
- Teléfono, WhatsApp, correo.
- Horarios de atención.
- Redes sociales.
- **Logo** y fotos del local.
- Disciplinas, horarios y precios.

Se aplican en `src/config/site.ts` y en los diez archivos con el nombre escrito
a mano (ver `docs/CLONAR-PARA-OTRO-GIMNASIO.md`, sección 3.1).

### 4.4 Imágenes a reemplazar (21 archivos, mismos nombres)

**Fotos del gimnasio** (`public/images/`): `fachada.jpg` (portada y vista previa
al compartir), `boxeo.jpg`, `sacos.jpg`, `cambio.jpg`, `grupo.jpg`,
`pareja1.jpg`, `supl1.jpg`, `sala1.jpg` (pantalla de ingreso), `abs.jpg`,
`dip.jpg`, `pantorrilla.jpg`, `pesas.jpg`, `sala2.jpg`, `triceps.jpg`.
`emblema.jpg` no se usa.

**Marca**: `public/brand/emblema-strong.webp`, `public/icon-192.png`,
`public/icon-512.png`, `public/apple-icon.png`, `public/icons/` (4 tamaños) y
`public/splash/` (4 tamaños).

## 5 · Datos técnicos que hay que saber y no son obvios

1. **La biblioteca de ejercicios no se copia.** No está en el repo ni en la
   base: se descarga del origen oficial (RepDB, free-exercise-db) con el botón
   *Importar catálogo* del panel de administración, que **exige 2FA**. Queda
   idéntica, con fotos y textos en español.
2. **No hay buckets de Storage.** Las imágenes viven en `public/`. No hay nada
   que copiar entre proyectos.
3. **No existe `supabase/config.toml`.** Confirmaciones, redirecciones, SMTP y
   MFA viven sólo en el panel de Supabase: se rehacen en el proyecto nuevo.
4. **El rol admin no se cambia desde el panel.** Se asigna desde el SQL Editor:
   `update public.profiles set role='admin' where id='<uuid>'` (está en
   `PERSONALIZAR-GIMNASIO.sql`).
5. **La grilla de horarios de Strong está dentro de la función
   `generate_week_sessions()`.** No inserta nada al instalar (la tabla `classes`
   viene vacía y la función salta lo que no existe), pero si alguien aprieta
   «generar horarios» antes de crear las disciplinas del gimnasio nuevo, se
   lleva esa grilla. **Crear disciplinas primero.**
6. **El prefijo `strong_gym_` del SQL no se toca.** Es una clave interna, no una
   marca visible. Renombrarla obliga a editar 82 migraciones.
7. **El nombre visible de la categoría de cliente está en el código**, en
   `src/components/admin/category-rules.tsx`, no en la base.
8. **No hay Postgres ni Docker en el sandbox**, así que el SQL no se puede
   ejecutar en pruebas locales: la validación es por revisión del texto.

## 6 · Cómo crear la base del gimnasio nuevo

1. Supabase → **New project** → región `us-east-1` → guardar la contraseña.
2. **SQL Editor** → pegar `supabase/INSTALAR-BASE.sql` → Run.
3. **Authentication → Users → Add user**: correo y contraseña del dueño. Copiar
   el UID.
4. **SQL Editor** → pegar `supabase/PERSONALIZAR-GIMNASIO.sql` con el UID y los
   precios → Run.
5. **Authentication → URL Configuration** y **Providers** (SMTP si se quiere
   correo propio).
6. Activar **2FA** para el dueño.
7. Entrar al panel → **Importar catálogo** de ejercicios.
8. Cargar desde el panel: disciplinas, horarios, planes con precio, equipo,
   roles y cuentas bancarias reales.

## 7 · Reglas de trabajo de este proyecto

- **Idioma: español**, tono cercano, sin excusas largas.
- **El usuario hace el merge de los PR.** No fusionar por él.
- **Inventario antes de código.** Cambios pequeños, no duplicar.
- **Migraciones aditivas y reversibles.** Anular en vez de borrar.
- Nada de `filter`, `backdrop-filter` ni `drop-shadow`.
- `reduced-motion` no congela la interfaz; `CACHE_VERSION` en v8.
- Roles: cliente con 2+ entrenadores; altura sólo admin con bitácora; personal
  no reserva clases; la marca se cambia en un solo lugar.
- Tarifas de referencia de Strong (no se copian al gimnasio nuevo): Día C$40,
  Semana C$150, Quincena C$280, Mes C$560.
- **No copiar datos personales de un gimnasio a otro**, ni siquiera «para
  probar».

## 8 · Legal (Nicaragua)

Aplica la **Ley 787 de Protección de Datos Personales** y su **Decreto
36-2012**:

- **Art. 11**: medidas técnicas y organizativas de seguridad. Ya están en la
  base (RLS, bitácoras, roles) y se heredan completas.
- **Art. 12**: secreto profesional, y la obligación **sobrevive al fin de la
  relación**.
- **Art. 22**: cada gimnasio debe **inscribirse en el Registro de Ficheros de
  Datos** ante DIPRODAP (resolución en 30 días). Es obligación del gimnasio.

Contrato sugerido por gimnasio: (1) el gimnasio es responsable de los datos y se
obliga a inscribirse; (2) quien programa es encargado del tratamiento y no puede
usar esos datos para otro fin; (3) el código es del desarrollador, con licencia
de uso mientras la cuota esté al día; (4) los respaldos son de quien los
configura. Que lo revise un abogado.
