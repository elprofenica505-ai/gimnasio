#!/usr/bin/env node
/**
 * ============================================================
 *  Genera el SQL de Supabase a partir del código de la web
 * ============================================================
 *  Hace tres cosas:
 *
 *   1. Copia la grilla semanal de clases y los nombres de las salas
 *      desde `src/lib/data/demo-sessions.ts` a las migraciones
 *      00001 y 00003, así el calendario de la web y el de la base
 *      de datos son siempre iguales.
 *
 *   2. Junta las migraciones de instalación en `supabase/SETUP.sql`,
 *      un único archivo para pegar de una sola vez en el SQL Editor
 *      cuando el proyecto de Supabase está vacío.
 *
 *   3. Arma `supabase/ACTUALIZAR.sql` para quien ya corrió el SETUP
 *      anterior y sólo necesita ponerse al día.
 *
 *  Uso:
 *    node scripts/build-sql.mjs          # regenera los archivos
 *    node scripts/build-sql.mjs --check  # falla si están desactualizados (CI)
 */

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { validarSinDatosAjenos } from "./helpers/prohibidas.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CHECK_ONLY = process.argv.includes("--check");

const DEMO_SESSIONS = join(ROOT, "src/lib/data/demo-sessions.ts");
const SEED = join(ROOT, "supabase/migrations/00002_seed.sql");
const SCHEMA = join(ROOT, "supabase/migrations/00001_schema.sql");
const UPDATE_MIGRATION = join(ROOT, "supabase/migrations/00003_datos_reales.sql");
const SETUP = join(ROOT, "supabase/SETUP.sql");
const UPDATE = join(ROOT, "supabase/ACTUALIZAR.sql");

const MARCAS = {
  inicio: "-- >>> PLANTILLA SEMANAL (generada por scripts/build-sql.mjs — no editar a mano) >>>",
  fin: "-- <<< PLANTILLA SEMANAL <<<",
  salasInicio: "-- >>> SALAS >>>",
  salasFin: "-- <<< SALAS <<<",
};

const DIAS = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"];
const ORDEN_DIAS = ["Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"];

/* ------------------------------------------------------------
   1. Leer la grilla semanal desde el código de la web
   ------------------------------------------------------------ */

function leerPlantilla() {
  const codigo = readFileSync(DEMO_SESSIONS, "utf8");
  const bloque = codigo.match(/const WEEKLY_TEMPLATE[^{]*\{([\s\S]*?)\n\};/);
  if (!bloque) throw new Error("No encontré WEEKLY_TEMPLATE en demo-sessions.ts");

  const dias = [];
  const diaRegex = /(\d):\s*\[([\s\S]*?)\]/g;
  let coincidencia;

  while ((coincidencia = diaRegex.exec(bloque[1])) !== null) {
    const numeroDia = Number(coincidencia[1]);
    const slots = [...coincidencia[2].matchAll(/time:\s*"(\d{2}:\d{2})",\s*slug:\s*"([a-z-]+)"/g)].map(
      (slot) => ({ time: slot[1], slug: slot[2] }),
    );
    // Un día puede quedar vacío a propósito: el gimnasio cierra los
    // domingos y hay días sin clases dirigidas (sólo sala abierta).
    dias.push({ dia: numeroDia, slots });
  }

  if (dias.length !== 7) {
    throw new Error(`Esperaba los 7 días (0 a 6) en la plantilla y encontré ${dias.length}`);
  }

  dias.sort((a, b) => a.dia - b.dia);

  const faltantes = dias.map((d, i) => (d.dia === i ? null : i)).filter((d) => d !== null);
  if (faltantes.length > 0) {
    throw new Error(`La plantilla tiene que ir de 0 a 6. Días mal numerados: ${faltantes}`);
  }

  // La plantilla PUEDE estar vacía a propósito: un gimnasio nuevo arranca
  // sin horarios y la función SQL no debe crear nada hasta que se carguen.
  return dias;
}

function leerSalas() {
  const codigo = readFileSync(DEMO_SESSIONS, "utf8");
  const bloque = codigo.match(/const ROOMS[^{]*\{([\s\S]*?)\n\};/);
  if (!bloque) throw new Error("No encontré ROOMS en demo-sessions.ts");

  const salas = [...bloque[1].matchAll(/([a-z-]+):\s*"([^"]+)"/g)].map((s) => ({
    slug: s[1],
    sala: s[2],
  }));

  // ROOMS puede quedar vacío: sin salas por disciplina, la función SQL
  // usa «Salón principal» para todo (la rama `else` del case).
  return salas;
}

/* ------------------------------------------------------------
   2. Armar los bloques SQL
   ------------------------------------------------------------ */

function bloqueSQL(plantilla) {
  const lineas = [
    MARCAS.inicio,
    "      -- Misma grilla que src/lib/data/demo-sessions.ts (la web).",
    "      -- día (0 = lunes), hora local del gimnasio, disciplina",
  ];

  // Los días sin clases no generan filas: sólo se dejan anotados como
  // comentario. Con la grilla totalmente vacía se escribe una fila
  // centinela con NULLs: el SQL sigue siendo válido y la función no
  // crea nada (ninguna disciplina tiene slug NULL).
  const conClases = plantilla.filter((d) => d.slots.length > 0);

  if (conClases.length === 0) {
    for (const { dia } of plantilla) {
      lineas.push(`      -- ${ORDEN_DIAS[dia]}: sin clases`);
    }
    lineas.push("      -- Grilla vacía a propósito: el gimnasio carga sus horarios en el panel.");
    lineas.push("      (null::integer, null::time, null::text)");
    lineas.push(MARCAS.fin);
    return lineas.join("\n");
  }

  const ultimoDia = conClases[conClases.length - 1].dia;

  for (const { dia, slots } of plantilla) {
    if (slots.length === 0) {
      lineas.push(`      -- ${ORDEN_DIAS[dia]}: sin clases`);
      continue;
    }

    lineas.push(`      -- ${ORDEN_DIAS[dia]}`);

    slots.forEach((slot, i) => {
      const esFinalDeTodo = dia === ultimoDia && i === slots.length - 1;
      const valor = `(${dia}, '${slot.time}'::time, '${slot.slug}')`;
      lineas.push(`      ${valor}${esFinalDeTodo ? "" : ","}`);
    });
  }

  lineas.push(MARCAS.fin);
  return lineas.join("\n");
}

function bloqueSalas(salas) {
  const escapar = (t) => t.replace(/'/g, "''");
  if (salas.length === 0) {
    // Un CASE sin ningún WHEN es SQL inválido: se deja un WHEN que no
    // matchea nunca (slug nunca es NULL) para que valga el else
    // («Salón principal») cuando el gimnasio no definió salas propias.
    return [
      MARCAS.salasInicio,
      "        when null then null  -- sin salas por disciplina: todo en «Salón principal»",
      MARCAS.salasFin,
    ].join("\n");
  }
  return [
    MARCAS.salasInicio,
    ...salas.map(({ slug, sala }) => `        when '${slug}' then '${escapar(sala)}'`),
    MARCAS.salasFin,
  ].join("\n");
}

/** Reemplaza el texto entre dos marcas dentro de un archivo SQL. */
function reemplazarBloque(texto, inicio, fin, contenido, archivo) {
  const i = texto.indexOf(inicio);
  const f = texto.indexOf(fin);
  if (i === -1 || f === -1) {
    throw new Error(`Faltan las marcas ${inicio} / ${fin} en ${archivo}`);
  }
  return texto.slice(0, i) + contenido + texto.slice(f + fin.length);
}

/* ------------------------------------------------------------
   3. Escribir los archivos
   ------------------------------------------------------------ */

const plantilla = leerPlantilla();
const salas = leerSalas();
const cantidadSemanal = plantilla.reduce((total, dia) => total + dia.slots.length, 0);

const cambios = [];

/* --- 3a. La grilla y las salas dentro de cada migración --- */
//  00001 crea la función desde cero (instalación nueva) y 00003 la
//  vuelve a crear con la grilla corregida (base ya en uso). Las dos
//  tienen que decir exactamente lo mismo.
function sincronizar(archivo) {
  const original = readFileSync(archivo, "utf8");
  let texto = reemplazarBloque(original, MARCAS.inicio, MARCAS.fin, bloqueSQL(plantilla), archivo);
  texto = reemplazarBloque(texto, MARCAS.salasInicio, MARCAS.salasFin, bloqueSalas(salas), archivo);
  validarSinDatosAjenos(texto, archivo);
  if (texto !== original) cambios.push([archivo, texto]);
  return texto;
}

const schemaNuevo = sincronizar(SCHEMA);
const migracionNueva = sincronizar(UPDATE_MIGRATION);
const financeNuevo = readFileSync(join(ROOT, "supabase/migrations/00010_finance.sql"), "utf8");
const financeSeedNuevo = readFileSync(join(ROOT, "supabase/migrations/00011_finance_seed.sql"), "utf8");

const profilesReadFix = readFileSync(join(ROOT, "supabase/migrations/00012_profiles_self_read.sql"), "utf8");

const crmCompat = readFileSync(join(ROOT, "supabase/migrations/00022_crm_finance_compat.sql"), "utf8");
const financeRead = readFileSync(join(ROOT, "supabase/migrations/00023_finance_read_bank_accounts.sql"), "utf8");
const accountPlanSql = readFileSync(join(ROOT, "supabase/migrations/00025_account_assigned_plan.sql"), "utf8");
const bookingReadSql = readFileSync(join(ROOT, "supabase/migrations/00026_booking_read_policy.sql"), "utf8");
const clientFinanceSql = readFileSync(join(ROOT, "supabase/migrations/00027_client_finance_read.sql"), "utf8");
const accessHardeningSql = readFileSync(join(ROOT, "supabase/migrations/00030_access_hardening.sql"), "utf8");
const crmSql = readFileSync(join(ROOT, "supabase/migrations/00020_clients_crm.sql"), "utf8") + "\n\n" + crmCompat + "\n\n" + financeRead + "\n\n" + accountPlanSql + "\n\n" + bookingReadSql + "\n\n" + clientFinanceSql + "\n\n" + accessHardeningSql;

/* --- 3b. SETUP.sql: instalación desde cero --- */
const cabecera = `-- ============================================================
--  CONFIGURACIÓN COMPLETA DE SUPABASE (instalación vacía)
-- ============================================================
--
--  ESTE ARCHIVO ES PARA UN PROYECTO NUEVO Y VACÍO.
--  Si ya corriste una versión anterior, usá supabase/ACTUALIZAR.sql.
--  Para la instalación nueva del gimnasio el camino recomendado es
--  supabase/INSTALAR-BASE.sql + PERSONALIZAR-GIMNASIO.sql (el kit).
--
--  CÓMO USARLO
--    1. Entrá a tu proyecto en https://supabase.com
--    2. Menú lateral → "SQL Editor" → "New query"
--    3. Copiá TODO este archivo y pegalo en el editor
--    4. Apretá "Run" (o Ctrl + Enter) y esperá unos segundos
--
--  Qué crea:
--    · Las tablas (socios, clases, reservas, consultas, novedades)
--    · Las reglas de seguridad: cada socio sólo ve sus propias reservas
--    · Las funciones de reservar y cancelar, sin sobreventa de cupos
--    · El sistema de caja, contabilidad y métodos de pago (Fase 1)
--    · El catálogo genérico de métodos de pago y categorías de gasto
--
--  Qué NO crea (a propósito):
--    · Ni disciplinas, ni planes, ni clases, ni socios, ni cuentas.
--    · La instalación queda VACÍA: el catálogo y los horarios se
--      cargan desde el panel del gimnasio.
--
--  Es seguro correrlo más de una vez: no duplica datos.
--
--  ARCHIVO GENERADO — no lo edites a mano.
--  El original son supabase/migrations/*.sql.
--  Para regenerarlo:  node scripts/build-sql.mjs
-- ============================================================


`;

const setupNuevo =
  cabecera +
  "-- ############################################################\n" +
  "-- #  PARTE 1 de 3 — ESTRUCTURA BASE (tablas, permisos, funciones)\n" +
  "-- #  Original: supabase/migrations/00001_schema.sql\n" +
  "-- ############################################################\n\n" +
  schemaNuevo.trimStart() +
  "\n\n\n-- ############################################################\n" +
  "-- #  PARTE 2 de 3 — DATOS INICIALES (semilla vaciada: no carga nada)\n" +
  "-- #  Original: supabase/migrations/00002_seed.sql\n" +
  "-- ############################################################\n\n" +
  readFileSync(SEED, "utf8").trimStart() +
  "\n\n\n-- ############################################################\n" +
  "-- #  PARTE 3 de 3 — SISTEMA DE CAJA Y CONTABILIDAD (Fase 1)\n" +
  "-- #  Originales: supabase/migrations/00010_finance.sql\n" +
  "-- #                supabase/migrations/00011_finance_seed.sql\n" +
  "-- ############################################################\n\n" +
  financeNuevo.trimStart() +
  "\n\n" +
  financeSeedNuevo.trimStart() +
  "\n\n-- Corrección de lectura del perfil propio (00012_profiles_self_read.sql)\n" +
  profilesReadFix.trimStart() + "\n\n-- FASE 2: CLIENTES Y RECEPCIÓN (sin seed opcional)\n" + crmSql.trimStart();

/* --- 3c. ACTUALIZAR.sql: para una base que ya está en uso --- */
const actualizarNuevo =
  `-- ============================================================
--  PONER LA BASE AL DÍA (sin tocar datos del gimnasio)
-- ============================================================
--
--  ESTE ARCHIVO ES PARA UN PROYECTO QUE YA ESTÁ FUNCIONANDO.
--  Aplica las correcciones estructurales (precio opcional, color
--  por defecto, generador de horarios con la grilla vacía).
--  Ya NO reemplaza datos: las semillas del gimnasio anterior están
--  vaciadas; disciplinas, planes y horarios se cargan desde el panel.
--  Si todavía no tenés la Fase 1 (caja), también la instala.
--
--  CÓMO USARLO (se hace todo desde el celular)
--    1. Entrá a https://supabase.com y abrí tu proyecto
--    2. Menú → "SQL Editor" → "New query"
--    3. Copiá TODO este archivo, pegalo y tocá "Run"
--    4. Al final del archivo hay una consulta para comprobar
--       que quedó bien
--
--  NO BORRA CUENTAS NI RESERVAS. Es seguro correrlo más de una vez.
--
--  ARCHIVO GENERADO — no lo edites a mano.
--  El original es supabase/migrations/00003_datos_reales.sql.
--  Para regenerarlo:  node scripts/build-sql.mjs
-- ============================================================


` +
  migracionNueva.trimStart() +
  "\n\n\n-- ############################################################\n" +
  "-- #  FASE 1: CAJA Y CONTABILIDAD (para bases que ya estaban\n" +
  "-- #  funcionando antes de esta fase)\n" +
  "-- ############################################################\n\n" +
  financeNuevo.trimStart() +
  "\n\n" +
  financeSeedNuevo.trimStart() +
  "\n\n-- Corrección de lectura del perfil propio (00012_profiles_self_read.sql)\n" +
  profilesReadFix.trimStart() + "\n\n-- FASE 2: CLIENTES Y RECEPCIÓN (sin seed opcional)\n" + crmSql.trimStart();

function sincronizarGenerado(archivo, contenido) {
  validarSinDatosAjenos(contenido, archivo);
  let anterior = "";
  try {
    anterior = readFileSync(archivo, "utf8");
  } catch {
    // todavía no existe
  }
  if (contenido !== anterior) cambios.push([archivo, contenido]);
}

sincronizarGenerado(join(ROOT, "supabase/FASE2.sql"), "-- ACTUALIZACIÓN FASE 2. Base con Fase 1 y fix 00012 aplicados.\n-- Sólo estructura CRM y vinculación de perfiles existentes; no borra ni carga ejemplos.\n-- Seed opcional (vaciada: no carga fichas): migrations/00021_clients_seed.sql.\n\n" + crmSql);
sincronizarGenerado(join(ROOT, "supabase/COMPATIBILIDAD-CRM.sql"), crmCompat);
sincronizarGenerado(join(ROOT, "supabase/LECTURA-CAJA.sql"), financeRead);
sincronizarGenerado(join(ROOT, "supabase/COBROS-GASTOS.sql"), readFileSync(join(ROOT, "supabase/migrations/00024_finance_movements.sql"), "utf8"));
sincronizarGenerado(join(ROOT, "supabase/PLAN-CUENTA.sql"), accountPlanSql);
sincronizarGenerado(join(ROOT, "supabase/LECTURA-RESERVAS.sql"), bookingReadSql);
sincronizarGenerado(join(ROOT, "supabase/SALDO-CLIENTE.sql"), clientFinanceSql);
sincronizarGenerado(join(ROOT, "supabase/DEUDAS-ABONOS.sql"), readFileSync(join(ROOT, "supabase/migrations/00028_debts_payments.sql"), "utf8"));
sincronizarGenerado(join(ROOT, "supabase/VUELTO-ABONOS.sql"), readFileSync(join(ROOT, "supabase/migrations/00029_cash_change.sql"), "utf8"));
sincronizarGenerado(join(ROOT, "supabase/SEGURIDAD-ACCESOS.sql"), accessHardeningSql);
sincronizarGenerado(SETUP, setupNuevo);
sincronizarGenerado(UPDATE, actualizarNuevo);

/* ------------------------------------------------------------
   4. Guardar o avisar
   ------------------------------------------------------------ */

if (cambios.length === 0) {
  console.log(`✅ Todo al día — ${cantidadSemanal} clases por semana.`);
  process.exit(0);
}

if (CHECK_ONLY) {
  console.error("❌ Hay archivos SQL desactualizados respecto al código de la web:");
  for (const [archivo] of cambios) console.error(`   · ${relative(ROOT, archivo)}`);
  console.error("\n   Corré:  node scripts/build-sql.mjs");
  process.exit(1);
}

for (const [archivo, contenido] of cambios) {
  writeFileSync(archivo, contenido);
  console.log(`✏️  Actualizado ${relative(ROOT, archivo)}`);
}

console.log(`✅ Listo — ${cantidadSemanal} clases por semana.`);
