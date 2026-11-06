import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const sql = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const migration = sql("supabase/migrations/00062_mensajes_leidos_personal.sql");
const alignmentMigration = sql(
  "supabase/migrations/00063_mensajes_leidos_personal_alineacion.sql",
);
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
  await db.exec(alignmentMigration);

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
  const setRead = async (actor, aal, messageId, isRead, expectedIsRead = null) =>
    (await as(actor, aal, "select public.staff_set_message_read($1,$2,$3) as value", [
      messageId,
      isRead,
      expectedIsRead,
    ])).rows[0].value;
  const messageRow = (id) => row("select id, is_read from public.messages where id=$1", [id]);

  const unreadId = (
    await row(
      "insert into public.messages(name,email,subject,message,locale,is_read) values('Consulta EJEMPLO','consulta@test.invalid','info','Mensaje de ejemplo suficientemente largo','es',false) returning id",
    )
  ).id;
  const readId = (
    await row(
      "insert into public.messages(name,email,subject,message,locale,is_read) values('Leída EJEMPLO','leida@test.invalid','plans','Otra consulta de ejemplo suficientemente larga','es',true) returning id",
    )
  ).id;

  const snapshot = async () =>
    JSON.stringify((await db.query("select to_jsonb(m) as value from public.messages m order by m.id")).rows);
  const beforeSecondApply = await snapshot();
  await db.exec(migration);
  await db.exec(alignmentMigration);
  check("00062–00063 son idempotentes y no cambian mensajes al reaplicarse", (await snapshot()) === beforeSecondApply);

  const fn = await row(
    "select prosecdef, has_function_privilege('authenticated', oid, 'EXECUTE') as auth_exec, has_function_privilege('anon', oid, 'EXECUTE') as anon_exec from pg_proc where oid='public.staff_set_message_read(uuid,boolean,boolean)'::regprocedure",
  );
  check("la RPC es SECURITY DEFINER y solo authenticated puede invocarla", fn.prosecdef && fn.auth_exec && !fn.anon_exec);

  const policies = (await db.query(
    "select policyname, cmd, roles::text as roles from pg_policies where schemaname='public' and tablename='messages' order by policyname",
  )).rows;
  check(
    "solo quedan las políticas v1 de alta pública y lectura del personal",
    policies.length === 2 &&
      policies.some((p) => p.policyname === "messages_insert_public_v1" && p.cmd === "INSERT") &&
      policies.some((p) => p.policyname === "messages_read_staff_v1" && p.cmd === "SELECT"),
  );

  const grants = await row(
    `select has_table_privilege('anon','public.messages','INSERT') as anon_insert,
            has_table_privilege('anon','public.messages','SELECT') as anon_select,
            has_table_privilege('anon','public.messages','UPDATE') as anon_update,
            has_table_privilege('anon','public.messages','DELETE') as anon_delete,
            has_table_privilege('authenticated','public.messages','INSERT') as auth_insert,
            has_table_privilege('authenticated','public.messages','SELECT') as auth_select,
            has_table_privilege('authenticated','public.messages','UPDATE') as auth_update,
            has_table_privilege('authenticated','public.messages','DELETE') as auth_delete`,
  );
  check(
    "grants mínimos: alta pública, lectura authenticated y ninguna escritura directa",
    grants.anon_insert && !grants.anon_select && !grants.anon_update && !grants.anon_delete &&
      grants.auth_insert && grants.auth_select && !grants.auth_update && !grants.auth_delete,
  );

  await as(
    null,
    null,
    "insert into public.messages(name,email,subject,message,locale) values('Pública EJEMPLO','publica@test.invalid','info','Consulta pública de ejemplo con texto suficiente','es')",
    [],
    "anon",
  );
  const publicRow = await row("select is_read from public.messages where email='publica@test.invalid'");
  check("el formulario anónimo sigue insertando y nace no leído", publicRow.is_read === false);

  await denied(
    "un alta pública no puede nacer como leída",
    as(
      null,
      null,
      "insert into public.messages(name,email,message,is_read) values('Intrusa EJEMPLO','intrusa@test.invalid','Consulta de ejemplo suficientemente larga',true)",
      [],
      "anon",
    ),
    /row-level security/,
  );
  check("el alta rechazada no quedó guardada", !(await row("select id from public.messages where email='intrusa@test.invalid'")));

  await as(
    member,
    "aal1",
    "insert into public.messages(name,email,message) values('Cliente EJEMPLO','cliente-form@test.invalid','Consulta autenticada de ejemplo suficientemente larga')",
  );
  check("un cliente autenticado también puede enviar el formulario", !!(await row("select id from public.messages where email='cliente-form@test.invalid'")));

  const visibleCount = async (actor, aal, role) =>
    Number((await as(actor, aal, "select count(*)::int as total from public.messages", [], role)).rows[0].total);
  check("admin con MFA lee las consultas", (await visibleCount(admin, "aal2")) >= 4);
  check("caja con MFA lee las consultas", (await visibleCount(cashier, "aal2")) >= 4);
  check("entrenador no lee consultas", (await visibleCount(trainer, "aal2")) === 0);
  check("cliente no lee consultas", (await visibleCount(member, "aal1")) === 0);
  check("caja sin MFA no lee consultas", (await visibleCount(cashier, "aal1")) === 0);
  await denied("anónimo no puede seleccionar consultas", as(null, null, "select id from public.messages", [], "anon"), /permission denied/);

  const markedRead = await setRead(admin, "aal2", unreadId, true, false);
  check("admin con MFA marca leída y persiste", markedRead.changed && markedRead.previous_is_read === false && (await messageRow(unreadId)).is_read === true);

  const repeated = await setRead(cashier, "aal2", unreadId, true, false);
  check("repetir leída es idempotente aunque la pantalla estuviera vieja", !repeated.changed && repeated.is_read === true && repeated.previous_is_read === true);

  const markedUnread = await setRead(cashier, "aal2", unreadId, false, true);
  check("caja con MFA vuelve a marcar no leída y persiste", markedUnread.changed && (await messageRow(unreadId)).is_read === false);

  await denied(
    "un estado esperado viejo no pisa el cambio de otra persona",
    setRead(admin, "aal2", unreadId, true, true),
    /STALE_READ_STATE/,
  );
  check("tras STALE_READ_STATE sigue no leída", (await messageRow(unreadId)).is_read === false);

  await denied("un destino nulo se rechaza", setRead(admin, "aal2", unreadId, null, false), /INVALID_READ_STATE/);
  await denied(
    "una consulta inexistente devuelve NOT_FOUND",
    setRead(admin, "aal2", "00000000-0000-0000-0000-000000000000", true, false),
    /NOT_FOUND/,
  );

  await denied("entrenador con MFA no cambia el estado", setRead(trainer, "aal2", unreadId, true, false), /AUTH/);
  await denied("cliente no cambia el estado", setRead(member, "aal1", unreadId, true, false), /AUTH/);
  await denied("caja sin MFA no cambia el estado", setRead(cashier, "aal1", unreadId, true, false), /AUTH/);
  await denied("admin sin MFA no cambia el estado", setRead(admin, "aal1", unreadId, true, false), /AUTH/);
  await denied(
    "authenticated sin identidad no cambia el estado",
    as(null, null, "select public.staff_set_message_read($1,true,false)", [unreadId], "authenticated"),
    /AUTH/,
  );
  await denied(
    "anónimo ni siquiera puede ejecutar la RPC",
    as(null, null, "select public.staff_set_message_read($1,true,false)", [unreadId], "anon"),
    /permission denied/,
  );
  check("todos los rechazos dejaron la consulta no leída", (await messageRow(unreadId)).is_read === false);
  check("la consulta ya leída de ejemplo no fue tocada", (await messageRow(readId)).is_read === true);

  for (const [label, actor] of [["admin", admin], ["caja", cashier], ["cliente", member]]) {
    await denied(
      `${label} no actualiza messages directo`,
      as(actor, "aal2", "update public.messages set is_read=true where id=$1", [unreadId]),
      /permission denied/,
    );
  }
  await denied(
    "admin no borra messages directo",
    as(admin, "aal2", "delete from public.messages where id=$1", [unreadId]),
    /permission denied/,
  );
  await denied(
    "anónimo no actualiza messages directo",
    as(null, null, "update public.messages set is_read=true where id=$1", [unreadId], "anon"),
    /permission denied/,
  );
  check("tras los intentos directos la consulta sigue no leída", (await messageRow(unreadId)).is_read === false);
} finally {
  await db.close();
}

console.log(`\n🎉 Mensajes leídos del personal: ${checks} comprobaciones pasaron (PGlite; sin SQL remoto).`);
