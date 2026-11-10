// ARM: asistente interno de punta a punta sobre las migraciones reales.
// Interruptores de canal, hilos visitante/socio, RPCs con token, RLS de
// lectura, captura de lead (source 'asistente') y respuesta del personal.
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
ok("00099 (embudo) se aplica sin error", true);
await db.exec(sqlFile("supabase/migrations/00104_arm_asistente_interno.sql"));
ok("00104 (ARM) se aplica sobre la cadena completa sin error", true);

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
const asSocio = (q, a = []) => as(socio, "aal2", q, a);
const denied = async (label, promise, pattern) => {
  await assert.rejects(promise, pattern, label);
  ok(label, true);
};

const admin = await makeUser("admin@test.invalid", "admin");
const socio = await makeUser("socio@test.invalid", "member");

// ── Interruptores de canal ──────────────────────────────────────────────
const canales = await rows("select channel, enabled from public.arm_channels order by channel");
ok(
  "canales sembrados: interno encendido, whatsapp y correo apagados",
  canales.length === 3 &&
    canales.find((c) => c.channel === "interno").enabled === true &&
    canales.find((c) => c.channel === "whatsapp").enabled === false &&
    canales.find((c) => c.channel === "correo").enabled === false,
);

// En producción Supabase otorga por defecto todos los privilegios de tabla;
// estos GRANT reproducen eso para probar que la RLS es la puerta de verdad.
await db.exec(`grant select, insert, update, delete on public.arm_threads to anon, authenticated;
grant select, insert, update, delete on public.arm_messages to anon, authenticated;`);

// ── RLS: el anónimo no lee nada directo ────────────────────────────────
// Ojo: un SELECT negado por RLS no lanza error, devuelve 0 filas.
const anonHilos = await asAnon("select * from public.arm_threads");
ok("anon NO ve hilos de otros (RLS devuelve 0 filas)", anonHilos.rows.length === 0);
const anonMsgs = await asAnon("select * from public.arm_messages");
ok("anon NO ve mensajes directo (RLS devuelve 0 filas)", anonMsgs.rows.length === 0);
await denied("anon no puede insertar arm_threads directo", asAnon("insert into public.arm_threads (visitor_token) values (gen_random_uuid())"), /row-level security|permission denied/);

// ── Hilo de visitante por token ─────────────────────────────────────────
const token = "11111111-1111-4111-8111-111111111111";
const hilo1 = (await asAnon("select public.arm_hilo_visitante($1,'es') as v", [token])).rows[0].v;
ok("arm_hilo_visitante crea un hilo para el token", Boolean(hilo1));
const hilo2 = (await asAnon("select public.arm_hilo_visitante($1,'es') as v", [token])).rows[0].v;
ok("la segunda llamada reutiliza el MISMO hilo (sin duplicar)", hilo1 === hilo2);

// ── Conversación: visitante escribe, cerebro responde ──────────────────
const msg1 = (await asAnon("select public.arm_enviar_visitante($1,$2) as v", [token, "¿Cuánto cuesta la mensualidad?"])).rows[0].v;
ok("arm_enviar_visitante inserta el mensaje del visitante", Boolean(msg1));
const trasEnviar = await row(
  "select staff_unread, last_message, status from public.arm_threads where id = $1",
  [hilo1],
);
ok("el hilo queda con staff_unread=1, último mensaje y abierta", trasEnviar.staff_unread === 1 && trasEnviar.last_message.includes("mensualidad") && trasEnviar.status === "abierta");

await asAnon("select public.arm_responder_asistente($1,$2)", [token, "Nuestros planes arrancan en C$600. ¿Te interesa mensual o diaria?"]);
const hist = (await asAnon("select public.arm_historial($1) as v", [token])).rows[0].v;
ok("arm_historial devuelve conversación + contacto", hist.mensajes.length === 2 && hist.mensajes[0].role === "visitante" && hist.mensajes[1].role === "asistente" && hist.contacto.full_name === null);
const otroToken = "22222222-2222-4222-8222-222222222222";
const histOtro = (await asAnon("select public.arm_historial($1) as v", [otroToken])).rows[0].v;
ok("con OTRO token el historial viene vacío (sin filtración)", histOtro === null);

const trasBot = await row("select visitor_unread from public.arm_threads where id = $1", [hilo1]);
ok("la respuesta del bot deja visitor_unread=1", trasBot.visitor_unread === 1);

await denied(
  "mensaje vacío lo rechaza el RPC (MENSAJE_INVALIDO)",
  asAnon("select public.arm_enviar_visitante($1,$2)", [token, "   "]),
  /MENSAJE_INVALIDO/,
);
await denied(
  "mensaje de 1001 caracteres lo rechaza el RPC",
  asAnon("select public.arm_enviar_visitante($1, repeat('a',1001))", [token]),
  /MENSAJE_INVALIDO/,
);

// ── El personal ve el hilo por RLS y responde por RPC ───────────────────
const vistaAdmin = await asAdmin("select id, staff_unread from public.arm_threads where id = $1", [hilo1]);
ok("el staff ve el hilo del visitante por RLS", vistaAdmin.rows.length === 1 && vistaAdmin.rows[0].staff_unread === 1);

await denied(
  "un anónimo NO puede responder como staff (sin execute → ni llega al AUTH)",
  asAnon("select public.arm_responder_staff($1,$2)", [hilo1, "hola"]),
  /AUTH|permission denied/,
);

await asAdmin("select public.arm_responder_staff($1,$2)", [hilo1, "¡Hola! Mensual C$1,200. Te esperamos 😊"]);
const trasStaff = await row(
  "select staff_unread, visitor_unread, last_message from public.arm_threads where id = $1",
  [hilo1],
);
ok("arm_responder_staff contesta, limpia staff_unread y sube visitor_unread", trasStaff.staff_unread === 0 && trasStaff.visitor_unread === 2 && trasStaff.last_message.includes("Mensual"));

const histStaff = (await asAnon("select public.arm_historial($1) as v", [token])).rows[0].v;
ok("la respuesta del staff llega al visitante (3 mensajes en el hilo)", histStaff.mensajes.length === 3 && histStaff.mensajes[2].role === "staff");

await asAnon("select public.arm_marcar_leida_visitante($1)", [token]);
const trasLeer = await row("select visitor_unread from public.arm_threads where id = $1", [hilo1]);
ok("arm_marcar_leida_visitante limpia visitor_unread", trasLeer.visitor_unread === 0);

// ── Socio autenticado: hilo propio, aislado del anónimo ────────────────
const tokenSocio = "33333333-3333-4333-8333-333333333333";
const hiloSocio = (await asSocio("select public.arm_hilo_visitante($1,'es') as v", [tokenSocio])).rows[0].v;
const hiloSocioRow = await row("select user_id, visitor_token from public.arm_threads where id = $1", [hiloSocio]);
ok("el hilo del socio queda amarrado a su user_id", hiloSocioRow.user_id === socio && hiloSocioRow.visitor_token === tokenSocio);

const vistaSocio = await asSocio("select id from public.arm_threads order by created_at");
ok("el socio ve SÓLO su hilo, no el del visitante anónimo", vistaSocio.rows.length === 1 && vistaSocio.rows[0].id === hiloSocio);
await denied(
  "el socio no puede escribir directo en arm_messages (va por RPC)",
  asSocio("insert into public.arm_messages (thread_id, role, text) values ($1,'visitante','hola')", [hiloSocio]),
  /row-level security|permission denied/,
);
const socioUpdate = await asSocio("update public.arm_threads set status='cerrada' where id = $1 returning id", [hiloSocio]);
const socioTrasUpdate = await row("select status from public.arm_threads where id = $1", [hiloSocio]);
ok("el socio intenta cerrar su hilo y RLS lo ignora (0 filas, sigue abierta)", socioUpdate.rows.length === 0 && socioTrasUpdate.status === "abierta");

// Socio escribe: el mensaje va al personal, SIN bot (arm_responder_asistente no hace nada en hilos de socio).
await asSocio("select public.arm_enviar_visitante($1,$2)", [tokenSocio, "¿Mañana hay boxeo a las 7?"]);
await asSocio("select public.arm_responder_asistente($1,$2)", [tokenSocio, "intento de suplantación"]);
const msgsSocio = await asAdmin("select role, text from public.arm_messages where thread_id = $1 order by created_at", [hiloSocio]);
ok(
  "en el hilo del socio NO entra respuesta del bot (sólo su mensaje)",
  msgsSocio.rows.length === 1 && msgsSocio.rows[0].role === "visitante",
);

// ── Captura de contacto → lead (source 'asistente') ────────────────────
const vinculo = (await asAnon(
  "select public.arm_vincular_contacto($1,$2,$3,$4) as v",
  [token, "María Prueba EJEMPLO", "888-77-66", null],
)).rows[0].v;
ok("arm_vincular_contacto crea el lead y lo devuelve", Boolean(vinculo.lead_id));
const lead = await row("select full_name, phone, source, interest from public.embudo_leads where id = $1", [vinculo.lead_id]);
ok("el lead queda con nombre, teléfono limpio y source 'asistente'", lead.full_name === "María Prueba EJEMPLO" && lead.phone === "8887766" && lead.source === "asistente" && lead.interest === "Asistente web");
const hiloVinculado = await row("select full_name, phone, lead_id from public.arm_threads where id = $1", [hilo1]);
ok("el hilo guarda el contacto y el lead_id", hiloVinculado.phone === "8887766" && hiloVinculado.lead_id === vinculo.lead_id);

const vinculo2 = (await asAnon(
  "select public.arm_vincular_contacto($1,$2,$3,$4) as v",
  [token, "María Prueba EJEMPLO", "8887766", "maria@test.invalid"],
)).rows[0].v;
ok("segunda vinculación es idempotente (mismo lead, sin duplicar)", vinculo2.lead_id === vinculo.lead_id);
const totalLeads = await row("select count(*)::int as v from public.embudo_leads");
ok("sólo existe 1 lead del asistente", totalLeads.v === 1);

await denied(
  "vincular sin teléfono válido lo rechaza (CONTACTO_INVALIDO)",
  asAnon("select public.arm_vincular_contacto($1,$2,$3)", [token, "Alguien", "12"]),
  /CONTACTO_INVALIDO/,
);

// Socio con teléfono de ficha: se enlaza cliente, NO se crea lead.
const ficha = (await row(
  "insert into public.gym_clients (full_name, phone) values ('Socio Ficha EJEMPLO', '86885663') returning id",
)).id;
const vinculoSocio = (await asSocio(
  "select public.arm_vincular_contacto($1,$2,$3,null) as v",
  [tokenSocio, "Socio de Prueba", "86885663"],
)).rows[0].v;
ok("para el SOCIO se enlaza su ficha de cliente", vinculoSocio.client_id === ficha && vinculoSocio.lead_id === null);
const totalLeads2 = await row("select count(*)::int as v from public.embudo_leads");
ok("la vinculación del socio NO crea leads", totalLeads2.v === 1);

// ── Cierre del hilo por el personal (RLS update) ────────────────────────
await asAdmin("update public.arm_threads set status='cerrada', updated_at=now() where id = $1", [hilo1]);
const cerrado = await row("select status from public.arm_threads where id = $1", [hilo1]);
ok("el staff puede cerrar un hilo", cerrado.status === "cerrada");
await asAnon("select public.arm_enviar_visitante($1,$2)", [token, "una pregunta más"]);
const reabierto = await row("select status from public.arm_threads where id = $1", [hilo1]);
ok("un mensaje del visitante reabre el hilo cerrado", reabierto.status === "abierta");

// ── El interruptor de canal manda (a nivel base) ────────────────────────
await denied(
  "un anónimo no puede tocar los interruptores",
  asAnon("update public.arm_channels set enabled = false where channel = 'interno'"),
  /row-level security|permission denied/,
);
await asAdmin("update public.arm_channels set enabled = false, updated_at = now() where channel = 'interno'");
await denied(
  "con el canal interno APAGADO, ni el RPC abre hilos (CANAL_APAGADO)",
  asAnon("select public.arm_hilo_visitante($1,'es')", [otroToken]),
  /CANAL_APAGADO/,
);
await asAdmin("update public.arm_channels set enabled = true, updated_at = now() where channel = 'interno'");
const hilo3 = (await asAnon("select public.arm_hilo_visitante($1,'es') as v", [otroToken])).rows[0].v;
ok("reencendido el canal, el chat vuelve a funcionar", Boolean(hilo3));

// ── Captura a medias: primero el nombre, después el teléfono ───────────
await asAnon("select public.arm_anotar_contacto($1,$2,$3)", [otroToken, "Beto Prueba EJEMPLO", null]);
const pista = (await asAnon("select public.arm_historial($1) as v", [otroToken])).rows[0].v;
ok("captura parcial: el nombre queda anotado, sin teléfono ni lead", pista.contacto.full_name === "Beto Prueba EJEMPLO" && pista.contacto.phone === null);
await asAnon("select public.arm_anotar_contacto($1,$2,$3)", [otroToken, null, "777-66-55"]);
const pista2 = (await asAnon("select public.arm_historial($1) as v", [otroToken])).rows[0].v;
ok("captura parcial: el teléfono completa la ficha del hilo", pista2.contacto.full_name === "Beto Prueba EJEMPLO" && pista2.contacto.phone === "7776655");
const leadsTrasPista = await row("select count(*)::int as v from public.embudo_leads");
ok("las anotaciones parciales NO crean leads", leadsTrasPista.v === 1);
await asAnon("select public.arm_anotar_contacto($1,$2,$3)", [otroToken, null, "12"]);
const pista3 = (await asAnon("select public.arm_historial($1) as v", [otroToken])).rows[0].v;
ok("teléfono imposible (2 dígitos) se descarta sin romper la ficha", pista3.contacto.phone === "7776655");

// ── Resumen ─────────────────────────────────────────────────────────────
console.log(`\n🧠 test-arm-sql: ${checks} comprobaciones correctas`);
