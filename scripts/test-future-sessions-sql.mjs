import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const sql = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const migration = sql("supabase/migrations/00065_generar_sesiones_futuras.sql");
const coachesCompatMigration = sql(
  "supabase/migrations/00066_coaches_specialties_generador.sql",
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
  await db.exec(sql("supabase/migrations/00064_disciplinas_activas.sql"));
  await db.exec(migration);
  await db.exec(coachesCompatMigration);

  const row = async (query, args = []) => (await db.query(query, args)).rows[0];
  const makeUser = async (name, role) => {
    const id = (
      await row("insert into auth.users(email, raw_user_meta_data) values($1,$2) returning id", [
        `${name}@test.invalid`,
        JSON.stringify({ full_name: `EJEMPLO ${name}` }),
      ])
    ).id;
    if (role) {
      await db.query("update public.profiles set role=$2::public.user_role where id=$1", [id, role]);
    }
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
  const generate = async (actor, aal, weeks = 4) =>
    (await as(actor, aal, "select public.admin_generate_future_sessions($1) as value", [weeks])).rows[0].value;
  const dataSnapshot = async () =>
    JSON.stringify({
      classes: (await db.query("select to_jsonb(c) as value from public.classes c order by c.id")).rows,
      sessions: (await db.query("select to_jsonb(s) as value from public.sessions s order by s.id")).rows,
      bookings: (await db.query("select to_jsonb(b) as value from public.bookings b order by b.session_id, b.user_id")).rows,
    });
  const sessionIds = async () =>
    new Set((await db.query("select id from public.sessions order by id")).rows.map((r) => r.id));
  const newSessionCount = async (before) => {
    const after = await sessionIds();
    return [...after].filter((id) => !before.has(id)).length;
  };
  const scheduledInRange = async (result) =>
    Number((
      await row(
        `select count(*)::int as n
           from public.sessions
          where status = 'scheduled'
            and starts_at >= ($1::date::timestamp at time zone 'America/Managua')
            and starts_at < (($2::date + 1)::timestamp at time zone 'America/Managua')`,
        [result.first_monday, result.last_sunday],
      )
    ).n);
  const weeklyCounts = async (result) =>
    (await db.query(
      `select date_trunc('week', (starts_at at time zone 'America/Managua'))::date::text as monday,
              count(*)::int as n
         from public.sessions
        where status = 'scheduled'
          and starts_at >= ($1::date::timestamp at time zone 'America/Managua')
          and starts_at < (($2::date + 1)::timestamp at time zone 'America/Managua')
        group by monday
        order by monday`,
      [result.first_monday, result.last_sunday],
    )).rows;

  const beforeSecondApply = await dataSnapshot();
  await db.exec(migration);
  check("00065 es idempotente y reaplicarla no cambia datos", (await dataSnapshot()) === beforeSecondApply);

  const coachesSnapshot = async () =>
    JSON.stringify(
      (await db.query("select to_jsonb(c) as value from public.coaches c order by c.id")).rows,
    );
  const coachesBeforeCompat = await coachesSnapshot();
  await db.exec(coachesCompatMigration);
  check(
    "00066 es idempotente en el esquema canónico y no cambia entrenadores",
    (await coachesSnapshot()) === coachesBeforeCompat &&
      (await dataSnapshot()) === beforeSecondApply,
  );

  // La plantilla base ya no trae la grilla incrustada en la función (los
  // datos del gimnasio anterior se desarmaron): la grilla vive en
  // class_schedule_slots y 00072 la carga y pasa el generador a leerla de
  // la tabla, igual que en la cadena real de migraciones.
  await db.exec(sql("supabase/migrations/00072_grilla_horarios.sql"));

  const functions = (await db.query(
    `select proname, prosecdef, coalesce(array_to_string(proconfig, ','), '') as config,
            pg_get_functiondef(oid) as definition,
            has_function_privilege('authenticated', oid, 'EXECUTE') as auth_exec,
            has_function_privilege('anon', oid, 'EXECUTE') as anon_exec
       from pg_proc
      where oid in ('public.admin_generate_future_sessions(integer)'::regprocedure,
                    'public.generate_week_sessions(date)'::regprocedure)
      order by proname`,
  )).rows;
  const wrapper = functions.find((fn) => fn.proname === "admin_generate_future_sessions");
  const generator = functions.find((fn) => fn.proname === "generate_week_sessions");
  check(
    "la RPC nueva es acotada, exige is_admin/MFA, reutiliza la grilla y ordena concurrencia",
    wrapper?.prosecdef && wrapper.auth_exec && !wrapper.anon_exec &&
      wrapper.config.includes("search_path=public, pg_temp") &&
      wrapper.config.includes("lock_timeout=5s") &&
      wrapper.definition.includes("public.is_admin()") &&
      wrapper.definition.includes("pg_advisory_xact_lock") &&
      wrapper.definition.includes("public.generate_week_sessions") &&
      wrapper.definition.includes("INVALID_FUTURE_WEEKS"),
  );
  // Modelo real desde 00072: la función es definer y queda cerrada a anon,
  // pero authenticated sí puede EJECUTARLA; lo que la blinda es su guardia
  // interna (sólo admin/staff) y los rechazos conductuales de más abajo.
  check(
    "generate_week_sessions es definer, cerrada a anon y con guardia interna de staff",
    generator?.prosecdef && !generator.anon_exec && generator.auth_exec &&
      generator.definition.includes("AUTH: sólo el staff puede generar horarios"),
  );

  const classesAndBookingsBefore = JSON.stringify({
    classes: JSON.parse(await dataSnapshot()).classes,
    bookings: JSON.parse(await dataSnapshot()).bookings,
  });
  const idsBeforeFirst = await sessionIds();
  const first = await generate(admin, "aal2", 4);
  check(
    "admin con MFA genera 4 semanas completas desde el próximo lunes",
    first.weeks === 4 &&
      first.created_count === (await newSessionCount(idsBeforeFirst)) &&
      first.scheduled_count === (await scheduledInRange(first)) &&
      first.scheduled_count === 36,
  );
  const firstWeeks = await weeklyCounts(first);
  check(
    "cada semana futura queda con las 9 sesiones de la grilla vigente",
    firstWeeks.length === 4 && firstWeeks.every((week) => week.n === 9),
  );
  const firstRange = await row(
    `select extract(isodow from $1::date)::int as first_dow,
            ($2::date - $1::date) as span_days,
            $1::date > (now() at time zone 'America/Managua')::date as starts_future`,
    [first.first_monday, first.last_sunday],
  );
  check(
    "el rango confirmado empieza un lunes futuro y termina el domingo de la cuarta semana",
    firstRange.first_dow === 1 && firstRange.span_days === 27 && firstRange.starts_future,
  );
  check(
    "generar no cambia disciplinas ni reservas existentes",
    JSON.stringify({
      classes: JSON.parse(await dataSnapshot()).classes,
      bookings: JSON.parse(await dataSnapshot()).bookings,
    }) === classesAndBookingsBefore,
  );

  const duplicateGroups = await row(
    `select count(*)::int as n
       from (
         select class_id, starts_at
           from public.sessions
          group by class_id, starts_at
         having count(*) > 1
       ) duplicates`,
  );
  check("la generación no duplica disciplina y horario", duplicateGroups.n === 0);

  const beforeRepeat = await dataSnapshot();
  const repeated = await generate(admin, "aal2", 4);
  check(
    "repetir la generación es idempotente y no toca ninguna fila",
    repeated.created_count === 0 && repeated.scheduled_count === 36 &&
      (await dataSnapshot()) === beforeRepeat,
  );

  await denied("cero semanas se rechaza", generate(admin, "aal2", 0), /INVALID_FUTURE_WEEKS/);
  await denied("nueve semanas se rechaza", generate(admin, "aal2", 9), /INVALID_FUTURE_WEEKS/);
  await denied("semanas nulas se rechazan", generate(admin, "aal2", null), /INVALID_FUTURE_WEEKS/);
  await denied("caja con MFA no genera sesiones", generate(cashier, "aal2", 4), /AUTH/);
  await denied("entrenador con MFA no genera sesiones", generate(trainer, "aal2", 4), /AUTH/);
  await denied("cliente no genera sesiones", generate(member, "aal1", 4), /AUTH/);
  await denied("admin sin MFA no genera sesiones", generate(admin, "aal1", 4), /AUTH/);
  await denied(
    "authenticated sin identidad no genera sesiones",
    as(null, null, "select public.admin_generate_future_sessions(4)", [], "authenticated"),
    /AUTH/,
  );
  await denied(
    "anónimo ni siquiera puede ejecutar la RPC",
    as(null, null, "select public.admin_generate_future_sessions(4)", [], "anon"),
    /permission denied/,
  );
  await denied(
    "cliente no puede usar el generador directo: la guardia interna lo rechaza",
    as(
      member,
      "aal2",
      "select public.generate_week_sessions(((now() at time zone 'America/Managua')::date + 28))",
    ),
    /AUTH/,
  );
  await denied(
    "anónimo no puede usar el generador directo",
    as(
      null,
      null,
      "select public.generate_week_sessions(((now() at time zone 'America/Managua')::date + 28))",
      [],
      "anon",
    ),
    /permission denied/,
  );
  check("todos los rechazos dejaron las sesiones iguales", (await dataSnapshot()) === beforeRepeat);

  await db.query("update public.classes set is_active=false where slug='boxeo'");
  const beforeInactive = await dataSnapshot();
  const inactive = await generate(admin, "aal2", 8);
  check(
    "con Boxeo desactivado no se crean sesiones nuevas de la grilla",
    inactive.created_count === 0 && inactive.scheduled_count === 36 &&
      (await dataSnapshot()) === beforeInactive,
  );

  await db.query("update public.classes set is_active=true where slug='boxeo'");
  const idsBeforeEight = await sessionIds();
  const eight = await generate(admin, "aal2", 8);
  const eightWeeks = await weeklyCounts(eight);
  check(
    "al reactivar, la misma acción completa las 8 semanas sin duplicar",
    eight.created_count === (await newSessionCount(idsBeforeEight)) &&
      eight.created_count === 36 &&
      eight.scheduled_count === 72 &&
      eightWeeks.length === 8 &&
      eightWeeks.every((week) => week.n === 9),
  );

  const generatedShape = await row(
    `select count(*)::int as total,
            count(*) filter (
              where c.slug = 'boxeo'
                and s.room = 'Área de boxeo'
                and s.capacity = c.capacity
                and s.ends_at = s.starts_at + make_interval(mins => c.duration_min)
            )::int as valid
       from public.sessions s
       join public.classes c on c.id = s.class_id
      where s.starts_at >= ($1::date::timestamp at time zone 'America/Managua')
        and s.starts_at < (($2::date + 1)::timestamp at time zone 'America/Managua')`,
    [eight.first_monday, eight.last_sunday],
  );
  check(
    "las sesiones generadas conservan sala, cupo y duración de la disciplina",
    generatedShape.total === 72 && generatedShape.valid === 72,
  );

  // Producción divergió de 00001: coaches conserva el texto visible
  // `specialty`, pero perdió el arreglo estructurado `specialties` que usa
  // el generador. Reproducimos ese 42703 real antes de probar la 00066.
  const mondayAfterEight = (
    await row("select ($1::date + 1)::text as monday", [eight.last_sunday])
  ).monday;
  const sessionsInWeek = async (monday) =>
    Number((
      await row(
        `select count(*)::int as n
           from public.sessions
          where starts_at >= ($1::date::timestamp at time zone 'America/Managua')
            and starts_at < (($1::date + 7)::timestamp at time zone 'America/Managua')`,
        [monday],
      )
    ).n);

  await db.exec(`
    insert into public.coaches
      (id, slug, name, role_es, role_en, specialties, initials, color, sort_order)
    values
      ('coa_ejemplo_boxeo', 'entrenador-ejemplo', 'Entrenador EJEMPLO',
       'Boxeo y acondicionamiento', 'Boxing and conditioning',
       array['boxeo'], 'EE', '#d81a22', 99);
    alter table public.coaches add column specialty text;
    update public.coaches set specialty = role_es;
    alter table public.coaches drop column specialties;
  `);
  await denied(
    "la divergencia productiva sin specialties reproduce el error real",
    db.query("select public.generate_week_sessions($1::date) as created", [
      mondayAfterEight,
    ]),
    /specialties/,
  );
  check(
    "el error por la columna faltante revierte la generación completa",
    (await sessionsInWeek(mondayAfterEight)) === 0,
  );

  const visibleSpecialties = async () =>
    JSON.stringify(
      (await db.query("select id, specialty from public.coaches order by id")).rows,
    );
  const visibleSpecialtiesBefore = await visibleSpecialties();
  await db.exec(coachesCompatMigration);
  await db.exec(coachesCompatMigration);

  const compatColumn = await row(
    `select data_type, udt_name, is_nullable,
            coalesce(column_default, '') as column_default
       from information_schema.columns
      where table_schema = 'public'
        and table_name = 'coaches'
        and column_name = 'specialties'`,
  );
  const compatRows = await row(
    `select count(*)::int as total,
            count(*) filter (where specialties = '{}'::text[])::int as empty
       from public.coaches`,
  );
  check(
    "00066 restaura specialties sin inferir slugs desde el texto visible",
    compatColumn.data_type === "ARRAY" &&
      compatColumn.udt_name === "_text" &&
      compatColumn.is_nullable === "NO" &&
      compatColumn.column_default.includes("{}") &&
      compatRows.total > 0 &&
      compatRows.empty === compatRows.total &&
      (await visibleSpecialties()) === visibleSpecialtiesBefore,
  );

  const repaired = Number((
    await row("select public.generate_week_sessions($1::date) as created", [
      mondayAfterEight,
    ])
  ).created);
  const repairedRepeat = Number((
    await row("select public.generate_week_sessions($1::date) as created", [
      mondayAfterEight,
    ])
  ).created);
  check(
    "con 00066 el generador vuelve a crear la semana y sigue sin duplicar",
    repaired === 9 &&
      repairedRepeat === 0 &&
      (await sessionsInWeek(mondayAfterEight)) === 9,
  );
} finally {
  await db.close();
}

console.log(`\n🎉 Sesiones futuras OP-04: ${checks} comprobaciones pasaron (PGlite; sin SQL remoto).`);
