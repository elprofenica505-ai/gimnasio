# Instalar la base desde el celular (3 partes)

**Qué es esto:** la base de datos del gimnasio se instala pegando un SQL
en Supabase. El SQL completo pesa más de 800 KB y el editor del celular
se traba o lo corta a la mitad. Por eso está partido en **3 partes**: el
resultado es exactamente el mismo, byte a byte (lo prueba la suite
automática del repo).

**Las 3 partes viven en el repositorio, carpeta
`supabase/instalar/`:**

1. `parte-1-de-3.sql`
2. `parte-2-de-3.sql`
3. `parte-3-de-3.sql`

Cada una pesa menos de 300 KB y dice arriba «PARTE X DE 3 — NO CORRER
FUERA DE ORDEN». Se generan solas a partir de las migraciones: nunca
editarlas a mano.

---

## Antes de empezar

- Necesitás el **proyecto de Supabase ya creado** (fase 4) y la
  contraseña guardada.
- Abrí en el navegador del celular:
  `github.com/elprofenica505-ai/gimnasio` → carpeta `supabase` →
  carpeta `instalar`.

## Cómo copiar cada parte (en el celular)

1. Tocá el archivo (por ejemplo `parte-1-de-3.sql`).
2. Tocá el botón **Raw** (arriba a la derecha del archivo).
3. Mantenés apretado sobre el texto → **Seleccionar todo** → **Copiar**.

Repetís lo mismo con cada parte cuando le toque.

---

## Paso 1 de 3 — la primera parte

1. Entrá a **supabase.com** → tu proyecto.
2. Abajo a la izquierda, tocá el ícono **SQL Editor**.
3. Tocá **New query** (o el botón **+**).
4. Pegá el contenido completo de `parte-1-de-3.sql`.
5. Tocá **Run**.
6. **Esperá** hasta ver **Success. No rows returned.** Puede tardar un
   minuto. No cierres la pestaña y no toques Run otra vez.

## Paso 2 de 3 — la segunda parte

1. En el SQL Editor, tocá **New query** (una query NUEVA, no la misma
   del paso 1).
2. Pegá el contenido completo de `parte-2-de-3.sql`.
3. Tocá **Run** y esperá el **Success**, igual que antes.

## Paso 3 de 3 — la tercera parte

1. Otra vez **New query**.
2. Pegá el contenido completo de `parte-3-de-3.sql`.
3. Tocá **Run** y esperá el **Success**.

Listo: la base quedó instalada completa y vacía (cero socios, cero
cobros, cero datos de nadie). Seguí con la guía
`docs/CLONAR-PARA-OTRO-GIMNASIO.md` §4: crear el usuario del dueño en
**Authentication → Users** y después correr
`supabase/PERSONALIZAR-GIMNASIO.sql`.

---

## Reglas de oro

- **Nunca fuera de orden**: 1 → 2 → 3. Cada parte dice su número arriba.
- **Una parte por query.** Nunca pegues dos partes juntas.
- **Si una parte da error, PARÁ.** No sigas con la siguiente y no
  reintentéis sin más: copiá el mensaje de error tal cual y mandalo por
  chat. Un error a la mitad no se arregla apretando Run de nuevo a
  ciegas.
- Las partes se pueden volver a correr **enteras**, en orden, sobre el
  mismo proyecto (el SQL es idempotente: los «ya existe» son
  inofensivos). Lo que no se debe hacer es quedarse a mitad de camino.
- No uses el botón que dice «Snippets» ni guardes la query con otro
  nombre: pegá, Run, y a la siguiente.
