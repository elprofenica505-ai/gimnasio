/**
 * ============================================================
 *  ARM — el cerebro del asistente (paso 2)
 * ============================================================
 *  Puro y sin I/O: recibe el texto de la persona, el conocimiento
 *  cargado de la base (planes, clases, tienda, horario) y lo que
 *  ya sabemos del contacto. Devuelve respuesta + chips sugeridos
 *  + acciones clicables + lo que haya capturado (nombre/teléfono).
 *
 *  Nivel 2 del ARM: FAQ respondida leyendo la base. No inventa:
 *  si no sabe, lo dice y ofrece pasar con una persona (nivel
 *  conversacional con IA queda reservado para después de la firma).
 */

export interface ArmAccion {
  etiqueta: string;
  url: string;
}

export interface ArmKnowledge {
  /** Nombre comercial del gimnasio. */
  gimnasio: string;
  /** Planes ya formateados: «Mensual — C$1,200 al mes». */
  planes: string[];
  /** Clases activas, por nombre. */
  clases: string[];
  /** Productos de la tienda ya formateados: «Proteína (C$1,500)». */
  productos: string[];
  /** Resumen del horario de atención: «Lunes a viernes: 06:00 — 20:00 · …». */
  horarioResumen: string;
  /** ¿Está abierto en este momento (hora de Managua)? null = no sabemos. */
  abiertoAhora: boolean | null;
  /** Link de WhatsApp con mensaje prellenado. */
  whatsappUrl: string;
  urlPlanes: string;
  urlHorarios: string;
  urlTienda: string;
}

export interface ArmEstado {
  nombre?: string | null;
  telefono?: string | null;
}

export interface ArmCaptura {
  nombre?: string;
  telefono?: string;
}

export interface ArmSalida {
  reply: string;
  /** Chips que envían esa pregunta como mensaje nuevo. */
  sugerencias: string[];
  /** Botones con link (WhatsApp, precios, horarios…). */
  acciones: ArmAccion[];
  captura?: ArmCaptura;
}

export type ArmLocale = "es" | "en";

/** Minúsculas, sin tildes y sin signos: «Téfono?» → «telefono». */
export function normalizar(texto: string): string {
  return texto
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9ñ\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Teléfono nicaragüense: 8 dígitos que arrancan en 5, 7 u 8, con o sin
 *  separadores (88887766, 8888-7766, 8888 77 66, +505…). */
export function detectarTelefono(texto: string): string | null {
  const m = texto.match(/\b(?:\+?505[\s-]?)?([578]\d{3}(?:[\s-]?\d{2}){2})\b/);
  return m ? m[1].replace(/\D/g, "") : null;
}

const NO_NOMBRES = new Set([
  "de", "del", "la", "el", "los", "las", "un", "una", "unos", "unas",
  "muy", "mas", "que", "por", "para", "con", "sin", "fan", "equipo",
  // Palabras de pregunta/uso común: solas NO son un nombre.
  "tienen", "tiene", "cuanto", "cuesta", "donde", "como", "cuando", "hay",
  "puedo", "pueden", "dan", "hacen", "quiero", "necesito", "busco", "precio",
  "precios", "horario", "horarios", "clase", "clases", "plan", "planes", "hola",
]);

/** «me llamo Ana», «soy Carlos Pérez», o una palabra suelta tipo nombre.
 *  Trabaja sobre el texto ORIGINAL (con tildes y mayúsculas) para no
 *  entregar «Jose» cuando la persona escribe «José». */
export function detectarNombre(texto: string): string | null {
  const patron = texto.match(
    /(?:me llamo|mi nombre es|soy)\s+([A-Za-zÁÉÍÓÚÜÑáéíóúüñ]{2,20}(?:\s+[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]{2,20}){0,2})/i,
  );
  if (patron) {
    const palabras = patron[1].split(/\s+/);
    // «soy de Managua» / «soy del barrio»: descripción, no nombre.
    if (NO_NOMBRES.has(normalizar(palabras[0]))) return null;
    const validas = palabras.filter((p) => !NO_NOMBRES.has(normalizar(p)));
    if (validas.length > 0) return capitalizar(validas.join(" "));
  }
  // UNA palabra suelta, sin intención reconocible: probablemente es el nombre
  // que el bot acaba de pedir. «Precios» no llega acá (es intención) y
  // «tienen sauna» tampoco (dos palabras).
  const suelto = texto.trim().match(/^([A-Za-zÁÉÍÓÚÜÑáéíóúüñ]{2,20})$/);
  if (suelto && !NO_NOMBRES.has(normalizar(suelto[1]))) {
    return capitalizar(suelto[1]);
  }
  return null;
}

function capitalizar(s: string): string {
  return s
    .toLowerCase()
    .replace(/(^|\s)([a-záéíóúüñ])/g, (_, sep: string, letra: string) => sep + letra.toUpperCase());
}

/** Textos por idioma. El inglés es espejo corto; el español es la voz real. */
const T = {
  es: {
    listo: (n: string, t: string) =>
      `¡Listo, ${n}! 🤜🤛 Ya anoté tu número ${t}. Una persona del equipo te escribe hoy mismo.`,
    pideNombre: `¡Perfecto! ¿Y tu nombre, para anotarte bien?`,
    pideTelefono: (n: string) =>
      `Gracias, ${n}. ¿A qué número te escribimos? (ej: 8888 7766)`,
    gracias: `¡Con gusto! Aquí estoy cuando necesites algo más. 💪`,
    adios: `¡Hasta pronto! Te esperamos en el gimnasio. 🥊`,
    humano: (k: ArmKnowledge) =>
      `Claro 👍 La vía rápida es WhatsApp: suele responderse en horario de atención.`,
    horario: (k: ArmKnowledge) => {
      if (!k.horarioResumen) return `El horario todavía no está confirmado; pregúntalo por WhatsApp y te respondemos al toque.`;
      const ahora =
        k.abiertoAhora === true
          ? ` Ahora mismo estamos ABIERTO 💪`
          : k.abiertoAhora === false
            ? ` Ahora mismo está cerrado, pero dejá tu pregunta y te respondemos al abrir.`
            : ``;
      return `Abrimos ${k.horarioResumen}.${ahora}`;
    },
    precios: (k: ArmKnowledge) => {
      if (k.planes.length === 0)
        return `Los precios los estamos actualizando. Decime qué plan te interesa y te confirmo por WhatsApp.`;
      return `Estas son nuestras opciones:\n${k.planes.map((p) => `• ${p}`).join("\n")}\n¿Cuál te llama la atención?`;
    },
    clases: (k: ArmKnowledge) => {
      if (k.clases.length === 0)
        return `Las clases las estamos actualizando. Mirá el horario completo o pregúntame por WhatsApp.`;
      return `Esto es lo que damos: ${k.clases.join(", ")}. El horario de cada una lo ves en la sección Horarios.`;
    },
    tienda: (k: ArmKnowledge) => {
      if (k.productos.length === 0)
        return `La tienda de suplementos está en esta misma página; si buscás algo en especial, preguntame por WhatsApp.`;
      return `En la tienda tenemos, por ejemplo: ${k.productos.slice(0, 3).join(", ")}. Se compra directo por la web y lo pasás a buscar al gimnasio.`;
    },
    ubicacion: `Estamos en Managua, Nicaragua 📍. La dirección exacta te la pasamos por WhatsApp para que llegues fácil.`,
    pago: `Podés pagar con transferencia (BAC o LAFISE), Tigo Money, Claro Pay o efectivo en recepción. Al confirmar tu pago, activamos tu membresía al toque. ✅`,
    registro: `Es fácil: 1) elegí tu plan en Precios, 2) tocá «Comprar» y llená tus datos, 3) pagá por transferencia, Tigo o Claro Money, y 4) te activamos la membresía en minutos.`,
    saludo: (k: ArmKnowledge) =>
      `¡Hola! 👋 Soy el asistente de ${k.gimnasio}. Preguntame por precios, horarios, clases o la tienda.`,
    fallback: `Esa me la pusiste difícil 😅 No la tengo clara. Puedo ayudarte con precios, horarios, clases o productos; o dejá tu nombre y número (ej: Ana 8888 7766) y te escribe una persona del equipo hoy mismo.`,
    etiquetas: {
      whatsapp: "Escribir por WhatsApp",
      planes: "Ver planes",
      horarios: "Ver horarios",
      tienda: "Ir a la tienda",
    },
    sugerencias: {
      precios: "Precios",
      horarios: "Horarios",
      clases: "Clases",
      humano: "Hablar con una persona",
      tienda: "Tienda",
    },
  },
  en: {
    listo: (n: string, t: string) =>
      `Done, ${n}! 🤜🤛 I saved your number ${t}. A team member will text you today.`,
    pideNombre: `Great! And your name, so we can register you properly?`,
    pideTelefono: (n: string) =>
      `Thanks, ${n}. What number should we text? (e.g.: 8888 7766)`,
    gracias: `You're welcome! I'm here whenever you need me. 💪`,
    adios: `See you soon at the gym! 🥊`,
    humano: (k: ArmKnowledge) =>
      `Sure 👍 Fastest way is WhatsApp — we usually reply during opening hours.`,
    horario: (k: ArmKnowledge) => {
      if (!k.horarioResumen) return `Our schedule isn't confirmed yet; ask us on WhatsApp for a quick answer.`;
      const ahora =
        k.abiertoAhora === true ? ` We are OPEN right now 💪` : k.abiertoAhora === false ? ` We are closed right now, but leave your question and we'll answer when we open.` : ``;
      return `We are open ${k.horarioResumen}.${ahora}`;
    },
    precios: (k: ArmKnowledge) => {
      if (k.planes.length === 0) return `We're updating our prices. Tell me which plan you're interested in and I'll confirm on WhatsApp.`;
      return `Here are our options:\n${k.planes.map((p) => `• ${p}`).join("\n")}\nWhich one do you like?`;
    },
    clases: (k: ArmKnowledge) => {
      if (k.clases.length === 0) return `We're updating the class list. Check the full schedule or ask me on WhatsApp.`;
      return `Here's what we offer: ${k.clases.join(", ")}. You can see each class time in the Schedule section.`;
    },
    tienda: (k: ArmKnowledge) => {
      if (k.productos.length === 0) return `Our supplement store is on this very page; for anything specific, ask me on WhatsApp.`;
      return `At the store we have, for example: ${k.productos.slice(0, 3).join(", ")}. You buy right on the web and pick it up at the gym.`;
    },
    ubicacion: `We are in Managua, Nicaragua 📍. We share the exact address on WhatsApp so you can find us easily.`,
    pago: `You can pay by bank transfer (BAC or LAFISE), Tigo Money, Claro Pay or cash at the front desk. Once your payment is confirmed, we activate your membership right away. ✅`,
    registro: `It's easy: 1) pick your plan under Prices, 2) tap "Buy" and fill in your details, 3) pay by transfer, Tigo or Claro Money, and 4) we activate your membership in minutes.`,
    saludo: (k: ArmKnowledge) =>
      `Hi! 👋 I'm ${k.gimnasio}'s assistant. Ask me about prices, schedule, classes or the store.`,
    fallback: `That one's tricky 😅 I don't have it clear. I can help with prices, schedule, classes or products; or leave your name and number (e.g.: Ana 8888 7766) and a team member will text you today.`,
    etiquetas: {
      whatsapp: "Chat on WhatsApp",
      planes: "See plans",
      horarios: "See schedule",
      tienda: "Go to store",
    },
    sugerencias: {
      precios: "Prices",
      horarios: "Schedule",
      clases: "Classes",
      humano: "Talk to a person",
      tienda: "Store",
    },
  },
} as const;

export function responderArm(
  textoOriginal: string,
  k: ArmKnowledge,
  estado: ArmEstado,
  locale: ArmLocale = "es",
): ArmSalida {
  const t = T[locale] ?? T.es;
  const norm = normalizar(textoOriginal);
  const accionWhatsApp = { etiqueta: t.etiquetas.whatsapp, url: k.whatsappUrl };
  const sug = t.sugerencias;

  const tiene = (...palabras: string[]) =>
    palabras.some((p) => new RegExp(`(^| )${p}( |$)`).test(norm) || norm.includes(p));

  // ── Cortesías primero (para que «Gracias» no se tome por nombre) ──
  if (tiene("gracias", "thank")) {
    return { reply: t.gracias, sugerencias: [sug.precios, sug.horarios, sug.humano], acciones: [] };
  }
  if (tiene("adios", "chao", "hasta luego", "nos vemos", "bye")) {
    return { reply: t.adios, sugerencias: [], acciones: [] };
  }
  if (/^(hola|buenas|buenos dias|buenas tardes|buenas noches|hey|que tal|hello|hi)\b/.test(norm)) {
    return {
      reply: t.saludo(k),
      sugerencias: [sug.precios, sug.horarios, sug.clases, sug.humano],
      acciones: [
        { etiqueta: t.etiquetas.planes, url: k.urlPlanes },
        { etiqueta: t.etiquetas.horarios, url: k.urlHorarios },
      ],
    };
  }

  // ── Captura EXPLÍCITA de contacto (me llamo… / un teléfono presente) ──
  const telefono = detectarTelefono(textoOriginal);
  const normSuelto = norm.match(/^([a-zñ]{2,20})$/);
  const nombreExplicito =
    /(^| )(me llamo|mi nombre es|soy)( |$)/.test(norm) || (telefono && !normSuelto);
  const nombre = nombreExplicito ? detectarNombre(textoOriginal) : null;
  if (telefono || nombre) {
    const captura: ArmCaptura = {};
    if (nombre) captura.nombre = nombre;
    if (telefono) captura.telefono = telefono;
    const nombreFinal = captura.nombre ?? estado.nombre ?? null;
    const telFinal = captura.telefono ?? estado.telefono ?? null;
    if (nombreFinal && telFinal) {
      return {
        reply: t.listo(nombreFinal, telFinal),
        sugerencias: [sug.precios, sug.horarios],
        acciones: [accionWhatsApp],
        captura,
      };
    }
    if (telFinal && !nombreFinal) {
      return { reply: t.pideNombre, sugerencias: [], acciones: [], captura };
    }
    // Tiene nombre (o es un nombre suelto) y falta el teléfono.
    return {
      reply: t.pideTelefono(nombreFinal ?? ""),
      sugerencias: [],
      acciones: [],
      captura,
    };
  }

  // ── Intenciones FAQ (nivel 2: responde leyendo la base) ──
  if (tiene("humano", "persona real", "hablar con alguien", "hablar con una persona", "whatsapp", "wasap", "asesor", "encargado", "administrador", "dueno", "llamar", "call", "talk", "real person")) {
    return { reply: t.humano(k), sugerencias: [sug.precios, sug.horarios], acciones: [accionWhatsApp] };
  }
  if (tiene("horario", "horarios", "abren", "abre", "cierran", "cierra", "atienden", "atencion", "abierto", "a que hora", "schedule", "open hours")) {
    return { reply: t.horario(k), sugerencias: [sug.precios, sug.clases], acciones: [{ etiqueta: t.etiquetas.horarios, url: k.urlHorarios }] };
  }
  if (tiene("precio", "precios", "cuanto", "cuesta", "cuestan", "cuota", "mensualidad", "tarifa", "tarifas", "plan", "planes", "costo", "matricula", "inscripcion", "vale", "price", "prices")) {
    return { reply: t.precios(k), sugerencias: [sug.horarios, sug.humano], acciones: [{ etiqueta: t.etiquetas.planes, url: k.urlPlanes }, accionWhatsApp] };
  }
  if (tiene("tienda", "producto", "productos", "suplemento", "suplementos", "proteina", "creatina", "shaker", "guantes", "agua", "venden", "venta", "comprar", "compra", "store", "buy")) {
    return { reply: t.tienda(k), sugerencias: [sug.precios, sug.horarios], acciones: [{ etiqueta: t.etiquetas.tienda, url: k.urlTienda }] };
  }
  if (tiene("clase", "clases", "zumba", "boxeo", "box", "pesas", "musculacion", "disciplinas", "funcional", "entrenamiento", "class", "classes")) {
    return { reply: t.clases(k), sugerencias: [sug.horarios, sug.precios], acciones: [{ etiqueta: t.etiquetas.horarios, url: k.urlHorarios }] };
  }
  if (tiene("donde", "ubicacion", "ubicado", "direccion", "mapa", "quedan", "queda", "encontrar", "where", "location", "address")) {
    return { reply: t.ubicacion, sugerencias: [sug.horarios, sug.humano], acciones: [accionWhatsApp] };
  }
  if (tiene("como pago", "pagar", "pago", "metodo de pago", "transferencia", "bac", "lafise", "tigo", "claro", "efectivo", "tarjeta", "pay")) {
    return { reply: t.pago, sugerencias: [sug.precios], acciones: [{ etiqueta: t.etiquetas.planes, url: k.urlPlanes }, accionWhatsApp] };
  }
  if (tiene("inscribirme", "inscribir", "registrarme", "registro", "crear cuenta", "empezar", "apuntarme", "unirme", "sign up", "join")) {
    return { reply: t.registro, sugerencias: [sug.precios, sug.humano], acciones: [{ etiqueta: t.etiquetas.planes, url: k.urlPlanes }] };
  }

  // ── Una palabra suelta tras las intenciones: es el nombre que el bot pidió ──
  const palabraSuelta = normSuelto?.[1];
  if (palabraSuelta && !NO_NOMBRES.has(palabraSuelta) && !estado.nombre) {
    const captura: ArmCaptura = { nombre: capitalizar(palabraSuelta) };
    return {
      reply: t.pideTelefono(captura.nombre ?? ""),
      sugerencias: [],
      acciones: [],
      captura,
    };
  }

  // ── No sé: honesto y con salida humana (el mensaje ya quedó en la bandeja) ──
  return {
    reply: t.fallback,
    sugerencias: [sug.precios, sug.horarios, sug.humano],
    acciones: [accionWhatsApp],
  };
}
