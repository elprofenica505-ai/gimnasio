#!/usr/bin/env node
/**
 * Protege el baseline histórico 00099–00104.
 *
 * Esas seis migraciones ya tienen su resultado final en producción, pero no
 * aparecen de manera individual en supabase_migrations.schema_migrations. No
 * se vuelven a aplicar ni se modifican para “arreglar” el historial: un cambio
 * de comportamiento debe llegar en una migración nueva, revisada y ensayada.
 *
 * Este chequeo no se conecta a Supabase ni toca datos. Falla antes de CI si se
 * edita, borra o saca del instalador una de las fuentes congeladas. Los hashes
 * se tomaron del baseline cotejado el 17 de noviembre de 2026; para cambiar
 * esta lista se necesita una revisión explícita de migraciones, no editar este
 * script junto al SQL por conveniencia.
 *
 * Uso: npm run check:migration-baseline
 */

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const INSTALLER = join(ROOT, "supabase", "INSTALAR-BASE.sql");

const BASELINE = [
  ["00099_embudo_de_ventas.sql", "1e808eccd9bdc68af1807327e4edaacad629fbe171eaf7e41802b8aac72eaabc"],
  ["00100_superadministrador.sql", "c40c3e615571c38f832ee0b79bc6a78e87e3d8c1d981f9b6271710930548042c"],
  ["00101_tienda_publica.sql", "c988343ce380ac856f36b0ccf5889a04f32b2d3ba43f82c6b20707e9cbff9dbb"],
  ["00102_embudo_metodo_pago_resiliente.sql", "0d080e9ef8335525f7d318f6eb803a9796e35df161013ef7bd86c80108820987"],
  ["00103_embudo_cuenta_resiliente_y_rechazo.sql", "9b8143419e97347c2910284afac97ce806d6ae5c34da584824e0389cf0690cd8"],
  ["00104_arm_asistente_interno.sql", "35005dba96116477ad5321f469ddaa43a69658a3e48474061d77576ac24483a2"],
];

const sha256 = (text) => createHash("sha256").update(text).digest("hex");
const errors = [];

if (!existsSync(INSTALLER)) {
  errors.push("No existe supabase/INSTALAR-BASE.sql; corré build:install y revisá el cambio.");
}
const installer = existsSync(INSTALLER) ? readFileSync(INSTALLER, "utf8") : "";

for (const [name, expectedHash] of BASELINE) {
  const path = join(ROOT, "supabase", "migrations", name);
  if (!existsSync(path)) {
    errors.push(`${name}: falta el archivo congelado.`);
    continue;
  }

  const source = readFileSync(path, "utf8");
  const actualHash = sha256(source);
  if (actualHash !== expectedHash) {
    errors.push(`${name}: cambió su SHA-256 (${actualHash}). No se editan migraciones ya verificadas; agregá una migración nueva.`);
  }

  // El generador usa trim() al concatenar migraciones. Esta comparación evita
  // que el instalador de un proyecto nuevo quede sin una parte del baseline.
  if (!installer.includes(source.trim())) {
    errors.push(`${name}: su contenido no aparece íntegro en INSTALAR-BASE.sql.`);
  }
}

if (errors.length > 0) {
  console.error("\n❌ Baseline de migraciones 00099–00104 no protegido:");
  for (const error of errors) console.error(`   - ${error}`);
  console.error("\nLeé docs/MIGRACIONES-PRODUCCION.md antes de cambiar migraciones o desplegar SQL.");
  process.exitCode = 1;
} else {
  console.log("✅ Baseline 00099–00104 íntegro y presente en INSTALAR-BASE.sql.");
}
