import test, { afterEach } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import React from "react";
import { createLoader } from "./helpers/react-loader.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "https://strong.test",
});
for (const key of ["window", "document", "navigator", "HTMLElement", "Node", "FormData"])
  Object.defineProperty(globalThis, key, {
    value: dom.window[key],
    configurable: true,
    writable: true,
  });
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
globalThis.self = dom.window;
const { render, screen, fireEvent, waitFor, cleanup } = await import(
  "@testing-library/react"
);
const { CategoryRules } = await createLoader({})("components/admin/category-rules.tsx");

const originalFetch = globalThis.fetch;
afterEach(() => {
  cleanup();
  globalThis.fetch = originalFetch;
});

const rules = () => [
  {
    category: "strong_gym",
    sort_order: 1,
    is_active: true,
    is_fallback: false,
    requires_validity: true,
    forbids_validity: false,
    validity_days_min: 30,
    requires_purchase_window_days: 90,
    visits_min: 0,
    visits_window_days: 30,
    updated_at: "2026-10-28T00:00:00Z",
  },
  {
    category: "familia",
    sort_order: 2,
    is_active: true,
    is_fallback: false,
    requires_validity: true,
    forbids_validity: false,
    validity_days_min: 1,
    requires_purchase_window_days: null,
    visits_min: 0,
    visits_window_days: 30,
    updated_at: "2026-10-28T00:00:00Z",
  },
  {
    category: "amigo",
    sort_order: 3,
    is_active: true,
    is_fallback: false,
    requires_validity: false,
    forbids_validity: true,
    validity_days_min: 0,
    requires_purchase_window_days: null,
    visits_min: 3,
    visits_window_days: 30,
    updated_at: "2026-10-28T00:00:00Z",
  },
  {
    category: "comun",
    sort_order: 99,
    is_active: true,
    is_fallback: true,
    requires_validity: false,
    forbids_validity: false,
    validity_days_min: 0,
    requires_purchase_window_days: null,
    visits_min: 0,
    visits_window_days: 30,
    updated_at: "2026-10-28T00:00:00Z",
  },
];

const catalog = () => ({
  rules: rules(),
  counts: { strong_gym: 2, familia: 5, amigo: 8, comun: 20 },
  pending: 1,
  history: [],
});

function setup() {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ url: String(url), body });
    return new Response(JSON.stringify(catalog()), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };
  render(React.createElement(CategoryRules, { initial: catalog() }));
  return calls;
}

test("las reglas muestran el estado actual y los conteos por categoría", async () => {
  setup();
  assert.ok(screen.getByRole("heading", { name: "Power Box" }));
  assert.ok(screen.getByText(/Power Box:/));
  assert.ok(screen.getByText(/Sin calcular todavía/));
  assert.equal(
    screen.getByRole("button", { name: "Guardar reglas" }).disabled,
    true,
    "sin cambios no hay nada que guardar",
  );
});

test("cambiar un umbral se guarda sin tocar código", async () => {
  const calls = setup();
  const visits = screen.getAllByLabelText(/Visitas mínimas/)[2];
  fireEvent.change(visits, { target: { value: "5" } });
  const save = screen.getByRole("button", { name: "Guardar reglas" });
  await waitFor(() => assert.equal(save.disabled, false));
  fireEvent.click(save);
  await screen.findByText(/Reglas guardadas/);
  assert.equal(calls.length, 2, "guardar y recargar");
  assert.equal(calls[0].body.action, "save");
  assert.equal(calls[0].body.rules.length, 4);
  const amigo = calls[0].body.rules.find((r) => r.category === "amigo");
  assert.equal(amigo.visits_min, 5);
  assert.equal(calls[0].body.rules.filter((r) => r.is_fallback).length, 1);
  assert.equal(calls[0].body.rules.find((r) => r.is_fallback).category, "comun");
});

test("reordenar la prioridad y descartar cambios funciona", async () => {
  const calls = setup();
  const order = screen.getAllByLabelText(/Orden/)[2];
  fireEvent.change(order, { target: { value: "1" } });
  assert.ok(screen.getByRole("button", { name: "Descartar cambios" }));
  fireEvent.click(screen.getByRole("button", { name: "Descartar cambios" }));
  assert.equal(
    screen.getByRole("button", { name: "Guardar reglas" }).disabled,
    true,
  );
  assert.equal(calls.length, 0, "descartar no envía nada");
});

test("un error del servidor se muestra sin inventar que se guardó", async () => {
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({ error: "INVALID_RULES", message: "Revisá las cuatro categorías." }),
      { status: 422, headers: { "Content-Type": "application/json" } },
    );
  render(React.createElement(CategoryRules, { initial: catalog() }));
  fireEvent.change(screen.getAllByLabelText(/Visitas mínimas/)[0], {
    target: { value: "5" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Guardar reglas" }));
  assert.ok(await screen.findByText(/Revisá las cuatro categorías/));
});
