#!/usr/bin/env node
/**
 * ============================================================
 *  Genera `supabase/INSTALAR-BASE.sql`
 * ============================================================
 *  Un solo archivo con TODA la estructura de la base, para
 *  levantar un proyecto nuevo de Supabase desde cero, sin
 *  arrastrar ni un dato de nadie.
 *
 *  Qué entra: las 82 migraciones de estructura (tablas, RLS,
 *  funciones, disparadores, permisos, límites de abuso) y el
 *  catálogo genérico de métodos de pago y categorías de gasto.
 *
 *  Qué NO entra: los archivos con datos de ejemplo o con datos
 *  reales del gimnasio, y las secciones de `00011` que traían
 *  cuentas bancarias, entrenadores, transacciones y la apertura
 *  de caja.
 *
 *  Uso:  node scripts/build-install-sql.mjs
 *        node scripts/build-install-sql.mjs --check   (falla si el
 *        archivo del repo está desactualizado)
 */

import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { validarSinDatosAjenos } from "./helpers/prohibidas.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const migrationsDir = join(root, "supabase", "migrations");
const outFile = join(root, "supabase", "INSTALAR-BASE.sql");

/**
 * Migraciones que NO van al clon, con el motivo escrito, porque dentro de
 * un año nadie se va a acordar de por qué.
 * (Las tres están además VACIADAS en origen desde el desarme de datos;
 * la exclusión queda como doble seguro.)
 */
const EXCLUIDAS = {
  "00002_seed.sql": "semilla vaciada (antes: planes y clases de ejemplo del gimnasio anterior)",
  "00003_datos_reales.sql": "semilla vaciada (antes: tarifas, disciplinas y grilla reales); sólo queda estructura",
  "00021_clients_seed.sql": "semilla vaciada (antes: socios ficticios con is_demo = true)",
};

/**
 * `00011_finance_seed.sql` se parte: la mitad de arriba es catálogo genérico
 * (métodos de pago y categorías de gasto) y sirve para cualquier gimnasio;
 * de la sección 3 en adelante quedaban las cuentas bancarias, entrenadores,
 * transacciones y la caja inicial (hoy ya están anuladas también en origen;
 * el corte sigue activo como doble seguro).
 */
const RECORTE_00011 = "--  3. CUENTAS DEL GIMNASIO";

/**
 * Bloques con datos del gimnasio anterior que viven dentro de migraciones
 * ESTRUCTURALES (que sí entran al clon). Se anulan por texto: desde una
 * línea de inicio hasta una de fin (comparadas sin espacios al borde).
 * Son OBLIGATORIOS: si el patrón no aparece, el generador FALLA en vez de
 * dejar pasar el dato en silencio.
 */
const RECORTES_DE_DATOS = {
  "00057_pase_del_dia_tarifa.sql": [
    {
      desde: "-- Tarifa inicial aprobada. Solo completa el valor si está vacío.",
      hasta: "and price_nio is null;",
      reemplazo: [
        "-- Tarifa inicial ANULADA en la plantilla: el precio del pase del día",
        "-- se configura en PERSONALIZAR-GIMNASIO.sql o en Administración → Planes.",
      ],
    },
  ],
  "00058_tarifas_gimnasio_nio.sql": [
    {
      desde: "-- Planes nuevos solo si todavía no existen por id ni por slug. Si una fila ya",
      hasta: ");",
      reemplazo: [
        "-- Catálogo de planes ANULADO en la plantilla: los cuatro planes base",
        "-- (sin precio) los crea PERSONALIZAR-GIMNASIO.sql. Las tarifas se",
        "-- cargan en Administración → Planes, no se heredan de nadie.",
      ],
    },
    {
      desde: "-- Completar tarifas iniciales solo donde todavía estén vacías. Una tarifa que",
      hasta: "and price_nio is null;",
      reemplazo: [
        "-- Relleno de tarifas ANULADO en la plantilla: ningún plan nace con",
        "-- precio; los define cada gimnasio.",
      ],
    },
  ],
  "00072_grilla_horarios.sql": [
    {
      desde: "-- 2. Semilla: exactamente el Boxeo que ya estaba en la plantilla fija.",
      hasta: "where not exists (select 1 from public.class_schedule_slots);",
      reemplazo: [
        "-- 2. Semilla ANULADA en la plantilla: la grilla del gimnasio nuevo se",
        "--    carga en el panel (Horarios y clases). No se hereda la grilla de",
        "--    nadie: class_schedule_slots nace vacía.",
      ],
    },
  ],
};

/**
 * Barrido final: ninguna cadena del gimnasio anterior puede sobrevivir en
 * el archivo armado. La lista vive en scripts/helpers/prohibidas.mjs (la
 * comparte con build-sql.mjs).
 */
const validar = (sql) => validarSinDatosAjenos(sql, "supabase/INSTALAR-BASE.sql");

function aplicarRecortes(nombre, texto) {
  const recortes = RECORTES_DE_DATOS[nombre];
  if (!recortes) return texto;
  let lineas = texto.split("\n");
  for (const { desde, hasta, reemplazo } of recortes) {
    const i = lineas.findIndex((l) => l.trim() === desde.trim());
    if (i < 0) {
      throw new Error(
        `${nombre}: no encuentro el inicio del bloque anulado «${desde.slice(0, 48)}…»`,
      );
    }
    let f = -1;
    for (let k = i; k < lineas.length; k++) {
      if (lineas[k].trim() === hasta.trim()) {
        f = k;
        break;
      }
    }
    if (f < 0) {
      throw new Error(`${nombre}: no encuentro el fin del bloque anulado «${hasta}»`);
    }
    lineas = [...lineas.slice(0, i), ...reemplazo, ...lineas.slice(f + 1)];
  }
  return lineas.join("\n");
}

function leerMigracion(nombre) {
  let texto = readFileSync(join(migrationsDir, nombre), "utf8");

  if (nombre === "00011_finance_seed.sql") {
    const lineas = texto.split("\n");
    const corte = lineas.findIndex((l) => l.startsWith(RECORTE_00011));
    if (corte < 0) {
      throw new Error("00011: no se encontró el corte de la sección 3. Revisá el archivo.");
    }
    texto = lineas.slice(0, corte - 2).join("\n");
  }

  texto = aplicarRecortes(nombre, texto);
  return texto.trim();
}

function construir() {
  const todas = readdirSync(migrationsDir)
    .filter((f) => f.endsWith(".sql"))
    .sort();

  const incluidas = todas.filter((f) => !(f in EXCLUIDAS));
  const bloques = incluidas.map((nombre) => {
    const barra = "═".repeat(59);
    return `-- ${barra}\n--  ${nombre}\n-- ${barra}\n\n${leerMigracion(nombre)}\n`;
  });

  const cabecera = `-- ============================================================
--  PLANTILLA DE BASE DE DATOS — INSTALACIÓN COMPLETA
-- ============================================================
--  La casa entera, sin los muebles.
--
--  QUÉ INCLUYE (todo lo que hace funcionar la aplicación)
--    · las 45 tablas: socios, clases, reservas, caja, finanzas,
--      progreso, rutinas, nutrición, productos, mensajes…
--    · las reglas de seguridad (RLS): cada rol ve sólo lo suyo
--    · las funciones y disparadores: cobrar, reservar, cerrar caja,
--      calcular vigencias, categorías automáticas, bitácora, límites
--      de abuso
--    · los permisos del personal y los interruptores de caja
--    · la configuración mínima genérica: métodos de pago y
--      categorías de gasto
--
--  QUÉ NO INCLUYE
--    · Ni un socio, ni una reserva, ni un cobro, ni una medición.
--    · Ni una cuenta bancaria, ni un entrenador, ni una tarifa.
--    · Cero datos personales. Cero cuentas de acceso.
--
--  CÓMO SE USA
--    1. Supabase → proyecto nuevo → SQL Editor → New query
--    2. Pegar TODO este archivo
--    3. Run. Tarda unos segundos.
--    4. Después correr PERSONALIZAR-GIMNASIO.sql
--
--  QUÉ SIGUE DESPUÉS DE ESTO (no está en ningún SQL)
--    · La biblioteca de ejercicios se descarga con el botón de
--      administración (necesita 2FA): no vive en la base ni en el
--      repositorio, viene del dataset oficial.
--    · Las disciplinas, horarios, planes y precios se cargan desde
--      el panel del gimnasio, no por SQL.
--
--  Generado por scripts/build-install-sql.mjs — no editar a mano.
--  ${incluidas.length} migraciones incluidas de ${todas.length}.
-- ============================================================


`;
  return cabecera + bloques.join("\n").replace(/\n+$/, "\n") + `
-- ============================================================
--  FIN DE LA INSTALACIÓN
-- ============================================================
--  Si el editor marca un error, no te asustes: cada bloque trae su
--  propio begin/commit y se puede volver a correr. Los errores
--  típicos son «ya existe», y son inofensivos.
`;
}

const sql = construir();
validar(sql);
const check = process.argv.includes("--check");

if (check) {
  const actual = existsSync(outFile) ? readFileSync(outFile, "utf8") : "";
  if (actual !== sql) {
    console.error("✗ supabase/INSTALAR-BASE.sql está desactualizado.");
    console.error("  Corré: node scripts/build-install-sql.mjs");
    process.exit(1);
  }
  console.log("✓ supabase/INSTALAR-BASE.sql está al día.");
} else {
  writeFileSync(outFile, sql, "utf8");
  const lineas = sql.split("\n").length;
  const kb = Math.round(Buffer.byteLength(sql) / 1024);
  console.log(`✓ supabase/INSTALAR-BASE.sql — ${lineas} líneas, ${kb} KB`);
}
