#!/usr/bin/env node
/**
 * ============================================================
 *  Diagnóstico de esquema — corrida LOCAL (PGlite)
 * ============================================================
 *  Aplica supabase/INSTALAR-BASE.sql sobre PGlite (la misma base
 *  mínima que scripts/test-instalar-base-sql.mjs, vía el helper
 *  compartido) y después corre supabase/
 *  DIAGNOSTICO-ESQUEMA-FINANCIERO.sql tal cual.
 *
 *  Imprime por stdout la tabla comparable (seccion|objeto|detalle),
 *  en el mismo formato que se copia del SQL Editor de Supabase, y la
 *  guarda en diagnosticos/esquema-instalacion-nueva.txt.
 *
 *  Para qué: tener la salida de la instalación nueva ANTES de pedir
 *  la de Strong, y así detectar de una vez lo que el artefacto split
 *  (supabase/instalacion/00010-esquema-financiero-split.sql) deba
 *  corregir. La comparación FINAL que destraba el PR #4 es
 *  Strong-real vs proyecto-nuevo-real, las dos en Supabase.
 *
 *  Uso:  npm run diagnostic:local
 */

import { PGlite } from "@electric-sql/pglite";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { authMinimo } from "./helpers/pglite-auth-min.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const INSTALL = join(REPO, "supabase", "INSTALAR-BASE.sql");
const DIAG = join(REPO, "supabase", "DIAGNOSTICO-ESQUEMA-FINANCIERO.sql");
const SALIDA = join(REPO, "diagnosticos", "esquema-instalacion-nueva.txt");

const db = new PGlite();
await authMinimo(db);

console.error("▶ Aplicando INSTALAR-BASE.sql sobre PGlite…");
await db.exec(readFileSync(INSTALL, "utf8"));
console.error("  ✅ instalación completa sin errores");

console.error("▶ Corriendo DIAGNOSTICO-ESQUEMA-FINANCIERO.sql…");
const res = await db.query(readFileSync(DIAG, "utf8"));
const lineas = res.rows.map((r) => `${r.seccion}|${r.objeto}|${r.detalle}`);
const salida = lineas.join("\n") + "\n";

mkdirSync(dirname(SALIDA), { recursive: true });
writeFileSync(SALIDA, salida, "utf8");

process.stdout.write(salida);
console.error(`\n✅ ${res.rows.length} filas → diagnosticos/esquema-instalacion-nueva.txt`);
