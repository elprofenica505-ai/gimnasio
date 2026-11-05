import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createLoader } from "./helpers/react-loader.mjs";

const load = createLoader({
  "server-only": "export {};",
  "@/lib/supabase/env": "export const isSupabaseConfigured=true;export const DEMO_MODE=false;export const CONFIGURATION_UNAVAILABLE=false;",
  "@/lib/supabase/server":
    'export const getSupabaseServerClient=async()=> { if(globalThis.__dbThrows) throw new Error("secret"); return globalThis.__operationalDb; };',
});
const queries = await load("lib/data/queries.ts");
const { DataReadError, readData } = await load("lib/data/read-result.ts");
function db(respond) {
  globalThis.__dbThrows = false;
  const calls = [];
  globalThis.__operationalDb = {
    from(table) {
      calls.push(table);
      const chain = {};
      for (const fn of [
        "abortSignal",
        "select",
        "eq",
        "order",
        "gte",
        "lte",
        "in",
        "limit",
      ])
        chain[fn] = () => chain;
      chain.then = (yes, no) =>
        Promise.resolve()
          .then(() => respond(table, calls))
          .then(yes, no);
      return chain;
    },
  };
  return calls;
}
const funcs = [
  "getClasses",
  "getCoaches",
  "getPlans",
  "getSessionsForWeek",
  "getMyBookings",
  "getBookedSessionIds",
  "getAllBookings",
  "getContactMessages",
  "countMembers",
];
for (const fn of funcs) {
  test(`${fn}: errores SQL no devuelven ejemplos, vacíos ni ceros`, async () => {
    db(() => ({
      data: null,
      count: null,
      error: { code: "42501", message: "private@example.com SECRET" },
    }));
    await assert.rejects(
      queries[fn]("user"),
      (e) =>
        e instanceof DataReadError &&
        e.code.endsWith("42501") &&
        !e.message.includes("SECRET"),
    );
  });
  test(`${fn}: error de transporte es explícito y sanitizado`, async () => {
    db(() => {
      throw new Error("private@example.com SECRET");
    });
    const result = await readData(() => queries[fn]("user"));
    assert.equal(result.ok, false);
    assert.ok(result.code.startsWith("DATA_"));
    assert.ok(!JSON.stringify(result).includes("SECRET"));
  });
  test(`${fn}: Supabase configurado sin cliente no es demo`, async () => {
    db(() => assert.fail("No se debe consultar sin cliente"));
    globalThis.__operationalDb = null;
    await assert.rejects(queries[fn](), /confirmar los datos/);
  });
  test(`${fn}: respuesta vacía válida permanece vacía`, async () => {
    db(() => ({ data: [], count: 0, error: null }));
    const value = await queries[fn]();
    assert.deepEqual(
      value,
      fn === "countMembers"
        ? 0
        : fn === "getSessionsForWeek"
          ? { week: value.week, sessions: [] }
          : [],
    );
  });
  test(`${fn}: respuesta nula sin error tampoco prueba vacío`, async () => {
    db(() => ({ data: null, count: null, error: null }));
    await assert.rejects(queries[fn](), DataReadError);
  });
}

test("crear cliente Supabase arroja: no hay fallback a demo", async () => {
  globalThis.__dbThrows = true;
  await assert.rejects(
    queries.getClasses(),
    (e) => e instanceof DataReadError && e.code === "DATA_CONNECTION_UNKNOWN",
  );
  globalThis.__dbThrows = false;
});
for (const code of ["42P01", "PGRST205"]) {
  test(`conteo legacy sólo ante tabla CRM ausente (${code})`, async () => {
    const calls = db((table) =>
      table === "gym_clients"
        ? { error: { code }, count: null }
        : { error: null, count: 7 },
    );
    assert.equal(await queries.countMembers(), 7);
    assert.deepEqual(calls, ["gym_clients", "profiles"]);
  });
}
test("conteo: ni error de permisos ni columna inexistente habilita fallback", async () => {
  for (const code of ["42501", "42703", "57014"]) {
    const calls = db(() => ({ error: { code }, count: null }));
    await assert.rejects(queries.countMembers(), DataReadError);
    assert.deepEqual(calls, ["gym_clients"]);
  }
});
test("conteo legacy también propaga error", async () => {
  db((table) => ({
    error: { code: table === "gym_clients" ? "42P01" : "42501" },
    count: null,
  }));
  await assert.rejects(
    queries.countMembers(),
    (e) => e.code === "DATA_CLIENT_COUNT_42501",
  );
});
const session = {
  id: "session",
  class_id: "class",
  coach_id: null,
  starts_at: "2026-10-19T12:00:00Z",
  ends_at: "2026-10-19T13:00:00Z",
  capacity: 10,
  status: "scheduled",
  gymClass: { id: "class", capacity: 10, is_active: true },
};
test("ocupación fallida no fabrica cupos disponibles", async () => {
  db((table) =>
    table === "sessions"
      ? { data: [session], error: null }
      : { data: null, error: { code: "42501" } },
  );
  await assert.rejects(
    queries.getSessionsForWeek(),
    (e) => e.code === "DATA_OCCUPANCY_42501",
  );
});
test("ocupación sin filas tras lectura correcta sí representa cero reservas", async () => {
  db((table) => ({
    data:
      table === "sessions"
        ? [session]
        : table === "classes"
          ? [session.gymClass]
          : [],
    error: null,
  }));
  const { sessions } = await queries.getSessionsForWeek();
  assert.equal(sessions[0].bookedCount, 0);
  assert.equal(sessions[0].spotsLeft, 10);
});
test("una clase cancelada no aparece en la oferta pública", async () => {
  db((table) => ({
    data:
      table === "sessions"
        ? [{ ...session, status: "cancelled" }]
        : table === "classes"
          ? [session.gymClass]
          : [],
    error: null,
  }));
  const { sessions } = await queries.getSessionsForWeek();
  assert.deepEqual(sessions, []);
});

test("operación sí puede pedir las clases canceladas para ver el historial", async () => {
  db((table) => ({
    data:
      table === "sessions"
        ? [{ ...session, status: "cancelled" }]
        : table === "classes"
          ? [session.gymClass]
          : [],
    error: null,
  }));
  const { sessions } = await queries.getSessionsForWeek("2026-W43", {
    includeInactiveClasses: true,
  });
  assert.equal(sessions.length, 1);
});

test("ocupación válida se aplica a capacidad", async () => {
  db((table) => ({
    data:
      table === "sessions"
        ? [session]
        : table === "classes"
          ? [session.gymClass]
          : [{ session_id: "session", booked_count: 8 }],
    error: null,
  }));
  assert.equal((await queries.getSessionsForWeek()).sessions[0].spotsLeft, 2);
});
test("ocupación nula/negativa/inválida no se acepta como cero", async () => {
  for (const count of [null, -1, "bad", 1.5]) {
    db((table) => ({
      data:
        table === "sessions"
          ? [session]
          : [{ session_id: "session", booked_count: count }],
      error: null,
    }));
    await assert.rejects(queries.getSessionsForWeek(), DataReadError);
  }
});
test("relación rota de sesión/reserva no desaparece como lista vacía", async () => {
  db(() => ({ data: [{ id: "bad", session: null }], error: null }));
  for (const fn of ["getSessionsForWeek", "getMyBookings", "getAllBookings"])
    await assert.rejects(queries[fn](), DataReadError);
});
test("sin configurar conserva demo local explícita", async () => {
  const demo = await createLoader({
    "server-only": "export {};",
    "@/lib/supabase/env": "export const isSupabaseConfigured=false;export const DEMO_MODE=true;export const CONFIGURATION_UNAVAILABLE=false;",
    "@/lib/supabase/server":
      "export const getSupabaseServerClient=async()=>null;",
  })("lib/data/queries.ts");
  // Instalación vacía: el demo local se sigue usando como fallback, pero
  // está vacío a propósito (cero datos inventados del gimnasio anterior).
  // La prueba exige que devuelva EXACTAMENTE lo que declara el módulo
  // local: ni más (tarjetas ficticias resucitadas) ni un error de conexión.
  const { demoClasses } = await load("lib/data/demo-content.ts");
  assert.deepEqual(await demo.getClasses(), demoClasses.filter((c) => c.is_active));
  assert.deepEqual((await demo.getSessionsForWeek()).sessions, []);
  assert.deepEqual(await demo.getMyBookings(), []);
});
for (const [file, fn, section] of [
  ["classes-grid", "ClassesGrid", "clases"],
  ["coaches", "Coaches", "equipo"],
  ["plans", "Plans", "planes"],
]) {
  test(`${fn}: error SSR visible sin destruir otras secciones`, async () => {
    db(() => ({ data: null, error: { code: "42501" } }));
    const component = (await load(`components/sections/${file}.tsx`))[fn];
    const html = renderToStaticMarkup(await component({ locale: "es" }));
    assert.ok(html.includes('role="alert"'));
    assert.ok(html.includes("Reintentar consulta"));
    assert.ok(html.includes(`id="${section}"`));
  });
  test(`${fn}: catálogo vacío no resucita tarjetas ficticias`, async () => {
    db(() => ({ data: [], error: null }));
    const component = (await load(`components/sections/${file}.tsx`))[fn];
    const html = renderToStaticMarkup(await component({ locale: "en" }));
    assert.ok(!html.includes('role="alert"'));
    assert.ok(!html.includes("Douglas"));
  });
}
