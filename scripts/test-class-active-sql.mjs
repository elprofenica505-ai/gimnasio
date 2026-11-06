import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const sql = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const migration = sql("supabase/migrations/00064_disciplinas_activas.sql");
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
  const member = await makeUser("cliente", null);
  const secondMember = await makeUser("cliente2", null);
  const cancelledMember = await makeUser("cliente3", null);

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
  const setActive = async (actor, aal, classId, isActive, expectedIsActive = null) =>
    (await as(actor, aal, "select public.admin_set_class_active($1,$2,$3) as value", [
      classId,
      isActive,
      expectedIsActive,
    ])).rows[0].value;
  const book = async (actor, sessionId) =>
    (await as(actor, "aal1", "select public.book_session($1) as value", [sessionId])).rows[0].value;
  const classRow = (id) => row("select to_jsonb(c) as value from public.classes c where id=$1", [id]).then((r) => r?.value);
  const bookingRow = (sessionId, userId) =>
    row("select to_jsonb(b) as value from public.bookings b where session_id=$1 and user_id=$2", [sessionId, userId]).then((r) => r?.value);

  const activeClassId = "cls_op03_test";
  const inactiveClassId = "cls_op03_inactive";
  const activeSessionId = "ses_op03_future";
  const inactiveSessionId = "ses_op03_inactive_future";

  await db.exec(`
    insert into public.classes(id, slug, name_es, name_en, description_es, description_en, intensity, duration_min, capacity, color, sort_order, is_active)
    values
      ('${activeClassId}', 'op03-test', 'Disciplina EJEMPLO', 'Example discipline', '', '', 'medium', 60, 10, '#d81a22', 90, true),
      ('${inactiveClassId}', 'op03-inactive', 'Inactiva EJEMPLO', 'Inactive example', '', '', 'low', 45, 10, '#333333', 91, false);
    insert into public.sessions(id, class_id, starts_at, ends_at, capacity, room, status)
    values
      ('${activeSessionId}', '${activeClassId}', now() + interval '2 days', now() + interval '2 days 1 hour', 10, 'Sala EJEMPLO', 'scheduled'),
      ('${inactiveSessionId}', '${inactiveClassId}', now() + interval '3 days', now() + interval '3 days 1 hour', 10, 'Sala EJEMPLO', 'scheduled');
  `);

  const existingBooking = await book(member, activeSessionId);
  check("con la disciplina activa, un cliente puede reservar como antes", existingBooking.session_id === activeSessionId && existingBooking.status === "confirmed");

  await db.query(
    "insert into public.bookings(session_id, user_id, status, cancelled_at) values($1,$2,'cancelled',now())",
    [activeSessionId, cancelledMember],
  );

  const dataSnapshot = async () =>
    JSON.stringify({
      classes: (await db.query("select to_jsonb(c) as value from public.classes c order by c.id")).rows,
      sessions: (await db.query("select to_jsonb(s) as value from public.sessions s order by s.id")).rows,
      bookings: (await db.query("select to_jsonb(b) as value from public.bookings b order by b.session_id, b.user_id")).rows,
    });
  const beforeSecondApply = await dataSnapshot();
  await db.exec(migration);
  check("00064 es idempotente y reaplicarla no cambia datos", (await dataSnapshot()) === beforeSecondApply);

  const functions = (await db.query(
    `select proname, prosecdef, coalesce(array_to_string(proconfig, ','), '') as config,
            pg_get_functiondef(oid) as definition,
            has_function_privilege('authenticated', oid, 'EXECUTE') as auth_exec,
            has_function_privilege('anon', oid, 'EXECUTE') as anon_exec
       from pg_proc
      where oid in ('public.admin_set_class_active(text,boolean,boolean)'::regprocedure,
                    'public.book_session(text)'::regprocedure)
      order by proname`,
  )).rows;
  const adminFn = functions.find((fn) => fn.proname === "admin_set_class_active");
  const bookFn = functions.find((fn) => fn.proname === "book_session");
  check(
    "admin_set_class_active es acotada, con MFA por is_admin y solo para authenticated",
    adminFn?.prosecdef && adminFn.auth_exec && !adminFn.anon_exec &&
      adminFn.config.includes("search_path=public, pg_temp") &&
      adminFn.config.includes("lock_timeout=5s") &&
      adminFn.definition.includes("public.is_admin()") &&
      adminFn.definition.includes("for update") &&
      adminFn.definition.includes("STALE_ACTIVE_STATE"),
  );
  check(
    "book_session conserva su superficie y agrega la guarda FOR SHARE + CLASS_INACTIVE",
    bookFn?.prosecdef && bookFn.auth_exec && !bookFn.anon_exec &&
      bookFn.definition.includes("for share") &&
      bookFn.definition.includes("CLASS_INACTIVE") &&
      bookFn.definition.includes("ALREADY_BOOKED") &&
      bookFn.definition.includes("FULL") &&
      bookFn.definition.includes("LIMIT"),
  );

  const policies = (await db.query(
    "select policyname, cmd from pg_policies where schemaname='public' and tablename='classes' order by policyname",
  )).rows;
  check(
    "classes conserva solo lectura pública y ninguna política de escritura",
    policies.length === 1 && policies[0].policyname === "classes_read_public_v1" && policies[0].cmd === "SELECT",
  );

  const grants = await row(
    `select has_table_privilege('anon','public.classes','SELECT') as anon_select,
            has_table_privilege('anon','public.classes','INSERT,UPDATE,DELETE') as anon_write,
            has_table_privilege('authenticated','public.classes','SELECT') as auth_select,
            has_table_privilege('authenticated','public.classes','INSERT') as auth_insert,
            has_table_privilege('authenticated','public.classes','UPDATE') as auth_update,
            has_table_privilege('authenticated','public.classes','DELETE') as auth_delete`,
  );
  check(
    "grants mínimos: lectura para anon/authenticated y ninguna escritura directa",
    grants.anon_select && !grants.anon_write && grants.auth_select &&
      !grants.auth_insert && !grants.auth_update && !grants.auth_delete,
  );

  await denied(
    "una sesión futura de una disciplina ya inactiva no acepta reservas",
    book(secondMember, inactiveSessionId),
    /CLASS_INACTIVE/,
  );
  check("el rechazo CLASS_INACTIVE no creó ninguna reserva", !(await bookingRow(inactiveSessionId, secondMember)));

  const activated = await setActive(admin, "aal2", inactiveClassId, true, false);
  check("admin con MFA reactiva y persiste", activated.changed && activated.previous_is_active === false && (await classRow(inactiveClassId)).is_active === true);
  const inactiveNowBooked = await book(secondMember, inactiveSessionId);
  check("al reactivar, la sesión programada vuelve a aceptar reservas", inactiveNowBooked.status === "confirmed" && !!(await bookingRow(inactiveSessionId, secondMember)));

  const repeated = await setActive(admin, "aal2", inactiveClassId, true, false);
  check("repetir el estado ya guardado es idempotente", !repeated.changed && repeated.previous_is_active === true && repeated.is_active === true);

  await denied(
    "un estado esperado viejo no pisa el cambio de otra persona",
    setActive(admin, "aal2", inactiveClassId, false, false),
    /STALE_ACTIVE_STATE/,
  );
  check("tras STALE_ACTIVE_STATE la disciplina sigue activa", (await classRow(inactiveClassId)).is_active === true);

  const beforeDeactivate = await dataSnapshot();
  const deactivated = await setActive(admin, "aal2", activeClassId, false, true);
  check("admin con MFA desactiva y persiste", deactivated.changed && deactivated.previous_is_active === true && (await classRow(activeClassId)).is_active === false);

  const afterDeactivate = JSON.parse(await dataSnapshot());
  const beforeParsed = JSON.parse(beforeDeactivate);
  const withoutActive = (rows) => rows.map(({ value }) => ({ ...value, is_active: undefined }));
  check(
    "desactivar solo cambia is_active: sesiones y reservas quedan byte a byte iguales",
    JSON.stringify(withoutActive(afterDeactivate.classes)) === JSON.stringify(withoutActive(beforeParsed.classes)) &&
      JSON.stringify(afterDeactivate.sessions) === JSON.stringify(beforeParsed.sessions) &&
      JSON.stringify(afterDeactivate.bookings) === JSON.stringify(beforeParsed.bookings),
  );

  const publicRows = (await as(null, null, "select id, is_active from public.classes where id=$1", [activeClassId], "anon")).rows;
  check("la fila desactivada sigue resolviéndose para reservas ya hechas", publicRows.length === 1 && publicRows[0].is_active === false);
  check(
    "la reserva previa y su sesión siguen intactas tras desactivar",
    (await bookingRow(activeSessionId, member)).status === "confirmed" &&
      (await row("select status::text as status from public.sessions where id=$1", [activeSessionId])).status === "scheduled",
  );

  await denied(
    "tras desactivar no entran reservas nuevas",
    book(secondMember, activeSessionId),
    /CLASS_INACTIVE/,
  );
  check("la reserva nueva rechazada no quedó creada", !(await bookingRow(activeSessionId, secondMember)));

  await denied(
    "tras desactivar tampoco se revive una reserva cancelada",
    book(cancelledMember, activeSessionId),
    /CLASS_INACTIVE/,
  );
  const cancelledAfterReject = await bookingRow(activeSessionId, cancelledMember);
  check("la reserva cancelada queda cancelada y sin tocar", cancelledAfterReject.status === "cancelled" && !!cancelledAfterReject.cancelled_at);

  await denied("caja con MFA no escribe catálogos", setActive(cashier, "aal2", activeClassId, true, false), /AUTH/);
  await denied("entrenador con MFA no cambia disciplinas", setActive(trainer, "aal2", activeClassId, true, false), /AUTH/);
  await denied("cliente no cambia disciplinas", setActive(member, "aal1", activeClassId, true, false), /AUTH/);
  await denied("admin sin MFA no cambia disciplinas", setActive(admin, "aal1", activeClassId, true, false), /AUTH/);
  await denied(
    "authenticated sin identidad no cambia disciplinas",
    as(null, null, "select public.admin_set_class_active($1,true,false)", [activeClassId], "authenticated"),
    /AUTH/,
  );
  await denied(
    "anónimo ni siquiera puede ejecutar la RPC",
    as(null, null, "select public.admin_set_class_active($1,true,false)", [activeClassId], "anon"),
    /permission denied/,
  );
  check("todos los rechazos por rol dejaron la disciplina desactivada", (await classRow(activeClassId)).is_active === false);

  await denied("un destino nulo se rechaza", setActive(admin, "aal2", activeClassId, null, false), /INVALID_ACTIVE_STATE/);
  await denied("un ID vacío se rechaza", setActive(admin, "aal2", "", true, false), /INVALID_ACTIVE_STATE/);
  await denied("un ID con espacios se rechaza", setActive(admin, "aal2", "cls con espacios", true, false), /INVALID_ACTIVE_STATE/);
  await denied("una disciplina inexistente devuelve NOT_FOUND", setActive(admin, "aal2", "cls_no_existe", true, false), /NOT_FOUND/);

  for (const [label, actor] of [["admin", admin], ["caja", cashier], ["cliente", member]]) {
    await denied(
      `${label} no actualiza classes directo`,
      as(actor, "aal2", "update public.classes set is_active=true where id=$1", [activeClassId]),
      /permission denied/,
    );
  }
  await denied(
    "admin no borra classes directo",
    as(admin, "aal2", "delete from public.classes where id=$1", [activeClassId]),
    /permission denied/,
  );
  await denied(
    "anónimo no actualiza classes directo",
    as(null, null, "update public.classes set is_active=true where id=$1", [activeClassId], "anon"),
    /permission denied/,
  );
  check("tras los intentos directos la disciplina sigue desactivada", (await classRow(activeClassId)).is_active === false);

  const reactivated = await setActive(admin, "aal2", activeClassId, true, false);
  check("admin con MFA vuelve a activarla y persiste", reactivated.changed && (await classRow(activeClassId)).is_active === true);
  const revived = await book(cancelledMember, activeSessionId);
  check("al reactivar se conserva el comportamiento histórico de revivir una cancelada", revived.status === "confirmed" && (await bookingRow(activeSessionId, cancelledMember)).status === "confirmed");
} finally {
  await db.close();
}

console.log(`\n🎉 Disciplinas activas OP-03: ${checks} comprobaciones pasaron (PGlite; sin SQL remoto).`);
