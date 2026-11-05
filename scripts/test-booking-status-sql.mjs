import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const sql = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const migration = sql("supabase/migrations/00061_estado_reservas_personal.sql");
const db = new PGlite();
let checks = 0;

function check(label, value) {
  assert.ok(value, label);
  checks += 1;
  console.log(`✅ ${label}`);
}

try {
  await db.exec(`create schema auth; create role anon nologin; create role authenticated nologin;
    create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}'::jsonb, created_at timestamptz default now());
    create table auth.current_user(id uuid, aal text);
    create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
    create function auth.jwt() returns jsonb language sql stable as $$select jsonb_build_object('aal', aal) from auth.current_user limit 1$$;
    grant usage on schema auth to anon, authenticated;
    grant select on auth.current_user to anon, authenticated;`);

  for (const file of [
    "supabase/migrations/00001_schema.sql",
    "tests/fixtures/base-catalog.sql",
    "tests/fixtures/finance-bank-accounts.sql",
    "supabase/migrations/00012_profiles_self_read.sql",
    "supabase/migrations/00020_clients_crm.sql",
    "supabase/migrations/00022_crm_finance_compat.sql",
    "supabase/migrations/00023_finance_read_bank_accounts.sql",
    "supabase/migrations/00024_finance_movements.sql",
    "supabase/migrations/00025_account_assigned_plan.sql",
    "supabase/migrations/00026_booking_read_policy.sql",
    "supabase/migrations/00027_client_finance_read.sql",
    "supabase/migrations/00028_debts_payments.sql",
    "supabase/migrations/00029_cash_change.sql",
    "supabase/migrations/00030_access_hardening.sql",
  ]) {
    await db.exec(sql(file));
  }

  // Estado previo a 00032/00033: crm_is_staff con AAL2 de 00031.
  await db.exec(`create or replace function public.crm_is_staff()
    returns boolean language sql stable security definer set search_path = public, pg_temp as $$
      select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
         and exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff'));
    $$;
    revoke all on function public.crm_is_staff() from public, anon;
    grant execute on function public.crm_is_staff() to authenticated;`);
  await db.exec(sql("supabase/migrations/00032_mfa_is_staff_y_privilegios_anon.sql"));
  await db.exec(sql("supabase/migrations/00033_roles_fase_a.sql"));
  await db.exec(sql("supabase/migrations/00034_roles_fase_b.sql"));
  await db.exec(migration);

  const row = async (query, args = []) => (await db.query(query, args)).rows[0];
  const makeUser = async (name, role) => {
    const id = (
      await row("insert into auth.users(email, raw_user_meta_data) values($1,$2) returning id", [
        `${name}@test.invalid`,
        JSON.stringify({ full_name: `EJEMPLO ${name}` }),
      ])
    ).id;
    if (role) await db.query("update public.profiles set role=$2::public.user_role where id=$1", [id, role]);
    return id;
  };

  const admin = await makeUser("admin", "admin");
  const cashier = await makeUser("caja", "cashier");
  const trainer = await makeUser("entrenador", "trainer");
  const member = await makeUser("cliente-a", null);
  const other = await makeUser("cliente-b", null);

  async function as(actor, aal, query, args = [], role = actor ? "authenticated" : "anon") {
    await db.exec("reset role; delete from auth.current_user");
    if (actor) await db.query("insert into auth.current_user values($1,$2)", [actor, aal]);
    await db.exec(`set role ${role}`);
    try {
      return await db.query(query, args);
    } finally {
      await db.exec("reset role; delete from auth.current_user");
    }
  }

  const denied = async (label, promise, pattern) => {
    await assert.rejects(promise, pattern, label);
    check(label, true);
  };
  const setStatus = async (actor, aal, bookingId, status, expectedStatus = null) =>
    (await as(actor, aal, "select public.staff_set_booking_status($1,$2,$3) as value", [
      bookingId,
      status,
      expectedStatus,
    ])).rows[0].value;
  const bookingRow = (id) => row("select id, session_id, status::text as status, cancelled_at from public.bookings where id=$1", [id]);
  const occupancy = async (sessionId) =>
    Number((await row("select booked_count from public.session_occupancy where session_id=$1", [sessionId]))?.booked_count ?? 0);

  const classId = (await row("select id from public.classes order by id limit 1")).id;
  async function makeSession(id, { starts = "now() + interval '2 days'", ends = "now() + interval '2 days 1 hour'", capacity = 2, status = "scheduled" } = {}) {
    await db.query(
      `insert into public.sessions(id, class_id, starts_at, ends_at, capacity, status)
       values($1,$2,${starts},${ends},$3,$4::public.session_status)`,
      [id, classId, capacity, status],
    );
  }
  async function makeBooking(sessionId, userId, status = "confirmed", cancelledAt = null) {
    return (
      await row(
        "insert into public.bookings(session_id,user_id,status,cancelled_at) values($1,$2,$3::public.booking_status,$4) returning id",
        [sessionId, userId, status, cancelledAt],
      )
    ).id;
  }

  await makeSession("op01-main", { capacity: 2 });
  const mainBooking = await makeBooking("op01-main", member);
  const snapshot = async () =>
    JSON.stringify((await db.query("select to_jsonb(b) as value from public.bookings b order by b.id")).rows);
  const beforeSecondApply = await snapshot();
  await db.exec(migration);
  check("00061 es idempotente y no cambia reservas al reaplicarse", (await snapshot()) === beforeSecondApply);

  const fn = await row(
    "select prosecdef, has_function_privilege('authenticated', oid, 'EXECUTE') as auth_exec, has_function_privilege('anon', oid, 'EXECUTE') as anon_exec from pg_proc where oid='public.staff_set_booking_status(uuid,text,text)'::regprocedure",
  );
  check("la RPC es SECURITY DEFINER y solo authenticated puede invocarla", fn.prosecdef && fn.auth_exec && !fn.anon_exec);
  const grants = await row(
    `select has_table_privilege('authenticated','public.bookings','SELECT') as can_select,
            has_table_privilege('authenticated','public.bookings','INSERT') as can_insert,
            has_table_privilege('authenticated','public.bookings','UPDATE') as can_update,
            has_table_privilege('authenticated','public.bookings','DELETE') as can_delete,
            has_table_privilege('anon','public.bookings','SELECT') as anon_select`,
  );
  check("bookings queda de solo lectura directa para authenticated", grants.can_select && !grants.can_insert && !grants.can_update && !grants.can_delete && !grants.anon_select);

  const attended = await setStatus(admin, "aal2", mainBooking, "attended", "confirmed");
  check("admin con MFA marca asistida y la fila persiste", attended.changed && attended.previous_status === "confirmed" && (await bookingRow(mainBooking)).status === "attended");
  check("confirmed → attended conserva el cupo ocupado", (await occupancy("op01-main")) === 1);

  const repeated = await setStatus(cashier, "aal2", mainBooking, "attended", "confirmed");
  check("repetir el estado final es idempotente aunque la pantalla estuviera vieja", !repeated.changed && repeated.status === "attended" && repeated.previous_status === "attended");

  const noShow = await setStatus(cashier, "aal2", mainBooking, "no_show", "attended");
  check("caja con MFA corrige asistida → ausente y libera el cupo", noShow.changed && (await occupancy("op01-main")) === 0);

  await denied(
    "un estado esperado viejo no pisa el cambio de otra persona",
    setStatus(admin, "aal2", mainBooking, "attended", "confirmed"),
    /STALE_STATUS/,
  );
  check("tras STALE_STATUS la reserva sigue ausente", (await bookingRow(mainBooking)).status === "no_show");

  await makeSession("op01-full", { capacity: 1 });
  const fullNoShow = await makeBooking("op01-full", member, "no_show");
  const fullConfirmed = await makeBooking("op01-full", other, "confirmed");
  await denied(
    "volver a asistida no sobrevende un cupo ya ocupado",
    setStatus(cashier, "aal2", fullNoShow, "attended", "no_show"),
    /FULL/,
  );
  check("FULL no cambia la reserva ausente", (await bookingRow(fullNoShow)).status === "no_show" && (await occupancy("op01-full")) === 1);

  const cancelled = await setStatus(admin, "aal2", fullConfirmed, "cancelled", "confirmed");
  const cancelledRow = await bookingRow(fullConfirmed);
  check("cancelación administrativa futura libera el cupo y fija cancelled_at", cancelled.changed && cancelledRow.status === "cancelled" && !!cancelledRow.cancelled_at && (await occupancy("op01-full")) === 0);
  const backToAttended = await setStatus(cashier, "aal2", fullNoShow, "attended", "no_show");
  check("con el lugar libre, ausente → asistida vuelve a ocupar exactamente uno", backToAttended.changed && (await occupancy("op01-full")) === 1);

  await denied(
    "cancelada es terminal desde la RPC del personal",
    setStatus(admin, "aal2", fullConfirmed, "attended", "cancelled"),
    /INVALID_TRANSITION/,
  );
  check("el intento sobre cancelada no borra cancelled_at", String((await bookingRow(fullConfirmed)).cancelled_at) === String(cancelledRow.cancelled_at));

  await denied("confirmed no es un destino administrativo", setStatus(admin, "aal2", mainBooking, "confirmed", "no_show"), /INVALID_STATUS/);
  await denied("un estado inventado se rechaza", setStatus(admin, "aal2", mainBooking, "inventado", "no_show"), /INVALID_STATUS/);
  await denied("un estado esperado inventado se rechaza", setStatus(admin, "aal2", mainBooking, "attended", "inventado"), /INVALID_STATUS/);
  await denied("una reserva inexistente devuelve NOT_FOUND", setStatus(admin, "aal2", "00000000-0000-0000-0000-000000000000", "attended", "confirmed"), /NOT_FOUND/);

  await makeSession("op01-ended", {
    starts: "now() - interval '2 hours'",
    ends: "now() - interval '1 hour'",
    capacity: 2,
  });
  const endedBooking = await makeBooking("op01-ended", member);
  await denied(
    "una clase terminada no se cancela hacia atrás",
    setStatus(admin, "aal2", endedBooking, "cancelled", "confirmed"),
    /SESSION_ENDED/,
  );
  const endedNoShow = await setStatus(cashier, "aal2", endedBooking, "no_show", "confirmed");
  check("la misma clase terminada sí puede cerrarse como ausente", endedNoShow.changed && (await bookingRow(endedBooking)).status === "no_show");

  await makeSession("op01-cancelled-session", { capacity: 2, status: "cancelled" });
  const cancelledSessionBooking = await makeBooking("op01-cancelled-session", member);
  await denied(
    "una sesión cancelada por el gimnasio no puede marcarse asistida",
    setStatus(admin, "aal2", cancelledSessionBooking, "attended", "confirmed"),
    /SESSION_CANCELLED/,
  );
  const cancelledSessionResult = await setStatus(admin, "aal2", cancelledSessionBooking, "cancelled", "confirmed");
  check("su reserva sí puede quedar cancelada", cancelledSessionResult.changed && (await bookingRow(cancelledSessionBooking)).status === "cancelled");

  await makeSession("op01-auth", { capacity: 2 });
  const authBooking = await makeBooking("op01-auth", member);
  await denied("entrenador con MFA no cambia reservas", setStatus(trainer, "aal2", authBooking, "attended", "confirmed"), /AUTH/);
  await denied("cliente no cambia reservas ajenas ni propias por esta RPC", setStatus(member, "aal2", authBooking, "attended", "confirmed"), /AUTH/);
  await denied("caja sin MFA no cambia reservas", setStatus(cashier, "aal1", authBooking, "attended", "confirmed"), /AUTH/);
  await denied("admin sin MFA no cambia reservas", setStatus(admin, "aal1", authBooking, "attended", "confirmed"), /AUTH/);
  await denied(
    "authenticated sin identidad no cambia reservas",
    as(null, null, "select public.staff_set_booking_status($1,'attended','confirmed')", [authBooking], "authenticated"),
    /AUTH/,
  );
  await denied(
    "anónimo ni siquiera puede ejecutar la RPC",
    as(null, null, "select public.staff_set_booking_status($1,'attended','confirmed')", [authBooking], "anon"),
    /permission denied/,
  );
  check("todos los rechazos de autorización dejaron la reserva confirmada", (await bookingRow(authBooking)).status === "confirmed");

  for (const [label, actor] of [["admin", admin], ["caja", cashier], ["cliente", member]]) {
    await denied(
      `${label} no actualiza bookings directo`,
      as(actor, "aal2", "update public.bookings set status='cancelled' where id=$1", [authBooking]),
      /permission denied/,
    );
  }
  await denied(
    "caja no inserta bookings directo",
    as(cashier, "aal2", "insert into public.bookings(session_id,user_id) values('op01-auth',$1)", [other]),
    /permission denied/,
  );
  await denied(
    "admin no borra bookings directo",
    as(admin, "aal2", "delete from public.bookings where id=$1", [authBooking]),
    /permission denied/,
  );

  await makeSession("op01-member-flow", { capacity: 2 });
  const booked = (await as(member, "aal1", "select public.book_session('op01-member-flow') as value")).rows[0].value;
  check("book_session sigue funcionando tras cerrar la escritura directa", booked.status === "confirmed" && (await occupancy("op01-member-flow")) === 1);
  check("el cliente sigue leyendo su reserva", (await as(member, "aal1", "select id from public.bookings where id=$1", [booked.id])).rows.length === 1);
  check("caja sigue leyendo la reserva para Operación", (await as(cashier, "aal2", "select id from public.bookings where id=$1", [booked.id])).rows.length === 1);
  check("entrenador no lee la reserva ajena", (await as(trainer, "aal2", "select id from public.bookings where id=$1", [booked.id])).rows.length === 0);
  const ownCancelled = (await as(member, "aal1", "select public.cancel_booking($1) as value", [booked.id])).rows[0].value;
  check("cancel_booking propio sigue liberando el cupo", ownCancelled.status === "cancelled" && (await occupancy("op01-member-flow")) === 0);
} finally {
  await db.close();
}

console.log(`\n🎉 Estado administrativo de reservas: ${checks} comprobaciones pasaron (PGlite; sin SQL remoto).`);
