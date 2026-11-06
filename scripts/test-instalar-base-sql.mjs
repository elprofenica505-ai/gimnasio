#!/usr/bin/env node
/**
 * ============================================================
 *  Prueba de supabase/INSTALAR-BASE.sql — el archivo que se pega
 * ============================================================
 *  Las demás suites aplican la cadena que arma el helper (lista
 *  curada de migraciones + shims). Esta suite NO: aplica el
 *  INSTALAR-BASE.sql COMPLETO, de una sola vez, sin recortes ni
 *  parches. Es la única prueba que ejecuta el artefacto real que
 *  se pega en el SQL Editor de Supabase del gimnasio nuevo.
 *
 *  Lo único que se agrega antes es el schema `auth` mínimo, porque
 *  PGlite no trae lo que Supabase ya provee (schema, roles anon /
 *  authenticated, auth.users, auth.uid(), auth.jwt()).
 *
 *  Verifica:
 *    1. El archivo completo corre sin errores sobre una base limpia.
 *    2. Instalación vacía: 0 filas en las tablas de negocio.
 *    3. Ninguna columna de texto (ni JSON) de ninguna tabla del
 *       schema public contiene «Strong». Las claves internas
 *       strong_gym / strong_gym_ son minúsculas y no chocan.
 *    4. El catálogo genérico sí sobrevive: category_rules = 4,
 *       payment_methods > 0, expense_categories > 0.
 *    5. Existen las funciones clave: generate_week_sessions,
 *       admin_import_exercises, rate_limit_hit, crm_is_staff.
 *    6. generate_week_sessions() no inserta nada (sin grilla).
 *
 *  Uso:  npm run test:instalar
 */

import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const ARCHIVO = join(REPO, "supabase/INSTALAR-BASE.sql");

let failures = 0;
function check(label, condition, detail = "") {
  const ok = Boolean(condition);
  if (!ok) failures++;
  console.log(`${ok ? "  ✅" : "  ❌"} ${label}${detail ? ` — ${detail}` : ""}`);
}

const db = new PGlite();

/* ------------------------------------------------------------
   0. El mínimo de Supabase que PGlite no trae
   ------------------------------------------------------------ */
await db.exec(`
create schema if not exists auth;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
create table if not exists auth.current_user (id uuid, aal text);
create or replace function auth.uid() returns uuid
  language sql stable as $$ select id from auth.current_user limit 1 $$;
create or replace function auth.jwt() returns jsonb
  language sql stable as $$ select jsonb_build_object('aal', aal) from auth.current_user limit 1 $$;
grant usage on schema auth to authenticated, anon;
grant select on auth.current_user to authenticated, anon;
`);

/* ------------------------------------------------------------
   1. El archivo completo, de una sola vez
   ------------------------------------------------------------ */
console.log("\n▶ Ejecutando supabase/INSTALAR-BASE.sql completo (sin recortes ni shims)…");
const sql = readFileSync(ARCHIVO, "utf8");
const inicio = Date.now();
await db.exec(sql);
const segundos = ((Date.now() - inicio) / 1000).toFixed(1);
console.log(`  ✅ corrió sin errores (${Math.round(sql.length / 1024)} KB en ${segundos}s)`);

/* ------------------------------------------------------------
   2. Instalación vacía
   ------------------------------------------------------------ */
console.log("\n▶ Instalación vacía: 0 filas en las tablas de negocio");
for (const tabla of [
  "plans",
  "classes",
  "sessions",
  "coaches",
  "gym_clients",
  "transactions",
  // Dos agregados en el mismo espíritu: las cuentas bancarias y la
  // siembra de la grilla de boxeo fueron fugas reales del kit original.
  "accounts",
  "class_schedule_slots",
]) {
  const n = (await db.query(`select count(*)::int as n from public."${tabla}"`)).rows[0].n;
  check(`${tabla}: 0 filas`, n === 0, `${n} fila(s)`);
}

/* ------------------------------------------------------------
   3. Barrido: «Strong» en ninguna columna de texto
   ------------------------------------------------------------ */
console.log("\n▶ Barrido: ninguna columna de texto contiene «Strong»");
const columnas = (
  await db.query(`
    select table_name, column_name
      from information_schema.columns
     where table_schema = 'public'
       and data_type in ('text', 'character varying', 'character', 'jsonb', 'json')
     order by table_name, ordinal_position`)
).rows;
const trozos = columnas.map(
  ({ table_name, column_name }) =>
    `select '${table_name}.${column_name}' as lugar, count(*)::int as n
       from public."${table_name}"
      where "${column_name}"::text like '%Strong%'`,
);
const sucias = trozos.length
  ? (await db.query(trozos.join("\nunion all\n"))).rows.filter((r) => r.n > 0)
  : [];
check(
  `«Strong» no aparece en ninguna fila (${columnas.length} columnas de texto/JSON del schema public)`,
  sucias.length === 0,
  sucias.map((s) => `${s.lugar} (${s.n})`).join(", "),
);

/* ------------------------------------------------------------
   4. El catálogo genérico sí sobrevive
   ------------------------------------------------------------ */
console.log("\n▶ Catálogo genérico (lo único que viene cargado)");
const reglas = (await db.query(`select count(*)::int as n from public.category_rules`)).rows[0].n;
check("category_rules: 4 filas", reglas === 4, `${reglas} fila(s)`);
const metodos = (await db.query(`select count(*)::int as n from public.payment_methods`)).rows[0].n;
check("payment_methods > 0", metodos > 0, `${metodos} método(s)`);
const categorias = (await db.query(`select count(*)::int as n from public.expense_categories`)).rows[0]
  .n;
check("expense_categories > 0", categorias > 0, `${categorias} categoría(s)`);

/* ------------------------------------------------------------
   5. Las funciones clave existen
   ------------------------------------------------------------ */
console.log("\n▶ Funciones clave");
for (const fn of [
  "generate_week_sessions",
  "admin_import_exercises",
  "rate_limit_hit",
  "crm_is_staff",
]) {
  const n = (
    await db.query(
      `select count(*)::int as n
         from pg_proc p
         join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'public' and p.proname = $1`,
      [fn],
    )
  ).rows[0].n;
  check(`public.${fn}(…) existe`, n >= 1, `${n} definición(es)`);
}

/* ------------------------------------------------------------
   6. El generador de semanas no inventa nada
   ------------------------------------------------------------ */
console.log("\n▶ generate_week_sessions() sobre la instalación vacía");
const generadas = (
  await db.query(`select public.generate_week_sessions(current_date + 28) as n`)
).rows[0].n;
check("devuelve 0 clases nuevas", Number(generadas) === 0, `${generadas}`);
const sesiones = (await db.query(`select count(*)::int as n from public.sessions`)).rows[0].n;
check("sessions sigue con 0 filas", sesiones === 0, `${sesiones} fila(s)`);

console.log(
  `\n${
    failures === 0
      ? "🎉 INSTALAR-BASE.sql pasa: instala limpio, vacío y sin datos ajenos"
      : `⚠️  ${failures} prueba(s) fallaron`
  }\n`,
);
process.exit(failures === 0 ? 0 : 1);
