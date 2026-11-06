/**
 * ============================================================
 *  Barrido de datos ajenos en el SQL generado
 * ============================================================
 *  Cadenas que NO pueden quedar en ningún SQL generado
 *  (SETUP, ACTUALIZAR, FASE2, INSTALAR-BASE y compañía). Son
 *  datos del gimnasio del que se clonó esta plantilla: cuentas
 *  bancarias, billeteras, tarifas, nombres de personas, salas de
 *  la grilla vieja y marca.
 *
 *  El barrido corre sobre el texto ARMADO, antes de escribirlo o
 *  compararlo: si alguna cadena sobrevive a los vaciados y
 *  recortes, el generador FALLA en vez de publicar el dato.
 *
 *  Excepciones deliberadas (estructura, no datos): las claves con
 *  prefijo `strong_gym_`, la categoría CRM `strong_gym` y el slug
 *  `boxeo` de la lógica de vigencias. Por eso las cadenas de marca
 *  van con mayúsculas y espacio ('Strong Gym'), que no chocan con
 *  las claves técnicas en minúscula y guion bajo.
 */

export const PROHIBIDAS = [
  // Cuentas bancarias y billeteras del gimnasio anterior
  "123-456789",
  "987-654321",
  "555-444-333",
  "8888-1234",
  "8500-1234",
  "8500-5678",
  "TQrX9wK",
  // Nombres y correos de personas
  "Douglas",
  "María Rodríguez",
  "José Luis Pérez",
  "Cliente Strong",
  "andrea.solis",
  "kevin.ramirez",
  "cch_diego",
  // Marca
  "Strong Fitness",
  "Strong Gym",
  // Tarifas del gimnasio anterior
  "set price_nio = 40",
  "then 150",
  "then 280",
  "then 560",
  "150::numeric",
  "280::numeric",
  // Salas de la grilla vieja
  "Área de boxeo",
  "Sala de máquinas",
  "Salón de clases",
  // Semilla de finanzas
  "SEED-GASTO",
  "Apertura inicial",
];

/** Falla si el SQL armado conserva alguna cadena del gimnasio anterior. */
export function validarSinDatosAjenos(sql, archivo) {
  const encontradas = PROHIBIDAS.filter((cadena) => sql.includes(cadena));
  if (encontradas.length > 0) {
    throw new Error(
      `${archivo} dejaría datos del gimnasio anterior: ${encontradas.join(" · ")}`,
    );
  }
}
