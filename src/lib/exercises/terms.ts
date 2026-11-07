/**
 * Cómo se llaman en español las cosas de la biblioteca de ejercicios (EX-01).
 *
 * Por qué existe: el dataset viene con identificadores técnicos en inglés
 * (`latissimus_dorsi`, `smith_machine`, `upper_legs`). Un socio no lee eso.
 * Acá vive **un solo** mapa de etiquetas, y `tests/exercises-terms.test.mjs`
 * falla si la base trae un valor que no esté acá: así nunca se cuela un
 * `smith_machine` crudo en la pantalla.
 */

export const BODY_PART_LABELS: Record<string, string> = {
  chest: "Pecho",
  back: "Espalda",
  shoulders: "Hombros",
  upper_arms: "Brazos",
  lower_arms: "Antebrazo",
  core: "Abdomen y core",
  upper_legs: "Piernas",
  lower_legs: "Pantorrilla",
  full_body: "Cuerpo completo",
};

/** El orden en que se muestran las zonas: de arriba hacia abajo del cuerpo. */
export const BODY_PART_ORDER = [
  "chest",
  "back",
  "shoulders",
  "upper_arms",
  "lower_arms",
  "core",
  "upper_legs",
  "lower_legs",
  "full_body",
];

export const MUSCLE_LABELS: Record<string, string> = {
  pectoralis_major: "Pectoral",
  latissimus_dorsi: "Dorsal ancho",
  trapezius: "Trapecio",
  rhomboids: "Romboides",
  erector_spinae: "Lumbares",
  serratus_anterior: "Serrato",
  anterior_deltoid: "Deltoides frontal",
  lateral_deltoid: "Deltoides lateral",
  posterior_deltoid: "Deltoides posterior",
  infraspinatus_teres_minor: "Rotadores externos",
  supraspinatus: "Supraespinoso",
  biceps_brachii: "Bíceps",
  brachialis: "Braquial",
  triceps_brachii: "Tríceps",
  brachioradialis: "Braquiorradial",
  forearms: "Antebrazo",
  forearm_extensors: "Extensores del antebrazo",
  forearm_flexors: "Flexores del antebrazo",
  rectus_abdominis: "Recto abdominal",
  obliques: "Oblicuos",
  transverse_abdominis: "Transverso",
  quadratus_lumborum: "Cuadrado lumbar",
  gluteus_maximus: "Glúteo mayor",
  gluteus_medius: "Glúteo medio",
  hip_flexors: "Flexores de cadera",
  adductors: "Aductores",
  abductors: "Abductores",
  quadriceps: "Cuádriceps",
  hamstrings: "Isquiotibiales",
  gastrocnemius: "Gemelo",
  soleus: "Sóleo",
  tibialis_anterior: "Tibial anterior",
};

export const EQUIPMENT_LABELS: Record<string, string> = {
  ab_crunch_machine: "Máquina de abdominales",
  ab_wheel: "Rueda abdominal",
  air_bike: "Bicicleta de aire",
  assisted_pullup_machine: "Máquina de dominadas asistidas",
  back_extension_machine: "Máquina de extensión lumbar",
  barbell: "Barra",
  battle_rope: "Cuerda de batalla",
  bicep_curl_machine: "Máquina de bíceps",
  bicycle: "Bicicleta",
  bosu_ball: "Bosu",
  cable: "Polea",
  chest_fly_machine: "Pec deck / aperturas",
  chest_press_machine: "Máquina de press de pecho",
  climbing_rope: "Cuerda de trepar",
  dip_machine: "Máquina de fondos",
  dip_station: "Paralelas",
  donkey_calf_raise_machine: "Máquina de gemelo (burro)",
  dumbbell: "Mancuerna",
  elliptical: "Elíptica",
  ez_bar: "Barra Z",
  flat_bench: "Banco plano",
  glute_ham_developer: "Glúteo-hamstring",
  hack_squat: "Hack squat",
  hip_abduction_machine: "Máquina de abductores",
  hip_adduction_machine: "Máquina de aductores",
  hip_thrust_machine: "Máquina de hip thrust",
  jump_rope: "Cuerda de saltar",
  kettlebell: "Pesa rusa",
  lat_pulldown_machine: "Jalón al pecho",
  leg_curl: "Curl femoral",
  leg_extension: "Extensión de cuádriceps",
  leg_press: "Prensa de piernas",
  loop_band: "Banda circular",
  machine: "Máquina de sala",
  medicine_ball: "Balón medicinal",
  pec_deck: "Pec deck",
  plate_loaded_dip_machine: "Fondos con discos",
  plate_loaded_lateral_raise_machine: "Elevación lateral con discos",
  plates: "Discos",
  plyo_box: "Cajón pliométrico",
  preacher_curl_machine: "Máquina de curl predicador",
  pull_up_bar: "Barra de dominadas",
  resistance_band: "Banda elástica",
  reverse_fly_machine: "Máquina de deltoides posterior",
  rings: "Anillas",
  rower: "Remo ergómetro",
  sandbag: "Saco de arena",
  seated_calf_raise_machine: "Máquina de gemelo sentado",
  seated_row_machine: "Remo sentado",
  shoulder_press_machine: "Máquina de press de hombro",
  shrug_machine: "Máquina de encogimientos",
  ski_erg: "Esquí ergómetro",
  slam_ball: "Balón de golpe",
  sled: "Trineo",
  smith_machine: "Máquina Smith",
  stability_ball: "Balón suizo",
  stair_climber: "Escaladora",
  standing_calf_raise_machine: "Máquina de gemelo de pie",
  stationary_bike: "Bicicleta fija",
  suspension_trainer: "Entrenador en suspensión",
  trap_bar: "Barra hexagonal",
  treadmill: "Caminadora",
  tricep_extension_machine: "Máquina de tríceps",
  wall_ball: "Balón para pared",
  wrist_roller: "Rodillo de muñeca",
};

/**
 * Grupos de equipo para filtrar sin listar 64 nombres.
 * `null` (sin equipo) es peso corporal: el dataset no lo dice con una palabra.
 */
export const EQUIPMENT_GROUPS: Array<{
  key: string;
  label: string;
  hint: string;
  slugs: string[];
}> = [
  {
    key: "maquinas",
    label: "Máquinas",
    hint: "Prensa, hack squat, jalón, pec deck, Smith y el resto de la sala",
    slugs: [
      "machine",
      "leg_press",
      "hack_squat",
      "smith_machine",
      "lat_pulldown_machine",
      "seated_row_machine",
      "chest_press_machine",
      "shoulder_press_machine",
      "pec_deck",
      "chest_fly_machine",
      "reverse_fly_machine",
      "leg_extension",
      "leg_curl",
      "glute_ham_developer",
      "hip_thrust_machine",
      "hip_abduction_machine",
      "hip_adduction_machine",
      "bicep_curl_machine",
      "tricep_extension_machine",
      "preacher_curl_machine",
      "ab_crunch_machine",
      "back_extension_machine",
      "assisted_pullup_machine",
      "dip_machine",
      "plate_loaded_dip_machine",
      "shrug_machine",
      "seated_calf_raise_machine",
      "standing_calf_raise_machine",
      "donkey_calf_raise_machine",
      "plate_loaded_lateral_raise_machine",
    ],
  },
  {
    key: "poleas",
    label: "Poleas",
    hint: "Cable, polea alta y baja, cruces",
    slugs: ["cable"],
  },
  {
    key: "peso_libre",
    label: "Peso libre",
    hint: "Barra, mancuernas, pesa rusa, banco",
    slugs: ["barbell", "dumbbell", "kettlebell", "ez_bar", "trap_bar", "plates", "flat_bench", "sandbag"],
  },
  {
    key: "accesorios",
    label: "Accesorios",
    hint: "Bandas, balones, cajón, rueda abdominal",
    slugs: [
      "resistance_band",
      "loop_band",
      "stability_ball",
      "bosu_ball",
      "medicine_ball",
      "slam_ball",
      "wall_ball",
      "plyo_box",
      "ab_wheel",
      "pull_up_bar",
      "dip_station",
      "rings",
      "suspension_trainer",
      "jump_rope",
      "battle_rope",
      "climbing_rope",
      "sled",
      "wrist_roller",
    ],
  },
  {
    key: "cardio",
    label: "Cardio",
    hint: "Caminadora, bicicleta, remo, elíptica",
    slugs: [
      "treadmill",
      "stationary_bike",
      "air_bike",
      "elliptical",
      "rower",
      "stair_climber",
      "ski_erg",
      "bicycle",
    ],
  },
  {
    key: "cuerpo",
    label: "Peso corporal",
    hint: "Sin equipo: solo tu cuerpo",
    slugs: [],
  },
];

export const CATEGORY_LABELS: Record<string, string> = {
  strength: "Fuerza",
  stretching: "Estiramiento",
  cardio: "Cardio",
  olympic: "Halterofilia",
  plyometrics: "Pliometría",
};

export const DIFFICULTY_LABELS: Record<string, string> = {
  beginner: "Principiante",
  intermediate: "Intermedio",
  advanced: "Avanzado",
};

export const GOAL_LABELS: Record<string, string> = {
  hypertrophy: "Hipertrofia",
  strength: "Fuerza",
  endurance: "Resistencia",
  mobility: "Movilidad",
  power: "Potencia",
  rehabilitation: "Rehabilitación",
  core: "Core",
};

export const FORCE_LABELS: Record<string, string> = {
  push: "Empuje",
  pull: "Tirón",
  static: "Sostén",
  dynamic: "Dinámico",
};

export const MECHANIC_LABELS: Record<string, string> = {
  compound: "Compuesto",
  isolation: "Aislado",
};

/** Etiqueta con respaldo legible: si falta el mapa, se muestra el slug limpio. */
const label = (map: Record<string, string>, key: string | null | undefined) =>
  key ? (map[key] ?? key.replaceAll("_", " ")) : "";

export const bodyPartLabel = (key: string | null | undefined) => label(BODY_PART_LABELS, key);
export const muscleLabel = (key: string | null | undefined) => label(MUSCLE_LABELS, key);
export const equipmentLabel = (key: string | null | undefined) =>
  key ? label(EQUIPMENT_LABELS, key) : "Peso corporal";
export const categoryLabel = (key: string | null | undefined) => label(CATEGORY_LABELS, key);
export const difficultyLabel = (key: string | null | undefined) => label(DIFFICULTY_LABELS, key);
export const goalLabel = (key: string | null | undefined) => label(GOAL_LABELS, key);
export const forceLabel = (key: string | null | undefined) => label(FORCE_LABELS, key);
export const mechanicLabel = (key: string | null | undefined) => label(MECHANIC_LABELS, key);

/** Slugs de equipo de un grupo, para mandar al filtro del servidor. */
export function equipmentGroupSlugs(key: string): string[] | null {
  const group = EQUIPMENT_GROUPS.find((item) => item.key === key);
  if (!group) return null;
  return group.slugs;
}

/** A qué grupo pertenece un equipo (para agrupar resultados). */
export function equipmentGroupOf(slug: string | null): string {
  if (!slug) return "cuerpo";
  return EQUIPMENT_GROUPS.find((group) => group.slugs.includes(slug))?.key ?? "otros";
}

/**
 * Color de cada familia de equipo (EX-01).
 *
 * La biblioteca tiene dos orígenes con dibujos y fotos muy distintas. Para que
 * todo se lea como una sola pantalla —y no como dos catálogos pegados— cada
 * familia lleva un color de la misma paleta oscura del aplicativo: el rojo de la
 * marca para el peso libre, azul acero para las máquinas, ámbar para las poleas
 * y verde para los aparatos de peso corporal. Es un detalle de 3 px: tiñe la
 * tarjeta, no compite con la foto.
 */
export const EQUIPMENT_TONES: Record<string, string> = {
  peso_libre: "#c8f73b",
  maquinas: "#6f8fb8",
  poleas: "#d9a441",
  cuerpo: "#6fbf9f",
  cardio: "#6fbf9f",
};

/** Color del equipo; gris de línea para lo que no cae en ninguna familia. */
export function equipmentTone(slug: string | null): string {
  return EQUIPMENT_TONES[equipmentGroupOf(slug)] ?? "#2b2b31";
}

/**
 * Atribución obligatoria del dataset. Vive en un solo lugar y la prueba
 * `tests/exercises-attribution.test.mjs` comprueba que la pantalla la muestre.
 */
export const EXERCISE_ATTRIBUTION = {
  text: "Exercise data by RepDB (repdb.co)",
  href: "https://repdb.co",
  /** Segundo catálogo: dominio público (Unlicense), se acredita igual. */
  secondText: "Fotos y datos adicionales de free-exercise-db (dominio público)",
  secondHref: "https://github.com/yuhonas/free-exercise-db",
} as const;
