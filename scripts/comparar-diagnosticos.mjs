#!/usr/bin/env node
/**
 * ============================================================
 *  Comparador de salidas del DIAGNOSTICO-ESQUEMA-FINANCIERO.sql
 * ============================================================
 *  La puerta final del hueco #5 exige comparar la salida del
 *  diagnóstico entre dos bases (Strong-real vs instalación-nueva).
 *  Esta herramienta hace el diff fila por fila y separa lo que es
 *  diferencia real de lo que es ruido ambiental conocido.
 *
 *  Formatos aceptados (en cualquier mezcla):
 *    · .csv exportado del SQL Editor de Supabase (con cabecera
 *      seccion,objeto,detalle y campos entrecomillados)
 *    · .txt plano de `npm run diagnostic:local` (seccion|objeto|detalle)
 *
 *  Ruido ambiental filtrado (salvo --estricto):
 *    · 07.permiso — los ACL dependen del entorno: PGlite no tiene
 *      los roles/default-privileges de Supabase (service_role etc.).
 *      Esta sección sólo es comparable Supabase real ↔ Supabase real.
 *    · 03.constraint filas "NOT NULL …" — Postgres 17 registra los
 *      NOT NULL en pg_constraint; versiones anteriores no. Depende
 *      de la versión mayor de cada base, no del artefacto.
 *
 *  Uso:
 *    node scripts/comparar-diagnosticos.mjs <referencia> <comparada> [--estricto]
 *                                          [--aceptar <clave> ...]
 *    npm run diagnostic:comparar -- diagnosticos/esquema-strong-real.csv \
 *                                   diagnosticos/esquema-instalacion-nueva.txt
 *
 *  --aceptar: repite la bandera con la clave completa
 *  (`seccion|tabla.objeto`) de una diferencia DOCUMENTADA a propósito
 *  (p. ej. la FK sessions_coach_id_fkey que Strong real perdió y la
 *  instalación nueva conserva fiel al repo). Se listan aparte y no
 *  afectan el código de salida; una clave aceptada que deja de
 *  diferir se reporta como anomalía.
 *
 *  Salida: por cada sección, claves SOLO EN REFERENCIA, SOLO EN
 *  COMPARADA y VALOR DISTINTO. Sale con código 1 si queda alguna
 *  diferencia no ambiental y no aceptada (la puerta es cero
 *  diferencias, salvo las aceptadas una por una).
 */

import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const [refPath, cmpPath] = args;
if (!refPath || !cmpPath) {
  console.error("Uso: comparar-diagnosticos.mjs <referencia> <comparada> [--estricto] [--aceptar <clave>]...");
  process.exit(2);
}
const restantes = args.slice(2);
const estricto = restantes.includes("--estricto");
const aceptadas = new Set();
for (let i = 0; i < restantes.length; i++) {
  if (restantes[i] === "--aceptar") {
    const valor = restantes[i + 1];
    if (!valor || valor.startsWith("--")) {
      console.error('--aceptar requiere la clave completa, p. ej. --aceptar "03.constraint|sessions.sessions_coach_id_fkey"');
      process.exit(2);
    }
    aceptadas.add(valor);
    i++;
  }
}

/** Parsea un CSV del SQL Editor (comillas RFC4180, CRLF). */
function parseCsv(texto) {
  const filas = [];
  let campo = "";
  let fila = [];
  let enComillas = false;
  for (let i = 0; i < texto.length; i++) {
    const ch = texto[i];
    if (enComillas) {
      if (ch === '"') {
        if (texto[i + 1] === '"') {
          campo += '"';
          i++;
        } else enComillas = false;
      } else campo += ch;
    } else if (ch === '"') enComillas = true;
    else if (ch === ",") {
      fila.push(campo);
      campo = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && texto[i + 1] === "\n") i++;
      fila.push(campo);
      campo = "";
      if (fila.some((f) => f !== "")) filas.push(fila);
      fila = [];
    } else campo += ch;
  }
  fila.push(campo);
  if (fila.some((f) => f !== "")) filas.push(fila);
  if (filas.length && filas[0][0] === "seccion") filas.shift();
  return filas;
}

/** Parsea el .txt plano del runner local (seccion|objeto|detalle). */
function parseTxt(texto) {
  return texto
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "")
    .map((l) => {
      const a = l.indexOf("|");
      const b = l.indexOf("|", a + 1);
      return [l.slice(0, a), l.slice(a + 1, b), l.slice(b + 1)];
    });
}

function cargar(ruta) {
  const texto = readFileSync(ruta, "utf8");
  const filas = ruta.toLowerCase().endsWith(".csv") ? parseCsv(texto) : parseTxt(texto);
  const mapa = new Map();
  for (const [seccion, objeto, detalle] of filas) {
    mapa.set(`${seccion}|${objeto}`, String(detalle ?? "").trim());
  }
  return mapa;
}

function esAmbiental(clave, detalle) {
  if (estricto) return null;
  if (clave.startsWith("07.permiso|")) {
    return "ACL/permisos: sólo comparable Supabase real ↔ Supabase real (PGlite no tiene service_role ni default privileges)";
  }
  if (clave.startsWith("03.constraint|") && detalle.startsWith("NOT NULL ")) {
    return "Postgres 17 registra NOT NULL en pg_constraint; bases más viejas no (ruido de versión, no del artefacto)";
  }
  return null;
}

const ref = cargar(refPath);
const cmp = cargar(cmpPath);

const ambientales = new Map(); // motivo -> [claves]
function registrarAmbiental(motivo, clave) {
  if (!ambientales.has(motivo)) ambientales.set(motivo, []);
  ambientales.get(motivo).push(clave);
}

let diferencias = 0;
const aceptadasUsadas = new Map(); // clave -> tipo de diferencia
function clasificar(tipo, clave, seccion, valor) {
  if (aceptadas.has(clave)) {
    aceptadasUsadas.set(clave, tipo);
    console.log(`    ACEPTADA (${tipo})  ${clave.slice(seccion.length + 1)}  →  ${valor ?? ""}`);
    return;
  }
  diferencias++;
  if (valor !== null) console.log(`    ${tipo}  ${clave.slice(seccion.length + 1)}  →  ${valor}`);
  else console.log(`    ${tipo}  ${clave.slice(seccion.length + 1)}`);
}

const secciones = [...new Set([...ref.keys(), ...cmp.keys()].map((k) => k.split("|")[0]))].sort();

console.log(`Referencia: ${refPath} (${ref.size} filas)`);
console.log(`Comparada:  ${cmpPath} (${cmp.size} filas)`);
console.log(
  `Modo: ${estricto ? "ESTRICTO (sin filtro ambiental)" : "normal (filtra ruido ambiental conocido)"}` +
    (aceptadas.size ? ` · ${aceptadas.size} diferencia(s) aceptada(s) explícita(s)` : "") +
    "\n",
);

for (const seccion of secciones) {
  const soloRef = [];
  const soloCmp = [];
  const distintas = [];
  for (const [clave, valor] of [...ref.entries()].filter(([k]) => k.startsWith(seccion + "|"))) {
    const ambiental = esAmbiental(clave, valor);
    if (ambiental) {
      registrarAmbiental(ambiental, clave);
      continue;
    }
    if (!cmp.has(clave)) soloRef.push([clave, valor]);
    else if (cmp.get(clave) !== valor) distintas.push([clave, valor, cmp.get(clave)]);
  }
  for (const [clave, valor] of [...cmp.entries()].filter(([k]) => k.startsWith(seccion + "|"))) {
    const ambiental = esAmbiental(clave, valor);
    if (ambiental) {
      registrarAmbiental(ambiental, clave);
      continue;
    }
    if (!ref.has(clave)) soloCmp.push([clave, valor]);
  }
  if (!soloRef.length && !soloCmp.length && !distintas.length) {
    console.log(`✔ ${seccion}: sin diferencias`);
    continue;
  }
  console.log(`✖ ${seccion}:`);
  for (const [clave, valor] of soloRef) clasificar("SOLO EN REFERENCIA", clave, seccion, valor);
  for (const [clave, valor] of soloCmp) clasificar("SOLO EN COMPARADA", clave, seccion, valor);
  for (const [clave, a, b] of distintas) {
    clasificar("VALOR DISTINTO", clave, seccion, null);
    console.log(`        referencia: ${a}`);
    console.log(`        comparada:  ${b}`);
  }
}

for (const clave of aceptadas) {
  if (!aceptadasUsadas.has(clave)) {
    console.log(`⚠  La diferencia aceptada ya NO se presenta (revisar y quitar de la lista): ${clave}`);
  }
}

if (ambientales.size) {
  console.log("\n─ Ruido ambiental filtrado (no cuenta como diferencia):");
  for (const [motivo, claves] of ambientales) {
    console.log(`  · ${motivo}: ${claves.length} fila(s)`);
  }
}

console.log(`\n${diferencias === 0 ? "✅ CERO diferencias no ambientales." : `❌ ${diferencias} diferencia(s) no ambientales.`}`);
process.exit(diferencias === 0 ? 0 : 1);
