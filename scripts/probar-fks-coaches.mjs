#!/usr/bin/env node
/**
 * Prueba directa de las dos claves foráneas hacia coaches.
 *
 * La reconstrucción de coaches (sección 10 del artefacto split) hace
 * `drop table … cascade`, que se llevó una vez transactions_coach_id_fkey
 * por sorpresa. Este probe aplica supabase/INSTALAR-BASE.sql completo
 * sobre PGlite limpia y pregunta al catálogo por las DOS FKs:
 *   · sessions_coach_id_fkey      (la restaura la sección 10; Strong
 *                                  real NO la tiene — diferencia
 *                                  aceptada, ver docs/INVENTARIO §8.7.2)
 *   · transactions_coach_id_fkey  (la restaura la sección 10)
 *
 * Uso:  node scripts/probar-fks-coaches.mjs
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { authMinimo } from "./helpers/pglite-auth-min.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const db = new PGlite();
await authMinimo(db);
await db.exec(readFileSync(join(REPO, "supabase", "INSTALAR-BASE.sql"), "utf8"));

const r = await db.query(`
  select conrelid::regclass::text as tabla, conname, pg_get_constraintdef(oid) as def
    from pg_constraint
   where conname in ('sessions_coach_id_fkey', 'transactions_coach_id_fkey')
   order by conname`);

for (const f of r.rows) console.log(`${f.tabla} · ${f.conname} · ${f.def}`);
if (r.rows.length === 2) {
  console.log("✅ LAS DOS claves foráneas hacia coaches quedan tras instalar");
  process.exit(0);
}
console.error(`❌ Faltan claves foráneas (${r.rows.length}/2)`);
process.exit(1);
