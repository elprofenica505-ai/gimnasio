import test from "node:test";
import assert from "node:assert/strict";
import {
  normalizar,
  detectarTelefono,
  detectarNombre,
  responderArm,
} from "../src/lib/arm/brain.ts";

const CONOCIMIENTO = {
  gimnasio: "Power Box Gym",
  planes: ["Mensual — C$1,200 al mes", "Pase del día — C$200 por clase"],
  clases: ["Boxeo", "Zumba", "Pesas"],
  productos: ["Proteína EJEMPLO (C$1,500)", "Shaker EJEMPLO (C$250)"],
  horarioResumen: "Lunes a viernes: 06:00 — 20:00 · Sábado: 08:00 — 13:00 · Domingo: Cerrado",
  abiertoAhora: true,
  whatsappUrl: "https://wa.me/50588276908",
  urlPlanes: "/es#planes",
  urlHorarios: "/es/horarios",
  urlTienda: "/es#tienda",
};

test("normalizar quita tildes, signos y mayúsculas", () => {
  assert.equal(normalizar("¿TéLEFono? ¡Sí!"), "telefono si");
});

test("detecta teléfono nicaragüense con y sin separadores", () => {
  assert.equal(detectarTelefono("mi número es 8888 7766"), "88887766");
  assert.equal(detectarTelefono("escribinos al 86885663"), "86885663");
  assert.equal(detectarTelefono("+505 7777-8899"), "77778899");
  assert.equal(detectarTelefono("cuesta C$600 y 1242 de referencia"), null);
});

test("detecta nombre en frases y palabra suelta, pero no palabras vacías", () => {
  assert.equal(detectarNombre("hola, me llamo Ana"), "Ana");
  assert.equal(detectarNombre("soy Carlos Pérez"), "Carlos Pérez");
  assert.equal(detectarNombre("Carlos"), "Carlos");
  assert.equal(detectarNombre("soy de Managua"), null);
});

test("saludo: se presenta y ofrece temas", () => {
  const s = responderArm("hola", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /asistente de Power Box Gym/);
  assert.ok(s.sugerencias.length >= 3);
});

test("precios: responde con los planes reales de la base", () => {
  const s = responderArm("¿cuánto cuesta la mensualidad?", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /Mensual — C\$1,200/);
  assert.ok(s.acciones.some((a) => a.url === "/es#planes"));
});

test("horario: dice el horario y si está abierto ahora", () => {
  const s = responderArm("a qué hora abren?", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /Abrimos Lunes a viernes/);
  assert.match(s.reply, /ABIERTO/);
  assert.ok(s.acciones.some((a) => a.url === "/es/horarios"));
});

test("clases: lista lo que da el gimnasio", () => {
  const s = responderArm("dan clases de boxeo?", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /Boxeo/);
  assert.match(s.reply, /Zumba/);
});

test("tienda: muestra productos con precio y manda a la tienda", () => {
  const s = responderArm("venden proteína?", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /Proteína EJEMPLO \(C\$1,500\)/);
  assert.ok(s.acciones.some((a) => a.url === "/es#tienda"));
});

test("ubicación: Managua sin dirección exacta (va por WhatsApp)", () => {
  const s = responderArm("dónde están ubicados?", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /Managua/);
  assert.doesNotMatch(s.reply, /calle/i);
  assert.ok(s.acciones.some((a) => a.url.startsWith("https://wa.me/")));
});

test("pago: métodos de Nicaragua, jamás SINPE", () => {
  const s = responderArm("cómo puedo pagar?", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /BAC/);
  assert.match(s.reply, /Tigo Money/);
  assert.doesNotMatch(s.reply, /sinpe/i);
});

test("humano: entrega el WhatsApp", () => {
  const s = responderArm("quiero hablar con una persona", CONOCIMIENTO, {}, "es");
  assert.ok(s.acciones.some((a) => a.url === "https://wa.me/50588276908"));
});

test("captura completa: nombre + teléfono → confirmación y captura", () => {
  const s = responderArm("soy Ana, mi número es 8888 7766", CONOCIMIENTO, {}, "es");
  assert.deepEqual(s.captura, { nombre: "Ana", telefono: "88887766" });
  assert.match(s.reply, /Listo, Ana/);
  assert.match(s.reply, /88887766/);
});

test("captura a medias: teléfono sin nombre pide el nombre", () => {
  const s = responderArm("anota 88887766", CONOCIMIENTO, {}, "es");
  assert.deepEqual(s.captura, { telefono: "88887766" });
  assert.match(s.reply, /nombre/i);
});

test("captura a medias con memoria: el nombre venía de un mensaje anterior", () => {
  const s = responderArm("es 8688 56 63", CONOCIMIENTO, { nombre: "Carlos" }, "es");
  assert.deepEqual(s.captura, { telefono: "86885663" });
  assert.match(s.reply, /Listo, Carlos/);
});

test("nombre suelto después de que el bot pide datos", () => {
  const s = responderArm("Marta", CONOCIMIENTO, {}, "es");
  assert.deepEqual(s.captura, { nombre: "Marta" });
  assert.match(s.reply, /número/i);
});

test("no sabe: honesto, con salida humana y captura de contacto", () => {
  const s = responderArm("tienen sauna?", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /No la tengo clara/);
  assert.match(s.reply, /Ana 8888 7766/);
  assert.ok(s.acciones.some((a) => a.url.startsWith("https://wa.me/")));
});

test("inglés: responde en inglés con sus chips", () => {
  const s = responderArm("prices?", CONOCIMIENTO, {}, "en");
  assert.match(s.reply, /Mensual — C\$1,200/);
  assert.equal(s.sugerencias[0], "Schedule");
});

test("los chips («Precios», «Horarios») rutean a intenciones, no se toman por nombre", () => {
  const precios = responderArm("Precios", CONOCIMIENTO, {}, "es");
  assert.match(precios.reply, /C\$1,200/);
  assert.equal(precios.captura, undefined);
  const horarios = responderArm("Horarios", CONOCIMIENTO, {}, "es");
  assert.match(horarios.reply, /Abrimos/);
  assert.equal(horarios.captura, undefined);
});

test("«tienen sauna» (dos palabras) cae al fallback honesto, no a captura", () => {
  const s = responderArm("tienen sauna?", CONOCIMIENTO, {}, "es");
  assert.match(s.reply, /No la tengo clara/);
  assert.equal(s.captura, undefined);
});

test("con base vacía no inventa: sale honesto", () => {
  const vacio = { ...CONOCIMIENTO, planes: [], clases: [], productos: [], horarioResumen: "", abiertoAhora: null };
  const precios = responderArm("precios", vacio, {}, "es");
  assert.match(precios.reply, /actualizando|WhatsApp/);
  const horario = responderArm("horarios", vacio, {}, "es");
  assert.match(horario.reply, /todavía no está confirmado/);
});
