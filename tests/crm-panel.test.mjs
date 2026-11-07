import test, { afterEach } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import React from "react";
import { createLoader } from "./helpers/react-loader.mjs";
const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "https://strong.test",
});
for (const key of [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "FormData",
  "sessionStorage",
])
  Object.defineProperty(globalThis, key, {
    value: dom.window[key],
    configurable: true,
    writable: true,
  });
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
globalThis.self = dom.window;
const { render, screen, fireEvent, waitFor, cleanup, act } =
  await import("@testing-library/react");
const { ClientsPanel } = await createLoader({
  "next/navigation": "export const useRouter=()=>({refresh(){}});",
  "@/components/providers/dictionary-provider":
    'export const useDictionary = () => ({locale:"es"});',
})("components/crm/clients-panel.tsx");
const originalFetch = globalThis.fetch;
const originalConfirm = window.confirm;
let saleCatalogResponse = { products: [] };
let categoryResponse = () => categoryInfo();
afterEach(() => {
  cleanup();
  globalThis.fetch = originalFetch;
  sessionStorage.clear();
  window.confirm = originalConfirm;
  saleCatalogResponse = { products: [] };
  categoryResponse = () => categoryInfo();
});
const id = "11111111-1111-4111-8111-111111111111",
  other = "22222222-2222-4222-8222-222222222222";
const token = "33333333-3333-4333-8333-333333333333";
const client = (cid = id, name = "Hellen Reyes", num = 1) => ({
  id: cid,
  full_name: name,
  client_number: num,
  profile_id: null,
  phone: null,
  email: null,
  plan_id: null,
  category: "client",
  status: "active",
  notes: "",
  is_demo: true,
  balance_nio: 0,
});
const detail = (c = client()) => ({
  client: c,
  card: token,
  visits: [],
  events: [],
  payments: [],
  balance: null,
  finance: { version:1, client_id:c.id, profile_id:c.profile_id, layout:"repository",
    balance_status:c.profile_id ? "missing" : "unlinked", balance_nio:null, balances:null,
    collections:{count_nio:0,amount_nio:0,count_usd:0,amount_usd:0} },
});
const options = {
  payments_enabled: true,
  plans: [],
  methods: [
    { id: "cash", name_es: "Efectivo", accepts_nio: true, accepts_usd: false },
  ],
  accounts: [{ id: "cash_nio", name: "Caja NIO", currency: "NIO" }],
};
const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status });
const categoryInfo = (over = {}) => ({
  category: "familia",
  auto_category: "familia",
  reason: "gimnasio vigente",
  source: "auto",
  manual: false,
  manual_reason: null,
  validity_days: 30,
  visits_30_days: 4,
  purchases_90_days: 0,
  gym: { state: "active", expires_on: "2026-11-26" },
  classes: [],
  ...over,
});
function setup(
  handler,
  rows = [client()],
  optionsResponse = () => json(options),
) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({
      url: String(url),
      body: init.body ? JSON.parse(init.body) : null,
    });
    const u = new URL(url, "https://strong.test");
    if (u.pathname === "/api/products") return json(saleCatalogResponse);
    if (u.pathname === "/api/admin/categories")
      return json(init.method === "POST" ? { ok: true } : categoryResponse());
    if (u.pathname === "/api/admin/finance") return handler(u, init);
    if (u.searchParams.get("mode") === "options") return optionsResponse();
    if (!u.searchParams.has("id") && init.method !== "POST")
      return json({ rows, total: rows.length });
    return handler(u, init);
  };
  render(React.createElement(ClientsPanel, { isAdmin: true, isDemo: false }));
  return calls;
}
async function open(name = "Hellen Reyes") {
  fireEvent.click(
    await screen.findByRole("button", { name: new RegExp(name) }),
  );
}
const heading = (name = "Hellen Reyes") =>
  screen.findByRole("heading", { name: new RegExp(name) });
// La ficha es un menú de tarjetas; cada una abre su propia vista y desde
// ahí se vuelve con "← Volver a la ficha".
async function openModule(title) {
  if (!screen.queryByRole("button", { name: new RegExp(`^${title}`) })) {
    const back = screen.queryByRole("button", {
      name: "← Volver a la ficha",
    });
    if (back) fireEvent.click(back);
  }
  const button = await screen.findByRole("button", {
    name: new RegExp(`^${title}`),
  });
  fireEvent.click(button);
  return button;
}
const backToClients = () => {
  const backFicha = screen.queryByRole("button", {
    name: "← Volver a la ficha",
  });
  if (backFicha) fireEvent.click(backFicha);
  fireEvent.click(
    screen.getByRole("button", { name: "← Volver a clientes" }),
  );
};

test("nombre primero, QR opcional; búsqueda envía nombre sin exigir carnet", async () => {
  const calls = setup(() => json(detail()));
  assert.equal(screen.queryByLabelText("Lector USB o código copiado"), null);
  const search = screen.getByLabelText("Nombre, teléfono o número de cliente");
  fireEvent.change(search, { target: { value: "Hellen" } });
  fireEvent.click(screen.getByRole("button", { name: "Buscar", exact: true }));
  await waitFor(() =>
    assert.ok(calls.some((c) => c.url.includes("search=Hellen"))),
  );
  await open();
  await heading();
  assert.equal(
    calls.filter((c) => c.body).length,
    0,
    "abrir no registra ni cobra",
  );
  assert.equal(screen.queryByLabelText("Lector USB o código copiado"), null);
  backToClients();
  const searchAgain = await screen.findByLabelText(
    "Nombre, teléfono o número de cliente",
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Usar QR o lector (opcional)" }),
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Buscar por nombre", exact: true }),
  );
  assert.equal(document.activeElement, searchAgain);
});

test("error de ficha termina carga, sobrevive al éxito del listado y reintenta sólo GET", async () => {
  let fail = true;
  const calls = setup(() =>
    fail
      ? json(
          {
            error: "La base rechazó permisos para la ficha.",
            code: "CRM_DETAIL_42501",
          },
          503,
        )
      : json(detail()),
  );
  await open();
  await screen.findByRole("heading", { name: "No pudimos abrir esta ficha" });
  assert.equal(screen.queryByText("Cargando ficha…"), null);
  assert.match(screen.getByRole("alert").textContent, /CRM_DETAIL_42501/);
  fireEvent.click(screen.getByRole("button", { name: "Buscar", exact: true }));
  await waitFor(() =>
    assert.ok(calls.filter((c) => c.url.includes("id=")).length >= 2),
  );
  assert.ok(await screen.findByText(/CRM_DETAIL_42501/));
  fail = false;
  fireEvent.click(screen.getByRole("button", { name: "Reintentar ficha" }));
  await heading();
  assert.equal(screen.queryByText("No pudimos abrir esta ficha"), null);
  assert.equal(calls.filter((c) => c.body).length, 0);
});

for (const [label, response] of [
  ["null", () => json(null)],
  ["JSON inválido", () => new Response("<html>error</html>")],
]) {
  test(`detalle ${label}: error visible, no carga infinita ni ficha inventada`, async () => {
    setup(() => response());
    await open();
    await screen.findByRole("heading", { name: "No pudimos abrir esta ficha" });
    assert.equal(screen.queryByText("Cargando ficha…"), null);
    assert.equal(
      screen.queryByRole("button", { name: /Confirmar entrada/ }),
      null,
    );
  });
}

test("respuesta tardía del cliente anterior no reemplaza al cliente actual", async () => {
  let resolveFirst;
  setup(
    (u) =>
      u.searchParams.get("id") === id
        ? new Promise((resolve) => {
            resolveFirst = resolve;
          })
        : json(detail(client(other, "Carlos Prueba", 2))),
    [client(), client(other, "Carlos Prueba", 2)],
  );
  await open();
  await waitFor(() => assert.ok(resolveFirst));
  await open("Carlos Prueba");
  await heading("Carlos Prueba");
  await act(async () => {
    resolveFirst(json(detail()));
  });
  assert.equal(screen.queryByRole("heading", { name: /Hellen Reyes/ }), null);
  assert.ok(screen.getByRole("heading", { name: /Carlos Prueba/ }));
});

test("alta sólo nombre se conserva aunque falle ficha; reintentar no duplica alta", async () => {
  const calls = setup((u, init) =>
    init.method === "POST"
      ? json({ data: id })
      : json({ error: "Fallo en ficha", code: "CRM_DETAIL_42703" }, 503),
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Nuevo cliente", exact: true }),
  );
  fireEvent.change(screen.getByLabelText("Nombre completo *"), {
    target: { value: "Hellen Reyes" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Guardar cliente" }));
  await screen.findByRole("heading", { name: "No pudimos abrir esta ficha" });
  assert.ok(screen.getByText(/Cliente creado\. No lo registres de nuevo/));
  assert.equal(calls.filter((c) => c.body?.action === "create").length, 1);
  assert.equal(calls.find((c) => c.body)?.body.phone, "");
  fireEvent.click(screen.getByRole("button", { name: "Reintentar ficha" }));
  await waitFor(() =>
    assert.ok(calls.filter((c) => c.url.includes("id=")).length >= 2),
  );
  assert.equal(calls.filter((c) => c.body?.action === "create").length, 1);
});

test("fallo de opciones no borra listado ni ficha y bloquea cobros", async () => {
  setup(
    () => json(detail()),
    [client()],
    () => json({ error: "No disponible", code: "CRM_OPTIONS_42P01" }, 503),
  );
  await open();
  await heading();
  assert.ok(screen.getByText(/CRM_OPTIONS_42P01/));
  await openModule("Cobrar un servicio");
  assert.ok(screen.getByRole("button", { name: "Confirmar cobro" }).disabled);
  assert.equal(screen.queryByText("No pudimos abrir esta ficha"), null);
});

test("refresh conserva referencia de cobro y oculta carnet obsoleto hasta confirmar detalle", async () => {
  let details = 0,
    resolveRefresh;
  const pending = {
    action: "payment",
    id,
    requestId: other,
    amount: 500,
    currency: "NIO",
    method: "cash",
    account: "cash_nio",
    concept: "Mensualidad",
    fx: 1,
  };
  sessionStorage.setItem(
    `strong-gym:crm-payment:${id}`,
    JSON.stringify(pending),
  );
  setup(() =>
    ++details === 1
      ? json(detail())
      : new Promise((resolve) => {
          resolveRefresh = resolve;
        }),
  );
  await open();
  await heading();
  // El intento pendiente abre solo su módulo: nunca queda escondido.
  assert.ok(screen.getByText(`Referencia de intento: ${other}`));
  fireEvent.click(screen.getByRole("button", { name: "Actualizar ficha" }));
  await waitFor(() => assert.ok(resolveRefresh));
  assert.ok(screen.getByText(`Referencia de intento: ${other}`));
  assert.ok(
    screen.getByRole("button", { name: "Reintentar el mismo cobro" }).disabled,
  );
  await openModule("Datos del cliente y carnet");
  assert.equal(
    screen.queryByRole("button", { name: "Imprimir / guardar PDF" }),
    null,
  );
  assert.ok(screen.getByText(/Carnet oculto hasta confirmar/));
  await act(async () => resolveRefresh(json(detail())));
  assert.ok(
    await screen.findByRole("button", { name: "Imprimir / guardar PDF" }),
  );
  await openModule("Cobrar un servicio");
  assert.ok(screen.getByText(`Referencia de intento: ${other}`));
});

test("lectura de ficha colgada termina en timeout con reintento visible", async (t) => {
  setup(
    (_url, init) =>
      new Promise((_, reject) =>
        init.signal.addEventListener(
          "abort",
          () => reject(new DOMException("Aborted", "AbortError")),
          { once: true },
        ),
      ),
  );
  const row = await screen.findByRole("button", { name: /Hellen Reyes/ });
  t.mock.timers.enable({ apis: ["setTimeout"] });
  fireEvent.click(row);
  assert.ok(screen.getByText("Cargando ficha…"));
  await act(async () => t.mock.timers.tick(15001));
  assert.equal(screen.queryByText("Cargando ficha…"), null);
  assert.ok(screen.getByRole("button", { name: "Reintentar ficha" }));
  assert.ok(screen.getByText(/La lectura tardó demasiado/));
});

test("cobro con respuesta perdida conserva referencia; reintento usa exactamente el mismo cuerpo y recibo sobrevive refresh", async () => {
  let posts = 0;
  const tx = "44444444-4444-4444-8444-444444444444";
  const pending = {
    action: "payment",
    id,
    requestId: other,
    amount: 500,
    currency: "NIO",
    method: "cash",
    account: "cash_nio",
    concept: "Mensualidad",
    fx: 1,
  };
  sessionStorage.setItem(
    `strong-gym:crm-payment:${id}`,
    JSON.stringify(pending),
  );
  window.confirm = () => true;
  const calls = setup((_url, init) => {
    if (init.method !== "POST") return json(detail());
    if (++posts === 1) throw new TypeError("Failed to fetch");
    return json({ data: tx });
  });
  await open();
  await heading();
  fireEvent.click(
    screen.getByRole("button", { name: "Reintentar el mismo cobro" }),
  );
  await screen.findByText(/No se pudo confirmar la operación/);
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Reintentar el mismo cobro" })
        .disabled,
      false,
    ),
  );
  assert.equal(
    JSON.parse(sessionStorage.getItem(`strong-gym:crm-payment:${id}`))
      .requestId,
    other,
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Reintentar el mismo cobro" }),
  );
  await screen.findByText(`Cobro confirmado. Referencia: ${tx}`);
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Actualizar ficha" }).disabled,
      false,
    ),
  );
  assert.ok(screen.getByText(`Cobro confirmado. Referencia: ${tx}`));
  await openModule("Datos del cliente y carnet");
  assert.ok(screen.getByRole("button", { name: "Imprimir / guardar PDF" }));
  assert.equal(sessionStorage.getItem(`strong-gym:crm-payment:${id}`), null);
  const bodies = calls.filter((c) => c.body).map((c) => c.body);
  assert.equal(bodies.length, 2);
  assert.deepEqual(bodies, [pending, pending]);
});

test("estructura bank_accounts abre ficha y muestra monedas separadas, sin habilitar cobros", async () => {
  const legacy = {
    ...detail(),
    finance_layout: "bank_accounts_split",
    balances: { credit_nio: 100, credit_usd: 7, debt_nio: 20, debt_usd: 3 },
    client: { ...client(), profile_id: other },
    finance: { ...detail().finance, profile_id:other, layout:"bank_accounts_split", balance_status:"ready",
      balances:{credit_nio:100,credit_usd:7,debt_nio:20,debt_usd:3} },
  };
  const calls = setup(
    () => json(legacy),
    [client()],
    () =>
      json({
        ...options,
        payments_enabled: false,
        payment_block_reason: "Caja pendiente de compatibilidad",
      }),
  );
  await open();
  await heading();
  await openModule("Saldo e historial");
  assert.ok(screen.getByText("Crédito NIO: C$ 100.00"));
  assert.ok(screen.getByText("Deuda NIO: C$ 20.00"));
  assert.ok(screen.getByText("Crédito USD: US$ 7.00"));
  assert.ok(screen.getByText("Deuda USD: US$ 3.00"));
  assert.equal(screen.queryByText(/Saldo de cuenta vinculada:/), null);
  await openModule("Cobrar un servicio");
  assert.ok(screen.getByRole("button", { name: "Confirmar cobro" }).disabled);
  assert.ok(screen.getByText("Caja pendiente de compatibilidad"));
  await openModule("Registrar entrada");
  assert.equal(
    screen.getByRole("button", { name: /Confirmar entrada/ }).disabled,
    false,
  );
  assert.equal(calls.filter((c) => c.body).length, 0);
});
test("cobro pendiente conserva referencia pero no puede reintentarse en modelo bloqueado", async () => {
  const pending = {
    action: "payment",
    id,
    requestId: other,
    amount: 500,
    currency: "NIO",
    method: "cash",
    account: "cash_nio",
    concept: "Mensualidad",
    fx: 1,
  };
  sessionStorage.setItem(
    `strong-gym:crm-payment:${id}`,
    JSON.stringify(pending),
  );
  const calls = setup(
    () => json(detail()),
    [client()],
    () => json({ ...options, payments_enabled: false }),
  );
  await open();
  await heading();
  const button = screen.getByRole("button", {
    name: "Reintentar el mismo cobro",
  });
  assert.ok(button.disabled);
  fireEvent.submit(button.closest("form"));
  assert.equal(calls.filter((c) => c.body).length, 0);
  assert.deepEqual(
    JSON.parse(sessionStorage.getItem(`strong-gym:crm-payment:${id}`)),
    pending,
  );
});

test("primera entrada y reintento muestran confirmación junto al botón, no sólo arriba", async () => {
  let writes = 0;
  const visits = [
    {
      id: other,
      visited_at: "2026-10-16T04:01:00Z",
      local_day: "2026-10-15",
      source: "manual",
    },
  ];
  const calls = setup((_url, init) => {
    if (init.method === "POST")
      return json({ data: { already: ++writes > 1, id: other } });
    return json({ ...detail(), visits: writes ? visits : [] });
  });
  await open();
  await heading();
  await openModule("Registrar entrada");
  const entry = screen.getByRole("button", {
    name: "Confirmar entrada manual",
  });
  fireEvent.click(entry);
  const first = await screen.findByText(
    "Entrada registrada. No se realizó ningún cobro.",
  );
  assert.equal(first.parentElement.id, entry.getAttribute("aria-describedby"));
  assert.equal(first.closest("section"), entry.closest("section"));
  await waitFor(() => assert.equal(entry.disabled, false));
  fireEvent.click(entry);
  const repeated = await screen.findByText(
    "Este cliente ya tiene una visita registrada hoy. No se duplicó.",
  );
  assert.equal(repeated.parentElement.id, "crm-entry-feedback");
  await waitFor(() => assert.equal(entry.disabled, false));
  await openModule("Saldo e historial");
  assert.ok(screen.getByText(/10:01 p/));
  assert.equal(calls.filter((c) => c.body?.action === "check-in").length, 2);
  assert.equal(calls.filter((c) => c.body?.action === "payment").length, 0);
  assert.equal(screen.getAllByText(/10:01 p/).length, 1);
});
test("error de entrada es visible en su botón y no se confunde con registro confirmado", async () => {
  setup((_url, init) =>
    init.method === "POST"
      ? json({ error: "No se pudo confirmar la entrada." }, 503)
      : json(detail()),
  );
  await open();
  await heading();
  await openModule("Registrar entrada");
  fireEvent.click(
    screen.getByRole("button", { name: "Confirmar entrada manual" }),
  );
  await waitFor(() =>
    assert.match(
      document.getElementById("crm-entry-feedback").textContent,
      /No se pudo confirmar/,
    ),
  );
  assert.equal(
    document
      .getElementById("crm-entry-feedback")
      .querySelector('[role="alert"]').textContent,
    "No se pudo confirmar la entrada.",
  );
  assert.equal(
    screen.queryByText("Entrada registrada. No se realizó ningún cobro."),
    null,
  );
});
test("respuesta de entrada incompleta no muestra éxito ni provoca repetición automática", async () => {
  const calls = setup((_url, init) =>
    init.method === "POST" ? json({ data: {} }) : json(detail()),
  );
  await open();
  await heading();
  await openModule("Registrar entrada");
  fireEvent.click(
    screen.getByRole("button", { name: "Confirmar entrada manual" }),
  );
  await screen.findByText(/El servidor no confirmó el resultado/);
  assert.equal(calls.filter((c) => c.body).length, 1);
  assert.equal(
    screen.queryByText("Entrada registrada. No se realizó ningún cobro."),
    null,
  );
});
test("cambiar de cliente limpia el aviso de entrada anterior", async () => {
  const calls = setup(
    (u, init) =>
      init.method === "POST"
        ? json({ data: { already: true } })
        : json(
            detail(
              u.searchParams.get("id") === other
                ? client(other, "Carlos Prueba", 2)
                : client(),
            ),
          ),
    [client(), client(other, "Carlos Prueba", 2)],
  );
  await open();
  await heading();
  await openModule("Registrar entrada");
  fireEvent.click(
    screen.getByRole("button", { name: "Confirmar entrada manual" }),
  );
  await screen.findByText(/ya tiene una visita registrada hoy/);
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Confirmar entrada manual" }).disabled,
      false,
    ),
  );
  backToClients();
  await open("Carlos Prueba");
  await heading("Carlos Prueba");
  assert.equal(screen.queryByText(/ya tiene una visita registrada hoy/), null);
  assert.equal(calls.filter((c) => c.body).length, 1);
});

test("ficha bancaria usa el nuevo protocolo de cobro sin depender del escritor legacy bloqueado", async () => {
  const bank = {
    ...options,
    finance_layout: "bank_accounts_split",
    payments_enabled: false,
  };
  const calls = setup(
    (url, init) => {
      if (url.pathname === "/api/admin/finance")
        return json(
          url.searchParams.has("history")
            ? []
            : {
                ...bank,
                protocol: "service-v1",
                writes_enabled: true,
                categories: [],
              },
        );
      return json({ ...detail(), finance_layout: "bank_accounts_split" });
    },
    [client()],
    () => json(bank),
  );
  await open();
  await heading();
  await openModule("Cobrar un servicio");
  await screen.findByRole("heading", { name: "Cobro por servicio" });
  const submit = screen.getByRole("button", {
    name: "Confirmar cobro por servicio",
  });
  await waitFor(() => assert.equal(submit.disabled, false));
  assert.ok(screen.getByText(/No reduce deudas/));
  assert.equal(screen.queryByText(/Los cobros están bloqueados/), null);
  assert.ok(calls.some((c) => c.url === "/api/admin/finance"));
});

const quickTariffReceiptId = "44444444-4444-4444-8444-444444444444";
const checkoutProductId = "55555555-5555-4555-8555-555555555555";
const checkoutProductReceiptId = "66666666-6666-4666-8666-666666666666";
const quickTariffPlans = [
  {
    id: "pln_boxeo",
    name_es: "Boxeo mensual",
    slug: "\u0062oxeo",
    period: "month",
    price_nio: 750,
    sort_order: 1,
    access: "class",
    class_id: "cls_boxeo",
    class_name: "Boxeo",
    duration_days: 30,
    validity_currency: "USD",
    validity_amount: 20,
  },
  {
    id: "pln_dia",
    name_es: "Pase del día",
    slug: "pase-del-dia",
    period: "session",
    price_nio: 40,
    sort_order: 2,
    access: "gym",
    duration_days: 1,
    validity_currency: "NIO",
    validity_amount: 40,
  },
  {
    id: "pln_semana",
    name_es: "Gimnasio semanal",
    slug: "gimnasio-semanal",
    period: "week",
    price_nio: 150,
    sort_order: 3,
    access: "gym",
    duration_days: 7,
    validity_currency: "NIO",
    validity_amount: 150,
  },
  {
    id: "pln_quincena",
    name_es: "Gimnasio quincenal",
    slug: "gimnasio-quincenal",
    period: "fortnight",
    price_nio: 280,
    sort_order: 4,
    access: "gym",
    duration_days: 15,
    validity_currency: "NIO",
    validity_amount: 280,
  },
  {
    id: "pln_mes",
    name_es: "Gimnasio mensual",
    slug: "gimnasio-mensual",
    period: "month",
    price_nio: 560,
    sort_order: 5,
    access: "gym",
    duration_days: 30,
    validity_currency: "NIO",
    validity_amount: 560,
  },
];
function setupQuickTariffs(checkIn, plans = quickTariffPlans, usd = false) {
  window.confirm = () => true;
  window.requestAnimationFrame = (callback) => {
    callback(0);
    return 1;
  };
  globalThis.requestAnimationFrame = window.requestAnimationFrame;
  const bank = {
    ...options,
    finance_layout: "bank_accounts_split",
    payments_enabled: false,
    plans,
    ...(usd
      ? {
          methods: [
            ...options.methods,
            {
              id: "cash_usd",
              name_es: "Efectivo dólares",
              accepts_nio: false,
              accepts_usd: true,
            },
          ],
          accounts: [
            ...options.accounts,
            { id: "cash_usd", name: "Caja USD", currency: "USD" },
          ],
        }
      : {}),
  };
  return setup(
    (url, init) => {
      if (url.pathname === "/api/admin/finance") {
        if (init.method === "POST") {
          const body = JSON.parse(init.body);
          if (body.items?.length) {
            const productsTotal = body.items.reduce(
              (sum, item) => sum + item.qty * item.unitPrice,
              0,
            );
            return json({
              id: quickTariffReceiptId,
              transactionIds: [
                quickTariffReceiptId,
                checkoutProductReceiptId,
              ],
              receipts: [
                {
                  id: quickTariffReceiptId,
                  label: body.concept,
                  amount: body.amount,
                },
                {
                  id: checkoutProductReceiptId,
                  label: "Venta: Agua EJEMPLO x2",
                  amount: productsTotal,
                },
              ],
              serviceTransactionId: quickTariffReceiptId,
              serviceAmount: body.amount,
              productsTotal,
              total: body.amount + productsTotal,
              currency: "NIO",
            });
          }
          return json({ id: quickTariffReceiptId });
        }
        return json(
          url.searchParams.has("history")
            ? []
            : {
                protocol: "service-v1",
                writes_enabled: true,
                finance_layout: "bank_accounts_split",
                methods: bank.methods,
                accounts: bank.accounts,
                categories: [],
                plans,
              },
        );
      }
      if (init.method === "POST") {
        const body = JSON.parse(init.body);
        if (body.action === "check-in") return checkIn(body);
        return json({ error: "Acción inesperada en la prueba." }, 500);
      }
      return json({ ...detail(), finance_layout: "bank_accounts_split" });
    },
    [client()],
    () => json(bank),
  );
}
const setupDayPass = (checkIn) =>
  setupQuickTariffs(
    checkIn,
    quickTariffPlans.filter((plan) => plan.slug === "pase-del-dia"),
  );
async function chargeQuickTariff({
  buttonName = /Cobrar pase del día/,
  amount = "40",
  concept = "Pase del día",
  registerEntry = true,
  expectedNotice = null,
} = {}) {
  await open();
  await heading();
  await openModule("Registrar entrada");
  fireEvent.click(await screen.findByRole("button", { name: buttonName }));
  if (expectedNotice) assert.ok(await screen.findByText(expectedNotice));
  const checkbox = await screen.findByRole("checkbox", {
    name: /Registrar entrada ahora/,
  });
  assert.equal(checkbox.checked, true);
  if (!registerEntry) fireEvent.click(checkbox);
  const submit = screen.getByRole("button", {
    name: "Confirmar cobro por servicio",
  });
  await waitFor(() => assert.equal(submit.disabled, false));
  assert.equal(screen.getByLabelText("Monto").value, amount);
  assert.equal(screen.getByLabelText("Concepto").value, concept);
  fireEvent.change(screen.getByLabelText("Método"), {
    target: { value: "cash" },
  });
  fireEvent.change(screen.getByLabelText("Cuenta"), {
    target: { value: "cash_nio" },
  });
  fireEvent.change(screen.getByLabelText("Tasa NIO por 1 USD"), {
    target: { value: "36.7244" },
  });
  fireEvent.click(submit);
}
const chargeDayPass = (options) => chargeQuickTariff(options);
const quickTariffCharges = (calls) =>
  calls.filter(
    (call) =>
      call.url === "/api/admin/finance" &&
      call.body?.kind === "service_income",
  );
const quickTariffCheckIns = (calls) =>
  calls.filter((call) => call.body?.action === "check-in");
const dayPassCharges = quickTariffCharges;
const dayPassCheckIns = quickTariffCheckIns;

test("pase del día precarga C$40 y registra la entrada solo tras confirmar el cobro", async () => {
  const calls = setupDayPass(() =>
    json({ data: { already: false, id: token } }),
  );
  await chargeDayPass();
  await screen.findByText("Cobro confirmado y entrada registrada.");
  assert.equal(dayPassCharges(calls).length, 1);
  assert.equal(dayPassCharges(calls)[0].body.amount, 40);
  assert.equal(dayPassCharges(calls)[0].body.currency, "NIO");
  assert.equal(dayPassCharges(calls)[0].body.concept, "Pase del día");
  assert.equal(dayPassCharges(calls)[0].body.clientId, id);
  assert.equal(dayPassCheckIns(calls).length, 1);
  assert.equal(dayPassCheckIns(calls)[0].body.id, id);
});

test("pase del día y productos se cobran en un solo intento antes de registrar la entrada", async () => {
  saleCatalogResponse = {
    products: [
      {
        id: checkoutProductId,
        name: "Agua EJEMPLO",
        category: "Bebidas",
        subcategory: null,
        attributes: {},
        price: 20,
        stock: 5,
        low_stock: false,
      },
    ],
  };
  const calls = setupDayPass(() =>
    json({ data: { already: false, id: token } }),
  );
  await open();
  await heading();
  await openModule("Registrar entrada");
  fireEvent.click(
    await screen.findByRole("button", { name: /Cobrar pase del día/ }),
  );
  fireEvent.change(await screen.findByLabelText("Cantidad de Agua EJEMPLO"), {
    target: { value: "2" },
  });
  assert.ok(await screen.findByText(/Total a cobrar:.*C\$80/));
  fireEvent.change(screen.getByLabelText("Método"), {
    target: { value: "cash" },
  });
  fireEvent.change(screen.getByLabelText("Cuenta"), {
    target: { value: "cash_nio" },
  });
  fireEvent.change(screen.getByLabelText("Tasa NIO por 1 USD"), {
    target: { value: "36.7244" },
  });
  fireEvent.click(
    screen.getByRole("button", { name: "Confirmar cobro y productos" }),
  );
  await screen.findByText("Cobro confirmado y entrada registrada.");
  assert.equal(dayPassCharges(calls).length, 1);
  assert.equal(dayPassCharges(calls)[0].body.amount, 40);
  assert.deepEqual(dayPassCharges(calls)[0].body.items, [
    { product: checkoutProductId, qty: 2, unitPrice: 20 },
  ]);
  assert.equal(dayPassCheckIns(calls).length, 1);
});

test("pase del día con entrada de hoy no duplica la visita", async () => {
  const calls = setupDayPass(() =>
    json({ data: { already: true, id: token } }),
  );
  await chargeDayPass();
  await screen.findByText(/ya tenía una visita registrada hoy.*no se duplicó/);
  assert.equal(dayPassCharges(calls).length, 1);
  assert.equal(dayPassCheckIns(calls).length, 1);
});

test("pase del día sin registrar entrada cobra una vez y no llama check-in", async () => {
  const calls = setupDayPass(() =>
    json({ data: { already: false, id: token } }),
  );
  await chargeDayPass({ registerEntry: false });
  await screen.findByRole("link", { name: /Abrir comprobante interno/ });
  assert.equal(dayPassCharges(calls).length, 1);
  assert.equal(dayPassCheckIns(calls).length, 0);
});

test("si la entrada falla tras cobrar el pase, avisa que no se repita el cobro", async () => {
  const calls = setupDayPass(() =>
    json({ error: "No se pudo confirmar la entrada." }, 503),
  );
  await chargeDayPass();
  await screen.findByText(/No repitas el cobro/);
  assert.equal(dayPassCharges(calls).length, 1);
  assert.equal(dayPassCheckIns(calls).length, 1);
});

test("tarifas rápidas muestran Día, Semana, Quincena y Mes, pero nunca Boxeo", async () => {
  const calls = setupQuickTariffs(() =>
    json({ data: { already: false, id: token } }),
  );
  await open();
  await heading();
  await openModule("Registrar entrada");
  const tariffButtons = [
    await screen.findByRole("button", { name: /Cobrar pase del día.*C\$40/ }),
    screen.getByRole("button", { name: /Cobrar semana.*C\$150/ }),
    screen.getByRole("button", { name: /Cobrar quincena.*C\$280/ }),
    screen.getByRole("button", { name: /Cobrar mes.*C\$560/ }),
  ];
  for (const button of tariffButtons) {
    assert.ok(button.classList.contains("bg-brand"));
    assert.equal(button.getAttribute("aria-pressed"), "false");
  }
  assert.ok(
    screen
      .getByRole("button", { name: /Solo confirmar entrada/ })
      .classList.contains("bg-night-3"),
  );
  assert.equal(screen.queryByRole("button", { name: /Boxeo/ }), null);
  assert.equal(calls.filter((call) => call.body).length, 0);
});

test("tarifa sin precio NIO válido no aparece como cobro rápido", async () => {
  const plans = quickTariffPlans.map((plan) => {
    if (plan.slug === "gimnasio-semanal") return { ...plan, price_nio: null };
    if (plan.slug === "gimnasio-quincenal") return { ...plan, price_nio: 0 };
    return plan;
  });
  setupQuickTariffs(() => json({ data: { already: false, id: token } }), plans);
  await open();
  await heading();
  await openModule("Registrar entrada");
  assert.ok(
    await screen.findByRole("button", { name: /Cobrar pase del día/ }),
  );
  assert.equal(screen.queryByRole("button", { name: /Cobrar semana/ }), null);
  assert.equal(screen.queryByRole("button", { name: /Cobrar quincena/ }), null);
  assert.ok(screen.getByRole("button", { name: /Cobrar mes/ }));
});

test("quincena precarga C$280, avisa que activa la vigencia y registra la entrada tras el cobro", async () => {
  const calls = setupQuickTariffs(() =>
    json({ data: { already: false, id: token } }),
  );
  await chargeQuickTariff({
    buttonName: /Cobrar quincena/,
    amount: "280",
    concept: "Gimnasio quincenal",
    expectedNotice: /activa o renueva la vigencia del plan: 15 días/,
  });
  await screen.findByText("Cobro confirmado y entrada registrada.");
  assert.equal(quickTariffCharges(calls).length, 1);
  assert.equal(quickTariffCharges(calls)[0].body.amount, 280);
  assert.equal(quickTariffCharges(calls)[0].body.currency, "NIO");
  assert.equal(
    quickTariffCharges(calls)[0].body.concept,
    "Gimnasio quincenal",
  );
  assert.equal(quickTariffCharges(calls)[0].body.clientId, id);
  assert.equal(quickTariffCharges(calls)[0].body.planId, "pln_quincena");
  assert.equal(quickTariffCheckIns(calls).length, 1);
  assert.equal(
    calls.filter((call) => call.body?.action && call.body.action !== "check-in")
      .length,
    0,
  );
});

test("mes sin registrar entrada cobra C$560 una vez y no llama check-in", async () => {
  const calls = setupQuickTariffs(() =>
    json({ data: { already: false, id: token } }),
  );
  await chargeQuickTariff({
    buttonName: /Cobrar mes/,
    amount: "560",
    concept: "Gimnasio mensual",
    registerEntry: false,
    expectedNotice: /activa o renueva la vigencia del plan: 30 días/,
  });
  await screen.findByRole("link", { name: /Abrir comprobante interno/ });
  assert.equal(quickTariffCharges(calls).length, 1);
  assert.equal(quickTariffCharges(calls)[0].body.amount, 560);
  assert.equal(quickTariffCharges(calls)[0].body.currency, "NIO");
  assert.equal(quickTariffCharges(calls)[0].body.concept, "Gimnasio mensual");
  assert.equal(quickTariffCharges(calls)[0].body.planId, "pln_mes");
  assert.equal(quickTariffCheckIns(calls).length, 0);
  assert.equal(calls.filter((call) => call.body?.action).length, 0);
});

test("Boxeo se cobra aparte en dólares y no registra entrada de gimnasio", async () => {
  const calls = setupQuickTariffs(
    () => json({ data: { already: false, id: token } }),
    quickTariffPlans,
    true,
  );
  await open();
  await heading();
  await openModule("Cobrar un servicio");
  fireEvent.click(
    await screen.findByRole("button", { name: /Cobrar Boxeo · USD\s*20/ }),
  );
  await screen.findByText(/Boxeo se cobra solo, sin productos/);
  assert.equal(
    screen.queryByRole("checkbox", { name: /Registrar entrada ahora/ }),
    null,
  );
  const submit = screen.getByRole("button", {
    name: "Confirmar cobro por servicio",
  });
  await waitFor(() => assert.equal(submit.disabled, false));
  assert.equal(screen.getByLabelText("Monto").value, "20");
  assert.equal(screen.getByLabelText("Concepto").value, "Boxeo mensual");
  assert.equal(screen.getByLabelText("Moneda").value, "USD");
  fireEvent.change(screen.getByLabelText("Método"), {
    target: { value: "cash_usd" },
  });
  fireEvent.change(screen.getByLabelText("Cuenta"), {
    target: { value: "cash_usd" },
  });
  fireEvent.change(screen.getByLabelText("Tasa NIO por 1 USD"), {
    target: { value: "36.7244" },
  });
  fireEvent.click(submit);
  await screen.findByRole("link", { name: /Abrir comprobante interno/ });
  assert.equal(quickTariffCharges(calls).length, 1);
  const body = quickTariffCharges(calls)[0].body;
  assert.equal(body.amount, 20);
  assert.equal(body.currency, "USD");
  assert.equal(body.planId, "pln_boxeo");
  assert.equal(quickTariffCheckIns(calls).length, 0);
  assert.equal(calls.filter((call) => call.body?.action).length, 0);
});

test("la ficha muestra Gimnasio y Boxeo con su propio botón de cobro", async () => {
  setupQuickTariffs(
    () => json({ data: { already: false, id: token } }),
    quickTariffPlans,
    true,
  );
  await open();
  await heading();
  await screen.findByText("Vigencias");
  assert.ok(screen.getByRole("button", { name: /Cobrar Gimnasio · C\$560/ }));
  assert.ok(screen.getByRole("button", { name: /Cobrar Boxeo · USD\s*20/ }));
});

test("un plan sin duración definida cobra sin crear vigencia", async () => {
  const calls = setupQuickTariffs(
    () => json({ data: { already: false, id: token } }),
    quickTariffPlans.map((plan) =>
      plan.slug === "pase-del-dia"
        ? { ...plan, duration_days: null, validity_amount: null, validity_currency: null, access: null }
        : plan,
    ),
  );
  await chargeDayPass({
    expectedNotice: /no tiene una duración definida/,
  });
  await screen.findByRole("link", { name: /Abrir comprobante interno/ });
  assert.equal(quickTariffCharges(calls).length, 1);
  assert.equal(quickTariffCharges(calls)[0].body.planId, undefined);
});

test("saldo: SQL anterior no bloquea recepción y reintentar confirma sección sólo con GET", async () => {
  let updated=false;
  const calls=setup(()=>{
    const value=detail();
    if(!updated) delete value.finance;
    return json(value);
  });
  await open(); await heading();
  await openModule("Saldo e historial");
  await screen.findByText('CRM_FINANCE_READ_UNCONFIRMED');
  assert.equal(screen.queryByText(/Córdobas: C\$ 0.00/),null);
  await openModule("Registrar entrada");
  assert.equal(screen.getByRole('button',{name:/Confirmar entrada/}).disabled,false);
  await openModule("Saldo e historial");
  updated=true;
  fireEvent.click(screen.getByRole('button',{name:'Reintentar saldo y cobros'}));
  await screen.findByText('Córdobas: C$ 0.00 · 0 cobros');
  assert.equal(screen.queryByText('CRM_FINANCE_READ_UNCONFIRMED'),null);
  assert.equal(calls.filter(call=>call.body).length,0);
});

test("saldo: un refresh fallido oculta cifras antiguas sin anunciar cero", async () => {
  let fail=false;
  const value=detail();
  value.finance.collections={count_nio:1,amount_nio:125,count_usd:0,amount_usd:0};
  const calls=setup(()=> fail ? json({error:'Lectura no confirmada'},503) : json(value));
  await open(); await heading();
  await openModule("Saldo e historial");
  await screen.findByText('Córdobas: C$ 125.00 · 1 cobro');
  fail=true;
  fireEvent.click(screen.getByRole('button',{name:'Actualizar ficha'}));
  await screen.findByText('CRM_FINANCE_READ_UNCONFIRMED');
  assert.equal(screen.queryByText('Córdobas: C$ 125.00 · 1 cobro'),null);
  assert.equal(screen.queryByText(/Córdobas: C\$ 0.00/),null);
  fail=false;
  const retry=screen.getByRole('button',{name:'Reintentar saldo y cobros'});
  assert.equal(retry.disabled,false);
  fireEvent.click(retry);
  await screen.findByText('Córdobas: C$ 125.00 · 1 cobro');
  assert.equal(calls.filter(call=>call.body).length,0);
});

test("saldo: respuesta financiera de otra ficha no se muestra aunque la ficha principal coincida", async () => {
  const value=detail();
  value.finance.client_id=other;
  value.finance.collections={count_nio:1,amount_nio:777,count_usd:0,amount_usd:0};
  setup(()=>json(value));
  await open(); await heading();
  await openModule("Saldo e historial");
  await screen.findByText('CRM_FINANCE_READ_UNCONFIRMED');
  assert.equal(screen.queryByText(/Córdobas: C\$ 777.00/),null);
  await openModule("Registrar entrada");
  assert.equal(screen.getByRole('button',{name:/Confirmar entrada/}).disabled,false);
});

test("saldo: datos financieros inválidos se aíslan de recepción, no bloquean toda la ficha", async () => {
  const value=detail();
  value.balance='incorrecto';
  value.finance.balance_status='ready';
  value.finance.balance_nio=null;
  setup(()=>json(value));
  await open(); await heading();
  await openModule("Saldo e historial");
  await screen.findByText('CRM_FINANCE_READ_UNCONFIRMED');
  await openModule("Registrar entrada");
  assert.equal(screen.getByRole('button',{name:/Confirmar entrada/}).disabled,false);
  assert.equal(screen.queryByText('No pudimos abrir esta ficha'),null);
});

test("cada tarjeta de la ficha abre su propia vista y Volver regresa al menú", async () => {
  setup(() => json(detail()));
  await open();
  await heading();
  // Menú de tarjetas visible; el contenido de cada vista todavía no.
  assert.ok(screen.getByRole("button", { name: /^Saldo e historial/ }));
  assert.equal(screen.queryByText("Saldo y cobros del cliente"), null);
  const asistencia = screen.getByRole("link", {
    name: /^Asistencia \(día, semana, mes\)/,
  });
  assert.match(asistencia.getAttribute("href"), /\?vista=asistencia$/);
  await openModule("Saldo e historial");
  assert.ok(await screen.findByText("Saldo y cobros del cliente"));
  // La tarjeta abre una pantalla propia: cubre la ficha, se desplaza por
  // dentro y la página de atrás queda quieta.
  const moduleScreen = document.getElementById("ficha-cliente");
  assert.equal(moduleScreen.dataset.moduleScreen, "historial");
  assert.match(moduleScreen.className, /fixed inset-0/);
  assert.match(moduleScreen.className, /overflow-y-auto/);
  assert.equal(document.body.style.overflow, "hidden");
  assert.equal(
    screen.queryByRole("button", { name: /^Cobrar un servicio/ }),
    null,
  );
  assert.equal(
    screen.queryByRole("button", { name: "← Volver a clientes" }),
    null,
  );
  fireEvent.click(screen.getByRole("button", { name: "← Volver a la ficha" }));
  assert.ok(
    await screen.findByRole("button", { name: /^Cobrar un servicio/ }),
  );
  assert.equal(screen.queryByText("Saldo y cobros del cliente"), null);
  assert.equal(moduleScreen.dataset.moduleScreen, undefined);
  assert.equal(document.body.style.overflow, "");
});

test("la ficha muestra la categoría real por vigencia y su motivo", async () => {
  setup(() => json(detail()));
  await open();
  await heading();
  await openModule("Datos del cliente y carnet");
  assert.ok(await screen.findByText(/gimnasio vigente/));
  assert.ok(screen.getByText(/Gimnasio vigente hasta el 26\/11\/2026/));
  assert.ok(screen.getByText(/4 visitas en 30 días/));
  assert.ok(screen.getByText(/Sale de la vigencia pagada, no de la etiqueta del plan asignado/));
});

test("el administrador fija la categoría con motivo y queda registrada", async () => {
  const calls = setup(() => json(detail()));
  await open();
  await heading();
  await openModule("Datos del cliente y carnet");
  await screen.findByText(/gimnasio vigente/);
  const confirm = screen.getByRole("button", { name: "Fijar categoría" });
  assert.equal(confirm.disabled, true, "sin motivo no se puede fijar");
  fireEvent.change(screen.getByLabelText("Categoría"), {
    target: { value: "comun" },
  });
  fireEvent.change(screen.getByPlaceholderText("Motivo (obligatorio)"), {
    target: { value: "Acuerdo con el dueño" },
  });
  fireEvent.click(confirm);
  await screen.findByText(/Categoría fijada y registrada/);
  const post = calls.find(
    (call) => call.url === "/api/admin/categories" && call.body?.action,
  );
  assert.equal(post.body.action, "set-override");
  assert.equal(post.body.clientId, client().id);
  assert.equal(post.body.category, "comun");
  assert.equal(post.body.reason, "Acuerdo con el dueño");
});

test("una categoría fijada a mano se muestra con su motivo y se puede liberar", async () => {
  categoryResponse = () =>
    categoryInfo({
      category: "comun",
      source: "manual",
      manual: true,
      manual_reason: "Acuerdo con el dueño",
    });
  const calls = setup(() => json(detail()));
  await open();
  await heading();
  await openModule("Datos del cliente y carnet");
  assert.ok(await screen.findByText(/Fijada a mano por administración/));
  assert.ok(screen.getByText(/El cálculo automático diría «Familia»/));
  fireEvent.change(screen.getByPlaceholderText("Motivo para volver al cálculo"), {
    target: { value: "Terminó el acuerdo" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Volver al cálculo" }));
  await screen.findByText(/vuelve al cálculo automático/);
  const post = calls.find(
    (call) => call.url === "/api/admin/categories" && call.body?.action,
  );
  assert.equal(post.body.action, "clear-override");
  assert.equal(post.body.reason, "Terminó el acuerdo");
});

test("el listado distingue la categoría por vigencia y el filtro la envía al servidor", async () => {
  const calls = setup(() => json(detail()), [
    { ...client(), category_calc: "strong_gym", category_source: "auto" },
    {
      ...client(other, "Marcos Vencido", 2),
      category_calc: "comun",
      category_source: "manual",
    },
    { ...client(other, "Sin recalcular", 3) },
  ]);
  // La categoría real se ve tal cual; la decisión manual se anuncia.
  assert.ok(await screen.findByText(/Power Box · EJEMPLO/));
  assert.ok(screen.getByText(/Común \(a mano\) · EJEMPLO/));
  // Sin categoría calculada, el listado sigue mostrando la etiqueta histórica.
  assert.ok(screen.getByText(/Clientes · EJEMPLO/));
  fireEvent.change(screen.getByLabelText("Categoría o etiqueta"), {
    target: { value: "amigo" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Buscar" }));
  await waitFor(() =>
    assert.ok(
      calls.some((call) => call.url.includes("category=amigo")),
      "el filtro de categoría debe viajar al servidor",
    ),
  );
});
