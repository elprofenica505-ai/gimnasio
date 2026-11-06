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
import { authMinimo } from "./helpers/pglite-auth-min.mjs";

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
   0. El mínimo de Supabase que PGlite no trae (helper compartido
      con scripts/diagnostic-esquema-local.mjs)
   ------------------------------------------------------------ */
await authMinimo(db);

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
  // En el esquema split de la instalación nueva las cuentas viven en
  // bank_accounts; `accounts` es del modelo histórico repository.
  "bank_accounts",
  "class_schedule_slots",
]) {
  const n = (await db.query(`select count(*)::int as n from public."${tabla}"`)).rows[0].n;
  check(`${tabla}: 0 filas`, n === 0, `${n} fila(s)`);
}

// El layout tiene que dar split: es lo que exigen los guards de
// aplicación de 00024/00028/00029 y lo que usa finance_read (00023).
const layout = (await db.query("select public.crm_finance_layout() as l")).rows[0].l;
check(
  "crm_finance_layout() = bank_accounts_split",
  layout === "bank_accounts_split",
  `layout=${layout}`,
);

// Las tablas del modelo repository NO deben existir en la instalación
// nueva: si alguna migración las creara, el clasificador vería los dos
// modelos a la vez y devolvería 'unsupported'.
for (const tabla of ["accounts", "invoices", "invoice_items", "cash_registers"]) {
  const existe = (await db.query(`select to_regclass('public.${tabla}') is not null as x`))
    .rows[0].x;
  check(`${tabla} (repository) no existe`, !existe, existe ? "existe" : "no existe");
}

// Las DOS claves foráneas hacia coaches deben sobrevivir a la
// reconstrucción de la sección 10 del artefacto split: el
// `drop table … cascade` ya se llevó una vez
// transactions_coach_id_fkey por sorpresa (sessions_coach_id_fkey
// es diferencia ACEPTADA contra Strong real, que la perdió — ver
// docs/INVENTARIO-DATOS-STRONG.md §8.7.2).
{
  const fks = (
    await db.query(`
      select conname from pg_constraint
       where conname in ('sessions_coach_id_fkey', 'transactions_coach_id_fkey')
       order by conname`)
  ).rows.map((r) => r.conname);
  check(
    "FK sessions_coach_id_fkey y transactions_coach_id_fkey presentes",
    JSON.stringify(fks) === JSON.stringify(["sessions_coach_id_fkey", "transactions_coach_id_fkey"]),
    fks.join(", ") || "ninguna",
  );
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
