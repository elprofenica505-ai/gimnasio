// EMBUDO: venta online de punta a punta sobre el modelo split.
// Orden creada por un visitante anónimo con precios canónicos de la base,
// pago informado con número de referencia, confirmación de 1 toque por el
// personal (membresía con plan_register_segment + cobros con
// finance_record_movement + salida de stock) y el pipeline de leads.
import { createTestDb, sqlFile } from "./helpers/sql-test-db.mjs";
import assert from "node:assert/strict";

let checks = 0;
const ok = (label, cond) => {
  assert.ok(cond, label);
  checks += 1;
  console.log(`✅ ${label}`);
};

const db = await createTestDb();
await db.exec(sqlFile("supabase/migrations/00099_embudo_de_ventas.sql"));
ok("00099 se aplica sobre la cadena completa sin error", true);
await db.exec(sqlFile("supabase/migrations/00102_embudo_metodo_pago_resiliente.sql"));
ok("00102 (método de pago resiliente) se aplica sin error", true);

const row = async (query, args = []) => (await db.query(query, args)).rows[0];
const rows = async (query, args = []) => (await db.query(query, args)).rows;
const makeUser = async (email, role) => {
  const id = (await row("insert into auth.users(email, raw_user_meta_data) values ($1,$2) returning id", [
    email,
    JSON.stringify({ full_name: "EJEMPLO " + email }),
  ])).id;
  if (role) await db.query("update public.profiles set role=$2::public.user_role where id=$1", [id, role]);
  return id;
};
const admin = await makeUser("admin@test.invalid", "admin");

async function as(actor, aal, query, args = []) {
  await db.exec("reset role; delete from auth.current_user");
  if (actor) await db.query("insert into auth.current_user values($1,$2)", [actor, aal]);
  await db.exec(`set role ${actor ? "authenticated" : "anon"}`);
  try {
    return await db.query(query, args);
  } finally {
    await db.exec("reset role; delete from auth.current_user");
  }
}
const asAnon = (q, a = []) => as(null, null, q, a);
const asAdmin = (q, a = []) => as(admin, "aal2", q, a);
const rpcAnon = async (name, args) =>
  (await asAnon(`select public.${name}(${args.map((_, i) => `$${i + 1}`).join(",")}) as value`, args)).rows[0].value;
const rpcAdmin = async (name, args) =>
  (await asAdmin(`select public.${name}(${args.map((_, i) => `$${i + 1}`).join(",")}) as value`, args)).rows[0].value;
const denied = async (label, promise, pattern) => {
  await assert.rejects(promise, pattern, label);
  ok(label, true);
};

// La caja de efectivo NIO y el método SINPE (en la instalación los crean
// PERSONALIZAR-GIMNASIO y la semilla genérica del artefacto split).
await db.query(
  `insert into bank_accounts (id, name, account_type, currency, balance, is_active, display_order)
   values ('cta_caja_nio','Caja fuerte (C$)','caja_fuerte','NIO',0,true,1)`,
);
await db.query(
  `insert into payment_methods (id, name, currency, fee_pct, is_active, display_order)
   values ('pm_sinpe','SINPE Móvil','NIO',0,true,7)`,
);

// Plan con precio NIO (el catálogo de la cadena trae el pase del día) y un
// "boxeo" en USD para probar el rechazo del checkout online.
const planDia = (await row(`select id from plans where slug='pase-del-dia' limit 1`)).id;
const precioDia = Number((await row(`select price_nio from plans where id=$1`, [planDia])).price_nio);
ok("hay un plan NIO con precio canónico para vender", precioDia > 0);
// El plan de boxeo existe en la cadena y su precio es USD (plans.price):
// el checkout online no debe aceptarlo en esta fase.
const planBoxeo = (await row(`select id from plans where slug='boxeo' limit 1`)).id;
ok("hay un plan USD para probar el rechazo", Boolean(planBoxeo));
const producto = (
  await row("insert into products(name, category, price) values ('PROTEINA EJEMPLO','suplementos',1500) returning id")
).id;

// ── 00102: el método de pago por defecto no puede tumbar la orden ───────
// Incidente del demo: sin la fila 'pm_sinpe', el default duro mataba TODA
// orden con una FK críptica. Sin NINGÚN método activo el error debe ser
// claro; con un método no-SINPE la orden debe salir con ese método.
await db.query("delete from payment_methods");
await denied(
  "sin métodos de pago activos falla con SIN_METODO_PAGO (no con FK)",
  rpcAnon("embudo_crear_orden", [JSON.stringify({ full_name: "NOE EJEMPLO", phone: "88886666", plan_id: planDia })]),
  /SIN_METODO_PAGO/,
);
await db.query(
  `insert into payment_methods (id, name, currency, fee_pct, is_active, display_order)
   values ('pm_efectivo','Efectivo C$','NIO',0,true,1)`,
);
const ordenFallback = await rpcAnon("embudo_crear_orden", [
  JSON.stringify({ full_name: "NOE EJEMPLO", phone: "88887777", plan_id: planDia }),
]);
ok(
  "sin SINPE activo la orden sale con el mejor método disponible",
  (await row("select pay_method from embudo_orders where public_id=$1", [ordenFallback.public_id]))
    .pay_method === "pm_efectivo",
);
await db.query("delete from embudo_leads where phone='88887777'");
await db.query("delete from embudo_orders where public_id=$1", [ordenFallback.public_id]);
await db.query("delete from payment_methods where id='pm_efectivo'");
// Se repone el SINPE canónico para el resto de la batería.
await db.query(
  `insert into payment_methods (id, name, currency, fee_pct, is_active, display_order)
   values ('pm_sinpe','SINPE Móvil','NIO',0,true,7)`,
);

// ── 1. Crear orden ──────────────────────────────────────────────────────
const orden = await rpcAnon("embudo_crear_orden", [
  JSON.stringify({ full_name: "BELÉN EJEMPLO", phone: "88881111", email: "belen@test.invalid", plan_id: planDia }),
]);
ok("el visitante crea una orden sin cuenta", /^PB[0-9A-F]{8}$/.test(orden.public_id));
ok("el total lo calcula la base, no el navegador", Number(orden.total) === precioDia);
ok("nace el lead con la orden", (await row(`select stage from embudo_leads where phone='88881111'`)).stage === "nuevo");

await denied(
  "plan inexistente se rechaza",
  rpcAnon("embudo_crear_orden", [JSON.stringify({ full_name: "X Y", phone: "88882222", plan_id: "pln_fantasma" })]),
  /PLAN_NO_DISPONIBLE/,
);
await denied(
  "plan en USD (boxeo) no entra al checkout online",
  rpcAnon("embudo_crear_orden", [JSON.stringify({ full_name: "X Y", phone: "88883333", plan_id: planBoxeo })]),
  /PLAN_NO_DISPONIBLE/,
);
await denied(
  "orden sin plan ni productos se rechaza",
  rpcAnon("embudo_crear_orden", [JSON.stringify({ full_name: "X Y", phone: "88884444" })]),
  /ORDEN_VACIA/,
);

const ordenConProductos = await rpcAnon("embudo_crear_orden", [
  JSON.stringify({
    full_name: "CARLOS EJEMPLO",
    phone: "88885555",
    plan_id: planDia,
    items: [{ product_id: producto, qty: 2 }],
  }),
]);
ok("el carrito suma plan + productos con precio de la base", Number(ordenConProductos.total) === precioDia + 3000);
ok("los ítems quedan como foto en la orden", ordenConProductos.items[0]?.qty === 2);

// ── 2. Informar pago + estado ───────────────────────────────────────────
await rpcAnon("embudo_informar_pago", [orden.public_id, "SINPE-123456"]);
ok("informar pago deja la orden por_verificar",
  (await row(`select status from embudo_orders where public_id=$1`, [orden.public_id])).status === "por_verificar");
const estado = await rpcAnon("embudo_estado_orden", [orden.public_id]);
ok("el estado público no filtra datos sensibles", estado.public_id === orden.public_id && estado.correo === undefined);
await denied(
  "referencia demasiado corta se rechaza",
  rpcAnon("embudo_informar_pago", [orden.public_id, "12"]),
  /REFERENCIA_INVALIDA/,
);

// ── 3. Confirmación (sólo personal) ────────────────────────────────────
const ordenRow = await row(`select id from embudo_orders where public_id=$1`, [orden.public_id]);
await denied(
  "un anónimo no puede confirmar pagos",
  asAnon(`select public.embudo_confirmar_orden($1,$2) as value`, [ordenRow.id, null]),
  /AUTH|permission denied/,
);
const confirmada = await rpcAdmin("embudo_confirmar_orden", [ordenRow.id, null]);
ok("la orden queda pagada", confirmada.status === "pagada");
const clienta = await row(`select id, full_name from gym_clients where phone='88881111'`);
ok("confirmar crea a la clienta en el CRM", clienta && clienta.full_name === "BELÉN EJEMPLO");
ok("la orden enlaza al cliente", confirmada.client_id === clienta.id);
const cobros = await rows(
  `select t.amount, t.concept from transactions t
    join finance_entries fe on fe.transaction_id = t.id
   where fe.request_id = $1`, [ordenRow.id],
);
ok("el cobro de la membresía quedó por el escritor de la caja",
  cobros.length === 1 && Number(cobros[0].amount) === precioDia);
const segmento = await row(
  `select ps.started_on, ps.expires_on from payment_plans ps where ps.client_id=$1`, [clienta.id],
);
ok("la membresía queda registrada con vigencia", segmento && segmento.expires_on >= segmento.started_on);
ok("el lead comprador se cierra solo",
  (await row(`select stage from embudo_leads where phone='88881111'`)).stage === "comprador");

await denied(
  "orden cancelada no se confirma",
  (async () => {
    const cancelada = await rpcAnon("embudo_crear_orden", [
      JSON.stringify({ full_name: "ZOE EJEMPLO", phone: "88889999", plan_id: planDia }),
    ]);
    const cid = (await row(`select id from embudo_orders where public_id=$1`, [cancelada.public_id])).id;
    await db.query(`update embudo_orders set status='cancelada' where id=$1`, [cid]);
    return rpcAdmin("embudo_confirmar_orden", [cid, null]);
  })(),
  /ORDEN_NO_CONFIRMABLE/,
);

// Confirmar dos veces no duplica nada (idempotencia).
const antes = await row(`select count(*)::int as n from transactions t
  join finance_entries fe on fe.transaction_id=t.id where fe.request_id=$1`, [ordenRow.id]);
await rpcAdmin("embudo_confirmar_orden", [ordenRow.id, null]);
const despues = await row(`select count(*)::int as n from transactions t
  join finance_entries fe on fe.transaction_id=t.id where fe.request_id=$1`, [ordenRow.id]);
ok("reconfirmar es idempotente (cero cobros duplicados)", antes.n === despues.n && antes.n === 1);

// ── 4. Productos: cobro + stock ─────────────────────────────────────────
const ordenProdRow = await row(`select id from embudo_orders where public_id=$1`, [ordenConProductos.public_id]);
await rpcAdmin("embudo_confirmar_orden", [ordenProdRow.id, null]);
const carlos = (await row(`select id from gym_clients where phone='88885555'`)).id;
const ventaProd = await row(
  `select qty from stock_movements where client_id=$1 and product_id=$2`,
  [carlos, producto],
);
ok("la venta de producto baja el stock (venta -2)", Number(ventaProd?.qty) === -2);

// ── 5. Leads: dedupe, etapas, sólo personal avanza ──────────────────────
await rpcAnon("embudo_guardar_lead", [JSON.stringify({ full_name: "BELÉN NUEVO NOMBRE", phone: "88881111" })]);
ok("el lead se deduplica por teléfono",
  (await row(`select count(*)::int as n from embudo_leads where phone='88881111'`)).n === 1);
await rpcAnon("embudo_guardar_lead", [JSON.stringify({ full_name: "MARTA LEAD", phone: "88886666", interest: "boxeo" })]);
const leadId = (await row(`select id from embudo_leads where phone='88886666'`)).id;
await rpcAdmin("embudo_avanzar_lead", [leadId, "contactado", "Le escribió por WhatsApp"]);
ok("el personal avanza el lead y deja nota",
  (await row(`select stage from embudo_leads where id=$1`, [leadId])).stage === "contactado");
await denied(
  "etapa inválida se rechaza",
  rpcAdmin("embudo_avanzar_lead", [leadId, "casado"]),
  /ETAPA_INVALIDA/,
);
await denied(
  "un anónimo no puede avanzar leads",
  asAnon(`select public.embudo_avanzar_lead($1,$2,$3) as value`, [leadId, "perdido", null]),
  /AUTH|permission denied/,
);

// ── 6. RLS y revocas: la tabla no se toca por fuera de las RPCs ─────────
await denied(
  "un anónimo no lee las órdenes directo",
  asAnon(`select * from embudo_orders`),
  /permission denied/,
);
ok("el personal sí lee las órdenes (panel)",
  (await asAdmin(`select count(*)::int as n from embudo_orders`)).rows[0].n >= 1);

// ── 7. 00103: cuenta de cobro resiliente + rechazo de órdenes ───────────
await db.exec(sqlFile("supabase/migrations/00103_embudo_cuenta_resiliente_y_rechazo.sql"));
ok("00103 (cuenta resiliente + rechazo) se aplica sobre 00102 sin error", true);

// Sin cuenta explícita, el confirm usa la mejor caja NIO activa aunque el
// id canónico 'cta_caja_nio' no exista (incidente del demo: INVALID_ACCOUNT).
// Desactivar en vez de borrar: las transacciones de la batería referencian
// las cuentas y la FK lo prohíbe.
await db.query(`update bank_accounts set is_active=false where currency='NIO'`);
await db.query(
  `insert into bank_accounts (id, name, account_type, currency, balance, is_active, display_order)
   values ('billetera_demo','Billetera demo NIO','billetera','NIO',0,true,5)
   on conflict (id) do update set is_active=true`,
);
const ordenFallbackCta = await rpcAnon("embudo_crear_orden", [
  JSON.stringify({ full_name: "FALLA CTA EJEMPLO", phone: "88889001", plan_id: planDia }),
]);
await rpcAnon("embudo_informar_pago", [ordenFallbackCta.public_id, "REF-CTA-001", null]);
const idFallbackCta = (await row(`select id from embudo_orders where public_id=$1`, [ordenFallbackCta.public_id])).id;
await rpcAdmin("embudo_confirmar_orden", [idFallbackCta, null]);
ok(
  "sin caja canónica el cobro cae en la mejor cuenta NIO activa",
  (await row(`select account_id from transactions where concept = 'Venta online ' || $1 limit 1`, [ordenFallbackCta.public_id]))
    .account_id === "billetera_demo",
);

// Sin NINGUNA cuenta NIO activa el error es claro (no una FK críptica).
await db.query(`update bank_accounts set is_active=false where currency='NIO'`);
const ordenSinCta = await rpcAnon("embudo_crear_orden", [
  JSON.stringify({ full_name: "SIN CTA EJEMPLO", phone: "88889002", plan_id: planDia }),
]);
await rpcAnon("embudo_informar_pago", [ordenSinCta.public_id, "REF-CTA-002", null]);
const idSinCta = (await row(`select id from embudo_orders where public_id=$1`, [ordenSinCta.public_id])).id;
await denied(
  "sin cuentas NIO el confirm falla con SIN_CUENTA_NIO",
  rpcAdmin("embudo_confirmar_orden", [idSinCta, null]),
  /SIN_CUENTA_NIO/,
);
await db.query(`update bank_accounts set is_active=true where id='cta_caja_nio'`);
await db.query(`update bank_accounts set is_active=false where id='billetera_demo'`);

// Rechazo: pendiente/por_verificar → cancelada, idempotente, sin cobros.
const ordenRechazo = await rpcAnon("embudo_crear_orden", [
  JSON.stringify({ full_name: "RECHAZO EJEMPLO", phone: "88889003", plan_id: planDia }),
]);
const idRechazo = (await row(`select id from embudo_orders where public_id=$1`, [ordenRechazo.public_id])).id;
const rechazo1 = await rpcAdmin("embudo_cancelar_orden", [idRechazo, "Cliente no completó el pago"]);
ok("el personal rechaza la orden y queda cancelada", rechazo1.status === "cancelada" && rechazo1.ya_estaba === false);
const rechazo2 = await rpcAdmin("embudo_cancelar_orden", [idRechazo, null]);
ok("rechazar dos veces es inofensivo (idempotente)", rechazo2.ya_estaba === true);
await denied(
  "confirmar una orden cancelada se rechaza",
  rpcAdmin("embudo_confirmar_orden", [idRechazo, null]),
  /ORDEN_NO_CONFIRMABLE/,
);
await denied(
  "un anónimo no puede rechazar órdenes",
  asAnon(`select public.embudo_cancelar_orden($1,$2) as value`, [idRechazo, null]),
  /AUTH|permission denied/,
);
ok(
  "la orden rechazada no dejó cobros",
  (await row(`select count(*)::int as n from transactions where concept = 'Venta online ' || $1`, [ordenRechazo.public_id])).n === 0,
);
// Rechazar una orden YA pagada no procede.
await denied(
  "rechazar una orden pagada se rechaza",
  rpcAdmin("embudo_cancelar_orden", [idFallbackCta, null]),
  /ORDEN_YA_PAGADA/,
);

console.log(`\n✅ ${checks} comprobaciones del embudo en verde.`);
