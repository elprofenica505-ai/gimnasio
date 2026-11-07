import { test } from "node:test";
import assert from "node:assert/strict";
import { activeModuleId, panelAccess, visibleModules } from "../src/lib/admin/modules.ts";

const ids = (mods) => mods.map((m) => m.id);
const childIds = (mods, id) => mods.find((m) => m.id === id)?.children.map((c) => c.id) ?? [];

test("administrador ve todos los módulos y todas sus secciones", () => {
  const mods = visibleModules("admin");
  assert.deepEqual(ids(mods), ["inicio", "clientes", "finanzas", "operacion", "administracion"]);
  assert.deepEqual(childIds(mods, "finanzas"), ["caja", "ventas", "cuentas", "gastos", "productos", "reportes"]);
  assert.deepEqual(childIds(mods, "administracion"), ["roles", "entrenadores", "equipo", "disciplinas", "planes", "horarios", "categorias", "tarifas", "dinero", "importar", "herramientas", "ayuda"]);
});

test("caja ve Reportes en el menú (la página decide si muestra el cierre del día), pero no administración", () => {
  const mods = visibleModules("cashier");
  assert.deepEqual(ids(mods), ["inicio", "clientes", "finanzas", "operacion"]);
  assert.deepEqual(childIds(mods, "finanzas"), ["caja", "ventas", "cuentas", "gastos", "productos", "reportes"]);
  assert.equal(mods.some((m) => m.id === "administracion"), false);
});

test("entrenador ve sólo su módulo 'Mis clientes'; cliente y visitante no ven módulos", () => {
  const mods = visibleModules("trainer");
  assert.deepEqual(ids(mods), ["entrenador"]);
  assert.deepEqual(mods[0].children, []);
  assert.equal(panelAccess("trainer"), "trainer");
  assert.deepEqual(visibleModules("member"), []);
  assert.deepEqual(visibleModules(null), []);
  assert.equal(panelAccess("member"), "none");
});

test("el módulo del entrenador no lo ven administrador ni caja", () => {
  assert.equal(ids(visibleModules("admin")).includes("entrenador"), false);
  assert.equal(ids(visibleModules("cashier")).includes("entrenador"), false);
});

test("el rol staff retirado no tiene acceso a módulos", () => {
  assert.deepEqual(visibleModules("staff"), []);
});

test("modo demo muestra todo para poder revisar el diseño", () => {
  assert.equal(visibleModules(null, true).length, 5);
});

test("la sección activa es la más específica", () => {
  const mods = visibleModules("admin");
  assert.equal(activeModuleId("/panel", mods), "inicio");
  assert.equal(activeModuleId("/panel/caja", mods), "finanzas");
  assert.equal(activeModuleId("/panel/finanzas", mods), "finanzas");
  assert.equal(activeModuleId("/panel/administracion/roles", mods), "administracion");
  assert.equal(activeModuleId("/panel/clientes", mods), "clientes");
  assert.equal(activeModuleId("/panel/operacion", mods), "operacion");
  assert.equal(activeModuleId("/panel/otra-cosa", mods), null);
});

test("un prefijo parcial no activa un módulo (/panel/cajas no es caja)", () => {
  const mods = visibleModules("admin");
  assert.equal(activeModuleId("/panel/cajas", mods), null);
});
