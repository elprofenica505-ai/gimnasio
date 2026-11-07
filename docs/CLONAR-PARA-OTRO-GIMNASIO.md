# Clonar la aplicación para otro gimnasio

**Regla: todo igual. Módulo por módulo, función por función. Lo único que cambia
son los datos del gimnasio y las imágenes que son suyas.**

No se quita ningún módulo. No se desactiva nada. La aplicación nueva es la
misma aplicación, con otro nombre y sin los datos de nadie.

---

## 1 · Qué es idéntico y no hay que tocar

| Pieza | Por qué es idéntica |
|---|---|
| Las 45 tablas | Mismo esquema, creadas por `INSTALAR-BASE.sql` |
| Las reglas de seguridad (RLS) | Vienen en las migraciones, no en el código |
| Las funciones y disparadores | Cobrar, reservar, cerrar caja, vigencias, bitácora |
| Los permisos del personal y los interruptores de caja | Estructura, no configuración |
| Los límites de abuso y la protección de datos | `00098` |
| **Los módulos y sus pantallas** | **Todos. No se quita ninguno.** |
| **La biblioteca de ejercicios** | **Catálogo completo, con sus fotos y su atribución** |
| El sonido de la transición | `public/sounds/trueno.mp3` |
| El service worker y el manifest | `public/sw.js`, `src/app/manifest.ts` |

---

## 2 · La biblioteca de ejercicios: cómo viaja

Esto importa porque pediste que las imágenes de ejercicios queden iguales.

**No están en el repositorio ni en la base.** El dataset se descarga del origen
oficial (`RepDB/exercise-dataset` y `yuhonas/free-exercise-db`) y se carga con
la función `admin_import_exercises`. El repositorio guarda sólo el código que la
usa: la licencia permite usarlo dentro de la app, no redistribuirlo.

Entonces, en el proyecto nuevo:

1. Entrar como administrador **con el segundo factor activo**.
2. Ir a la pantalla de la biblioteca de ejercicios.
3. Apretar **Importar catálogo**. Descarga ~2,6 MB y hace *upsert* por `id`.

Resultado: **el mismo catálogo, las mismas fotos, los mismos textos en
español.** Sin copiar un solo archivo. Tarda menos de un minuto y se puede
repetir sin duplicar nada.

> Si se aprieta antes de tener 2FA, la ruta responde que falta el segundo
> factor. Es a propósito: cargar el catálogo es una acción de administración.

---

## 3 · Qué cambia (y sólo esto)

### 3.1 Datos del gimnasio

Todo en `src/config/site.ts`: nombre, nombre corto, razón social, teléfono,
WhatsApp, correo, dirección, **link de Google Maps**, coordenadas, zona horaria,
moneda, redes sociales y horario de atención.

Y estos diez puntos donde el nombre está escrito a mano (rutas verificadas
contra el código real de este repo; el relevado completo, incluidos `sw.js`,
`manifest`, `icon.svg` y tests que pinean la marca, está en
`docs/INVENTARIO-DATOS-STRONG.md` §3):

| Archivo | Qué contiene |
|---|---|
| `src/i18n/dictionaries/es.ts` · `en.ts` | Textos de la marca |
| `src/components/sections/hero.tsx` | Título de portada |
| `src/components/sections/cta-band.tsx` | Mensaje de WhatsApp |
| `src/components/layout/storm-transition.tsx` | Texto de la transición |
| `src/components/legal/legal-document.tsx` | Razón social del aviso legal |
| `src/components/admin/master-export-button.tsx` | Nombre del Excel exportado |
| `src/components/admin/category-rules.tsx` | «Strong Gym» como nombre visible de categoría (la clave SQL `strong_gym` no se toca) |
| `src/lib/reports/workbook.ts` | Encabezados del Excel |
| `src/app/manifest.ts` | Descripción de la app instalada |
| `src/app/[locale]/layout.tsx` (línea ~99) | `themeColor` (rojo `#d81a22`) |

**El prefijo `strong_gym_` del SQL no se toca.** Es una clave interna, no una
marca visible. Renombrarla obliga a editar 82 migraciones y no cambia nada para
el usuario.

### 3.2 Imágenes

Son 21 archivos. Se reemplazan por los del gimnasio nuevo, con los mismos
nombres y medidas, y no hay que tocar código.

**Fotos del gimnasio y de su gente** (`public/images/`, 15 archivos):

| Archivo | Dónde se ve |
|---|---|
| `fachada.jpg` | Portada y vista previa al compartir |
| `boxeo.jpg`, `sacos.jpg` | Sección de boxeo |
| `cambio.jpg`, `grupo.jpg`, `pareja1.jpg` | Sección de comunidad |
| `supl1.jpg` | Sección de suplementos |
| `sala1.jpg` | Pantalla de ingreso |
| `abs.jpg`, `dip.jpg`, `pantorrilla.jpg`, `pesas.jpg`, `sala2.jpg`, `triceps.jpg` | Landing: qué hacemos y galería |
| `emblema.jpg` | Sin uso, se puede borrar |

**Marca** (6 archivos): `public/brand/emblema-strong.webp`, `icon-192.png`,
`icon-512.png`, `apple-icon.png`, `public/icons/` (4 tamaños) y
`public/splash/` (4 tamaños).

### 3.3 Lo que NO se copia

- **Los socios de Strong**: nombre, cédula, teléfono, mediciones, cobros.
  No son datos tuyos para reutilizar, y legalmente son de esas personas.
- **Las fotos donde salen socios reales**: mismo motivo, más derecho de imagen.
- **Las cuentas de acceso**: cada persona crea la suya.
- **El historial de caja y las facturas**: arranca en cero.

---

## 4 · Secuencia completa

**Base de datos**

1. Supabase → **New project** → región `us-east-1` → guardar la contraseña.
2. **SQL Editor** → pegar `supabase/INSTALAR-BASE.sql` → Run.
   *(Desde el celular, instalar con las 3 partes de `supabase/instalar/`:
   guía en `docs/INSTALAR-DESDE-EL-CELULAR.md`.)*
3. **Authentication → Users → Add user**: correo y contraseña del dueño. Copiar su UID.
4. **SQL Editor** → pegar `supabase/PERSONALIZAR-GIMNASIO.sql` con el UID y los precios → Run.
5. **Authentication → URL Configuration**: URL del sitio y `/auth/callback`.
6. **Authentication → Providers**: SMTP propio si se quieren correos con dominio.
7. Activar **2FA** para el dueño y entrar al panel.
8. **Importar catálogo** de ejercicios (botón, con 2FA).

**Aplicación**

9. Cambiar `src/config/site.ts` y los diez archivos de la tabla 3.1.
10. Reemplazar las 21 imágenes de la tabla 3.2.
11. Vercel → importar el repositorio → variables:
    `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`,
    `NEXT_PUBLIC_SITE_URL`, `NEXT_PUBLIC_DEVELOPER_BRAND`.
12. Dominio en Vercel → **Settings → Domains**.

**Configuración dentro del panel** (nada de esto es SQL)

13. Disciplinas y modalidades.
14. Horarios y clases, con sus salas.
15. Planes y precios.
16. Equipo: entrenadores, recepción, roles y permisos.
17. Categorías de cliente (las reglas ya vienen; los nombres visibles están en el código).
18. Cuentas de dinero: agregar los bancos reales con sus números.

---

## 5 · Lo que no existe y conviene saber

- **No hay buckets de Storage.** Las imágenes viven en el repositorio (`public/`),
  no en Supabase. Por eso no hay nada que copiar de un proyecto a otro.
- **No existe `supabase/config.toml`.** La configuración de Auth (confirmaciones,
  redirecciones, SMTP, MFA) no está versionada: se rehace en el panel del
  proyecto nuevo.
- **El SQL no trae disciplinas, horarios, planes con precio ni entrenadores.**
  A propósito: son datos del gimnasio, no estructura.
- **La grilla de boxeo de Strong está dentro de la función `generate_week_sessions()`.**
  No inserta nada al instalar (la tabla `classes` viene vacía y la función salta
  lo que no existe), pero si se aprieta «generar horarios» antes de crear las
  disciplinas del gimnasio nuevo, se lleva esa grilla. Crear disciplinas primero.

---

## 6 · Mantener los dos proyectos

Un arreglo que sirve para los dos se hace dos veces. Para que no se pierda:

| Qué | Nació en | Portado al gimnasio nuevo | Fecha |
|---|---|---|---|
| — | — | — | — |

Regla de corte: cuando un mismo cambio haya que hacerlo tres veces, dejar de
copiar y armar un núcleo compartido. Con dos clientes no hace falta.
