-- ============================================================
--  PARTE 1 DE 3 — NO CORRER FUERA DE ORDEN
-- ============================================================
--  Es el mismo contenido de supabase/INSTALAR-BASE.sql, cortado
--  en 3 para que el SQL Editor del celular no se trabe.
--  Correr la 1, esperar el «Success», después la 2 y después la 3.
--  Guía paso a paso: docs/INSTALAR-DESDE-EL-CELULAR.md
--  Generado por scripts/build-install-sql.mjs — no editar a mano.
-- ============================================================

-- ============================================================
--  PLANTILLA DE BASE DE DATOS — INSTALACIÓN COMPLETA
-- ============================================================
--  La casa entera, sin los muebles.
--
--  QUÉ INCLUYE (todo lo que hace funcionar la aplicación)
--    · las 45 tablas: socios, clases, reservas, caja, finanzas,
--      progreso, rutinas, nutrición, productos, mensajes…
--    · las reglas de seguridad (RLS): cada rol ve sólo lo suyo
--    · las funciones y disparadores: cobrar, reservar, cerrar caja,
--      calcular vigencias, categorías automáticas, bitácora, límites
--      de abuso
--    · los permisos del personal y los interruptores de caja
--    · la configuración mínima genérica: métodos de pago y
--      categorías de gasto
--    · el esquema financiero «bank_accounts_split» que la cadena
--      exige desde 00024 (reemplaza a las migraciones 00010/00011,
--      que instalan el modelo histórico «repository»)
--
--  QUÉ NO INCLUYE
--    · Ni un socio, ni una reserva, ni un cobro, ni una medición.
--    · Ni una cuenta bancaria, ni un entrenador, ni una tarifa.
--    · Cero datos personales. Cero cuentas de acceso.
--
--  CÓMO SE USA
--    1. Supabase → proyecto nuevo → SQL Editor → New query
--    2. Pegar TODO este archivo
--    3. Run. Tarda unos segundos.
--    4. Después correr PERSONALIZAR-GIMNASIO.sql
--
--    · Desde el celular, en vez de este archivo entero usar las
--      3 partes de supabase/instalar/ (mismo contenido, cortado
--      en pedazos que el editor del teléfono aguanta):
--      docs/INSTALAR-DESDE-EL-CELULAR.md
--
--  QUÉ SIGUE DESPUÉS DE ESTO (no está en ningún SQL)
--    · La biblioteca de ejercicios se descarga con el botón de
--      administración (necesita 2FA): no vive en la base ni en el
--      repositorio, viene del dataset oficial.
--    · Las disciplinas, horarios, planes y precios se cargan desde
--      el panel del gimnasio, no por SQL.
--
--  Generado por scripts/build-install-sql.mjs — no editar a mano.
--  84 migraciones incluidas de 87.
-- ============================================================


-- ═══════════════════════════════════════════════════════════
--  00001_schema.sql
-- ═══════════════════════════════════════════════════════════

-- ============================================================
--  Esquema de base de datos (Supabase / PostgreSQL)
-- ============================================================
--  Cómo usarlo:
--    1. Entrá a tu proyecto en https://supabase.com
--    2. Menú lateral → SQL Editor → New query
--    3. Pegá TODO este archivo y apretá "Run"
--
--  Este archivo se puede correr varias veces sin romper nada
--  (usa IF NOT EXISTS y CREATE OR REPLACE).
-- ============================================================


-- ------------------------------------------------------------
--  1. TIPOS
-- ------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type public.user_role as enum ('member', 'staff', 'admin');
  end if;

  if not exists (select 1 from pg_type where typname = 'booking_status') then
    create type public.booking_status as enum ('confirmed', 'cancelled', 'attended', 'no_show');
  end if;

  if not exists (select 1 from pg_type where typname = 'session_status') then
    create type public.session_status as enum ('scheduled', 'cancelled');
  end if;

  if not exists (select 1 from pg_type where typname = 'intensity_level') then
    create type public.intensity_level as enum ('low', 'medium', 'high');
  end if;
end $$;


-- ------------------------------------------------------------
--  2. PERFILES  (extiende auth.users de Supabase)
-- ------------------------------------------------------------
--  No guardamos la contraseña: de eso se encarga Supabase Auth.

create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text,
  email       text,
  phone       text,
  role        public.user_role not null default 'member',
  plan_id     text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.profiles is 'Datos públicos del socio. Se crea solo al registrarse (trigger).';

-- Índice para buscar por email desde el panel
create index if not exists profiles_email_idx on public.profiles (lower(email));


-- ------------------------------------------------------------
--  3. DISCIPLINAS (pesas y máquinas, boxeo, zumba...)
-- ------------------------------------------------------------

create table if not exists public.classes (
  id             text primary key,
  slug           text not null unique,
  name_es        text not null,
  name_en        text not null,
  description_es text not null default '',
  description_en text not null default '',
  intensity      public.intensity_level not null default 'medium',
  duration_min   integer not null default 45 check (duration_min between 10 and 180),
  capacity       integer not null default 16 check (capacity between 1 and 200),
  color          text not null default '#d81a22',
  sort_order     integer not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

create index if not exists classes_active_idx on public.classes (is_active, sort_order);


-- ------------------------------------------------------------
--  4. PROFES
-- ------------------------------------------------------------

create table if not exists public.coaches (
  id         text primary key,
  slug       text not null unique,
  name       text not null,
  role_es    text not null default '',
  role_en    text not null default '',
  bio_es     text not null default '',
  bio_en     text not null default '',
  specialties text[] not null default '{}',
  initials   text not null default '',
  color      text not null default '#d81a22',
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists coaches_active_idx on public.coaches (is_active, sort_order);


-- ------------------------------------------------------------
--  5. PLANES
-- ------------------------------------------------------------

create table if not exists public.plans (
  id           text primary key,
  slug         text not null unique,
  name_es      text not null,
  name_en      text not null,
  tagline_es   text not null default '',
  tagline_en   text not null default '',
  -- Puede ser NULL: significa "precio a consultar", la web no inventa un número.
  price        numeric(10, 2),
  period       text not null default 'month' check (period in ('month', 'week', 'session')),
  features_es  text[] not null default '{}',
  features_en  text[] not null default '{}',
  is_popular   boolean not null default false,
  sort_order   integer not null default 0,
  is_active    boolean not null default true
);

-- Si la tabla ya existía con price NOT NULL, la aflojamos: hay planes
-- cuyo precio todavía no se publica.
alter table public.plans alter column price drop not null;
alter table public.plans alter column price drop default;

-- El perfil referencia el plan por id (sin FK estricta para poder
-- cambiar los IDs de los planes sin romper cuentas existentes).
alter table public.profiles
  drop constraint if exists profiles_plan_id_fkey;


-- ------------------------------------------------------------
--  6. CLASES PROGRAMADAS (con fecha y hora)
-- ------------------------------------------------------------
--  Cada fila es UNA clase en UN horario concreto.
--  Podés generarlas desde el panel: ver la función generate_sessions.

create table if not exists public.sessions (
  id         text primary key default gen_random_uuid()::text,
  class_id   text not null references public.classes (id) on delete cascade,
  coach_id   text references public.coaches (id) on delete set null,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  capacity   integer not null check (capacity between 1 and 200),
  room       text not null default 'Salón principal',
  status     public.session_status not null default 'scheduled',
  created_at timestamptz not null default now(),

  constraint sessions_time_valid check (ends_at > starts_at)
);

create index if not exists sessions_starts_at_idx on public.sessions (starts_at);
create index if not exists sessions_class_idx on public.sessions (class_id, starts_at);


-- ------------------------------------------------------------
--  7. RESERVAS
-- ------------------------------------------------------------

create table if not exists public.bookings (
  id           uuid primary key default gen_random_uuid(),
  session_id   text not null references public.sessions (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  status       public.booking_status not null default 'confirmed',
  created_at   timestamptz not null default now(),
  cancelled_at timestamptz,

  -- Un solo registro por socio y clase (si cancela, se reutiliza la fila)
  unique (session_id, user_id)
);

create index if not exists bookings_user_idx on public.bookings (user_id, status);
create index if not exists bookings_session_idx on public.bookings (session_id, status);


-- ------------------------------------------------------------
--  8. CONSULTAS DEL FORMULARIO DE CONTACTO
-- ------------------------------------------------------------

create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  email      text not null,
  phone      text,
  subject    text not null default 'info',
  message    text not null,
  locale     text not null default 'es',
  is_read    boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists messages_created_idx on public.messages (created_at desc);


-- ------------------------------------------------------------
--  9. SUSCRIPTORES DEL NEWSLETTER
-- ------------------------------------------------------------

create table if not exists public.subscribers (
  email      text primary key,
  locale     text not null default 'es',
  created_at timestamptz not null default now()
);


-- ------------------------------------------------------------
--  9-bis. OCUPACIÓN DE CADA CLASE (vista pública)
-- ------------------------------------------------------------
--  El sitio necesita mostrar "quedan 4 lugares" a todo el mundo,
--  pero las reservas están protegidas por RLS: cada socio sólo ve
--  las suyas. Esta vista expone ÚNICAMENTE el conteo por clase
--  (nunca quién reservó), así nadie puede espiar a los demás.

create or replace view public.session_occupancy as
  select
    session_id,
    count(*) filter (where status in ('confirmed', 'attended'))::int as booked_count
  from public.bookings
  group by session_id;

comment on view public.session_occupancy is
  'Cuántos lugares ocupados tiene cada clase. Sólo conteos, sin datos de socios.';

grant select on public.session_occupancy to anon, authenticated;


-- ============================================================
--  10. PERFIL AUTOMÁTICO AL REGISTRARSE
-- ============================================================
--  Cuando alguien crea una cuenta, Supabase inserta la fila en
--  auth.users y este trigger copia los datos a public.profiles.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email,
    new.raw_user_meta_data ->> 'phone'
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = coalesce(public.profiles.full_name, excluded.full_name);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ============================================================
--  11. FUNCIONES DE NEGOCIO
-- ============================================================
--  Las reservas pasan por estas funciones para evitar que dos
--  personas ocupen el último lugar al mismo tiempo.

-- ---------- Reservar ----------
create or replace function public.book_session(p_session_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_session  public.sessions;
  v_booking  public.bookings;
  v_existing boolean := false;   -- ¿ya tenía una reserva cancelada en esta clase?
  v_booked   integer;            -- lugares ocupados
  v_active   integer;            -- reservas activas del socio
  v_max      integer := 3;       -- máximo de reservas activas a la vez
begin
  if v_user_id is null then
    raise exception 'AUTH: tenés que iniciar sesión';
  end if;

  -- Bloqueamos la fila: nadie más puede reservar al mismo tiempo
  select * into v_session
  from public.sessions
  where id = p_session_id
  for update;

  if not found then
    raise exception 'NOT_FOUND: la clase no existe';
  end if;

  if v_session.status <> 'scheduled' then
    raise exception 'CANCELLED: la clase fue cancelada';
  end if;

  if v_session.starts_at <= now() then
    raise exception 'PAST: la clase ya comenzó';
  end if;

  -- ¿Ya tiene una reserva en esta clase?
  select * into v_booking
  from public.bookings
  where session_id = p_session_id and user_id = v_user_id;

  if found then
    if v_booking.status in ('confirmed', 'attended') then
      raise exception 'ALREADY_BOOKED: ya tenés una reserva en esa clase';
    end if;
    -- Estaba cancelada: después reutilizamos la fila
    v_existing := true;
  end if;

  -- Cupos disponibles (las canceladas no ocupan lugar)
  select count(*) into v_booked
  from public.bookings
  where session_id = p_session_id and status in ('confirmed', 'attended');

  if v_booked >= v_session.capacity then
    raise exception 'FULL: no quedan lugares';
  end if;

  -- Límite de reservas activas por socio
  select count(*) into v_active
  from public.bookings b
  join public.sessions s on s.id = b.session_id
  where b.user_id = v_user_id
    and b.status in ('confirmed', 'attended')
    and s.starts_at > now();

  if v_active >= v_max then
    raise exception 'LIMIT: ya tenés % reservas activas a la vez', v_max;
  end if;

  if v_existing then
    update public.bookings
      set status = 'confirmed', cancelled_at = null, created_at = now()
      where id = v_booking.id
      returning * into v_booking;
  else
    insert into public.bookings (session_id, user_id, status)
    values (p_session_id, v_user_id, 'confirmed')
    returning * into v_booking;
  end if;

  return jsonb_build_object(
    'id', v_booking.id,
    'session_id', v_booking.session_id,
    'status', v_booking.status
  );
end;
$$;


-- ---------- Cancelar ----------
create or replace function public.cancel_booking(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_booking public.bookings;
  v_starts  timestamptz;
  v_window  interval := interval '3 hours';   -- margen para cancelar
begin
  if v_user_id is null then
    raise exception 'AUTH: tenés que iniciar sesión';
  end if;

  select * into v_booking
  from public.bookings
  where id = p_booking_id and user_id = v_user_id
  for update;

  if not found then
    raise exception 'NOT_FOUND: la reserva no existe';
  end if;

  select starts_at into v_starts from public.sessions where id = v_booking.session_id;

  if v_starts - now() < v_window then
    raise exception 'TOO_LATE: ya no podés cancelar (faltan menos de 3 horas)';
  end if;

  update public.bookings
    set status = 'cancelled', cancelled_at = now()
    where id = p_booking_id
    returning * into v_booking;

  return jsonb_build_object('id', v_booking.id, 'status', v_booking.status);
end;
$$;


-- ---------- Generar la grilla semanal ----------
--  Crea las clases de una semana a partir de una plantilla.
--  Uso:  select public.generate_week_sessions('2026-10-19'::date);
create or replace function public.generate_week_sessions(p_monday date)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted integer := 0;
  v_template record;
  v_slot record;
  v_class  public.classes;
  v_coach  text;
  v_start  timestamptz;
  v_created integer;
begin
  -- Sólo admin o staff
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'staff')
  ) and auth.uid() is not null then
    raise exception 'AUTH: sólo el staff puede generar horarios';
  end if;

  for v_slot in
    select * from (values
-- >>> PLANTILLA SEMANAL (generada por scripts/build-sql.mjs — no editar a mano) >>>
      -- Misma grilla que src/lib/data/demo-sessions.ts (la web).
      -- día (0 = lunes), hora local del gimnasio, disciplina
      -- Lunes: sin clases
      -- Martes: sin clases
      -- Miércoles: sin clases
      -- Jueves: sin clases
      -- Viernes: sin clases
      -- Sábado: sin clases
      -- Domingo: sin clases
      -- Grilla vacía a propósito: el gimnasio carga sus horarios en el panel.
      (null::integer, null::time, null::text)
-- <<< PLANTILLA SEMANAL <<<
    ) as t(day_offset, start_time, slug)
  loop
    select * into v_class from public.classes where slug = v_slot.slug and is_active;
    if not found then continue; end if;

    -- `fecha + hora` da un timestamp "sin zona"; AT TIME ZONE lo interpreta
    -- como hora local del gimnasio y devuelve el instante UTC correcto.
    -- (Managua es UTC-6 todo el año, no tiene horario de verano.)
    v_start := ((p_monday + v_slot.day_offset) + v_slot.start_time)
               at time zone 'America/Managua';

    -- Evitamos duplicar si ya existe esa clase a esa hora
    select count(*) into v_created
    from public.sessions
    where class_id = v_class.id and starts_at = v_start;

    if v_created > 0 then continue; end if;

    -- Elegimos un profe al azar entre los que dictan la disciplina
    select id into v_coach
    from public.coaches
    where is_active and v_class.slug = any (specialties)
    order by random()
    limit 1;

    insert into public.sessions (class_id, coach_id, starts_at, ends_at, capacity, room)
    values (
      v_class.id,
      v_coach,
      v_start,
      v_start + (v_class.duration_min || ' minutes')::interval,
      v_class.capacity,
      case v_class.slug
-- >>> SALAS >>>
        when null then null  -- sin salas por disciplina: todo en «Salón principal»
-- <<< SALAS <<<
        else 'Salón principal'
      end
    );

    v_inserted := v_inserted + 1;
  end loop;

  return v_inserted;
end;
$$;


-- ---------- Marcar ausentes automáticamente ----------
--  Pasadas 2 horas del inicio, las reservas confirmadas que nadie
--  marcó pasan a "no_show". Programalo con pg_cron si querés.
create or replace function public.close_past_sessions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.bookings b
    set status = 'no_show'
    from public.sessions s
    where b.session_id = s.id
      and b.status = 'confirmed'
      and s.ends_at < now() - interval '2 hours';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


-- ============================================================
--  12. SEGURIDAD A NIVEL DE FILA (RLS)
-- ============================================================
--  Sin esto, cualquiera con la clave pública podría leer o
--  escribir toda la base. Cada tabla define quién ve qué.

alter table public.profiles    enable row level security;
alter table public.classes     enable row level security;
alter table public.coaches     enable row level security;
alter table public.plans       enable row level security;
alter table public.sessions    enable row level security;
alter table public.bookings    enable row level security;
alter table public.messages    enable row level security;
alter table public.subscribers enable row level security;


-- ---------- ¿Es staff? ----------
create or replace function public.is_staff()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'staff')
  );
$$;


-- ---------- profiles ----------
drop policy if exists "perfil: leer el propio" on public.profiles;
create policy "perfil: leer el propio" on public.profiles
  for select using (id = auth.uid() or public.is_staff());

drop policy if exists "perfil: editar el propio" on public.profiles;
create policy "perfil: editar el propio" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "perfil: el staff edita todo" on public.profiles;
create policy "perfil: el staff edita todo" on public.profiles
  for update using (public.is_staff());

drop policy if exists "perfil: el staff agrega" on public.profiles;
create policy "perfil: el staff agrega" on public.profiles
  for insert with check (public.is_staff());


-- ---------- contenido público ----------
drop policy if exists "clases: lectura pública" on public.classes;
create policy "clases: lectura pública" on public.classes
  for select using (true);

drop policy if exists "clases: el staff escribe" on public.classes;
create policy "clases: el staff escribe" on public.classes
  for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists "profes: lectura pública" on public.coaches;
create policy "profes: lectura pública" on public.coaches
  for select using (true);

drop policy if exists "profes: el staff escribe" on public.coaches;
create policy "profes: el staff escribe" on public.coaches
  for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists "planes: lectura pública" on public.plans;
create policy "planes: lectura pública" on public.plans
  for select using (true);

drop policy if exists "planes: el staff escribe" on public.plans;
create policy "planes: el staff escribe" on public.plans
  for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists "horarios: lectura pública" on public.sessions;
create policy "horarios: lectura pública" on public.sessions
  for select using (true);

drop policy if exists "horarios: el staff escribe" on public.sessions;
create policy "horarios: el staff escribe" on public.sessions
  for all using (public.is_staff()) with check (public.is_staff());


-- ---------- bookings ----------
drop policy if exists "reservas: ver las propias" on public.bookings;
create policy "reservas: ver las propias" on public.bookings
  for select using (user_id = auth.uid() or public.is_staff());

drop policy if exists "reservas: cancelar la propia" on public.bookings;
create policy "reservas: cancelar la propia" on public.bookings
  for update using (user_id = auth.uid() or public.is_staff());

drop policy if exists "reservas: el staff gestiona" on public.bookings;
create policy "reservas: el staff gestiona" on public.bookings
  for all using (public.is_staff()) with check (public.is_staff());

-- Las altas se hacen por la función book_session(), no directo a la tabla.
-- (La función es "security definer", así que saltea estas reglas.)


-- ---------- messages ----------
--  El formulario web inserta sin estar logueado; sólo el staff lee.
drop policy if exists "consultas: cualquiera puede escribir" on public.messages;
create policy "consultas: cualquiera puede escribir" on public.messages
  for insert with check (true);

drop policy if exists "consultas: el staff lee" on public.messages;
create policy "consultas: el staff lee" on public.messages
  for select using (public.is_staff());

drop policy if exists "consultas: el staff actualiza" on public.messages;
create policy "consultas: el staff actualiza" on public.messages
  for update using (public.is_staff());


-- ---------- subscribers ----------
drop policy if exists "novedades: cualquiera se suscribe" on public.subscribers;
create policy "novedades: cualquiera se suscribe" on public.subscribers
  for insert with check (true);

drop policy if exists "novedades: el staff lee" on public.subscribers;
create policy "novedades: el staff lee" on public.subscribers
  for select using (public.is_staff());


-- ============================================================
--  13. PERMISOS
-- ============================================================

grant usage on schema public to anon, authenticated;
grant select on public.classes, public.coaches, public.plans, public.sessions to anon, authenticated;
grant select, insert, update on public.bookings to authenticated;
grant select, update on public.profiles to authenticated;
grant insert on public.messages, public.subscribers to anon, authenticated;
grant select, update on public.messages to authenticated;
grant select on public.subscribers to authenticated;
grant execute on function public.book_session(text) to authenticated;
grant execute on function public.cancel_booking(uuid) to authenticated;
grant execute on function public.is_staff() to authenticated;

-- ═══════════════════════════════════════════════════════════
--  00010_finance.sql  →  REEMPLAZADA por supabase/instalacion/00010-esquema-financiero-split.sql
--  (esquema financiero split para instalación nueva; hueco #5,
--   docs/INVENTARIO-DATOS-STRONG.md §8.7)
-- ═══════════════════════════════════════════════════════════

-- ============================================================
--  ESQUEMA FINANCIERO «bank_accounts_split» PARA INSTALACIÓN NUEVA
-- ============================================================
--  ARTEFACTO DE INSTALACIÓN (no es una migración numerada).
--  `scripts/build-install-sql.mjs` lo intercala en INSTALAR-BASE.sql
--  EN LUGAR de `00010_finance.sql` (que crea el modelo histórico
--  «repository»). SETUP.sql y ACTUALIZAR.sql siguen usando 00010:
--  esos archivos describen la base histórica, no la instalación nueva.
--
--  POR QUÉ EXISTE (hueco #5, docs/INVENTARIO-DATOS-STRONG.md §8.7):
--  Desde 00022 la cadena clasifica el esquema financiero y a partir
--  de 00024 (y luego 00028, 00029, 00095, 00096…) EXIGE el modelo
--  «bank_accounts_split». Ninguna migración numerada crea ese
--  modelo: la base real de Strong se construyó por fuera del repo.
--  Sin este archivo, INSTALAR-BASE.sql se corta a mitad con
--  FINANCE_SCHEMA_UNSUPPORTED sobre una base vacía.
--
--  PROCEDENCIA de cada bloque:
--    · [DIAGNÓSTICO] transcripto de tests/fixtures/
--      finance-bank-accounts.sql, derivado A MANO de los diagnósticos
--      remotos de la Supabase real de Strong (2026-10-15 y
--      2026-10-17). NO es fuente de verdad: la estructura exacta de
--      la base real se confirma con supabase/
--      DIAGNOSTICO-ESQUEMA-FINANCIERO.sql (se corre en las dos
--      Supabase y se compara; el PR no se fusiona hasta que la
--      diferencia sea cero).
--    · [CÓDIGO] lo exigen las migraciones posteriores: el
--      clasificador crm_finance_layout() de 00022 (columnas exactas
--      de bank_accounts, payment_methods, member_balances y
--      transactions), las lecturas de 00023, las escrituras de
--      00024/00028/00029/00095/00096 y las vistas de 00050/00051.
--    · [PRUEBAS] verificado aplicando la cadena completa sobre este
--      esquema en PGlite (scripts/test-instalar-base-sql.mjs y las
--      suites que usan tests/fixtures/finance-bank-accounts.sql).
--
--  DIFERENCIAS con el fixture de pruebas (deliberadas):
--    · record_payment nace en forma GUARD: la salida real del
--      diagnóstico (2026-11-05) confirma que la función existe en la
--      base de Strong con la firma de 8 argumentos; acá se crea la
--      forma bloqueada (idéntica a la que instala 00023) para que el
--      estado final coincida. 00023 la normaliza y fija permisos.
--    · cash_sessions sin políticas: la base real no tiene ninguna
--      (00087 elimina las que aparezcan; la caja va por funciones).
--    · FKs de cash_sessions con ON DELETE (RESTRICT/SET NULL) y los
--      cinco índices idx_cash_sessions_open + idx_transactions_*,
--      que en la real nacieron por fuera del repo.
--    · coaches se reconstruye a la forma productiva de 11 columnas
--      si está en forma repo y vacía — ver sección 10.
--    · DDL idempotente (if not exists / or replace / drop policy if
--      exists): se puede volver a pegar sin romper.
--    · Sin «grant all» amplios: los permisos los fija la cadena
--      (00023, 00024, 00030, 00095…) que corre después.
-- ============================================================


-- ------------------------------------------------------------
--  1. Tipos enum del modelo split [DIAGNÓSTICO + CÓDIGO]
-- ------------------------------------------------------------
--  Ninguna migración numerada los crea; transactions los usa.
do $$ begin
  create type public.transaction_status as enum ('pending', 'completed', 'cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.transaction_type as enum ('income', 'expense', 'transfer');
exception when duplicate_object then null; end $$;


-- ------------------------------------------------------------
--  2. Categorías de gasto [DIAGNÓSTICO]
-- ------------------------------------------------------------
--  Columnas del modelo split (id, name, color, budget_monthly,
--  display_order). Las filas genéricas las siembra
--  00011-semilla-generica-split.sql.
create table if not exists public.expense_categories (
  id             text primary key,
  name           text not null,
  color          text not null default '#888888',
  budget_monthly numeric(12,2),
  display_order  integer not null default 0
);


-- ------------------------------------------------------------
--  3. Sesiones de caja [DIAGNÓSTICO]
-- ------------------------------------------------------------
--  La usan 00033/00037/00038/00087/00088 (apertura, cierre y arqueo).
create table if not exists public.cash_sessions (
  id                    uuid primary key default gen_random_uuid(),
  opened_by             uuid not null references public.profiles (id) on delete restrict,
  opened_at             timestamptz not null default now(),
  closed_by             uuid references public.profiles (id) on delete set null,
  closed_at             timestamptz,
  opening_balance_nio   numeric(12,2) not null default 0,
  opening_balance_usd   numeric(12,2) not null default 0,
  closing_balance_nio   numeric(12,2),
  closing_balance_usd   numeric(12,2),
  expected_balance_nio  numeric(12,2),
  expected_balance_usd  numeric(12,2),
  difference_nio        numeric(12,2),
  difference_usd        numeric(12,2),
  notes                 text
);


-- ------------------------------------------------------------
--  4. Cuentas del gimnasio [DIAGNÓSTICO + CÓDIGO]
-- ------------------------------------------------------------
--  bank_accounts(id, name, currency, is_active, display_order) son
--  las columnas exactas que exige el clasificador de 00022; el resto
--  (account_type con sus tres valores, bank_name, account_number,
--  balance) lo confirman 00023 (finance_read) y 00095 (alta y
--  edición desde el panel, que valida account_type y currency).
create table if not exists public.bank_accounts (
  id             text not null,
  name           text not null,
  account_type   text not null,
  currency       text not null,
  bank_name      text,
  account_number text,
  balance        numeric(12,2) not null default 0,
  is_active      boolean not null default true,
  display_order  integer not null default 0,
  constraint bank_accounts_account_type_check CHECK (account_type = ANY (ARRAY['caja_fuerte'::text, 'banco'::text, 'billetera'::text])),
  constraint bank_accounts_currency_check CHECK (currency = ANY (ARRAY['NIO'::text, 'USD'::text])),
  constraint bank_accounts_pkey PRIMARY KEY (id)
);


-- ------------------------------------------------------------
--  5. Saldos de socios [DIAGNÓSTICO + CÓDIGO]
-- ------------------------------------------------------------
--  member_balances(member_id, credit_nio, credit_usd, debt_nio,
--  debt_usd): las cinco columnas que exige el clasificador de 00022.
--  00028 (deudas y abonos) y 00029 (vuelto) escriben acá.
create table if not exists public.member_balances (
  member_id         uuid not null,
  credit_nio        numeric(12,2) not null default 0,
  credit_usd        numeric(12,2) not null default 0,
  debt_nio          numeric(12,2) not null default 0,
  debt_usd          numeric(12,2) not null default 0,
  last_payment_date timestamp with time zone,
  updated_at        timestamp with time zone not null default now(),
  constraint member_balances_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.profiles(id) ON DELETE CASCADE,
  constraint member_balances_pkey PRIMARY KEY (member_id)
);


-- ------------------------------------------------------------
--  6. Métodos de pago [DIAGNÓSTICO + CÓDIGO]
-- ------------------------------------------------------------
--  payment_methods(id, name, currency, is_active, display_order):
--  lo que exige el clasificador de 00022. currency admite BOTH
--  (00023 lo traduce a accepts_nio/accepts_usd para la web).
create table if not exists public.payment_methods (
  id            text not null,
  name          text not null,
  currency      text not null,
  fee_pct       numeric(5,2) not null default 0,
  is_active     boolean not null default true,
  display_order integer not null default 0,
  constraint payment_methods_currency_check CHECK (currency = ANY (ARRAY['NIO'::text, 'USD'::text, 'BOTH'::text])),
  constraint payment_methods_pkey PRIMARY KEY (id)
);


-- ------------------------------------------------------------
--  7. Movimientos [DIAGNÓSTICO + CÓDIGO]
-- ------------------------------------------------------------
--  transactions(type, method_id, amount_nio, amount_usd, fx_used):
--  lo que exige el clasificador de 00022. El resto de las columnas
--  y claves foráneas viene del diagnóstico; 00024 (finance_entries)
--  y 00096 (transferencias entre cuentas) las usan.
create table if not exists public.transactions (
  id                     uuid not null default gen_random_uuid(),
  type                   public.transaction_type not null,
  status                 public.transaction_status not null default 'completed'::transaction_status,
  occurred_at            timestamp with time zone not null default now(),
  account_id             text not null,
  destination_account_id text,
  method_id              text,
  category_id            text,
  member_id              uuid,
  coach_id               text,
  plan_id                text,
  amount                 numeric(12,2) not null,
  currency               text not null,
  amount_nio             numeric(12,2) not null,
  amount_usd             numeric(12,4) not null,
  fx_used                numeric(12,4) not null,
  concept                text not null,
  reference              text,
  receipt_url            text,
  notes                  text,
  created_by             uuid,
  created_at             timestamp with time zone not null default now(),
  updated_at             timestamp with time zone not null default now(),
  constraint transactions_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.bank_accounts(id) ON DELETE RESTRICT,
  constraint transactions_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.expense_categories(id) ON DELETE SET NULL,
  constraint transactions_coach_id_fkey FOREIGN KEY (coach_id) REFERENCES public.coaches(id) ON DELETE SET NULL,
  constraint transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL,
  constraint transactions_currency_check CHECK (currency = ANY (ARRAY['NIO'::text, 'USD'::text])),
  constraint transactions_destination_account_id_fkey FOREIGN KEY (destination_account_id) REFERENCES public.bank_accounts(id) ON DELETE RESTRICT,
  constraint transactions_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.profiles(id) ON DELETE SET NULL,
  constraint transactions_method_id_fkey FOREIGN KEY (method_id) REFERENCES public.payment_methods(id) ON DELETE SET NULL,
  constraint transactions_pkey PRIMARY KEY (id),
  constraint transactions_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE SET NULL
);

--  Índices nacidos por fuera del repo [DIAGNÓSTICO 2026-11-05]
--  La base real tiene estos cinco índices y ninguna migración
--  numerada los crea (los únicos de cash_sessions que la cadena
--  fabrica son los unique de 00087/00096). Son de rendimiento: no
--  cambian resultados, pero sin ellos la instalación nueva difiere
--  de la real en 04.indice y en planes de consulta.
create index if not exists idx_cash_sessions_open
  on public.cash_sessions (opened_at desc)
  where closed_at is null;
create index if not exists idx_transactions_account
  on public.transactions (account_id);
create index if not exists idx_transactions_member
  on public.transactions (member_id)
  where member_id is not null;
create index if not exists idx_transactions_occurred_at
  on public.transactions (occurred_at desc);
create index if not exists idx_transactions_type
  on public.transactions (type);


-- ------------------------------------------------------------
--  8. Vista de saldos [DIAGNÓSTICO]
-- ------------------------------------------------------------
create or replace view public.v_account_balances as
  SELECT id, name, account_type, currency, balance, is_active
    FROM public.bank_accounts ba
   ORDER BY display_order;


-- ------------------------------------------------------------
--  9. RLS de las seis tablas [DIAGNÓSTICO]
-- ------------------------------------------------------------
--  Políticas mínimas de lectura/escritura por staff; la cadena las
--  endurece después (00023, 00024, 00030, 00095 revocan el acceso
--  directo y canalizan la escritura por funciones). En la base real
--  de Strong el conjunto exacto de políticas puede diferir: se
--  confirma con el DIAGNOSTICO-ESQUEMA-FINANCIERO.sql.
alter table public.bank_accounts      enable row level security;
alter table public.cash_sessions      enable row level security;
alter table public.expense_categories enable row level security;
alter table public.member_balances    enable row level security;
alter table public.payment_methods    enable row level security;
alter table public.transactions       enable row level security;

drop policy if exists "Authenticated can read bank_accounts" on public.bank_accounts;
create policy "Authenticated can read bank_accounts" on public.bank_accounts
  for select to authenticated using (true);
drop policy if exists "Staff can write bank_accounts" on public.bank_accounts;
create policy "Staff can write bank_accounts" on public.bank_accounts
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

--  cash_sessions NO lleva políticas: la base real no tiene ninguna.
--  (El fixture de pruebas trae «Staff can write cash_sessions», pero
--  es ruido del fixture: 00087 elimina cualquier política de esta
--  tabla y maneja la caja por funciones.)

drop policy if exists "Authenticated can read expense_categories" on public.expense_categories;
create policy "Authenticated can read expense_categories" on public.expense_categories
  for select to authenticated using (true);
drop policy if exists "Staff can write expense_categories" on public.expense_categories;
create policy "Staff can write expense_categories" on public.expense_categories
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists "Members see own balance" on public.member_balances;
create policy "Members see own balance" on public.member_balances
  for select to authenticated using (((member_id = auth.uid()) OR public.is_staff()));
drop policy if exists "Staff can write member_balances" on public.member_balances;
create policy "Staff can write member_balances" on public.member_balances
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists "Authenticated can read payment_methods" on public.payment_methods;
create policy "Authenticated can read payment_methods" on public.payment_methods
  for select to authenticated using (true);
drop policy if exists "Staff can write payment_methods" on public.payment_methods;
create policy "Staff can write payment_methods" on public.payment_methods
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists "Members see own transactions" on public.transactions;
create policy "Members see own transactions" on public.transactions
  for select to authenticated using (((member_id = auth.uid()) OR public.is_staff()));
drop policy if exists "Staff can write transactions" on public.transactions;
create policy "Staff can write transactions" on public.transactions
  for all to authenticated using (public.is_staff()) with check (public.is_staff());


-- ------------------------------------------------------------
-- 10. coaches a la forma productiva [DIAGNÓSTICO 2026-11-05]
-- ------------------------------------------------------------
--  La base real de Strong tiene coaches con OTRO cuerpo que el repo:
--  11 columnas de RRHH (id, profile_id, full_name, specialty, phone,
--  email, hire_date, is_active, monthly_salary, notes, specialties),
--  UNIQUE en profile_id, sin slug/name/role_es/bio_es/bio_en/color/
--  initials/sort_order/created_at y sin coaches_active_idx. Ese
--  cuerpo nació por fuera del repo: ninguna migración numerada lo
--  crea, pero la cadena completa lo tolera (00034/00050/00051/00066/
--  00072/00073/00074/00075/00076/00078/00079 son de forma dual) y
--  src/ nunca lee la tabla directa.
--
--  Reglas de reconstrucción (sin destruir datos nunca):
--    · forma repo (tiene `slug`) Y vacía → drop cascade + CREATE con
--      el cuerpo exacto de la real (11 columnas, en su orden). Se
--      restauran sessions_coach_id_fkey (como la creó 00001), RLS y
--      el grant de lectura (00001). Sin políticas: la real sólo tiene
--      «profes: el admin escribe», que crea 00034 más adelante, y el
--      cascade elimina «profes: lectura pública»/«el staff escribe»,
--      que la real no tiene.
--    · forma repo con filas, forma productiva o desconocida → NO se
--      reconstruye; sólo se garantiza full_name/specialty (add if
--      not exists + backfill desde name/role_es) para que 00050/00051
--      encuentren sus columnas.
do $$
declare
  v_slug    boolean;
  v_profile boolean;
  v_filas   bigint;
begin
  if to_regclass('public.coaches') is null
     or to_regclass('public.sessions') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.transactions') is null then
    raise exception 'COACHES_REBUILD_PREREQUISITE_MISSING';
  end if;

  select exists (
           select 1 from information_schema.columns
            where table_schema = 'public' and table_name = 'coaches'
              and column_name = 'slug'
         ),
         exists (
           select 1 from information_schema.columns
            where table_schema = 'public' and table_name = 'coaches'
              and column_name = 'profile_id'
         )
    into v_slug, v_profile;

  if v_profile or not v_slug then
    -- Forma productiva o desconocida: sólo asegurar las dos columnas
    -- que 00050/00051 exigen. Backfill sólo si existe `name`.
    alter table public.coaches add column if not exists full_name text;
    alter table public.coaches add column if not exists specialty text;
    if exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'coaches'
         and column_name = 'name'
    ) then
      update public.coaches
         set full_name = coalesce(full_name, name),
             specialty = coalesce(specialty, role_es);
    end if;
    return;
  end if;

  select count(*) into v_filas from public.coaches;
  if v_filas > 0 then
    -- Forma repo con datos (p. ej. semillas históricas): no se toca
    -- la tabla; sólo el parche de columnas.
    raise warning 'COACHES_REBUILD_OMITIDO: % fila(s) presentes; no se tocan datos', v_filas;
    alter table public.coaches add column if not exists full_name text;
    alter table public.coaches add column if not exists specialty text;
    update public.coaches
       set full_name = coalesce(full_name, name),
           specialty = coalesce(specialty, role_es);
    return;
  end if;

  -- Forma repo y vacía (instalación nueva): reconstrucción exacta.
  drop table public.coaches cascade;
  create table public.coaches (
    id             text primary key,
    profile_id     uuid references public.profiles (id) on delete set null unique,
    full_name      text not null,
    specialty      text,
    phone          text,
    email          text,
    hire_date      date not null default current_date,
    is_active      boolean not null default true,
    monthly_salary numeric(12,2) default 0,
    notes          text,
    specialties    text[] not null default '{}'::text[]
  );
  -- El cascade llevó sessions_coach_id_fkey: se restaura igual que la
  -- creó 00001 (coach_id es text en las dos formas). También llevó la
  -- FK de transactions.coach_id, que este mismo artefacto crea en la
  -- sección 7 ANTES de reconstruir coaches.
  alter table public.sessions
    add constraint sessions_coach_id_fkey
    foreign key (coach_id) references public.coaches (id) on delete set null;
  alter table public.transactions
    add constraint transactions_coach_id_fkey
    foreign key (coach_id) references public.coaches (id) on delete set null;
  -- 00001 habilita RLS y concede lectura sobre coaches; el cascade
  -- eliminó ambas cosas.
  alter table public.coaches enable row level security;
  grant select on public.coaches to anon, authenticated;
end
$$;

-- ------------------------------------------------------------
-- 11. record_payment en forma guard [DIAGNÓSTICO 2026-11-05]
-- ------------------------------------------------------------
--  La base real TIENE esta función con la firma de 8 argumentos
--  (uuid,numeric,text,text,text,text,text,text): fue el writer
--  bancario de Strong y hoy está bloqueada. 00023 la reemplaza por
--  este mismo guard cuando existe; acá nace directo en forma guard
--  para que el estado final coincida con la real. Nada de la cadena
--  la llama: los cobros van por finance_record_checkout y
--  crm_record_payment(_plan). El body referencia crm_is_staff(),
--  que no existe todavía acá: plpgsql la resuelve en ejecución y
--  00023 reinstala la función idéntica después de crearla.
create or replace function public.record_payment(
  p_member_id  uuid,
  p_amount     numeric,
  p_currency   text,
  p_method_id  text,
  p_account_id text,
  p_plan_id    text default null,
  p_concept    text default 'Pago de membresía',
  p_reference  text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $guard$
begin
  if not public.crm_is_staff() then
    raise exception 'AUTH';
  end if;
  raise exception 'FINANCE_REVIEW_REQUIRED';
end
$guard$;

revoke all on function public.record_payment(uuid, numeric, text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.record_payment(uuid, numeric, text, text, text, text, text, text)
  to authenticated;

-- ═══════════════════════════════════════════════════════════
--  00011_finance_seed.sql  →  REEMPLAZADA por supabase/instalacion/00011-semilla-generica-split.sql
--  (esquema financiero split para instalación nueva; hueco #5,
--   docs/INVENTARIO-DATOS-STRONG.md §8.7)
-- ═══════════════════════════════════════════════════════════

-- ============================================================
--  SEMILLA FINANCIERA GENÉRICA PARA EL ESQUEMA SPLIT
-- ============================================================
--  ARTEFACTO DE INSTALACIÓN (no es una migración numerada).
--  `scripts/build-install-sql.mjs` lo intercala en INSTALAR-BASE.sql
--  EN LUGAR de `00011_finance_seed.sql`, cuya siembra está escrita
--  para las columnas del modelo «repository» (slug/kind/name_es/
--  accepts_nio/icon…) y no encaja en las tablas split que crea
--  00010-esquema-financiero-split.sql.
--
--  Contenido: el MISMO catálogo genérico que conserva el 00011
--  sanitizado (10 métodos de pago y 11 categorías de gasto), con
--  tres adaptaciones al modelo split [CÓDIGO]:
--    · payment_methods: (id, name, currency, fee_pct, is_active,
--      display_order). `currency` sale de mapear accepts_nio/
--      accepts_usd del seed repository (ambas → BOTH). No existen
--      las columnas details/icon/slug: finance_read (00023) deriva
--      slug e icono desde el id para la web. fee_pct arranca en 0 y
--      se edita en el panel.
--    · expense_categories: (id, name, color, budget_monthly,
--      display_order). `name` es el name_es del seed repository;
--      color y presupuesto quedan en sus defaults (se editan en el
--      panel; 00095 trae el RPC del catálogo).
--    · Sin §0 de tipo de cambio: el 00011 repository hacía
--      set_config('app.fx_nio_per_usd') con alcance de SESIÓN y no
--      existe ningún consumidor de ese GUC en la cadena ni en la
--      web. En el modelo split el cambio viaja por movimiento
--      (transactions.fx_used) y por parámetro (00029, 00096).
--
--  Lo que NO hay acá (y en el 00011 repository está ANULADO):
--  cuentas del gimnasio, entrenadores, transacciones de ejemplo y
--  apertura de caja. Las cuentas se crean en PERSONALIZAR-GIMNASIO.sql
--  (las dos cajas) y en el panel (bancos y billeteras, vía 00095).
--
--  Idempotente: se puede volver a correr sin duplicar.
-- ============================================================


-- ------------------------------------------------------------
--  1. Métodos de pago genéricos
-- ------------------------------------------------------------
insert into public.payment_methods
  (id, name, currency, fee_pct, is_active, display_order)
values
  ('pm_cash_nio',   'Efectivo (C$)',          'NIO',  0, true,  1),
  ('pm_cash_usd',   'Efectivo (US$)',         'USD',  0, true,  2),
  ('pm_bac_nio',    'Transferencia BAC NIO',  'NIO',  0, true,  3),
  ('pm_bac_usd',    'Transferencia BAC USD',  'USD',  0, true,  4),
  ('pm_lafi_nio',   'Transferencia LAFISE',   'NIO',  0, true,  5),
  ('pm_card_local', 'Tarjeta POS',            'BOTH', 0, true,  6),
  ('pm_sinpe',      'SINPE Móvil',            'NIO',  0, true,  7),
  ('pm_tigo_money', 'Tigo Money',             'NIO',  0, true,  8),
  ('pm_claro_pay',  'Claro Pay',              'NIO',  0, true,  9),
  ('pm_crypto',     'Cripto (USDT)',          'USD',  0, true, 10)
on conflict (id) do update set
  name          = excluded.name,
  currency      = excluded.currency,
  display_order = excluded.display_order,
  is_active     = true;


-- ------------------------------------------------------------
--  2. Categorías de gasto genéricas
-- ------------------------------------------------------------
insert into public.expense_categories
  (id, name, display_order)
values
  ('exp_rent',        'Alquiler del local',       1),
  ('exp_electricity', 'Servicio eléctrico',       2),
  ('exp_water',       'Agua potable',             3),
  ('exp_internet',    'Internet y cable',         4),
  ('exp_coaches',     'Sueldos de coaches',       5),
  ('exp_cleaning',    'Artículos de limpieza',    6),
  ('exp_equipment',   'Mantenimiento equipos',    7),
  ('exp_supplements', 'Compra de suplementos',    8),
  ('exp_marketing',   'Marketing y redes',        9),
  ('exp_tax',         'Impuestos y tasas',       10),
  ('exp_misc',        'Otros gastos',            99)
on conflict (id) do update set
  name          = excluded.name,
  display_order = excluded.display_order;

-- ═══════════════════════════════════════════════════════════
--  00012_profiles_self_read.sql
-- ═══════════════════════════════════════════════════════════

-- ============================================================
-- Permitir la lectura del perfil propio con RLS.
-- ============================================================
-- Ejecutar en el SQL Editor del proyecto que usa el sitio.
-- Caso observado: profiles.role = admin como dueño, pero el usuario
-- authenticated no ve su propia fila aunque is_staff() = true.
--
-- Sólo agrega SELECT de la fila propia para authenticated. No cambia
-- roles, datos, grants, funciones ni políticas ajenas, y no desactiva RLS.
-- No permite leer perfiles ajenos ni escribir en profiles.
-- Es idempotente y puede aplicarse sin merge ni redeploy del frontend.
-- Si hay políticas AS RESTRICTIVE que bloquean SELECT, éstas siguen
-- vigentes: revisar pg_policies, no borrarlas ni desactivar RLS a ciegas.

begin;

drop policy if exists profiles_select_own_authenticated on public.profiles;
create policy profiles_select_own_authenticated
  on public.profiles
  as permissive
  for select
  to authenticated
  using (id = (select auth.uid()));

commit;

-- ═══════════════════════════════════════════════════════════
--  00020_clients_crm.sql
-- ═══════════════════════════════════════════════════════════

-- FASE 2: CRM de clientes + recepción manual/QR. Aplicar después de 00012.
-- profiles sigue siendo la tabla de identidades/login. gym_clients es una
-- ficha comercial independiente: NO exige teléfono, email ni cuenta web.
-- Etiquetas manuales, no precios ni promociones automáticas.
begin;

create or replace function public.crm_is_staff()
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff')); $$;
revoke all on function public.crm_is_staff() from public;
grant execute on function public.crm_is_staff() to authenticated;

create table if not exists public.gym_clients (
  id uuid primary key default gen_random_uuid(),
  client_number bigint generated always as identity unique,
  profile_id uuid unique references public.profiles(id) on delete set null,
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  birthdate date,
  address text check (length(address)<=200),
  emergency_contact_name text check (length(emergency_contact_name)<=120),
  emergency_contact_phone text check (length(emergency_contact_phone)<=40),
  medical_notes text check (length(medical_notes)<=500),
  phone text check (length(phone) <= 40),
  email text check (length(email) <= 120),
  category text not null default 'client' check (category in ('client','friend','family')),
  status text not null default 'active' check (status in ('active','frozen','cancelled')),
  plan_id text references public.plans(id) on delete set null,
  notes text not null default '' check (length(notes) <= 2000),
  joined_on date not null default (now() at time zone 'America/Managua')::date,
  is_demo boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists gym_clients_name_idx on public.gym_clients(lower(full_name));
create table if not exists public.client_cards (
  client_id uuid primary key references public.gym_clients(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  updated_at timestamptz not null default now()
);
create table if not exists public.client_visits (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.gym_clients(id) on delete cascade,
  visited_at timestamptz not null default now(),
  local_day date not null default (now() at time zone 'America/Managua')::date,
  source text not null check (source in ('manual','qr')),
  recorded_by uuid references public.profiles(id) on delete set null,
  unique(client_id, local_day)
);
create index if not exists client_visits_day_idx on public.client_visits(local_day desc);
create table if not exists public.client_events (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.gym_clients(id) on delete cascade,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  actor_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.transactions add column if not exists client_id uuid references public.gym_clients(id) on delete restrict;
alter table public.transactions add column if not exists crm_request_id uuid unique;
create index if not exists transactions_client_idx on public.transactions(client_id, occurred_at desc);

-- No escritura directa: las funciones verifican permisos, validan y auditan.
alter table public.gym_clients enable row level security;
alter table public.client_cards enable row level security;
alter table public.client_visits enable row level security;
alter table public.client_events enable row level security;
revoke all on public.gym_clients, public.client_cards, public.client_visits, public.client_events from anon, authenticated;
grant select on public.gym_clients, public.client_visits, public.client_events to authenticated;
drop policy if exists crm_clients_read on public.gym_clients;
create policy crm_clients_read on public.gym_clients for select to authenticated using (public.crm_is_staff());
drop policy if exists crm_visits_read on public.client_visits;
create policy crm_visits_read on public.client_visits for select to authenticated using (public.crm_is_staff());
drop policy if exists crm_events_read on public.client_events;
create policy crm_events_read on public.client_events for select to authenticated using (public.crm_is_staff());

create or replace function public.crm_create_client(p_name text, p_phone text default null, p_email text default null, p_plan text default null, p_duplicate_confirmed boolean default false)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_email is not null and trim(p_email) <> '' and p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'INVALID_EMAIL'; end if;
  perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_name)),0));
  if not coalesce(p_duplicate_confirmed,false) and exists(select 1 from public.gym_clients where
    (lower(full_name)=lower(trim(p_name)) and coalesce(phone,'')=coalesce(nullif(trim(p_phone),''),''))
    or (nullif(trim(p_email),'') is not null and email=lower(trim(p_email)))) then raise exception 'DUPLICATE_CLIENT'; end if;
  insert into public.gym_clients(full_name, phone, email, plan_id, created_by)
    values(trim(p_name), nullif(trim(p_phone),''), nullif(lower(trim(p_email)),''), nullif(p_plan,''), auth.uid()) returning id into v_id;
  insert into public.client_cards(client_id) values(v_id);
  insert into public.client_events(client_id, action, actor_id) values(v_id,'created',auth.uid());
  return v_id;
end $$;

create or replace function public.crm_update_client(p_id uuid, p_name text, p_phone text, p_email text, p_category text, p_status text, p_plan text, p_notes text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare old_row public.gym_clients; v_admin boolean;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into old_row from public.gym_clients where id=p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select role='admin' into v_admin from public.profiles where id=auth.uid();
  if p_category <> old_row.category and not coalesce(v_admin,false) then raise exception 'ADMIN_ONLY'; end if;
  if p_email is not null and trim(p_email) <> '' and p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'INVALID_EMAIL'; end if;
  update public.gym_clients set full_name=trim(p_name),phone=nullif(trim(p_phone),''),email=nullif(lower(trim(p_email)),''),
    category=p_category,status=p_status,plan_id=nullif(p_plan,''),notes=coalesce(p_notes,''),updated_at=now() where id=p_id;
  insert into public.client_events(client_id,action,details,actor_id) values(p_id,'updated',
    jsonb_build_object('category_before',old_row.category,'category_after',p_category,'status_before',old_row.status,'status_after',p_status),auth.uid());
end $$;

create or replace function public.crm_get_card(p_id uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_token uuid;
begin
  if not public.crm_is_staff() and not exists(select 1 from public.gym_clients where id=p_id and profile_id=auth.uid()) then raise exception 'AUTH'; end if;
  if not exists(select 1 from public.gym_clients where id=p_id) then raise exception 'NOT_FOUND'; end if;
  insert into public.client_cards(client_id) values(p_id) on conflict(client_id) do nothing;
  select token into v_token from public.client_cards where client_id=p_id;
  return v_token;
end $$;
create or replace function public.crm_rotate_card(p_id uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_token uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if not exists(select 1 from public.gym_clients where id=p_id) then raise exception 'NOT_FOUND'; end if;
  insert into public.client_cards(client_id) values(p_id) on conflict(client_id) do update set token=gen_random_uuid(),updated_at=now() returning token into v_token;
  insert into public.client_events(client_id,action,actor_id) values(p_id,'card_reset',auth.uid());
  return v_token;
end $$;
create or replace function public.crm_find_card(p_token uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select client_id into v_id from public.client_cards where token=p_token;
  if v_id is null then raise exception 'INVALID_CARD'; end if;
  return v_id;
end $$;

create or replace function public.crm_check_in(p_id uuid, p_source text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_visit uuid; v_existing uuid; v_status text;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select status into v_status from public.gym_clients where id=p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_status <> 'active' then raise exception 'INACTIVE'; end if;
  if p_source not in ('manual','qr') or p_source is null then raise exception 'INVALID_SOURCE'; end if;
  if p_source='qr' and not exists(select 1 from public.client_cards where client_id=p_id and token=p_token) then raise exception 'INVALID_CARD'; end if;
  insert into public.client_visits(client_id,source,recorded_by) values(p_id,p_source,auth.uid())
    on conflict(client_id,local_day) do nothing returning id into v_visit;
  if v_visit is null then
    select id into v_existing from public.client_visits where client_id=p_id and local_day=(now() at time zone 'America/Managua')::date;
    return jsonb_build_object('id',v_existing,'already',true);
  end if;
  return jsonb_build_object('id',v_visit,'already',false);
end $$;

-- Cobro confirmado, separado del escaneo y de la asistencia. Sin factura ni
-- descuento automático. Idempotencia: reintentar el MISMO request no duplica caja.
create or replace function public.crm_record_payment(p_id uuid, p_request uuid, p_amount numeric, p_currency text, p_method text, p_account text, p_concept text, p_fx numeric default 1)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_profile uuid; v_existing public.transactions;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into v_existing from public.transactions where crm_request_id=p_request;
  if found then
    if v_existing.client_id is distinct from p_id or v_existing.amount is distinct from p_amount
      or v_existing.currency::text is distinct from p_currency or v_existing.payment_method_id is distinct from p_method
      or v_existing.account_id is distinct from p_account or v_existing.concept is distinct from trim(p_concept)
      or v_existing.fx_rate is distinct from p_fx then raise exception 'REQUEST_CONFLICT'; end if;
    return v_existing.id;
  end if;
  if p_amount is null or p_amount<=0 or p_amount>99999999 or p_amount<>round(p_amount,2)
    or p_currency is null or p_currency not in ('NIO','USD') or p_fx is null or p_fx<=0 or p_fx>10000
    or p_fx<>round(p_fx,4) or round(p_amount*p_fx,2)>9999999999.99
    or (p_currency='NIO' and p_fx<>1) or p_concept is null or length(trim(p_concept)) not between 2 and 200 then raise exception 'INVALID_PAYMENT'; end if;
  select profile_id into v_profile from public.gym_clients where id=p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not exists(select 1 from public.payment_methods where id=p_method and is_active
    and ((p_currency='NIO' and accepts_nio) or (p_currency='USD' and accepts_usd))) then raise exception 'INVALID_METHOD'; end if;
  if not exists(select 1 from public.accounts where id=p_account and is_active and currency::text=p_currency) then raise exception 'INVALID_ACCOUNT'; end if;
  insert into public.transactions(direction,status,amount,currency,fx_rate,base_amount,payment_method_id,account_id,member_id,client_id,crm_request_id,concept,created_by)
    values('income','completed',p_amount,p_currency::public.currency_code,p_fx,round(p_amount*p_fx,2),p_method,p_account,v_profile,p_id,p_request,trim(p_concept),auth.uid()) returning id into v_id;
  insert into public.client_events(client_id,action,details,actor_id) values(p_id,'payment',jsonb_build_object('transaction_id',v_id),auth.uid());
  return v_id;
end $$;

-- Directorio paginado; filtros en servidor. No devuelve tokens QR.
create or replace function public.crm_directory(p_search text default '', p_category text default '', p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select jsonb_build_object('total',(select count(*) from public.gym_clients c where
    (p_category='' or c.category=p_category) and (p_search='' or c.full_name ilike '%'||p_search||'%' or coalesce(c.phone,'') ilike '%'||p_search||'%' or c.client_number::text=p_search)),
    'rows',coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb)) into result from (
    select c.*,p.name_es as plan_name,
      (select count(*)::int from public.client_visits v where v.client_id=c.id and v.local_day >= (now() at time zone 'America/Managua')::date-29) as visits_30,
      (select max(v.visited_at) from public.client_visits v where v.client_id=c.id) as last_visit
    from public.gym_clients c left join public.plans p on p.id=c.plan_id
    where (p_category='' or c.category=p_category) and (p_search='' or c.full_name ilike '%'||p_search||'%' or coalesce(c.phone,'') ilike '%'||p_search||'%' or c.client_number::text=p_search)
    order by c.full_name,c.id limit 30 offset greatest(0,least(coalesce(p_offset,0),1000000))
  ) r;
  return result;
end $$;
create or replace function public.crm_detail(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client public.gym_clients; v_result jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into v_client from public.gym_clients where id=p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  select jsonb_build_object('client',to_jsonb(v_client),'card',public.crm_get_card(p_id),
    'visits',coalesce((select jsonb_agg(to_jsonb(v)) from (select * from public.client_visits where client_id=p_id order by visited_at desc limit 60)v),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(e)) from (select * from public.client_events where client_id=p_id order by created_at desc limit 40)e),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(t)) from (select id,occurred_at,concept,amount,currency,status from public.transactions where client_id=p_id or (v_client.profile_id is not null and member_id=v_client.profile_id) order by occurred_at desc limit 40)t),'[]'::jsonb),
    'balance',case when v_client.profile_id is null then null else (select balance_nio from public.member_balances where member_id=v_client.profile_id) end) into v_result;
  return v_result;
end $$;

-- Perfil web existente/nuevo: crea una ficha vinculada sin exigir login a
-- quienes se registran en recepción. Nunca vincular por simple coincidencia de email.
create or replace function public.crm_profile_created()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.role='member' then
    insert into public.gym_clients(profile_id,full_name,phone,email,plan_id)
      values(new.id,coalesce(nullif(trim(new.full_name),''),'Cliente'),new.phone,new.email,new.plan_id)
      on conflict(profile_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists crm_profile_created on public.profiles;
create trigger crm_profile_created after insert on public.profiles for each row execute function public.crm_profile_created();
insert into public.gym_clients(profile_id,full_name,phone,email,plan_id)
  select id,coalesce(nullif(trim(full_name),''),'Cliente'),phone,email,plan_id from public.profiles where role='member'
  on conflict(profile_id) do nothing;
insert into public.client_cards(client_id) select id from public.gym_clients on conflict(client_id) do nothing;

create or replace function public.crm_my_pass()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.gym_clients;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select * into c from public.gym_clients where profile_id=auth.uid();
  if not found then return null; end if;
  return jsonb_build_object('name',c.full_name,'number',c.client_number,'token',public.crm_get_card(c.id));
end $$;

-- Importación sin auth.users ficticios; una fila por RPC, con deduplicación.
create or replace function public.crm_import_client(p_row jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_name text := trim(p_row->>'fullName'); v_email text := nullif(lower(trim(p_row->>'email')),''); v_phone text := nullif(trim(p_row->>'phone'),'');
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if v_name is null or length(v_name) not between 2 and 120 then raise exception 'INVALID_NAME'; end if;
  perform pg_advisory_xact_lock(hashtextextended(coalesce(v_email,lower(v_name)||coalesce(v_phone,'')),0));
  select id into v_id from public.gym_clients where (v_email is not null and email=v_email)
    or (lower(full_name)=lower(v_name) and phone is not distinct from v_phone) order by created_at limit 1;
  if found then return jsonb_build_object('id',v_id,'imported',false); end if;
  v_id := public.crm_create_client(v_name,v_phone,v_email,p_row->>'planId');
  update public.gym_clients set status=coalesce(nullif(p_row->>'status',''),'active'),
    birthdate=nullif(p_row->>'birthdate','')::date,address=nullif(p_row->>'address',''),
    emergency_contact_name=nullif(p_row->>'emergencyContactName',''),emergency_contact_phone=nullif(p_row->>'emergencyContactPhone',''),
    medical_notes=nullif(p_row->>'medicalNotes','') where id=v_id;
  return jsonb_build_object('id',v_id,'imported',true);
end $$;
revoke all on function public.crm_import_client(jsonb) from public;
grant execute on function public.crm_import_client(jsonb) to authenticated;

-- Las funciones CRM dependen de roles reales. Impedir que un cliente cambie
-- su propio role mediante la antigua política de edición del perfil propio.
create or replace function public.crm_protect_profile_role()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null
    and not exists(select 1 from public.profiles where id=auth.uid() and role='admin') then
    raise exception 'ADMIN_ONLY';
  end if;
  return new;
end $$;
revoke all on function public.crm_protect_profile_role() from public;
drop trigger if exists crm_protect_profile_role on public.profiles;
create trigger crm_protect_profile_role before update of role on public.profiles for each row execute function public.crm_protect_profile_role();

-- PostgreSQL concede EXECUTE a PUBLIC por defecto: revocación explícita.
revoke all on function public.crm_create_client(text,text,text,text,boolean), public.crm_update_client(uuid,text,text,text,text,text,text,text), public.crm_get_card(uuid), public.crm_rotate_card(uuid), public.crm_find_card(uuid), public.crm_check_in(uuid,text,uuid), public.crm_record_payment(uuid,uuid,numeric,text,text,text,text,numeric), public.crm_directory(text,text,integer), public.crm_detail(uuid), public.crm_my_pass(), public.crm_profile_created() from public;
grant execute on function public.crm_create_client(text,text,text,text,boolean), public.crm_update_client(uuid,text,text,text,text,text,text,text), public.crm_get_card(uuid), public.crm_rotate_card(uuid), public.crm_find_card(uuid), public.crm_check_in(uuid,text,uuid), public.crm_record_payment(uuid,uuid,numeric,text,text,text,text,numeric), public.crm_directory(text,text,integer), public.crm_detail(uuid), public.crm_my_pass() to authenticated;
commit;

-- ═══════════════════════════════════════════════════════════
--  00022_crm_finance_compat.sql
-- ═══════════════════════════════════════════════════════════

-- COMPATIBILIDAD CRM: estructura del repositorio y bank_accounts/saldos separados.
-- Base existente: aplicar sólo este archivo, después de FASE 2. Hacer backup.
-- No crea cuentas/tablas financieras, no cambia RLS, no recalcula saldos ni carga ejemplos.
-- Sustituye crm_detail/cobro y agrega opciones con guard de staff.
-- En bank_accounts los cobros quedan BLOQUEADOS hasta revisar su escritor financiero.
begin;

-- Clasificación conservadora: no adivinar modelos parcialmente mezclados.
create or replace function public.crm_finance_layout()
returns text language sql stable security definer set search_path = public, pg_temp as $$
  with expected(model, tab, cols) as (values
    ('repository', 'accounts', array['id','name','currency','is_active']),
    ('repository', 'payment_methods', array['id','name_es','accepts_nio','accepts_usd','is_active','sort_order']),
    ('repository', 'member_balances', array['member_id','balance_nio']),
    ('repository', 'transactions', array['direction','payment_method_id','fx_rate','base_amount']),
    ('bank_accounts_split', 'bank_accounts', array['id','name','currency','is_active','display_order']),
    ('bank_accounts_split', 'payment_methods', array['id','name','currency','is_active','display_order']),
    ('bank_accounts_split', 'member_balances', array['member_id','credit_nio','credit_usd','debt_nio','debt_usd']),
    ('bank_accounts_split', 'transactions', array['type','method_id','amount_nio','amount_usd','fx_used'])
  ), supported as (
    select model from expected e group by model
    having bool_and(not exists (
      select 1 from unnest(e.cols) required(col)
      where not exists (
        select 1 from pg_catalog.pg_attribute a
        where a.attrelid=to_regclass('public.' || e.tab)
          and a.attname=required.col and a.attnum>0 and not a.attisdropped
      )
    ))
  )
  select case when count(*)=1 then min(model) else 'unsupported' end from supported;
$$;
revoke all on function public.crm_finance_layout() from public, anon, authenticated;

create or replace function public.crm_options()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_layout text; v_methods jsonb; v_accounts jsonb; v_plans jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v_layout := public.crm_finance_layout();
  if v_layout='unsupported' then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;
  select coalesce(jsonb_agg(to_jsonb(p) order by sort_order),'[]'::jsonb) into v_plans
    from (select id,name_es,sort_order from public.plans where is_active) p;
  if v_layout='repository' then
    select coalesce(jsonb_agg(to_jsonb(m) order by sort_order),'[]'::jsonb) into v_methods
      from (select id,name_es,accepts_nio,accepts_usd,sort_order from public.payment_methods where is_active) m;
    select coalesce(jsonb_agg(to_jsonb(a) order by name),'[]'::jsonb) into v_accounts
      from (select id,name,currency from public.accounts where is_active) a;
  else
    select coalesce(jsonb_agg(to_jsonb(m) order by display_order),'[]'::jsonb) into v_methods
      from (select id,name as name_es,currency in ('NIO','BOTH') as accepts_nio,
        currency in ('USD','BOTH') as accepts_usd,display_order from public.payment_methods where is_active) m;
    select coalesce(jsonb_agg(to_jsonb(a) order by display_order),'[]'::jsonb) into v_accounts
      from (select id,name,currency,display_order from public.bank_accounts where is_active) a;
  end if;
  return jsonb_build_object('plans',v_plans,'methods',v_methods,'accounts',v_accounts,
    'finance_layout',v_layout,'payments_enabled',v_layout='repository',
    'payment_block_reason',case when v_layout<>'repository' then
      'Cobros CRM pendientes de compatibilidad con esta Caja. No se guardará ningún cobro desde esta ficha; no lo repitas en otra pantalla sin revisar el historial.' else null end);
end $$;
revoke all on function public.crm_options() from public, anon, authenticated;
grant execute on function public.crm_options() to authenticated;

create or replace function public.crm_detail(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client public.gym_clients; v_layout text; v_balance numeric; v_balances jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into v_client from public.gym_clients where id=p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_layout := public.crm_finance_layout();
  if v_client.profile_id is not null then
    if v_layout='repository' then
      select balance_nio into v_balance from public.member_balances where member_id=v_client.profile_id;
    elsif v_layout='bank_accounts_split' then
      select jsonb_build_object('credit_nio',credit_nio,'credit_usd',credit_usd,'debt_nio',debt_nio,'debt_usd',debt_usd)
        into v_balances from public.member_balances where member_id=v_client.profile_id;
    end if;
  end if;
  return jsonb_build_object('client',to_jsonb(v_client),'card',public.crm_get_card(p_id),
    'visits',coalesce((select jsonb_agg(to_jsonb(v)) from (select * from public.client_visits where client_id=p_id order by visited_at desc limit 60)v),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(e)) from (select * from public.client_events where client_id=p_id order by created_at desc limit 40)e),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(t)) from (select id,occurred_at,concept,amount,currency,status from public.transactions where client_id=p_id or (v_client.profile_id is not null and member_id=v_client.profile_id) order by occurred_at desc limit 40)t),'[]'::jsonb),
    'balance',v_balance,'balances',v_balances,'finance_layout',v_layout);
end $$;
revoke all on function public.crm_detail(uuid) from public, anon, authenticated;
grant execute on function public.crm_detail(uuid) to authenticated;

-- Implementación original conservada, privada; sólo el wrapper puede invocarla.
create or replace function public.crm_record_payment_repository(p_id uuid, p_request uuid, p_amount numeric, p_currency text, p_method text, p_account text, p_concept text, p_fx numeric default 1)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_profile uuid; v_existing public.transactions;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into v_existing from public.transactions where crm_request_id=p_request;
  if found then
    if v_existing.client_id is distinct from p_id or v_existing.amount is distinct from p_amount
      or v_existing.currency::text is distinct from p_currency or v_existing.payment_method_id is distinct from p_method
      or v_existing.account_id is distinct from p_account or v_existing.concept is distinct from trim(p_concept)
      or v_existing.fx_rate is distinct from p_fx then raise exception 'REQUEST_CONFLICT'; end if;
    return v_existing.id;
  end if;
  if p_amount is null or p_amount<=0 or p_amount>99999999 or p_amount<>round(p_amount,2)
    or p_currency is null or p_currency not in ('NIO','USD') or p_fx is null or p_fx<=0 or p_fx>10000
    or p_fx<>round(p_fx,4) or round(p_amount*p_fx,2)>9999999999.99
    or (p_currency='NIO' and p_fx<>1) or p_concept is null or length(trim(p_concept)) not between 2 and 200 then raise exception 'INVALID_PAYMENT'; end if;
  select profile_id into v_profile from public.gym_clients where id=p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not exists(select 1 from public.payment_methods where id=p_method and is_active
    and ((p_currency='NIO' and accepts_nio) or (p_currency='USD' and accepts_usd))) then raise exception 'INVALID_METHOD'; end if;
  if not exists(select 1 from public.accounts where id=p_account and is_active and currency::text=p_currency) then raise exception 'INVALID_ACCOUNT'; end if;
  insert into public.transactions(direction,status,amount,currency,fx_rate,base_amount,payment_method_id,account_id,member_id,client_id,crm_request_id,concept,created_by)
    values('income','completed',p_amount,p_currency::public.currency_code,p_fx,round(p_amount*p_fx,2),p_method,p_account,v_profile,p_id,p_request,trim(p_concept),auth.uid()) returning id into v_id;
  insert into public.client_events(client_id,action,details,actor_id) values(p_id,'payment',jsonb_build_object('transaction_id',v_id),auth.uid());
  return v_id;
end $$;

revoke all on function public.crm_record_payment_repository(uuid,uuid,numeric,text,text,text,text,numeric) from public, anon, authenticated;

create or replace function public.crm_record_payment(p_id uuid, p_request uuid, p_amount numeric, p_currency text, p_method text, p_account text, p_concept text, p_fx numeric default 1)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if public.crm_finance_layout()<>'repository' then raise exception 'FINANCE_REVIEW_REQUIRED'; end if;
  return public.crm_record_payment_repository(p_id,p_request,p_amount,p_currency,p_method,p_account,p_concept,p_fx);
end $$;
revoke all on function public.crm_record_payment(uuid,uuid,numeric,text,text,text,text,numeric) from public, anon, authenticated;
grant execute on function public.crm_record_payment(uuid,uuid,numeric,text,text,text,text,numeric) to authenticated;
commit;

-- ═══════════════════════════════════════════════════════════
--  00023_finance_read_bank_accounts.sql
-- ═══════════════════════════════════════════════════════════

-- LECTURA FINANCIERA compatible con el esquema recibido por CSV.
-- Requiere CRM + 00022. No altera datos, tablas, saldos, RLS ni vistas existentes.
-- Mantiene BLOQUEADOS los cobros CRM y bloquea record_payment antiguo en este modelo.
begin;

create or replace function public.finance_read(p_section text, p_limit integer default 30)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_data jsonb; v_limit integer := greatest(1,least(coalesce(p_limit,30),366));
  v_today date := (now() at time zone 'America/Managua')::date;
  v_month date := date_trunc('month',now() at time zone 'America/Managua')::date;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if public.crm_finance_layout()<>'bank_accounts_split' then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;
  case p_section
  when 'methods' then
    select coalesce(jsonb_agg(to_jsonb(r) order by sort_order,id),'[]'::jsonb) into v_data from (
      select id,id as slug,null::text as kind,name as name_es,null::text as name_en,
        ''::text as details_es,''::text as details_en,'Wallet'::text as icon,
        currency in ('NIO','BOTH') as accepts_nio,currency in ('USD','BOTH') as accepts_usd,
        is_active,display_order as sort_order
      from public.payment_methods where is_active
    ) r;
  when 'accounts' then
    select coalesce(jsonb_agg(to_jsonb(r) order by sort_order,id),'[]'::jsonb) into v_data from (
      select id,id as slug,name,
        case account_type when 'caja_fuerte' then 'cash' when 'banco' then 'bank' when 'billetera' then 'wallet' else account_type end as kind,
        currency,is_active,balance,display_order as sort_order
      from public.bank_accounts where is_active
    ) r;
  when 'categories' then
    select coalesce(jsonb_agg(to_jsonb(r) order by sort_order,id),'[]'::jsonb) into v_data from (
      select id,id as slug,name as name_es,null::text as name_en,'Receipt'::text as icon,
        null::boolean as is_active,display_order as sort_order
      from public.expense_categories
    ) r;
  when 'transactions' then
    select coalesce(jsonb_agg(to_jsonb(r) order by occurred_at desc,id),'[]'::jsonb) into v_data from (
      select t.id,t.occurred_at,t.type::text as direction,t.status::text as status,t.amount,t.currency,
        t.fx_used as fx_rate,t.amount_nio as base_amount,t.method_id as payment_method_id,
        t.account_id,t.member_id,null::uuid as invoice_id,t.category_id as expense_category_id,
        t.concept,t.notes,t.created_by,
        case when p.id is not null then jsonb_build_object('full_name',p.full_name) end as member,
        case when c.id is not null then jsonb_build_object('full_name',c.full_name) end as client
      from public.transactions t left join public.profiles p on p.id=t.member_id
        left join public.gym_clients c on c.id=t.client_id
      order by t.occurred_at desc,t.id limit v_limit
    ) r;
  when 'daily' then
    select coalesce(jsonb_agg(to_jsonb(r) order by day desc),'[]'::jsonb) into v_data from (
      select (occurred_at at time zone 'America/Managua')::date as day,
        sum(case when type::text='income' then amount_nio else 0 end) as income_nio,
        sum(case when type::text='expense' then amount_nio else 0 end) as expense_nio,
        sum(case when type::text='income' then amount_nio when type::text='expense' then -amount_nio else 0 end) as net_nio,
        count(*) as tx_count from public.transactions where status::text='completed'
      group by 1 order by 1 desc limit v_limit
    ) r;
  when 'monthly' then
    select coalesce(jsonb_agg(to_jsonb(r) order by month desc),'[]'::jsonb) into v_data from (
      select date_trunc('month',occurred_at at time zone 'America/Managua')::date as month,
        sum(case when type::text='income' then amount_nio else 0 end) as income_nio,
        sum(case when type::text='expense' then amount_nio else 0 end) as expense_nio,
        sum(case when type::text='income' then amount_nio when type::text='expense' then -amount_nio else 0 end) as net_nio
      from public.transactions where status::text='completed'
      group by 1 order by 1 desc limit v_limit
    ) r;
  when 'method_totals' then
    select coalesce(jsonb_agg(to_jsonb(r) order by total_nio desc,payment_method_id),'[]'::jsonb) into v_data from (
      select t.method_id as payment_method_id,m.name as name_es,'Wallet'::text as icon,count(*) as tx_count,
        sum(t.amount_nio) as total_nio,
        sum(case when t.type::text='income' then t.amount_nio else 0 end) as income_nio,
        sum(case when t.type::text='expense' then t.amount_nio else 0 end) as expense_nio
      from public.transactions t left join public.payment_methods m on m.id=t.method_id
      where t.status::text='completed' and t.type::text in ('income','expense') group by t.method_id,m.name
    ) r;
  when 'receivables' then
    select coalesce(jsonb_agg(to_jsonb(r) order by total_owed_nio desc,member_id),'[]'::jsonb) into v_data from (
      select b.member_id,p.full_name,p.email,p.phone,null::bigint as invoices_open,
        b.debt_nio as total_owed_nio,b.debt_usd as total_owed_usd,
        null::date as oldest_due,null::integer as days_overdue
      from public.member_balances b join public.profiles p on p.id=b.member_id
      where b.debt_nio>0 or b.debt_usd>0
    ) r;
  when 'summary' then
    select jsonb_build_object(
      'incomeToday',coalesce(sum(case when type::text='income' and (occurred_at at time zone 'America/Managua')::date=v_today then amount_nio else 0 end),0),
      'expenseToday',coalesce(sum(case when type::text='expense' and (occurred_at at time zone 'America/Managua')::date=v_today then amount_nio else 0 end),0),
      'netToday',coalesce(sum(case when (occurred_at at time zone 'America/Managua')::date=v_today then case when type::text='income' then amount_nio when type::text='expense' then -amount_nio else 0 end else 0 end),0),
      'txToday',count(*) filter(where (occurred_at at time zone 'America/Managua')::date=v_today),
      'incomeMonth',coalesce(sum(case when type::text='income' then amount_nio else 0 end),0),
      'expenseMonth',coalesce(sum(case when type::text='expense' then amount_nio else 0 end),0),
      'netMonth',coalesce(sum(case when type::text='income' then amount_nio when type::text='expense' then -amount_nio else 0 end),0),
      'txMonth',count(*),'pendingInvoices',null,'sourceModel','bank_accounts_split',
      'totalOwed',coalesce((select sum(debt_nio) from public.member_balances where debt_nio>0),0),
      'totalOwedUsd',coalesce((select sum(debt_usd) from public.member_balances where debt_usd>0),0),
      'openRegisterCount',(select count(*) from public.cash_sessions where closed_at is null),
      'openRegister',(select jsonb_build_object('id',id,'openedAt',opened_at,'openingAmount',opening_balance_nio,'openingAmountUsd',opening_balance_usd) from public.cash_sessions where closed_at is null order by opened_at desc,id limit 1)
    ) into v_data from public.transactions where status::text='completed'
      and (occurred_at at time zone 'America/Managua')::date>=v_month
      and (occurred_at at time zone 'America/Managua')::date<(v_month+interval '1 month')::date;
  else raise exception 'INVALID_FINANCE_SECTION';
  end case;
  return jsonb_build_object('finance_layout','bank_accounts_split','section',p_section,'data',v_data);
end $$;
revoke all on function public.finance_read(text,integer) from public,anon,authenticated;
grant execute on function public.finance_read(text,integer) to authenticated;

-- El escritor antiguo comprobado no verifica rol, no es idempotente y mezcla unidades.
-- Decisión del usuario: mantener cobros bloqueados. No se invoca ni se conserva como RPC accesible.
do $block$
begin
  if public.crm_finance_layout()='bank_accounts_split'
    and to_regprocedure('public.record_payment(uuid,numeric,text,text,text,text,text,text)') is not null then
    execute $definition$
      create or replace function public.record_payment(p_member_id uuid,p_amount numeric,p_currency text,p_method_id text,p_account_id text,p_plan_id text default null,p_concept text default 'Pago de membresía',p_reference text default null)
      returns uuid language plpgsql security definer set search_path=public,pg_temp as $guard$
      begin
        if not public.crm_is_staff() then raise exception 'AUTH'; end if;
        raise exception 'FINANCE_REVIEW_REQUIRED';
      end $guard$;
    $definition$;
    execute 'revoke all on function public.record_payment(uuid,numeric,text,text,text,text,text,text) from public,anon,authenticated';
    execute 'grant execute on function public.record_payment(uuid,numeric,text,text,text,text,text,text) to authenticated';
  end if;
end $block$;
commit;

-- ═══════════════════════════════════════════════════════════
--  00024_finance_movements.sql
-- ═══════════════════════════════════════════════════════════

-- Cobros por servicio y gastos. Sólo bank_accounts_split revisado 2026-10-17.
-- Requiere FASE2 + COMPATIBILIDAD-CRM + LECTURA-CAJA. Respaldar antes.
-- No carga ejemplos, recalcula históricos, aplica deuda/crédito ni renueva planes.
begin;
do $$ begin
  if public.crm_finance_layout()<>'bank_accounts_split' then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;
  if exists(select 1 from pg_trigger where tgrelid in ('public.transactions'::regclass,'public.bank_accounts'::regclass) and not tgisinternal and tgenabled<>'D') then raise exception 'FINANCE_TRIGGER_REVIEW_REQUIRED'; end if;
end $$;
create table if not exists public.finance_entries (
  transaction_id uuid primary key references public.transactions(id) on delete restrict,
  request_id uuid not null unique,
  payload jsonb not null,
  receipt jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.finance_entries enable row level security;
revoke all on public.finance_entries from public,anon,authenticated;
grant select on public.finance_entries to authenticated;
drop policy if exists finance_entries_staff_read on public.finance_entries;
create policy finance_entries_staff_read on public.finance_entries for select to authenticated using (public.crm_is_staff());
-- Se cierra la escritura directa: movimiento y saldo sólo se cambian juntos.
revoke all on public.transactions,public.bank_accounts from public,anon,authenticated;
grant select on public.transactions,public.bank_accounts to authenticated;
create or replace function public.finance_writes_ready()
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select public.crm_finance_layout()='bank_accounts_split'
    and not exists(select 1 from pg_trigger where tgrelid in ('public.transactions'::regclass,'public.bank_accounts'::regclass,'public.finance_entries'::regclass) and not tgisinternal and tgenabled<>'D')
    and not exists(select 1 from unnest(array['public.transactions','public.bank_accounts','public.finance_entries']) as targets(tab)
      where has_table_privilege('authenticated',tab,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        or has_table_privilege('anon',tab,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'));
$$;
revoke all on function public.finance_writes_ready() from public,anon,authenticated;
create or replace function public.finance_options()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v:=public.crm_options();
  return (v-'payments_enabled'-'payment_block_reason') || jsonb_build_object('protocol','service-v1','writes_enabled',public.finance_writes_ready(),
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by display_order) from public.expense_categories),'[]'::jsonb));
end $$;
revoke all on function public.finance_options() from public,anon,authenticated;
grant execute on function public.finance_options() to authenticated;
create or replace function public.finance_record_movement(
  p_request uuid,p_kind text,p_client uuid,p_amount numeric,p_currency text,
  p_method text,p_account text,p_concept text,p_fx numeric,p_category text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp set lock_timeout='5s' as $$
declare
  v_payload jsonb; v_existing public.finance_entries; v_id uuid; v_actor uuid:=auth.uid();
  v_name text; v_actor_name text; v_profile uuid; v_method text; v_category text; v_account public.bank_accounts;
  v_nio numeric; v_usd numeric; v_delta numeric; v_after numeric; v_at timestamptz:=clock_timestamp();
  v_receipt jsonb;
begin
  select full_name into v_actor_name from public.profiles where id=v_actor for share;
  if not found or not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  v_payload:=jsonb_build_object('kind',p_kind,'client',p_client,'amount',p_amount,'currency',p_currency,
    'method',p_method,'account',p_account,'concept',trim(p_concept),'fx',p_fx,'category',p_category);
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into v_existing from public.finance_entries where request_id=p_request;
  if found then
    if v_existing.payload is distinct from v_payload then raise exception 'REQUEST_CONFLICT'; end if;
    return v_existing.transaction_id;
  end if;
  if not public.finance_writes_ready() then raise exception 'FINANCE_REVIEW_REQUIRED'; end if;
  if p_kind is null or p_kind not in ('service_income','expense')
    or p_amount is null or p_amount<=0 or p_amount>99999999 or p_amount<>round(p_amount,2)
    or p_currency is null or p_currency not in ('NIO','USD')
    or p_fx is null or p_fx<0.0001 or p_fx>10000 or p_fx<>round(p_fx,4)
    or p_concept is null or length(trim(p_concept)) not between 2 and 200
    or (p_kind='service_income' and (p_client is null or p_category is not null))
    or (p_kind='expense' and (p_client is not null or p_category is null)) then raise exception 'INVALID_PAYMENT'; end if;
  if p_kind='service_income' then
    select full_name,profile_id into v_name,v_profile from public.gym_clients where id=p_client for share;
    if not found then raise exception 'NOT_FOUND'; end if;
  else
    select name into v_category from public.expense_categories where id=p_category for share;
    if not found then raise exception 'INVALID_CATEGORY'; end if;
  end if;
  select name into v_method from public.payment_methods where id=p_method and is_active
    and currency in (p_currency,'BOTH') for share;
  if not found then raise exception 'INVALID_METHOD'; end if;
  select * into v_account from public.bank_accounts where id=p_account and is_active and currency=p_currency for update;
  if not found then raise exception 'INVALID_ACCOUNT'; end if;
  v_nio:=case when p_currency='NIO' then p_amount else round(p_amount*p_fx,2) end;
  v_usd:=case when p_currency='USD' then p_amount else round(p_amount/p_fx,4) end;
  v_delta:=case when p_kind='expense' then -p_amount else p_amount end;
  v_after:=v_account.balance+v_delta;
  if v_nio>9999999999.99 or v_usd>99999999.9999 or abs(v_after)>9999999999.99 then raise exception 'INVALID_PAYMENT'; end if;
  insert into public.transactions(type,status,occurred_at,account_id,method_id,category_id,member_id,
    client_id,crm_request_id,amount,currency,amount_nio,amount_usd,fx_used,concept,created_by,created_at,updated_at)
  values(case when p_kind='expense' then 'expense'::public.transaction_type else 'income'::public.transaction_type end,
    'completed',v_at,p_account,p_method,p_category,v_profile,p_client,p_request,p_amount,p_currency,v_nio,v_usd,p_fx,trim(p_concept),v_actor,v_at,v_at)
  returning id into v_id;
  update public.bank_accounts set balance=v_after where id=p_account;
  v_receipt:=jsonb_build_object('id',v_id,'reference','SG-'||v_id::text,'requestId',p_request,'kind',p_kind,
    'occurredAt',v_at,'amount',p_amount,'currency',p_currency,'amountNio',v_nio,'amountUsd',v_usd,'fx',p_fx,
    'concept',trim(p_concept),'clientId',p_client,'clientName',v_name,'categoryName',v_category,
    'accountId',p_account,'accountName',v_account.name,'methodName',v_method,'actorId',v_actor,
    'actorName',v_actor_name,
    'accountBefore',v_account.balance,'accountAfter',v_after);
  insert into public.finance_entries(transaction_id,request_id,payload,receipt) values(v_id,p_request,v_payload,v_receipt);
  if p_kind='service_income' then
    insert into public.client_events(client_id,action,details,actor_id)
      values(p_client,'payment',jsonb_build_object('transaction_id',v_id,'kind',p_kind),v_actor);
  end if;
  return v_id;
end $$;
revoke all on function public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text) from public,anon,authenticated;
grant execute on function public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text) to authenticated;
create or replace function public.finance_receipt(p_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select receipt into v from public.finance_entries where transaction_id=p_id;
  if not found then raise exception 'RECEIPT_NOT_FOUND'; end if;
  return v;
end $$;
revoke all on function public.finance_receipt(uuid) from public,anon,authenticated;
grant execute on function public.finance_receipt(uuid) to authenticated;
create or replace function public.finance_recent_receipts(p_kind text,p_client uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_kind is null or p_kind not in ('service_income','expense')
    or (p_kind='service_income' and p_client is null)
    or (p_kind='expense' and p_client is not null) then raise exception 'INVALID_PAYMENT'; end if;
  return coalesce((select jsonb_agg(receipt order by created_at desc,transaction_id) from (
    select receipt,created_at,transaction_id from public.finance_entries
    where payload->>'kind'=p_kind and (p_client is null or payload->>'client'=p_client::text)
    order by created_at desc,transaction_id limit 50
  ) r),'[]'::jsonb);
end $$;
revoke all on function public.finance_recent_receipts(text,uuid) from public,anon,authenticated;
grant execute on function public.finance_recent_receipts(text,uuid) to authenticated;
notify pgrst,'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00025_account_assigned_plan.sql
-- ═══════════════════════════════════════════════════════════

-- Plan asignado en la ficha CRM: consulta propia, sin modificar datos.
-- Requiere FASE2. No cobra, no renueva ni establece fechas de vigencia.
begin;
create or replace function public.crm_my_assigned_plan()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_plan text;
  v_details jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select plan_id into v_plan from public.gym_clients where profile_id=auth.uid();
  if not found then
    return jsonb_build_object('linked',false,'plan',null);
  end if;
  if v_plan is not null then
    select jsonb_build_object('id',id,'name_es',name_es,'name_en',name_en,'is_active',is_active)
      into v_details from public.plans where id=v_plan;
    if not found then raise exception 'PLAN_NOT_FOUND'; end if;
  end if;
  return jsonb_build_object('linked',true,'plan',v_details);
end $$;
revoke all on function public.crm_my_assigned_plan() from public, anon, authenticated;
grant execute on function public.crm_my_assigned_plan() to authenticated;
notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00026_booking_read_policy.sql
-- ═══════════════════════════════════════════════════════════

-- Reparación de lectura: reservas persistidas ocultas por RLS sin políticas.
-- Requiere FASE2. No modifica reservas, funciones de escritura ni otros permisos.
begin;
alter table public.bookings enable row level security;
drop policy if exists bookings_read_own_or_staff_v1 on public.bookings;
create policy bookings_read_own_or_staff_v1
  on public.bookings
  for select
  to authenticated
  using (user_id = auth.uid() or public.crm_is_staff());
grant select on public.bookings to authenticated;
notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00027_client_finance_read.sql
-- ═══════════════════════════════════════════════════════════

-- Lectura financiera de la ficha: no crea saldos ni modifica movimientos.
-- Requiere FASE2/compatibilidad CRM ya instalada. Ejecutar sólo este archivo.
begin;
create or replace function public.crm_detail(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_client public.gym_clients; v_layout text; v_balance numeric;
  v_balances jsonb; v_state text; v_collections jsonb; v_payments jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into v_client from public.gym_clients where id=p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_layout := public.crm_finance_layout();
  v_state := case when v_layout='unsupported' then 'unsupported'
    when v_client.profile_id is null then 'unlinked' else 'missing' end;
  if v_client.profile_id is not null then
    if v_layout='repository' then
      select balance_nio into v_balance from public.member_balances where member_id=v_client.profile_id;
      if found then v_state := 'ready'; end if;
    elsif v_layout='bank_accounts_split' then
      select jsonb_build_object('credit_nio',credit_nio,'credit_usd',credit_usd,'debt_nio',debt_nio,'debt_usd',debt_usd)
        into v_balances from public.member_balances where member_id=v_client.profile_id;
      if found then v_state := 'ready'; end if;
    end if;
  end if;
  if v_layout in ('repository','bank_accounts_split') then
    -- Sólo ingresos: el vínculo explícito de ficha prevalece sobre member_id legado.
    -- to_jsonb permite leer direction/type sin referenciar columnas inexistentes.
    with income as (
      select t.* from public.transactions t
      where (t.client_id=p_id or (t.client_id is null and v_client.profile_id is not null and t.member_id=v_client.profile_id))
        and (case when v_layout='repository' then to_jsonb(t)->>'direction' else to_jsonb(t)->>'type' end)='income'
    )
    select jsonb_build_object(
      'count_nio',count(*) filter(where status::text='completed' and currency::text='NIO'),
      'amount_nio',coalesce(sum(amount) filter(where status::text='completed' and currency::text='NIO'),0),
      'count_usd',count(*) filter(where status::text='completed' and currency::text='USD'),
      'amount_usd',coalesce(sum(amount) filter(where status::text='completed' and currency::text='USD'),0))
    into v_collections from income;
    select coalesce(jsonb_agg(to_jsonb(t) order by t.occurred_at desc,t.id desc),'[]'::jsonb)
    into v_payments from (
      select id,occurred_at,concept,amount,currency,status from public.transactions t
      where (t.client_id=p_id or (t.client_id is null and v_client.profile_id is not null and t.member_id=v_client.profile_id))
        and (case when v_layout='repository' then to_jsonb(t)->>'direction' else to_jsonb(t)->>'type' end)='income'
      order by occurred_at desc,id desc limit 40
    ) t;
  end if;
  return jsonb_build_object('client',to_jsonb(v_client),'card',public.crm_get_card(p_id),
    'visits',coalesce((select jsonb_agg(to_jsonb(v)) from (select * from public.client_visits where client_id=p_id order by visited_at desc limit 60)v),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(e)) from (select * from public.client_events where client_id=p_id order by created_at desc limit 40)e),'[]'::jsonb),
    'payments',coalesce(v_payments,'[]'::jsonb),'balance',v_balance,'balances',v_balances,'finance_layout',v_layout,
    'finance',jsonb_build_object('version',1,'client_id',p_id,'profile_id',v_client.profile_id,
      'layout',v_layout,'balance_status',v_state,'balance_nio',v_balance,'balances',v_balances,
      'collections',v_collections));
end $$;
revoke all on function public.crm_detail(uuid) from public, anon, authenticated;
grant execute on function public.crm_detail(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00028_debts_payments.sql
-- ═══════════════════════════════════════════════════════════

-- Deudas y abonos manuales. Sólo bank_accounts_split con COBROS-GASTOS instalado.
-- No importa saldos, renueva planes, compensa créditos ni convierte deudas.
begin;
do $$ begin
  if public.crm_finance_layout()<>'bank_accounts_split' or to_regclass('public.finance_entries') is null
    then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;
end $$;
create table if not exists public.client_debt_balances (
  client_id uuid primary key references public.gym_clients(id) on delete restrict,
  credit_nio numeric(12,2) not null check(credit_nio>=0),
  credit_usd numeric(12,2) not null check(credit_usd>=0),
  debt_nio numeric(12,2) not null check(debt_nio>=0),
  debt_usd numeric(12,2) not null check(debt_usd>=0),
  updated_at timestamptz not null default now()
);
create table if not exists public.client_debt_entries (
  id uuid primary key default gen_random_uuid(), request_id uuid not null unique,
  client_id uuid not null references public.gym_clients(id) on delete restrict,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  transaction_id uuid unique references public.transactions(id) on delete restrict,
  payload jsonb not null, receipt jsonb not null, created_at timestamptz not null default now()
);
create index if not exists client_debt_entries_client_idx on public.client_debt_entries(client_id,created_at desc,id);
alter table public.client_debt_balances enable row level security;
alter table public.client_debt_entries enable row level security;
revoke all on public.client_debt_balances,public.client_debt_entries from public,anon,authenticated;
grant select on public.client_debt_balances,public.client_debt_entries to authenticated;
drop policy if exists client_debt_balances_staff_read on public.client_debt_balances;
create policy client_debt_balances_staff_read on public.client_debt_balances for select to authenticated using(public.crm_is_staff());
drop policy if exists client_debt_entries_staff_read on public.client_debt_entries;
create policy client_debt_entries_staff_read on public.client_debt_entries for select to authenticated using(public.crm_is_staff());
revoke insert,update,delete,truncate,references,trigger on public.member_balances from public,anon,authenticated;

-- Cambiar el vínculo con saldos presentes exige una conciliación explícita, no copiar/mezclar.
create or replace function public.finance_protect_client_balance_link()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.profile_id is distinct from old.profile_id and
    (exists(select 1 from public.client_debt_balances where client_id=old.id)
      or exists(select 1 from public.member_balances where member_id=old.profile_id))
    then raise exception 'BALANCE_LINK_RECONCILIATION_REQUIRED'; end if;
  return new;
end $$;
revoke all on function public.finance_protect_client_balance_link() from public,anon,authenticated;
drop trigger if exists finance_protect_client_balance_link on public.gym_clients;
create trigger finance_protect_client_balance_link before update of profile_id on public.gym_clients
for each row execute function public.finance_protect_client_balance_link();

create or replace function public.finance_protect_profile_balance_delete()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if exists(select 1 from public.member_balances where member_id=old.id)
    then raise exception 'BALANCE_LINK_RECONCILIATION_REQUIRED'; end if;
  return old;
end $$;
revoke all on function public.finance_protect_profile_balance_delete() from public,anon,authenticated;
drop trigger if exists finance_protect_profile_balance_delete on public.profiles;
create trigger finance_protect_profile_balance_delete before delete on public.profiles
for each row execute function public.finance_protect_profile_balance_delete();

create or replace function public.finance_client_balance(p_client uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_values jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select profile_id into v_profile from public.gym_clients where id=p_client;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_profile is not null then
    if exists(select 1 from public.client_debt_balances where client_id=p_client)
      then raise exception 'BALANCE_LINK_RECONCILIATION_REQUIRED'; end if;
    select jsonb_build_object('credit_nio',credit_nio,'credit_usd',credit_usd,'debt_nio',debt_nio,'debt_usd',debt_usd)
      into v_values from public.member_balances where member_id=v_profile;
  else
    select jsonb_build_object('credit_nio',credit_nio,'credit_usd',credit_usd,'debt_nio',debt_nio,'debt_usd',debt_usd)
      into v_values from public.client_debt_balances where client_id=p_client;
  end if;
  return jsonb_build_object('clientId',p_client,'profileId',v_profile,'source',case when v_profile is null then 'client' else 'profile' end,
    'balances',v_values);
end $$;
revoke all on function public.finance_client_balance(uuid) from public,anon,authenticated;
grant execute on function public.finance_client_balance(uuid) to authenticated;

create or replace function public.finance_debt_ready()
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select public.finance_writes_ready() and to_regprocedure('public.finance_debt_report(text)') is not null
    and position('finance_record_movement_before_debts' in pg_get_functiondef('public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text)'::regprocedure))>0
    and position('finance_read_before_debts' in pg_get_functiondef('public.finance_read(text,integer)'::regprocedure))>0
    and position('finance_client_balance' in pg_get_functiondef('public.crm_detail(uuid)'::regprocedure))>0
    and not exists(
    select 1 from pg_trigger where tgrelid in ('public.member_balances'::regclass,'public.client_debt_balances'::regclass,'public.client_debt_entries'::regclass)
      and not tgisinternal and tgenabled<>'D') and not exists(
    select 1 from unnest(array['public.member_balances','public.client_debt_balances','public.client_debt_entries']) t(tab)
    where has_table_privilege('authenticated',tab,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      or has_table_privilege('anon',tab,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'));
$$;
revoke all on function public.finance_debt_ready() from public,anon,authenticated;

create or replace function public.finance_debt_record(
  p_request uuid,p_kind text,p_client uuid,p_amount numeric,p_currency text,p_concept text,
  p_method text default null,p_account text default null,p_fx numeric default null,p_open jsonb default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp set lock_timeout='5s' as $$
declare v_actor uuid:=auth.uid(); v_actor_name text; v_role text; v_client public.gym_clients;
  v_payload jsonb; v_existing public.client_debt_entries; v_before jsonb; v_after jsonb;
  v_balance jsonb; v_debt numeric; v_next numeric; v_id uuid:=gen_random_uuid(); v_tx uuid;
  v_receipt jsonb; v_at timestamptz:=clock_timestamp(); v_key text; v_n numeric;
begin
  select full_name,role::text into v_actor_name,v_role from public.profiles where id=v_actor for share;
  if not found or not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  v_payload:=jsonb_build_object('kind',p_kind,'client',p_client,'amount',p_amount,'currency',p_currency,
    'concept',trim(p_concept),'method',p_method,'account',p_account,'fx',p_fx,'opening',p_open);
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into v_existing from public.client_debt_entries where request_id=p_request;
  if found then
    if v_existing.payload is distinct from v_payload then raise exception 'REQUEST_CONFLICT'; end if;
    return v_existing.receipt;
  end if;
  if exists(select 1 from public.finance_entries where request_id=p_request) then raise exception 'REQUEST_CONFLICT'; end if;
  if not public.finance_debt_ready() then raise exception 'FINANCE_REVIEW_REQUIRED'; end if;
  if p_kind is null or p_kind not in ('opening','charge','payment') or p_client is null
    or p_concept is null or length(trim(p_concept)) not between 2 and 200 then raise exception 'INVALID_DEBT'; end if;
  if p_kind='opening' then
    if v_role<>'admin' then raise exception 'ADMIN_REQUIRED'; end if;
    if p_amount is not null or p_currency is not null or p_method is not null or p_account is not null or p_fx is not null
      or p_open is null or jsonb_typeof(p_open)<>'object' then raise exception 'INVALID_DEBT'; end if;
    if (select count(*) from jsonb_object_keys(p_open))<>4 then raise exception 'INVALID_DEBT'; end if;
    foreach v_key in array array['credit_nio','credit_usd','debt_nio','debt_usd'] loop
      if jsonb_typeof(p_open->v_key) is distinct from 'number' then raise exception 'INVALID_DEBT'; end if;
      v_n:=(p_open->>v_key)::numeric;
      if v_n<0 or v_n>9999999999.99 or v_n<>round(v_n,2) then raise exception 'INVALID_DEBT'; end if;
    end loop;
  else
    if p_open is not null or p_amount is null or p_amount<=0 or p_amount>99999999 or p_amount<>round(p_amount,2)
      or p_currency is null or p_currency not in ('NIO','USD') then raise exception 'INVALID_DEBT'; end if;
    if p_kind='charge' and (p_method is not null or p_account is not null or p_fx is not null) then raise exception 'INVALID_DEBT'; end if;
    if p_kind='payment' and (p_method is null or p_account is null or p_fx is null) then raise exception 'INVALID_DEBT'; end if;
  end if;
  select * into v_client from public.gym_clients where id=p_client for share;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform pg_advisory_xact_lock(hashtextextended('client-balance:'||coalesce(v_client.profile_id::text,p_client::text),0));
  if v_client.profile_id is not null then
    perform 1 from public.member_balances where member_id=v_client.profile_id for update;
  else
    perform 1 from public.client_debt_balances where client_id=p_client for update;
  end if;
  v_balance:=public.finance_client_balance(p_client); v_before:=v_balance->'balances';
  if p_kind='opening' then
    if v_before<>'null'::jsonb then raise exception 'BALANCE_ALREADY_EXISTS'; end if;
    if v_client.profile_id is not null then
      insert into public.member_balances(member_id,credit_nio,credit_usd,debt_nio,debt_usd)
        values(v_client.profile_id,(p_open->>'credit_nio')::numeric,(p_open->>'credit_usd')::numeric,(p_open->>'debt_nio')::numeric,(p_open->>'debt_usd')::numeric);
    else
      insert into public.client_debt_balances(client_id,credit_nio,credit_usd,debt_nio,debt_usd)
        values(p_client,(p_open->>'credit_nio')::numeric,(p_open->>'credit_usd')::numeric,(p_open->>'debt_nio')::numeric,(p_open->>'debt_usd')::numeric);
    end if;
  else
    if v_before='null'::jsonb then raise exception 'BALANCE_NOT_INITIALIZED'; end if;
    foreach v_key in array array['credit_nio','credit_usd','debt_nio','debt_usd'] loop
      v_n:=(v_before->>v_key)::numeric;
      if v_n is null or v_n<0 or v_n>9999999999.99 then raise exception 'INVALID_DEBT'; end if;
    end loop;
    v_key:=case when p_currency='NIO' then 'debt_nio' else 'debt_usd' end;
    v_debt:=(v_before->>v_key)::numeric;
    if v_debt is null or v_debt<0 then raise exception 'INVALID_DEBT'; end if;
    if p_kind='payment' and p_amount>v_debt then raise exception 'PAYMENT_EXCEEDS_DEBT'; end if;
    v_next:=v_debt+case when p_kind='charge' then p_amount else -p_amount end;
    if v_next>9999999999.99 then raise exception 'INVALID_DEBT'; end if;
    if p_kind='payment' then
      -- Reutiliza el escritor atómico revisado; la clasificación final se guarda antes del commit.
      v_tx:=public.finance_record_movement(p_request,'service_income',p_client,p_amount,p_currency,p_method,p_account,p_concept,p_fx,null);
      update public.finance_entries set payload=jsonb_set(payload,'{kind}','"debt_payment"'::jsonb),
        receipt=receipt||jsonb_build_object('kind','debt_payment','debtBefore',v_debt,'debtAfter',v_next)
        where transaction_id=v_tx;
      update public.client_events set details=details||jsonb_build_object('kind','debt_payment')
        where client_id=p_client and details->>'transaction_id'=v_tx::text;
    end if;
    if v_client.profile_id is not null then
      update public.member_balances set debt_nio=case when p_currency='NIO' then v_next else debt_nio end,
        debt_usd=case when p_currency='USD' then v_next else debt_usd end,updated_at=v_at where member_id=v_client.profile_id;
    else
      update public.client_debt_balances set debt_nio=case when p_currency='NIO' then v_next else debt_nio end,
        debt_usd=case when p_currency='USD' then v_next else debt_usd end,updated_at=v_at where client_id=p_client;
    end if;
  end if;
  v_after:=public.finance_client_balance(p_client)->'balances';
  v_receipt:=jsonb_build_object('id',v_id,'reference','SD-'||v_id::text,'requestId',p_request,'kind',p_kind,
    'clientId',p_client,'clientName',v_client.full_name,'actorId',v_actor,'actorName',v_actor_name,
    'occurredAt',v_at,'concept',trim(p_concept),'currency',p_currency,'amount',p_amount,
    'before',v_before,'after',v_after,'transactionId',v_tx);
  insert into public.client_debt_entries(id,request_id,client_id,actor_id,transaction_id,payload,receipt,created_at)
    values(v_id,p_request,p_client,v_actor,v_tx,v_payload,v_receipt,v_at);
  if p_kind<>'payment' then
    insert into public.client_events(client_id,action,details,actor_id)
      values(p_client,'debt_'||p_kind,jsonb_build_object('reference',v_id,'concept',trim(p_concept)),v_actor);
  end if;
  return v_receipt;
end $$;
revoke all on function public.finance_debt_record(uuid,text,uuid,numeric,text,text,text,text,numeric,jsonb) from public,anon,authenticated;
grant execute on function public.finance_debt_record(uuid,text,uuid,numeric,text,text,text,text,numeric,jsonb) to authenticated;
create or replace function public.finance_debt_detail(p_client uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb; v_role text;
begin
  v:=public.finance_client_balance(p_client);
  select role::text into v_role from public.profiles where id=auth.uid();
  return v||jsonb_build_object('clientName',(select full_name from public.gym_clients where id=p_client),'protocol','debt-v1','writesEnabled',public.finance_debt_ready(),'canOpen',v_role='admin',
    'entries',coalesce((select jsonb_agg(receipt order by created_at desc,id) from(
      select receipt,created_at,id from public.client_debt_entries where client_id=p_client order by created_at desc,id limit 50
    )e),'[]'::jsonb));
end $$;
revoke all on function public.finance_debt_detail(uuid) from public,anon,authenticated;
grant execute on function public.finance_debt_detail(uuid) to authenticated;

-- Envolver el lector existente, sin cambiar sus otras secciones ni fórmulas.
do $$ begin
  if to_regprocedure('public.finance_read_before_debts(text,integer)') is null then
    execute replace(pg_get_functiondef('public.finance_read(text,integer)'::regprocedure),
      'FUNCTION public.finance_read(', 'FUNCTION public.finance_read_before_debts(');
  end if;
end $$;
revoke all on function public.finance_read_before_debts(text,integer) from public,anon,authenticated;
create or replace function public.finance_read(p_section text,p_limit integer default 30)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if public.crm_finance_layout()<>'bank_accounts_split' then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;
  v:=public.finance_read_before_debts(p_section,p_limit);
  if p_section='summary' then
    v:=jsonb_set(v,'{data,totalOwed}',to_jsonb(coalesce((v#>>'{data,totalOwed}')::numeric,0)+(select coalesce(sum(debt_nio),0) from public.client_debt_balances)));
    v:=jsonb_set(v,'{data,totalOwedUsd}',to_jsonb(coalesce((v#>>'{data,totalOwedUsd}')::numeric,0)+(select coalesce(sum(debt_usd),0) from public.client_debt_balances)));
  elsif p_section='receivables' then
    select jsonb_set(v,'{data}',coalesce(jsonb_agg(r order by (r->>'total_owed_nio')::numeric desc,r->>'member_id',r->>'client_id'),'[]'::jsonb)) into v from (
      select value as r from jsonb_array_elements(v->'data')
      union all
      select jsonb_build_object('member_id',null,'client_id',c.id,'full_name',c.full_name,'email',c.email,'phone',c.phone,
        'invoices_open',null,'total_owed_nio',b.debt_nio,'total_owed_usd',b.debt_usd,'oldest_due',null,'days_overdue',null)
      from public.client_debt_balances b join public.gym_clients c on c.id=b.client_id where b.debt_nio>0 or b.debt_usd>0
    )r;
  end if;
  return v;
end $$;
revoke all on function public.finance_read(text,integer) from public,anon,authenticated;
grant execute on function public.finance_read(text,integer) to authenticated;

-- Mismo espacio de referencias para operaciones de deuda y de Caja.
do $$ begin
  if to_regprocedure('public.finance_record_movement_before_debts(uuid,text,uuid,numeric,text,text,text,text,numeric,text)') is null then
    execute replace(pg_get_functiondef('public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text)'::regprocedure),
      'FUNCTION public.finance_record_movement(', 'FUNCTION public.finance_record_movement_before_debts(');
  end if;
end $$;
revoke all on function public.finance_record_movement_before_debts(uuid,text,uuid,numeric,text,text,text,text,numeric,text) from public,anon,authenticated;
create or replace function public.finance_record_movement(
  p_request uuid,p_kind text,p_client uuid,p_amount numeric,p_currency text,p_method text,p_account text,p_concept text,p_fx numeric,p_category text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp set lock_timeout='5s' as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  if exists(select 1 from public.client_debt_entries where request_id=p_request) then raise exception 'REQUEST_CONFLICT'; end if;
  return public.finance_record_movement_before_debts(p_request,p_kind,p_client,p_amount,p_currency,p_method,p_account,p_concept,p_fx,p_category);
end $$;
revoke all on function public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text) from public,anon,authenticated;
grant execute on function public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text) to authenticated;

create or replace function public.crm_detail(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_client public.gym_clients; v_layout text; v_balance numeric;
  v_balances jsonb; v_state text; v_collections jsonb; v_payments jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into v_client from public.gym_clients where id=p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_layout := public.crm_finance_layout();
  v_state := case when v_layout='unsupported' then 'unsupported'
    when v_client.profile_id is null then 'unlinked' else 'missing' end;
  if v_layout='bank_accounts_split' then
    v_balances:=public.finance_client_balance(p_id)->'balances';
    if v_balances is not null and v_balances<>'null'::jsonb then v_state:='ready'; else v_balances:=null; end if;
  elsif v_layout='repository' and v_client.profile_id is not null then
    select balance_nio into v_balance from public.member_balances where member_id=v_client.profile_id;
    if found then v_state:='ready'; end if;
  end if;
  if v_layout in ('repository','bank_accounts_split') then
    -- Sólo ingresos: el vínculo explícito de ficha prevalece sobre member_id legado.
    -- to_jsonb permite leer direction/type sin referenciar columnas inexistentes.
    with income as (
      select t.* from public.transactions t
      where (t.client_id=p_id or (t.client_id is null and v_client.profile_id is not null and t.member_id=v_client.profile_id))
        and (case when v_layout='repository' then to_jsonb(t)->>'direction' else to_jsonb(t)->>'type' end)='income'
    )
    select jsonb_build_object(
      'count_nio',count(*) filter(where status::text='completed' and currency::text='NIO'),
      'amount_nio',coalesce(sum(amount) filter(where status::text='completed' and currency::text='NIO'),0),
      'count_usd',count(*) filter(where status::text='completed' and currency::text='USD'),
      'amount_usd',coalesce(sum(amount) filter(where status::text='completed' and currency::text='USD'),0))
    into v_collections from income;
    select coalesce(jsonb_agg(to_jsonb(t) order by t.occurred_at desc,t.id desc),'[]'::jsonb)
    into v_payments from (
      select id,occurred_at,concept,amount,currency,status from public.transactions t
      where (t.client_id=p_id or (t.client_id is null and v_client.profile_id is not null and t.member_id=v_client.profile_id))
        and (case when v_layout='repository' then to_jsonb(t)->>'direction' else to_jsonb(t)->>'type' end)='income'
      order by occurred_at desc,id desc limit 40
    ) t;
  end if;
  return jsonb_build_object('client',to_jsonb(v_client),'card',public.crm_get_card(p_id),
    'visits',coalesce((select jsonb_agg(to_jsonb(v)) from (select * from public.client_visits where client_id=p_id order by visited_at desc limit 60)v),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(e)) from (select * from public.client_events where client_id=p_id order by created_at desc limit 40)e),'[]'::jsonb),
    'payments',coalesce(v_payments,'[]'::jsonb),'balance',v_balance,'balances',v_balances,'finance_layout',v_layout,
    'finance',jsonb_build_object('version',1,'client_id',p_id,'profile_id',v_client.profile_id,
      'source',case when v_client.profile_id is null then 'client' else 'profile' end,'layout',v_layout,'balance_status',v_state,'balance_nio',v_balance,'balances',v_balances,
      'collections',v_collections));
end $$;
revoke all on function public.crm_detail(uuid) from public, anon, authenticated;
grant execute on function public.crm_detail(uuid) to authenticated;
-- Capacidad explícita: evita vistas nativas antiguas que omitan fichas sin login.
create or replace function public.finance_debt_report(p_section text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if p_section not in ('summary','receivables') or p_section is null then raise exception 'INVALID_FINANCE_SECTION'; end if;
  return public.finance_read(p_section,30);
end $$;
revoke all on function public.finance_debt_report(text) from public,anon,authenticated;
grant execute on function public.finance_debt_report(text) to authenticated;
notify pgrst,'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00029_cash_change.sql
-- ═══════════════════════════════════════════════════════════

-- Efectivo recibido y vuelto para abonos, en la misma moneda.
-- Requiere DEUDAS-ABONOS (00028). No registra operaciones ni altera saldos al instalar.
begin;
do $$ begin
  if public.crm_finance_layout()<>'bank_accounts_split' or to_regprocedure('public.finance_debt_detail(uuid)') is null
    then raise exception 'DEBTS_SETUP_REQUIRED'; end if;
end $$;

create or replace function public.finance_debt_record_with_cash(
  p_request uuid,p_kind text,p_client uuid,p_amount numeric,p_currency text,p_concept text,
  p_method text,p_account text,p_fx numeric,p_open jsonb,p_cash_received numeric
) returns jsonb language plpgsql security definer set search_path=public,pg_temp set lock_timeout='5s' as $$
declare v_payload jsonb; v_existing public.client_debt_entries; v_receipt jsonb; v_change numeric; v_rows integer;
begin
  perform 1 from public.profiles where id=auth.uid() for share;
  if not found or not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  v_payload:=jsonb_build_object('kind',p_kind,'client',p_client,'amount',p_amount,'currency',p_currency,
    'concept',trim(p_concept),'method',p_method,'account',p_account,'fx',p_fx,'opening',p_open,'cash_received',p_cash_received);
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into v_existing from public.client_debt_entries where request_id=p_request;
  if found then
    if v_existing.payload is distinct from v_payload then raise exception 'REQUEST_CONFLICT'; end if;
    return v_existing.receipt;
  end if;
  if p_kind is distinct from 'payment' or p_open is not null or p_amount is null or p_amount<=0 or p_amount>99999999
    or p_amount<>round(p_amount,2) or p_cash_received is null or p_cash_received<p_amount or p_cash_received>99999999
    or p_cash_received<>round(p_cash_received,2) then raise exception 'INVALID_CASH_RECEIVED'; end if;
  v_change:=p_cash_received-p_amount;
  -- El escritor base valida deuda, método, FX y cuenta; ingresa sólo el abono neto.
  v_receipt:=public.finance_debt_record(p_request,p_kind,p_client,p_amount,p_currency,p_concept,p_method,p_account,p_fx,p_open);
  -- La cuenta ya está bloqueada por el escritor base: no invertir orden de locks.
  -- No se infiere efectivo por el nombre del método. El personal declara entrega
  -- física y sólo puede usar una cuenta de caja activa, en la moneda de la deuda.
  perform 1 from public.bank_accounts where id=p_account and is_active and account_type='caja_fuerte' and currency=p_currency;
  if not found then raise exception 'CASH_ACCOUNT_REQUIRED'; end if;
  v_receipt:=v_receipt||jsonb_build_object('cashReceived',p_cash_received,'changeGiven',v_change);
  update public.client_debt_entries set payload=v_payload,receipt=v_receipt where request_id=p_request;
  get diagnostics v_rows=row_count;
  if v_rows<>1 then raise exception 'CASH_RECEIPT_UNCONFIRMED'; end if;
  update public.finance_entries set receipt=receipt||jsonb_build_object('cashReceived',p_cash_received,'changeGiven',v_change)
    where transaction_id=(v_receipt->>'transactionId')::uuid;
  get diagnostics v_rows=row_count;
  if v_rows<>1 then raise exception 'CASH_RECEIPT_UNCONFIRMED'; end if;
  update public.client_events set details=details||jsonb_build_object('cash_received',p_cash_received,'change_given',v_change)
    where client_id=p_client and details->>'transaction_id'=v_receipt->>'transactionId';
  get diagnostics v_rows=row_count;
  if v_rows<>1 then raise exception 'CASH_RECEIPT_UNCONFIRMED'; end if;
  return v_receipt;
end $$;
revoke all on function public.finance_debt_record_with_cash(uuid,text,uuid,numeric,text,text,text,text,numeric,jsonb,numeric) from public,anon,authenticated;
grant execute on function public.finance_debt_record_with_cash(uuid,text,uuid,numeric,text,text,text,text,numeric,jsonb,numeric) to authenticated;

-- Capacidad explícita; clientes anteriores y referencias pendientes sin efectivo
-- continúan usando la firma original, sin inventar efectivo recibido histórico.
do $$ begin
  if to_regprocedure('public.finance_debt_detail_before_cash(uuid)') is null then
    execute replace(pg_get_functiondef('public.finance_debt_detail(uuid)'::regprocedure),
      'FUNCTION public.finance_debt_detail(', 'FUNCTION public.finance_debt_detail_before_cash(');
  end if;
end $$;
revoke all on function public.finance_debt_detail_before_cash(uuid) from public,anon,authenticated;
create or replace function public.finance_debt_detail(p_client uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  return public.finance_debt_detail_before_cash(p_client)||jsonb_build_object('cashProtocol','cash-v1',
    'cashAccounts',coalesce((select jsonb_agg(id order by id) from public.bank_accounts where is_active and account_type='caja_fuerte'),'[]'::jsonb));
end $$;
revoke all on function public.finance_debt_detail(uuid) from public,anon,authenticated;
grant execute on function public.finance_debt_detail(uuid) to authenticated;
notify pgrst,'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00030_access_hardening.sql
-- ═══════════════════════════════════════════════════════════

-- Seguridad 1A: permisos de perfiles, vistas y RPC de mantenimiento.
-- Compatible con repository y bank_accounts_split. Requiere FASE2/00020.
-- No modifica registros, saldos, planes ni escritores de dinero.
-- Aplicar SOLO este incremental; no reinstalar SETUP/FASE2/00028/00029.
begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.profiles') is null
     or to_regprocedure('public.crm_is_staff()') is null then
    raise exception 'SECURITY_PREREQUISITE_MISSING';
  end if;
end $$;

-- Ningún usuario de la API necesita crear objetos del esquema.
revoke create on schema public from public, anon, authenticated;

-- El registro se crea desde Auth/trigger; cambios comerciales vía RPC autorizada.
-- Revocar también grants por columna: quitar el grant de tabla no los elimina.
revoke all on table public.profiles from public, anon, authenticated;
do $$ declare cols text; begin
  select string_agg(quote_ident(attname), ', ' order by attnum) into cols
  from pg_attribute where attrelid='public.profiles'::regclass
    and attnum>0 and not attisdropped;
  execute format('revoke all (%s) on table public.profiles from public, anon, authenticated', cols);
end $$;
grant select on table public.profiles to authenticated;
grant update (full_name, phone) on table public.profiles to authenticated;
alter table public.profiles enable row level security;

-- Lectores administrativos necesitan nombres al unir perfiles con finanzas.
-- Helper SECURITY DEFINER sin recursión; clientes siguen viendo sólo su perfil.
drop policy if exists security_profiles_staff_read on public.profiles;
create policy security_profiles_staff_read on public.profiles
  for select to authenticated using (public.crm_is_staff());

-- La política permisiva antigua de bank_accounts permitía leer saldos a cualquier
-- usuario autenticado. Una política RESTRICTIVE se combina con todas las anteriores.
do $$ begin
  if to_regclass('public.bank_accounts') is not null then
    execute 'alter table public.bank_accounts enable row level security';
    execute 'revoke all on table public.bank_accounts from public, anon';
    execute 'drop policy if exists security_bank_accounts_staff_read on public.bank_accounts';
    execute 'create policy security_bank_accounts_staff_read on public.bank_accounts as restrictive for select to authenticated using (public.crm_is_staff())';
  end if;
end $$;

-- Permisos explícitos necesarios al pasar vistas a invoker. No se concede
-- escritura. Fallar antes de conceder SELECT si una tabla no tiene RLS.
do $$ declare t text; begin
  foreach t in array array['transactions','member_balances','invoices',
    'payment_methods','accounts','bank_accounts','cash_registers'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    if not exists(select 1 from pg_class where oid=to_regclass('public.' || t) and relrowsecurity) then
      raise exception 'SECURITY_TABLE_RLS_REQUIRED: %', t;
    end if;
    execute format('grant select on table public.%I to authenticated', t);
    if t in ('transactions','member_balances','invoices') then
      execute format('drop policy if exists security_finance_own_or_staff on public.%I', t);
      execute format('create policy security_finance_own_or_staff on public.%I as restrictive for select to authenticated using (member_id=(select auth.uid()) or (select public.crm_is_staff()))', t);
    end if;
  end loop;
end $$;

-- Vistas financieras: RLS/permisos DEL SOLICITANTE, nunca del propietario.
-- Clientes sólo pueden alcanzar filas propias cuando la política lo permite;
-- cuentas globales requieren staff. Se eliminan todos los grants públicos/escritura.
do $$ declare v text; cols text; begin
  foreach v in array array[
    'v_daily_cash','v_accounts_receivable','v_monthly_pnl',
    'v_payment_methods_breakdown','v_member_account',
    'v_account_balances','v_expenses_by_category','v_members_with_debt',
    'v_monthly_summary','v_top_members'
  ] loop
    if to_regclass('public.' || v) is null then continue; end if;
    if not exists(select 1 from pg_class where oid=to_regclass('public.' || v) and relkind='v') then
      raise exception 'SECURITY_EXPECTED_VIEW: %', v;
    end if;
    execute format('alter view public.%I set (security_invoker=true, security_barrier=true)', v);
    execute format('revoke all on table public.%I from public, anon, authenticated', v);
    select string_agg(quote_ident(attname), ', ' order by attnum) into cols
    from pg_attribute where attrelid=to_regclass('public.' || v)
      and attnum>0 and not attisdropped;
    execute format('revoke all (%s) on table public.%I from public, anon, authenticated', cols, v);
    execute format('grant select on table public.%I to authenticated', v);
  end loop;
end $$;

-- EXCEPCIÓN INTENCIONAL: ocupación pública agregada, sin datos de personas.
-- No pasarla a invoker: contaría sólo las reservas propias y falsearía los cupos.
-- Mantener únicamente los dos campos revisados y acceso de sólo lectura.
do $$ begin
  if to_regclass('public.session_occupancy') is not null then
    if (select array_agg(attname::text order by attnum) from pg_attribute
        where attrelid='public.session_occupancy'::regclass and attnum>0 and not attisdropped)
       is distinct from array['session_id','booked_count']::text[] then
      raise exception 'SECURITY_OCCUPANCY_COLUMNS_UNEXPECTED';
    end if;
    execute 'revoke all on table public.session_occupancy from public, anon, authenticated';
    execute 'grant select on table public.session_occupancy to anon, authenticated';
  end if;
end $$;

-- Funciones CRM: retirar ejecución pública heredada sin abrir helpers privados.
-- Mantener grants authenticated ya existentes y comprobaciones internas de rol.
do $$ declare f record; signature text; begin
  for f in select proname, proargtypes,
    has_function_privilege('authenticated', oid, 'EXECUTE') can_execute from pg_proc
    where pronamespace='public'::regnamespace
      and (left(proname,4)='crm_' or proname in ('book_session','cancel_booking','handle_new_user'))
  loop
    signature := format('public.%I(%s)', f.proname, oidvectortypes(f.proargtypes));
    if f.can_execute then
      execute format('grant execute on function %s to authenticated', signature);
    end if;
    execute format('revoke all on function %s from public, anon', signature);
  end loop;
  -- No están usadas por la web: mantenimiento sólo por SQL/servicio autorizado.
  -- Así se cierra la excepción antigua que admitía auth.uid() NULL.
  for f in select proname, proargtypes from pg_proc
    where pronamespace='public'::regnamespace
      and proname in ('generate_week_sessions','close_past_sessions')
  loop
    signature := format('public.%I(%s)', f.proname, oidvectortypes(f.proargtypes));
    execute format('revoke all on function %s from public, anon, authenticated', signature);
  end loop;
end $$;
notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00031_personal_requiere_mfa.sql
-- ═══════════════════════════════════════════════════════════

-- ESTADO: APLICADA EN SUPABASE (según docs/PENDIENTES-ACTUALES.md, PR #14). No volver a aplicar.
-- Objetivo: que el personal (admin/staff) sólo lea datos protegidos con MFA verificado (AAL2).
-- Cambia sólo crm_is_staff(): las políticas RLS y RPC existentes ya la usan.
-- No crea tablas, no borra datos, no cambia roles ni planes ni saldos.
-- Efecto esperado: personal sin MFA ve sólo lo permitido a clientes (su propia información).
-- Rollback: ver bloque al final.
begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('auth.jwt()') is null then
    raise exception 'MFA_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.crm_is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(
       select 1 from public.profiles
       where id = auth.uid() and role in ('admin', 'staff')
     );
$$;

revoke all on function public.crm_is_staff() from public, anon;
grant execute on function public.crm_is_staff() to authenticated;

notify pgrst, 'reload schema';
commit;

-- ROLLBACK (sólo si hay que volver atrás; pegar en lugar del bloque anterior):
-- begin;
-- create or replace function public.crm_is_staff()
-- returns boolean language sql stable security definer set search_path = public, pg_temp
-- as $$ select exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff')); $$;
-- revoke all on function public.crm_is_staff() from public;
-- grant execute on function public.crm_is_staff() to authenticated;
-- notify pgrst, 'reload schema';
-- commit;

-- ═══════════════════════════════════════════════════════════
--  00032_mfa_is_staff_y_privilegios_anon.sql
-- ═══════════════════════════════════════════════════════════

-- 00032 APLICADO en Supabase el 2026-10-18 con autorización del usuario. Prueba local previa: 14 comprobaciones.
-- Objetivo:
--   1) is_staff() exige aal2, igual que crm_is_staff() (00031). 22 políticas usan is_staff() sin MFA.
--   2) Quitar TRUNCATE, REFERENCES y TRIGGER a anon y authenticated en tablas de public.
--      Las políticas RLS no cubren TRUNCATE; la API no lo ofrece, pero el permiso sobra.
-- No cambia SELECT/INSERT/UPDATE/DELETE ni políticas RLS: esas se revisan aparte.

begin;
set local lock_timeout = '5s';

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(
       select 1 from public.profiles
       where id = auth.uid() and role in ('admin', 'staff')
     );
$$;

revoke all on function public.is_staff() from public, anon;
grant execute on function public.is_staff() to authenticated;

do $$
declare r record;
begin
  for r in
    select c.relname from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','p')
  loop
    execute format('revoke truncate, references, trigger on public.%I from anon, authenticated', r.relname);
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;

-- ROLLBACK (sólo si hay problemas y con autorización):
-- create or replace function public.is_staff() ... (definición anterior sin aal2)
-- grant truncate, references, trigger on all tables in schema public to anon, authenticated;

-- ═══════════════════════════════════════════════════════════
--  00033_roles_fase_a.sql
-- ═══════════════════════════════════════════════════════════

-- 00033 FASE A: APLICADA en Supabase el 2026-10-18 con autorización del usuario. Verificada en solo lectura.
-- Objetivo: base segura para roles de caja y entrenador, SIN cambiar lo que ya funciona.
--   1) Agrega los roles `cashier` y `trainer` al tipo user_role.
--   2) Tabla staff_permissions: interruptores que controla el administrador (cashier_can_void = false).
--   3) Funciones is_admin(), is_cashier(), is_trainer() exigen aal2 (MFA).
--   4) NO cambia is_staff(), crm_is_staff(), ni ninguna regla existente.
-- Efecto: un usuario con rol cashier o trainer no obtiene acceso nuevo; las reglas actuales
-- sólo reconocen admin y staff, así que siguen negándole el acceso.

-- Los valores de enum deben agregarse antes de usarlos; esta sentencia va primero.
alter type public.user_role add value if not exists 'cashier';
alter type public.user_role add value if not exists 'trainer';

begin;
set local lock_timeout = '5s';

-- 2) Permisos configurables por el administrador
create table if not exists public.staff_permissions (
  key        text primary key check (key ~ '^[a-z_]{3,60}$'),
  enabled    boolean not null default false,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.staff_permissions (key, enabled)
values ('cashier_can_void', false)
on conflict (key) do nothing;

alter table public.staff_permissions enable row level security;

-- 3) Funciones de rol con MFA
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(select 1 from public.profiles where id = auth.uid() and role::text = 'admin');
$$;

create or replace function public.is_cashier()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(select 1 from public.profiles where id = auth.uid() and role::text = 'cashier');
$$;

create or replace function public.is_trainer()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(select 1 from public.profiles where id = auth.uid() and role::text = 'trainer');
$$;

revoke all on function public.is_admin(), public.is_cashier(), public.is_trainer() from public, anon;
grant execute on function public.is_admin(), public.is_cashier(), public.is_trainer() to authenticated;

-- 2b) Acceso: sólo el administrador lee y cambia interruptores; nadie crea ni borra permisos.
revoke all on public.staff_permissions from anon, authenticated;
grant select on public.staff_permissions to authenticated;
grant update (enabled, updated_by, updated_at) on public.staff_permissions to authenticated;

drop policy if exists staff_permissions_admin_read on public.staff_permissions;
create policy staff_permissions_admin_read on public.staff_permissions
  for select to authenticated using (public.is_admin());

drop policy if exists staff_permissions_admin_update on public.staff_permissions;
create policy staff_permissions_admin_update on public.staff_permissions
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

notify pgrst, 'reload schema';
commit;

-- ROLLBACK (sólo con autorización):
-- drop table if exists public.staff_permissions;
-- drop function if exists public.is_admin(); drop function if exists public.is_cashier(); drop function if exists public.is_trainer();
-- (Los valores 'cashier' y 'trainer' del enum no se pueden quitar fácilmente; no tienen usuarios asignados.)

-- ═══════════════════════════════════════════════════════════
--  00034_roles_fase_b.sql
-- ═══════════════════════════════════════════════════════════

-- 00034 FASE B: separar permisos por función (caja, entrenador, administrador).
-- ESTADO: APLICADO EN SUPABASE (proyecto hcnuepdxmbsmlzdmvwhx). Incluye quitar la política antigua 'Staff can write coaches' tras detectar que caja podía escribir entrenadores.
-- Requiere: 00030, 00031 (crm_is_staff), 00032 (aal2) y 00033 (roles cashier/trainer, is_admin, is_cashier, is_trainer).
-- Aplicar sólo con autorización expresa. Una sentencia por llamada si se usa execute_query.
--
-- Reglas de la fase:
-- - "Personal" con acceso a datos (is_staff / crm_is_staff) = administrador o caja, siempre con MFA (aal2).
--   El entrenador NO entra en esas reglas: no ve teléfono, correo, saldos ni cobros.
-- - Planes, clases, entrenadores, horarios e importación = sólo administrador.
-- - Cuentas que tenían rol 'staff' pasan a 'trainer' (decisión del dueño). Pierden acceso a caja.
-- - El administrador asigna roles con admin_set_role(), queda bitácora en role_changes.
--   No puede cambiar su propio rol ni quitar al último administrador.
-- - Lista del entrenador sin datos de contacto: trainer_roster().

begin;
set local lock_timeout = '5s';

-- 1) Cuentas 'staff' existentes pasan a entrenador (decisión del dueño).
update public.profiles set role = 'trainer' where role = 'staff';

-- 2) Guardias de datos: administrador o caja, con MFA. El entrenador queda fuera.
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(select 1 from public.profiles where id = auth.uid() and role::text in ('admin', 'cashier'));
$$;

create or replace function public.crm_is_staff()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(select 1 from public.profiles where id = auth.uid() and role::text in ('admin', 'cashier'));
$$;

-- 3) Sólo administrador: planes, clases, entrenadores y horarios.
drop policy if exists "planes: el staff escribe" on public.plans;
create policy "planes: el admin escribe" on public.plans
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "clases: el staff escribe" on public.classes;
create policy "clases: el admin escribe" on public.classes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Staff can write coaches" on public.coaches;
drop policy if exists "profes: el staff escribe" on public.coaches;
create policy "profes: el admin escribe" on public.coaches
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "horarios: el staff escribe" on public.sessions;
create policy "horarios: el admin escribe" on public.sessions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 4) Sólo administrador: reporte de deudas e importación masiva de clientes.
create or replace function public.finance_debt_report(p_section text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_section not in ('summary', 'receivables') or p_section is null then raise exception 'INVALID_FINANCE_SECTION'; end if;
  return public.finance_read(p_section, 30);
end $$;
revoke all on function public.finance_debt_report(text) from public, anon, authenticated;
grant execute on function public.finance_debt_report(text) to authenticated;

do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.crm_import_client(jsonb)'::regprocedure);
  if position('if not public.crm_is_staff() then' in v_def) = 0 then
    raise exception 'CRM_IMPORT_GUARD_NOT_FOUND';
  end if;
  execute replace(v_def, 'if not public.crm_is_staff() then', 'if not public.is_admin() then');
end $$;

-- 5) Entrenador: lista de sus clientes activos con nombre y asistencia. Sin teléfono, correo ni notas.
create or replace function public.trainer_roster()
returns table(client_id uuid, full_name text, visits_30d integer, visited_today boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_today date := (now() at time zone 'America/Managua')::date;
begin
  if not public.is_trainer() then raise exception 'AUTH'; end if;
  return query
    select c.id, c.full_name,
      (select count(*)::int from public.client_visits v
         where v.client_id = c.id and v.local_day > v_today - 30 and v.local_day <= v_today),
      exists(select 1 from public.client_visits v where v.client_id = c.id and v.local_day = v_today)
    from public.gym_clients c
    where c.status = 'active'
    order by lower(c.full_name);
end $$;
revoke all on function public.trainer_roster() from public, anon;
grant execute on function public.trainer_roster() to authenticated;

-- 6) Bitácora de cambios de rol (sólo administrador lee).
create table if not exists public.role_changes (
  id bigint generated always as identity primary key,
  target_id uuid not null references public.profiles(id) on delete cascade,
  old_role text not null,
  new_role text not null,
  changed_by uuid references public.profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);
alter table public.role_changes enable row level security;
revoke all on public.role_changes from anon, authenticated;
grant select on public.role_changes to authenticated;
drop policy if exists role_changes_admin_read on public.role_changes;
create policy role_changes_admin_read on public.role_changes
  for select to authenticated using (public.is_admin());

-- 7) Asignación de roles desde el panel del administrador.
create or replace function public.admin_set_role(p_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_old text; v_admins integer;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_role not in ('member', 'cashier', 'trainer', 'admin') then raise exception 'INVALID_ROLE'; end if;
  if p_id is null or p_id = auth.uid() then raise exception 'SELF_ROLE_CHANGE'; end if;
  select role::text into v_old from public.profiles where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old = p_role then return; end if;
  if v_old = 'admin' then
    select count(*) into v_admins from public.profiles where role = 'admin';
    if v_admins <= 1 then raise exception 'LAST_ADMIN'; end if;
  end if;
  update public.profiles set role = p_role::public.user_role where id = p_id;
  insert into public.role_changes(target_id, old_role, new_role, changed_by)
    values (p_id, v_old, p_role, auth.uid());
end $$;
revoke all on function public.admin_set_role(uuid, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00035_asignacion_entrenador.sql
-- ═══════════════════════════════════════════════════════════

-- 00035 ASIGNACIÓN ENTRENADOR-CLIENTE. ESTADO: APLICADO EN SUPABASE (proyecto hcnuepdxmbsmlzdmvwhx) tras prueba local 59/59.
-- Requiere 00034 (roles caja/entrenador, is_admin/is_cashier/is_trainer, is_staff sin entrenador).
--
-- Reglas:
-- - El entrenador sólo ve a los clientes con acceso APROBADO para él (trainer_roster).
-- - Pedir acceso: el entrenador para sí mismo, o caja en nombre de un entrenador.
-- - Interruptor: el administrador activa o desactiva la búsqueda y los pedidos del entrenador (desactivado por defecto).
-- - Caja NO aprueba. Sólo el administrador (con MFA) aprueba, rechaza o revoca.
-- - Todas las escrituras van por funciones; las tablas no admiten INSERT/UPDATE/DELETE directo.
-- - El entrenador busca clientes por nombre sólo para pedirlos: devuelve id, nombre y su estado. Sin contacto.

begin;
set local lock_timeout = '5s';

-- 0) Interruptor del administrador: el entrenador puede buscar y pedir clientes sólo si está activo.
--    Desactivado por defecto. Lo cambia el administrador con MFA desde staff_permissions (00033).
--    Desactivarlo NO quita los clientes ya aprobados; sólo impide nuevos pedidos y búsquedas del entrenador.
insert into public.staff_permissions(key, enabled)
values ('trainer_can_request_clients', false)
on conflict (key) do nothing;

-- 1) Tabla de accesos (una fila por pedido; estado en la fila).
create table if not exists public.trainer_client_access (
  id           uuid primary key default gen_random_uuid(),
  trainer_id   uuid not null references public.profiles(id) on delete cascade,
  client_id    uuid not null references public.gym_clients(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'revoked')),
  requested_by uuid references public.profiles(id) on delete set null,
  requested_via text not null check (requested_via in ('trainer', 'cashier')),
  reason       text check (reason is null or length(reason) <= 300),
  created_at   timestamptz not null default now(),
  decided_by   uuid references public.profiles(id) on delete set null,
  decided_at   timestamptz
);

-- Como máximo un pedido abierto (pendiente o aprobado) por entrenador y cliente.
create unique index if not exists trainer_client_access_open_idx
  on public.trainer_client_access (trainer_id, client_id)
  where status in ('pending', 'approved');
create index if not exists trainer_client_access_trainer_idx
  on public.trainer_client_access (trainer_id, status);

alter table public.trainer_client_access enable row level security;
revoke all on public.trainer_client_access from anon, authenticated;
grant select on public.trainer_client_access to authenticated;

-- Lectura: administrador y caja ven todo; el entrenador ve sólo sus propias filas.
drop policy if exists trainer_access_read on public.trainer_client_access;
create policy trainer_access_read on public.trainer_client_access
  for select to authenticated
  using (
    public.is_admin()
    or public.is_cashier()
    or (public.is_trainer() and trainer_id = auth.uid())
  );

-- Lectura del interruptor desde funciones (el entrenador no lee staff_permissions directamente).
create or replace function public.trainer_request_enabled()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select enabled from public.staff_permissions where key = 'trainer_can_request_clients'), false);
$$;
revoke all on function public.trainer_request_enabled() from public, anon;
grant execute on function public.trainer_request_enabled() to authenticated;

-- 2) Pedir acceso: entrenador (para sí mismo) o caja (en nombre de un entrenador).
create or replace function public.request_trainer_access(p_trainer uuid, p_client uuid, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_caller uuid := auth.uid(); v_id uuid; v_status text; v_existing record;
begin
  if not (public.is_trainer() or public.is_cashier()) then raise exception 'AUTH'; end if;
  if public.is_trainer() and p_trainer is distinct from v_caller then raise exception 'AUTH'; end if;
  if public.is_trainer() and not public.trainer_request_enabled() then raise exception 'PERMISSION_DISABLED'; end if;
  if p_trainer is null or not exists(select 1 from public.profiles where id = p_trainer and role = 'trainer') then
    raise exception 'INVALID_TRAINER';
  end if;
  if p_reason is not null and length(p_reason) > 300 then raise exception 'INVALID_REASON'; end if;

  select status into v_status from public.gym_clients where id = p_client;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_status <> 'active' then raise exception 'INACTIVE_CLIENT'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_trainer::text || ':' || p_client::text, 0));
  select id, status into v_existing from public.trainer_client_access
    where trainer_id = p_trainer and client_id = p_client and status in ('pending', 'approved');
  if found then
    if v_existing.status = 'approved' then raise exception 'ALREADY_APPROVED'; end if;
    return v_existing.id;  -- pedido pendiente: no se duplica
  end if;

  insert into public.trainer_client_access(trainer_id, client_id, requested_by, requested_via, reason)
    values (p_trainer, p_client, v_caller,
            case when public.is_trainer() then 'trainer' else 'cashier' end, p_reason)
    returning id into v_id;
  return v_id;
end $$;
revoke all on function public.request_trainer_access(uuid, uuid, text) from public, anon;
grant execute on function public.request_trainer_access(uuid, uuid, text) to authenticated;

-- 3) Decisión: sólo administrador con MFA.
create or replace function public.admin_decide_trainer_access(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_old text;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_decision not in ('approved', 'rejected', 'revoked') then raise exception 'INVALID_DECISION'; end if;
  select status into v_old from public.trainer_client_access where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_decision in ('approved', 'rejected') and v_old <> 'pending' then raise exception 'INVALID_STATE'; end if;
  if p_decision = 'revoked' and v_old <> 'approved' then raise exception 'INVALID_STATE'; end if;
  update public.trainer_client_access
    set status = p_decision, decided_by = auth.uid(), decided_at = now()
    where id = p_id;
end $$;
revoke all on function public.admin_decide_trainer_access(uuid, text) from public, anon;
grant execute on function public.admin_decide_trainer_access(uuid, text) to authenticated;

-- 4) Lista del entrenador: sólo clientes aprobados para él. Sin teléfono, correo ni notas.
create or replace function public.trainer_roster()
returns table(client_id uuid, full_name text, visits_30d integer, visited_today boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_today date := (now() at time zone 'America/Managua')::date;
begin
  if not public.is_trainer() then raise exception 'AUTH'; end if;
  return query
    select c.id, c.full_name,
      (select count(*)::int from public.client_visits v
         where v.client_id = c.id and v.local_day > v_today - 30 and v.local_day <= v_today),
      exists(select 1 from public.client_visits v where v.client_id = c.id and v.local_day = v_today)
    from public.trainer_client_access a
    join public.gym_clients c on c.id = a.client_id
    where a.trainer_id = auth.uid() and a.status = 'approved' and c.status = 'active'
    order by lower(c.full_name);
end $$;
revoke all on function public.trainer_roster() from public, anon;
grant execute on function public.trainer_roster() to authenticated;

-- 5) Búsqueda para pedir acceso: sólo id, nombre y estado propio. Máximo 10. Sin contacto.
create or replace function public.trainer_search_clients(p_query text)
returns table(client_id uuid, full_name text, my_status text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_q text := lower(coalesce(trim(p_query), ''));
begin
  if not public.is_trainer() then raise exception 'AUTH'; end if;
  if not public.trainer_request_enabled() then raise exception 'PERMISSION_DISABLED'; end if;
  if length(v_q) < 3 then raise exception 'QUERY_TOO_SHORT'; end if;
  return query
    select c.id, c.full_name,
      (select a.status from public.trainer_client_access a
         where a.trainer_id = auth.uid() and a.client_id = c.id and a.status in ('pending', 'approved')
         order by a.created_at desc limit 1)
    from public.gym_clients c
    where c.status = 'active'
      and lower(c.full_name) like '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%'
    order by lower(c.full_name)
    limit 10;
end $$;
revoke all on function public.trainer_search_clients(text) from public, anon;
grant execute on function public.trainer_search_clients(text) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00036_personal_no_es_cliente.sql
-- ═══════════════════════════════════════════════════════════

-- 00036 PERSONAL NO ES CLIENTE. ESTADO: APLICADO EN SUPABASE (20261019015713) con autorización del dueño. Verificado: 0 fichas de personal activas.
-- Incluye: filtro de personal en el directorio de clientes y asignación directa de clientes por el administrador.
-- Requiere 00034 y 00035.
-- Problema: al registrarse, crm_profile_created crea una ficha de cliente para toda cuenta
-- nueva (rol member). Si luego se asigna rol de personal, la ficha seguía activa y aparecía
-- en la lista de clientes y en la búsqueda del entrenador.
-- Regla: una cuenta de personal (entrenador, caja o administrador) no es cliente.
--   - Su ficha vinculada pasa a 'cancelled' (no se borra: queda el historial).
--   - Al asignar un rol de personal, admin_set_role cancela la ficha automáticamente.
--   - La búsqueda y la solicitud de acceso ignoran fichas de personal.
-- Si se quita el rol de personal, la ficha NO se reactiva sola: la reactiva el administrador.

begin;
set local lock_timeout = '5s';

-- 1) Fichas ya existentes de cuentas de personal.
update public.gym_clients g
   set status = 'cancelled', updated_at = now()
  from public.profiles p
 where p.id = g.profile_id
   and p.role in ('trainer', 'cashier', 'admin')
   and g.status <> 'cancelled';

-- 2) Asignación de roles: al pasar a personal, la ficha se cancela en la misma transacción.
create or replace function public.admin_set_role(p_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_old text; v_admins integer;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_role not in ('member', 'cashier', 'trainer', 'admin') then raise exception 'INVALID_ROLE'; end if;
  if p_id is null or p_id = auth.uid() then raise exception 'SELF_ROLE_CHANGE'; end if;
  select role::text into v_old from public.profiles where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old = p_role then return; end if;
  if v_old = 'admin' then
    select count(*) into v_admins from public.profiles where role = 'admin';
    if v_admins <= 1 then raise exception 'LAST_ADMIN'; end if;
  end if;
  update public.profiles set role = p_role::public.user_role where id = p_id;
  if p_role in ('trainer', 'cashier', 'admin') then
    update public.gym_clients set status = 'cancelled', updated_at = now()
     where profile_id = p_id and status <> 'cancelled';
  end if;
  insert into public.role_changes(target_id, old_role, new_role, changed_by)
    values (p_id, v_old, p_role, auth.uid());
end $$;
revoke all on function public.admin_set_role(uuid, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text) to authenticated;

-- 3) La búsqueda no muestra fichas de personal.
create or replace function public.trainer_search_clients(p_query text)
returns table(client_id uuid, full_name text, my_status text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_q text := lower(coalesce(trim(p_query), ''));
begin
  if not public.is_trainer() then raise exception 'AUTH'; end if;
  if not public.trainer_request_enabled() then raise exception 'PERMISSION_DISABLED'; end if;
  if length(v_q) < 3 then raise exception 'QUERY_TOO_SHORT'; end if;
  return query
    select c.id, c.full_name,
      (select a.status from public.trainer_client_access a
         where a.trainer_id = auth.uid() and a.client_id = c.id and a.status in ('pending', 'approved')
         order by a.created_at desc limit 1)
    from public.gym_clients c
    where c.status = 'active'
      and not exists (select 1 from public.profiles p
                       where p.id = c.profile_id and p.role in ('trainer', 'cashier', 'admin'))
      and lower(c.full_name) like '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%'
    order by lower(c.full_name)
    limit 10;
end $$;
revoke all on function public.trainer_search_clients(text) from public, anon;
grant execute on function public.trainer_search_clients(text) to authenticated;

-- 4) No se puede pedir acceso a una ficha de personal.
create or replace function public.request_trainer_access(p_trainer uuid, p_client uuid, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_caller uuid := auth.uid(); v_id uuid; v_status text; v_existing record;
begin
  if not (public.is_trainer() or public.is_cashier()) then raise exception 'AUTH'; end if;
  if public.is_trainer() and p_trainer is distinct from v_caller then raise exception 'AUTH'; end if;
  if public.is_trainer() and not public.trainer_request_enabled() then raise exception 'PERMISSION_DISABLED'; end if;
  if p_trainer is null or not exists(select 1 from public.profiles where id = p_trainer and role = 'trainer') then
    raise exception 'INVALID_TRAINER';
  end if;
  if p_reason is not null and length(p_reason) > 300 then raise exception 'INVALID_REASON'; end if;

  select status into v_status from public.gym_clients where id = p_client;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_status <> 'active' then raise exception 'INACTIVE_CLIENT'; end if;
  if exists (select 1 from public.gym_clients g join public.profiles p on p.id = g.profile_id
              where g.id = p_client and p.role in ('trainer', 'cashier', 'admin')) then
    raise exception 'NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_trainer::text || ':' || p_client::text, 0));
  select id, status into v_existing from public.trainer_client_access
    where trainer_id = p_trainer and client_id = p_client and status in ('pending', 'approved');
  if found then
    if v_existing.status = 'approved' then raise exception 'ALREADY_APPROVED'; end if;
    return v_existing.id;
  end if;

  insert into public.trainer_client_access(trainer_id, client_id, requested_by, requested_via, reason)
    values (p_trainer, p_client, v_caller,
            case when public.is_trainer() then 'trainer' else 'cashier' end, p_reason)
    returning id into v_id;
  return v_id;
end $$;
revoke all on function public.request_trainer_access(uuid, uuid, text) from public, anon;
grant execute on function public.request_trainer_access(uuid, uuid, text) to authenticated;


-- 5) Una cuenta de personal no es cliente: helper para listas y búsquedas.
create or replace function public.is_staff_profile(p_profile uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists(select 1 from public.profiles where id = p_profile and role in ('trainer', 'cashier', 'admin'));
$$;
revoke all on function public.is_staff_profile(uuid) from public, anon;
grant execute on function public.is_staff_profile(uuid) to authenticated;

-- 6) Directorio de clientes (crm_directory, 00020): ahora excluye fichas de personal.
--    Misma firma y mismo cuerpo; sólo se agrega el filtro de personal.
create or replace function public.crm_directory(p_search text default '', p_category text default '', p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select jsonb_build_object('total',(select count(*) from public.gym_clients c where
    (p_category='' or c.category=p_category) and (p_search='' or c.full_name ilike '%'||p_search||'%' or coalesce(c.phone,'') ilike '%'||p_search||'%' or c.client_number::text=p_search)
    and not public.is_staff_profile(c.profile_id)),
    'rows',coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb)) into result from (
    select c.*,p.name_es as plan_name,
      (select count(*)::int from public.client_visits v where v.client_id=c.id and v.local_day >= (now() at time zone 'America/Managua')::date-29) as visits_30,
      (select max(v.visited_at) from public.client_visits v where v.client_id=c.id) as last_visit
    from public.gym_clients c left join public.plans p on p.id=c.plan_id
    where (p_category='' or c.category=p_category) and (p_search='' or c.full_name ilike '%'||p_search||'%' or coalesce(c.phone,'') ilike '%'||p_search||'%' or c.client_number::text=p_search)
      and not public.is_staff_profile(c.profile_id)
    order by c.full_name,c.id limit 30 offset greatest(0,least(coalesce(p_offset,0),1000000))
  ) r;
  return result;
end $$;
revoke all on function public.crm_directory(text, text, integer) from public, anon;
grant execute on function public.crm_directory(text, text, integer) to authenticated;

-- 7) El administrador asigna un cliente a un entrenador directamente (sin pedido previo).
--    Si ya había un pedido pendiente, lo aprueba; si ya estaba aprobado, no hace nada.
alter table public.trainer_client_access drop constraint if exists trainer_client_access_requested_via_check;
alter table public.trainer_client_access add constraint trainer_client_access_requested_via_check
  check (requested_via in ('trainer', 'cashier', 'admin'));

create or replace function public.admin_assign_trainer_client(p_trainer uuid, p_client uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_id uuid; v_status text; v_profile uuid; v_existing record;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_trainer is null or not exists(select 1 from public.profiles where id = p_trainer and role = 'trainer') then
    raise exception 'INVALID_TRAINER';
  end if;
  select status, profile_id into v_status, v_profile from public.gym_clients where id = p_client for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if public.is_staff_profile(v_profile) then raise exception 'NOT_FOUND'; end if;
  if v_status <> 'active' then raise exception 'INACTIVE_CLIENT'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_trainer::text || ':' || p_client::text, 0));
  select id, status into v_existing from public.trainer_client_access
    where trainer_id = p_trainer and client_id = p_client and status in ('pending', 'approved');
  if found then
    if v_existing.status = 'approved' then return v_existing.id; end if;
    update public.trainer_client_access
       set status = 'approved', decided_by = auth.uid(), decided_at = now()
     where id = v_existing.id;
    return v_existing.id;
  end if;

  insert into public.trainer_client_access(trainer_id, client_id, requested_by, requested_via, status, decided_by, decided_at)
    values (p_trainer, p_client, auth.uid(), 'admin', 'approved', auth.uid(), now())
    returning id into v_id;
  return v_id;
end $$;
revoke all on function public.admin_assign_trainer_client(uuid, uuid) from public, anon;
grant execute on function public.admin_assign_trainer_client(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00037_cierre_caja_interruptor.sql
-- ═══════════════════════════════════════════════════════════

-- 00037 CIERRE DEL DÍA PARA CAJA: interruptor del administrador.
-- ESTADO: APLICADO en Supabase (proyecto hcnuepdxmbsmlzdmvwhx) el 2026-10-19 con autorización del dueño. Interruptor apagado.
-- Qué hace:
--   1) Agrega el interruptor `cashier_can_view_daily_close` (apagado por defecto) en staff_permissions.
--   2) Crea cashier_daily_close_enabled(): devuelve true sólo si el interruptor está activo,
--      la sesión es aal2 y quien llama tiene rol cashier. El administrador no usa esta función
--      (lee el interruptor directamente con su RLS de 00033).
-- No cambia ninguna regla existente de transactions, debts ni del resto de los permisos.
-- Requiere 00033 (staff_permissions) ya aplicada.

begin;
set local lock_timeout = '5s';

insert into public.staff_permissions (key, enabled)
values ('cashier_can_view_daily_close', false)
on conflict (key) do nothing;

create or replace function public.cashier_daily_close_enabled()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(select 1 from public.profiles where id = auth.uid() and role::text = 'cashier')
     and coalesce((select enabled from public.staff_permissions where key = 'cashier_can_view_daily_close'), false);
$$;

revoke all on function public.cashier_daily_close_enabled() from public, anon;
grant execute on function public.cashier_daily_close_enabled() to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00038_caja_resumen_deudas.sql
-- ═══════════════════════════════════════════════════════════

-- 00038 CAJA VE EL RESUMEN DE DEUDAS (corrige 00034 para la página de Caja).
-- ESTADO: APLICADO en Supabase (proyecto hcnuepdxmbsmlzdmvwhx) con autorización del dueño. Verificado: usa crm_is_staff; anon sin permiso.
-- Motivo: 00034 dejó finance_debt_report sólo para administrador, pero la página de Caja
-- (getCashSummary) lo usa para el resumen. Caja recibía "FIN_DEBT_REPORT_P0001" (AUTH) y no veía nada.
-- Qué cambia: sólo el permiso de finance_debt_report. Acepta administrador o caja con aal2 (crm_is_staff),
-- igual que finance_read. Entrenador, cliente y visitante siguen sin acceso.
-- Requiere 00034 aplicada.

begin;
set local lock_timeout = '5s';

create or replace function public.finance_debt_report(p_section text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_section not in ('summary', 'receivables') or p_section is null then raise exception 'INVALID_FINANCE_SECTION'; end if;
  return public.finance_read(p_section, 30);
end $$;
revoke all on function public.finance_debt_report(text) from public, anon, authenticated;
grant execute on function public.finance_debt_report(text) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00039_medidas_metas_rutinas.sql
-- ═══════════════════════════════════════════════════════════

-- 00039 MEDIDAS, METAS Y RUTINAS POR CLIENTE. ESTADO: APLICADO EN SUPABASE (proyecto hcnuepdxmbsmlzdmvwhx, versión 20261020123310, nombre medidas_metas_rutinas) tras prueba local 43/43.
-- Requiere 00033 (is_admin/is_cashier/is_trainer), 00035 (trainer_client_access) y 00036.
-- Las reglas de negocio están en src/lib/progress/rules.ts; aquí van como restricciones duras.
--
-- Reglas:
-- - Medidas: ocho circunferencias ISAK opcionales. Vacío = no tomada, nunca cero.
--   Las medidas no se editan ni se borran; una corrección es una medición nueva.
-- - Quién registra medidas: administrador, caja (aal2) y entrenador con acceso APROBADO al cliente.
-- - Metas y rutinas: administrador y entrenador con acceso aprobado. Caja sólo lee.
-- - Metas: un tipo (pérdida, ganancia, mantenimiento, otra), plazo máximo de 12 meses.
--   Una sola meta activa por cliente; al cambiarla, la anterior queda cancelada (no se borra).
-- - Rutinas: una sola activa por cliente; al cambiarla, la anterior queda cerrada (no se borra).
-- - Todas las escrituras van por funciones. Las tablas no admiten INSERT/UPDATE/DELETE directo.
-- - Clientes sin acceso del personal: no ven estos datos (esta fase no da lectura al cliente).

begin;
set local lock_timeout = '5s';

-- 1) Función de lectura por cliente: administrador, caja, o entrenador con acceso aprobado.
create or replace function public.progress_can_read_client(p_client uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_admin()
      or public.is_cashier()
      or (public.is_trainer() and exists (
            select 1 from public.trainer_client_access a
            where a.trainer_id = auth.uid() and a.client_id = p_client and a.status = 'approved'));
$$;

-- Escritura de metas y rutinas: administrador, o entrenador con acceso aprobado (caja NO).
create or replace function public.progress_can_manage_client(p_client uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_admin()
      or (public.is_trainer() and exists (
            select 1 from public.trainer_client_access a
            where a.trainer_id = auth.uid() and a.client_id = p_client and a.status = 'approved'));
$$;

-- 2) Medidas corporales.
create table if not exists public.body_measurements (
  id                   uuid primary key default gen_random_uuid(),
  client_id            uuid not null references public.gym_clients(id) on delete restrict,
  measured_on          date not null,
  weight_kg            numeric(6,2) not null check (weight_kg > 0 and weight_kg <= 500),
  height_cm            numeric(5,1) check (height_cm is null or (height_cm > 0 and height_cm <= 250)),
  cintura_cm           numeric(5,1) check (cintura_cm is null or (cintura_cm > 0 and cintura_cm <= 300)),
  pecho_cm             numeric(5,1) check (pecho_cm is null or (pecho_cm > 0 and pecho_cm <= 300)),
  biceps_relajado_cm   numeric(5,1) check (biceps_relajado_cm is null or (biceps_relajado_cm > 0 and biceps_relajado_cm <= 300)),
  biceps_contraido_cm  numeric(5,1) check (biceps_contraido_cm is null or (biceps_contraido_cm > 0 and biceps_contraido_cm <= 300)),
  antebrazo_cm         numeric(5,1) check (antebrazo_cm is null or (antebrazo_cm > 0 and antebrazo_cm <= 300)),
  gluteo_cm            numeric(5,1) check (gluteo_cm is null or (gluteo_cm > 0 and gluteo_cm <= 300)),
  muslo_cm             numeric(5,1) check (muslo_cm is null or (muslo_cm > 0 and muslo_cm <= 300)),
  pantorrilla_cm       numeric(5,1) check (pantorrilla_cm is null or (pantorrilla_cm > 0 and pantorrilla_cm <= 300)),
  notes                text check (notes is null or length(notes) <= 300),
  recorded_by          uuid references public.profiles(id) on delete set null,
  created_at           timestamptz not null default now()
);
-- No se puede medir en el futuro (día de Managua).
alter table public.body_measurements drop constraint if exists body_measurements_not_future;
alter table public.body_measurements add constraint body_measurements_not_future
  check (measured_on <= (now() at time zone 'America/Managua')::date);
create index if not exists body_measurements_client_idx on public.body_measurements (client_id, measured_on);

-- Solo se agregan filas: se bloquea UPDATE y DELETE también para el dueño de la base.
create or replace function public.body_measurements_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'Las mediciones no se editan ni se borran; registra una nueva medicion.';
end;
$$;
drop trigger if exists body_measurements_no_update on public.body_measurements;
create trigger body_measurements_no_update before update or delete on public.body_measurements
  for each row execute function public.body_measurements_append_only();

-- 3) Metas.
create table if not exists public.client_goals (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references public.gym_clients(id) on delete restrict,
  goal_type       text not null check (goal_type in ('perdida', 'ganancia', 'mantenimiento', 'otra')),
  other_label     text check (other_label is null or length(trim(other_label)) between 3 and 120),
  starts_on       date not null,
  target_date     date not null,
  target_weight_kg numeric(6,2) check (target_weight_kg is null or (target_weight_kg > 0 and target_weight_kg <= 500)),
  status          text not null default 'activa' check (status in ('activa', 'cumplida', 'cancelada')),
  created_by      uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  closed_at       timestamptz,
  constraint client_goals_dates check (target_date > starts_on
    and target_date <= (starts_on + interval '12 months')::date),
  constraint client_goals_weight_required check (goal_type = 'otra' or target_weight_kg is not null),
  constraint client_goals_other_required check (goal_type <> 'otra' or other_label is not null)
);
create unique index if not exists client_goals_one_active_idx
  on public.client_goals (client_id) where status = 'activa';

-- 4) Rutinas.
create table if not exists public.client_routines (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.gym_clients(id) on delete restrict,
  name         text not null check (length(trim(name)) between 2 and 80),
  days         text[] not null check (cardinality(days) between 1 and 7),
  exercises    jsonb not null check (jsonb_typeof(exercises) = 'array' and jsonb_array_length(exercises) between 1 and 40),
  status       text not null default 'activa' check (status in ('activa', 'cerrada')),
  starts_on    date not null,
  ends_on      date,
  assigned_by  uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  constraint client_routines_ends check (ends_on is null or ends_on >= starts_on)
);
create unique index if not exists client_routines_one_active_idx
  on public.client_routines (client_id) where status = 'activa';

-- 5) Permisos de tablas y RLS.
alter table public.body_measurements enable row level security;
alter table public.client_goals enable row level security;
alter table public.client_routines enable row level security;
revoke all on public.body_measurements, public.client_goals, public.client_routines from anon, authenticated;
grant select on public.body_measurements, public.client_goals, public.client_routines to authenticated;

drop policy if exists body_measurements_read on public.body_measurements;
create policy body_measurements_read on public.body_measurements
  for select to authenticated using (public.progress_can_read_client(client_id));
drop policy if exists client_goals_read on public.client_goals;
create policy client_goals_read on public.client_goals
  for select to authenticated using (public.progress_can_read_client(client_id));
drop policy if exists client_routines_read on public.client_routines;
create policy client_routines_read on public.client_routines
  for select to authenticated using (public.progress_can_read_client(client_id));

-- 6) Funciones de escritura.

-- Registrar una medición. p_values lleva las claves de las ocho medidas; las que faltan quedan vacías.
create or replace function public.record_body_measurement(
  p_client uuid, p_measured_on date, p_weight numeric, p_height numeric, p_values jsonb, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not public.progress_can_read_client(p_client) then raise exception 'AUTH'; end if;
  if not (public.is_admin() or public.is_cashier() or public.is_trainer()) then raise exception 'AUTH'; end if;
  if p_values is not null and jsonb_typeof(p_values) <> 'object' then raise exception 'VALUES_INVALID'; end if;

  insert into public.body_measurements(client_id, measured_on, weight_kg, height_cm,
    cintura_cm, pecho_cm, biceps_relajado_cm, biceps_contraido_cm, antebrazo_cm, gluteo_cm, muslo_cm, pantorrilla_cm,
    notes, recorded_by)
  values (p_client, p_measured_on, p_weight, p_height,
    nullif(p_values->>'cintura_cm','')::numeric, nullif(p_values->>'pecho_cm','')::numeric,
    nullif(p_values->>'biceps_relajado_cm','')::numeric, nullif(p_values->>'biceps_contraido_cm','')::numeric,
    nullif(p_values->>'antebrazo_cm','')::numeric, nullif(p_values->>'gluteo_cm','')::numeric,
    nullif(p_values->>'muslo_cm','')::numeric, nullif(p_values->>'pantorrilla_cm','')::numeric,
    nullif(trim(coalesce(p_notes,'')), ''), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Cambiar la meta activa: la anterior queda cancelada (no se borra).
create or replace function public.set_client_goal(
  p_client uuid, p_goal_type text, p_other_label text, p_starts_on date, p_target_date date, p_target_weight numeric)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not public.progress_can_manage_client(p_client) then raise exception 'AUTH'; end if;
  update public.client_goals set status = 'cancelada', closed_at = now()
    where client_id = p_client and status = 'activa';
  insert into public.client_goals(client_id, goal_type, other_label, starts_on, target_date, target_weight_kg, created_by)
  values (p_client, p_goal_type, nullif(trim(coalesce(p_other_label,'')), ''), p_starts_on, p_target_date, p_target_weight, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Cambiar la rutina activa: la anterior queda cerrada (no se borra).
create or replace function public.set_client_routine(
  p_client uuid, p_name text, p_days text[], p_exercises jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_today date := (now() at time zone 'America/Managua')::date;
begin
  if not public.progress_can_manage_client(p_client) then raise exception 'AUTH'; end if;
  update public.client_routines set status = 'cerrada', ends_on = v_today
    where client_id = p_client and status = 'activa';
  insert into public.client_routines(client_id, name, days, exercises, starts_on, assigned_by)
  values (p_client, trim(p_name), p_days, p_exercises, v_today, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.progress_can_read_client(uuid), public.progress_can_manage_client(uuid) from public, anon;
grant execute on function public.progress_can_read_client(uuid), public.progress_can_manage_client(uuid) to authenticated;
revoke all on function public.record_body_measurement(uuid, date, numeric, numeric, jsonb, text) from public, anon;
revoke all on function public.set_client_goal(uuid, text, text, date, date, numeric) from public, anon;
revoke all on function public.set_client_routine(uuid, text, text[], jsonb) from public, anon;
grant execute on function public.record_body_measurement(uuid, date, numeric, numeric, jsonb, text) to authenticated;
grant execute on function public.set_client_goal(uuid, text, text, date, date, numeric) to authenticated;
grant execute on function public.set_client_routine(uuid, text, text[], jsonb) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00040_mi_progreso_cliente.sql
-- ═══════════════════════════════════════════════════════════

-- 00040 MI PROGRESO PARA EL CLIENTE. ESTADO: APLICADA en Supabase (proyecto hcnuepdxmbsmlzdmvwhx, 2026-10-20).
-- Requiere 00039. Sólo agrega una función de lectura; no cambia las tablas ni las políticas existentes.
--
-- Reglas:
-- - Un cliente con cuenta (gym_clients.profile_id = su usuario) lee SOLO sus propios datos.
-- - No incluye notas del personal, ni el nombre de quien registró o asignó.
-- - Sin cuenta vinculada devuelve null (no es un error y no muestra datos ajenos).
-- - El personal no usa esta función para ver clientes ajenos: para eso están las políticas de 00039.

begin;
set local lock_timeout = '5s';

create or replace function public.my_progress()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_client uuid;
  v_name text;
  v_out jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;

  select id, full_name into v_client, v_name
    from public.gym_clients
    where profile_id = auth.uid()
    limit 1;
  if v_client is null then return null; end if;

  select jsonb_build_object(
    'client_name', v_name,
    'measurements', coalesce((
      select jsonb_agg(jsonb_build_object(
        'measured_on', m.measured_on,
        'weight_kg', m.weight_kg,
        'height_cm', m.height_cm,
        'values', jsonb_build_object(
          'cintura_cm', m.cintura_cm, 'pecho_cm', m.pecho_cm,
          'biceps_relajado_cm', m.biceps_relajado_cm, 'biceps_contraido_cm', m.biceps_contraido_cm,
          'antebrazo_cm', m.antebrazo_cm, 'gluteo_cm', m.gluteo_cm,
          'muslo_cm', m.muslo_cm, 'pantorrilla_cm', m.pantorrilla_cm))
        order by m.measured_on desc, m.created_at desc)
      from (select * from public.body_measurements where client_id = v_client
            order by measured_on desc, created_at desc limit 200) m
    ), '[]'::jsonb),
    'goal', (select jsonb_build_object(
        'goal_type', g.goal_type, 'other_label', g.other_label,
        'starts_on', g.starts_on, 'target_date', g.target_date, 'target_weight_kg', g.target_weight_kg)
      from public.client_goals g where g.client_id = v_client and g.status = 'activa' limit 1),
    'routine', (select jsonb_build_object(
        'name', r.name, 'days', r.days, 'exercises', r.exercises, 'starts_on', r.starts_on)
      from public.client_routines r where r.client_id = v_client and r.status = 'activa' limit 1)
  ) into v_out;
  return v_out;
end;
$$;

revoke all on function public.my_progress() from public, anon;
grant execute on function public.my_progress() to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00041_asistencia_cliente.sql
-- ═══════════════════════════════════════════════════════════

-- 00041 ASISTENCIA POR CLIENTE (día, semana y mes). ESTADO: APLICADA en Supabase (migración asistencia_cliente, 2026-10-21).
-- Requiere 00039 (progress_can_read_client) y 00040 no es necesaria.
-- Sólo agrega una función de lectura. No cambia tablas ni políticas.
--
-- Quién puede leer:
-- - Administrador y caja: cualquier cliente.
-- - Entrenador: sólo clientes con acceso aprobado (trainer_client_access).
-- - Cliente: sólo su propia asistencia (cuando p_client es null o es su ficha).
-- Sin permiso o sin ficha vinculada devuelve null; nunca datos ajenos.

begin;
set local lock_timeout = '5s';

create or replace function public.client_attendance(p_client uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_client uuid;
  v_today date := (now() at time zone 'America/Managua')::date;
  v_out jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;

  -- Cliente sin parámetro: su propia ficha.
  if p_client is null then
    select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  else
    v_client := p_client;
  end if;
  if v_client is null then return null; end if;

  -- Permiso: personal con acceso, o el propio cliente.
  if not (
    public.progress_can_read_client(v_client)
    or exists(select 1 from public.gym_clients where id = v_client and profile_id = auth.uid())
  ) then
    return null;
  end if;

  select jsonb_build_object(
    'client_id', v_client,
    'today', v_today,
    'total_visits', (select count(*) from public.client_visits where client_id = v_client),
    'last_visit', (select max(local_day) from public.client_visits where client_id = v_client),
    'visits_30_days', (select count(*) from public.client_visits
                       where client_id = v_client and local_day > v_today - 30 and local_day <= v_today),
    'days', coalesce((select jsonb_agg(d order by d desc) from (
        select local_day::text as d from public.client_visits
        where client_id = v_client and local_day > v_today - 60 and local_day <= v_today
        order by local_day desc limit 60) x), '[]'::jsonb),
    -- Semanas (lunes a domingo), últimas 26.
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week_start', w.ws::text, 'visits', w.n) order by w.ws desc)
        from (select date_trunc('week', local_day)::date as ws, count(*)::int as n
              from public.client_visits
              where client_id = v_client and local_day > v_today - 182 and local_day <= v_today
              group by 1 order by 1 desc limit 26) w), '[]'::jsonb),
    -- Meses, últimos 12.
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', m.mo, 'visits', m.n) order by m.mo desc)
        from (select to_char(local_day, 'YYYY-MM') as mo, count(*)::int as n
              from public.client_visits
              where client_id = v_client and local_day > v_today - 366 and local_day <= v_today
              group by 1 order by 1 desc limit 12) m), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

revoke all on function public.client_attendance(uuid) from public, anon;
grant execute on function public.client_attendance(uuid) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00042_productos_stock_categorias.sql
-- ═══════════════════════════════════════════════════════════

-- Aplicada en Supabase (proyecto hcnuepdxmbsmlzdmvwhx) el 2026-10-21 tras pasar scripts/test-productos-sql.mjs.
-- Requiere 00024 (finance_record_movement), 00039 (progress_can_read_client), 00041 (asistencia).
--
-- Reglas:
-- - Productos y stock: sólo administración y caja (crm_is_staff). Entrenador y cliente no escriben.
-- - Venta: suma en finanzas con finance_record_movement (service_income) y baja el stock en la misma transacción.
--   Requiere cliente (la finanza actual exige cliente en ingresos). Moneda: NIO (precios en córdobas).
-- - Compra de inventario: resta en finanzas con finance_record_movement (expense) y suma stock.
-- - Stock nunca queda negativo. Mismo request_id = misma operación (no duplica dinero ni stock).
-- - Categoría de cliente calculada (no reemplaza gym_clients.category, que se conserva):
--   strong_gym: membresía mensual activa + compra de producto en 90 días.
--   familia: membresía semanal o mensual activa (sin cumplir lo anterior).
--   amigo: sin membresía y 3 o más visitas en 30 días.
--   comun: el resto.

begin;
set local lock_timeout = '5s';

-- Categoría de gasto para compras de inventario para la venta.
do $cat$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='expense_categories' and column_name='slug') then
    insert into public.expense_categories (id, slug, name_es, name_en, icon, sort_order)
    values ('exp_inventario', 'inventario-venta', 'Compra de inventario para venta', 'Inventory for resale', 'Package', 8)
    on conflict (id) do nothing;
  elsif exists (select 1 from information_schema.columns where table_schema='public' and table_name='expense_categories' and column_name='name') then
    insert into public.expense_categories (id, name)
    values ('exp_inventario', 'Compra de inventario para venta')
    on conflict (id) do nothing;
  end if;
end $cat$;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  category text not null check (length(trim(category)) between 2 and 60),
  subcategory text check (subcategory is null or length(trim(subcategory)) between 1 and 60),
  attributes jsonb not null default '{}'::jsonb check (jsonb_typeof(attributes) = 'object'),
  status text not null default 'activo' check (status in ('activo', 'inactivo')),
  cost numeric(12, 2) not null default 0 check (cost >= 0),
  price numeric(12, 2) not null check (price >= 0),
  profit numeric(12, 2) generated always as (price - cost) stored,
  stock_min integer not null default 0 check (stock_min >= 0),
  -- Imagen ya comprimida en el navegador a JPEG de máximo 600 KB (≈820 000 caracteres en base64).
  image_data text check (image_data is null or (image_data like 'data:image/jpeg;base64,%' and length(image_data) <= 820000)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  kind text not null check (kind in ('entrada', 'venta', 'ajuste')),
  qty integer not null check (qty <> 0),
  unit_cost numeric(12, 2) check (unit_cost is null or unit_cost >= 0),
  unit_price numeric(12, 2) check (unit_price is null or unit_price >= 0),
  client_id uuid references public.gym_clients(id) on delete restrict,
  transaction_id uuid references public.transactions(id) on delete restrict,
  request_id uuid unique,
  note text check (note is null or length(note) <= 200),
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint stock_sign check ((kind = 'venta' and qty < 0) or (kind = 'entrada' and qty > 0) or kind = 'ajuste'),
  constraint stock_sale_client check (kind <> 'venta' or client_id is not null)
);
create index if not exists stock_movements_product_idx on public.stock_movements(product_id);
create index if not exists stock_movements_client_idx on public.stock_movements(client_id, created_at desc);

alter table public.products enable row level security;
alter table public.stock_movements enable row level security;
revoke all on public.products, public.stock_movements from public, anon, authenticated;
grant select on public.products, public.stock_movements to authenticated;
drop policy if exists products_staff_read on public.products;
create policy products_staff_read on public.products for select to authenticated using (public.crm_is_staff());
drop policy if exists stock_staff_read on public.stock_movements;
create policy stock_staff_read on public.stock_movements for select to authenticated using (public.crm_is_staff());

-- Existencia actual de un producto (suma de movimientos).
create or replace function public.product_stock_of(p_id uuid)
returns integer language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(qty), 0)::integer from public.stock_movements where product_id = p_id;
$$;

-- Crear o editar producto (administración y caja).
create or replace function public.product_save(
  p_id uuid, p_name text, p_category text, p_subcategory text, p_attributes jsonb,
  p_status text, p_cost numeric, p_price numeric, p_stock_min integer, p_image text
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_id uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_name is null or length(trim(p_name)) not between 2 and 120
    or p_category is null or length(trim(p_category)) not between 2 and 60
    or p_status not in ('activo', 'inactivo')
    or p_cost is null or p_cost < 0 or p_cost > 9999999999.99
    or p_price is null or p_price < 0 or p_price > 9999999999.99
    or p_stock_min is null or p_stock_min < 0
    or (p_attributes is not null and jsonb_typeof(p_attributes) <> 'object') then
    raise exception 'INVALID_PRODUCT';
  end if;
  if p_id is null then
    insert into public.products(name, category, subcategory, attributes, status, cost, price, stock_min, image_data)
    values (trim(p_name), trim(p_category), nullif(trim(coalesce(p_subcategory, '')), ''),
            coalesce(p_attributes, '{}'::jsonb), p_status, p_cost, p_price, p_stock_min, nullif(p_image, ''))
    returning id into v_id;
  else
    update public.products set name = trim(p_name), category = trim(p_category),
      subcategory = nullif(trim(coalesce(p_subcategory, '')), ''), attributes = coalesce(p_attributes, '{}'::jsonb),
      status = p_status, cost = p_cost, price = p_price, stock_min = p_stock_min,
      image_data = case when p_image is null then image_data when p_image = '' then null else p_image end,
      updated_at = now()
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'NOT_FOUND'; end if;
  end if;
  return v_id;
end;
$$;

-- Lista de productos con existencia (administración y caja).
create or replace function public.product_list()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'category', p.category, 'subcategory', p.subcategory,
      'attributes', p.attributes, 'status', p.status, 'cost', p.cost, 'price', p.price,
      'profit', p.profit, 'stock', public.product_stock_of(p.id), 'stock_min', p.stock_min,
      'low_stock', public.product_stock_of(p.id) <= p.stock_min, 'image_data', p.image_data)
      order by p.category, p.name)
    from public.products p), '[]'::jsonb);
end;
$$;

-- Ajuste de inventario (conteo físico). Nunca deja existencia negativa.
create or replace function public.product_stock_adjust(p_product uuid, p_qty integer, p_note text)
returns integer language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_stock integer;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_qty is null or p_qty = 0 or abs(p_qty) > 100000 then raise exception 'INVALID_QTY'; end if;
  perform 1 from public.products where id = p_product for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_stock := public.product_stock_of(p_product);
  if v_stock + p_qty < 0 then raise exception 'SIN_STOCK'; end if;
  insert into public.stock_movements(product_id, kind, qty, note, created_by)
  values (p_product, 'ajuste', p_qty, nullif(trim(coalesce(p_note, '')), ''), auth.uid());
  return v_stock + p_qty;
end;
$$;

-- Compra de inventario: resta en finanzas (gasto) y suma stock. Idempotente por p_request.
create or replace function public.product_purchase(
  p_request uuid, p_product uuid, p_qty integer, p_unit_cost numeric,
  p_method text, p_account text, p_category text default 'exp_inventario', p_note text default null
) returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_name text; v_active text; v_total numeric; v_tx uuid; v_existing public.stock_movements;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  select * into v_existing from public.stock_movements where request_id = p_request;
  if found then
    return jsonb_build_object('transaction_id', v_existing.transaction_id, 'already', true,
      'stock', public.product_stock_of(p_product));
  end if;
  if p_qty is null or p_qty <= 0 or p_qty > 100000 then raise exception 'INVALID_QTY'; end if;
  if p_unit_cost is null or p_unit_cost <= 0 or p_unit_cost > 9999999 or p_unit_cost <> round(p_unit_cost, 2) then
    raise exception 'INVALID_COST';
  end if;
  select name, status into v_name, v_active from public.products where id = p_product for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_active <> 'activo' then raise exception 'PRODUCT_INACTIVE'; end if;
  v_total := round(p_qty * p_unit_cost, 2);
  v_tx := public.finance_record_movement(p_request, 'expense', null, v_total, 'NIO', p_method, p_account,
    'Compra inventario: ' || v_name || ' x' || p_qty, 1, p_category);
  insert into public.stock_movements(product_id, kind, qty, unit_cost, transaction_id, request_id, note, created_by)
  values (p_product, 'entrada', p_qty, p_unit_cost, v_tx, p_request, nullif(trim(coalesce(p_note, '')), ''), auth.uid());
  return jsonb_build_object('transaction_id', v_tx, 'already', false, 'stock', public.product_stock_of(p_product));
end;
$$;

-- Venta de producto a un cliente: suma en finanzas (ingreso) y baja stock. Idempotente por p_request.
create or replace function public.product_sell(
  p_request uuid, p_product uuid, p_qty integer, p_client uuid, p_method text, p_account text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_name text; v_status text; v_price numeric; v_stock integer; v_total numeric; v_tx uuid; v_existing public.stock_movements;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  select * into v_existing from public.stock_movements where request_id = p_request;
  if found then
    return jsonb_build_object('transaction_id', v_existing.transaction_id, 'already', true,
      'stock', public.product_stock_of(p_product));
  end if;
  if p_client is null then raise exception 'CLIENT_REQUIRED'; end if;
  if p_qty is null or p_qty <= 0 or p_qty > 1000 then raise exception 'INVALID_QTY'; end if;
  select name, status, price into v_name, v_status, v_price from public.products where id = p_product for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_status <> 'activo' then raise exception 'PRODUCT_INACTIVE'; end if;
  v_stock := public.product_stock_of(p_product);
  if v_stock < p_qty then raise exception 'SIN_STOCK'; end if;
  v_total := round(p_qty * v_price, 2);
  v_tx := public.finance_record_movement(p_request, 'service_income', p_client, v_total, 'NIO', p_method, p_account,
    'Venta: ' || v_name || ' x' || p_qty, 1, null);
  insert into public.stock_movements(product_id, kind, qty, unit_price, client_id, transaction_id, request_id, created_by)
  values (p_product, 'venta', -p_qty, v_price, p_client, v_tx, p_request, auth.uid());
  return jsonb_build_object('transaction_id', v_tx, 'already', false, 'stock', v_stock - p_qty, 'total', v_total);
end;
$$;

-- Categoría de cliente calculada. Permiso: personal con acceso al progreso, o el propio cliente.
create or replace function public.client_category(p_client uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_client uuid; v_today date := (now() at time zone 'America/Managua')::date;
  v_period text; v_status text; v_membership boolean; v_visits integer; v_purchases integer; v_cat text;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if p_client is null then
    select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  else
    v_client := p_client;
  end if;
  if v_client is null then return null; end if;
  if not (public.progress_can_read_client(v_client)
          or exists(select 1 from public.gym_clients where id = v_client and profile_id = auth.uid())) then
    return null;
  end if;
  select pl.period, g.status into v_period, v_status
    from public.gym_clients g left join public.plans pl on pl.id = g.plan_id where g.id = v_client;
  v_membership := v_status = 'active' and v_period in ('week', 'month');
  select count(*) into v_visits from public.client_visits
    where client_id = v_client and local_day > v_today - 30 and local_day <= v_today;
  select count(*) into v_purchases from public.stock_movements
    where client_id = v_client and kind = 'venta' and created_at >= now() - interval '90 days';
  v_cat := case
    when v_membership and v_period = 'month' and v_purchases > 0 then 'strong_gym'
    when v_membership then 'familia'
    when v_visits >= 3 then 'amigo'
    else 'comun' end;
  return jsonb_build_object('category', v_cat, 'membership_period', v_period, 'membership_active', v_membership,
    'visits_30_days', v_visits, 'purchases_90_days', v_purchases);
end;
$$;

-- Permisos de ejecución: sólo sesión iniciada; nunca anónimo.
revoke all on function public.product_stock_of(uuid), public.product_save(uuid,text,text,text,jsonb,text,numeric,numeric,integer,text),
  public.product_list(), public.product_stock_adjust(uuid,integer,text),
  public.product_purchase(uuid,uuid,integer,numeric,text,text,text,text),
  public.product_sell(uuid,uuid,integer,uuid,text,text), public.client_category(uuid) from public, anon;
grant execute on function public.product_save(uuid,text,text,text,jsonb,text,numeric,numeric,integer,text),
  public.product_list(), public.product_stock_adjust(uuid,integer,text),
  public.product_purchase(uuid,uuid,integer,numeric,text,text,text,text),
  public.product_sell(uuid,uuid,integer,uuid,text,text), public.client_category(uuid) to authenticated;
revoke all on function public.product_stock_of(uuid) from authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00043_plan_nutricion_interruptor.sql
-- ═══════════════════════════════════════════════════════════

-- Aplicada en Supabase (proyecto hcnuepdxmbsmlzdmvwhx) el 2026-10-21 tras pasar scripts/test-productos-sql.mjs.
-- Requiere 00039 (progress_can_read_client), 00033 (is_admin, is_cashier, is_trainer) y 00042.
--
-- Reglas:
-- - Lectura: personal con acceso al progreso del cliente y el propio cliente.
-- - Escritura (guardar cálculo, plan y rutina):
--   administrador: siempre; entrenador con acceso aprobado: sólo si el interruptor lo permite;
--   caja: sólo si el interruptor lo permite. Por defecto los interruptores están encendidos.
-- - Sólo el administrador cambia el interruptor, por cliente.
-- - Cada guardado reemplaza el plan activo (una fila por cliente). Las herramientas no son consejo médico:
--   el texto del aviso se muestra en la app y se guarda como aceptado por la versión actual.

begin;
set local lock_timeout = '5s';

create table if not exists public.client_tool_settings (
  client_id uuid primary key references public.gym_clients(id) on delete cascade,
  trainer_tools_enabled boolean not null default true,
  cashier_tools_enabled boolean not null default true,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

create table if not exists public.client_nutrition_plans (
  client_id uuid primary key references public.gym_clients(id) on delete cascade,
  goal text not null check (goal in ('bajar', 'definir', 'mantener', 'musculo', 'peso')),
  inputs jsonb not null check (jsonb_typeof(inputs) = 'object' and length(inputs::text) <= 4000),
  results jsonb not null check (jsonb_typeof(results) = 'object' and length(results::text) <= 20000),
  meal_plan jsonb not null check (jsonb_typeof(meal_plan) = 'array' and length(meal_plan::text) <= 60000),
  routine jsonb not null check (jsonb_typeof(routine) = 'array' and length(routine::text) <= 40000),
  disclaimer_version text not null default 'v1-2026-10',
  updated_by uuid,
  updated_at timestamptz not null default now()
);

alter table public.client_tool_settings enable row level security;
alter table public.client_nutrition_plans enable row level security;
revoke all on public.client_tool_settings, public.client_nutrition_plans from public, anon, authenticated;

-- Quién puede EDITAR las herramientas de este cliente.
create or replace function public.tools_can_edit(p_client uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_admin()
      or (public.is_trainer() and exists (
            select 1 from public.trainer_client_access a
            where a.trainer_id = auth.uid() and a.client_id = p_client and a.status = 'approved')
          and coalesce((select s.trainer_tools_enabled from public.client_tool_settings s where s.client_id = p_client), true))
      or (public.is_cashier()
          and coalesce((select s.cashier_tools_enabled from public.client_tool_settings s where s.client_id = p_client), true));
$$;

-- Interruptor por cliente (sólo administrador).
create or replace function public.admin_set_client_tools(p_client uuid, p_trainer boolean, p_cashier boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  perform 1 from public.gym_clients where id = p_client;
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into public.client_tool_settings(client_id, trainer_tools_enabled, cashier_tools_enabled, updated_by, updated_at)
  values (p_client, p_trainer, p_cashier, auth.uid(), now())
  on conflict (client_id) do update set trainer_tools_enabled = excluded.trainer_tools_enabled,
    cashier_tools_enabled = excluded.cashier_tools_enabled, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('trainer', p_trainer, 'cashier', p_cashier);
end;
$$;

-- Guardar cálculo, objetivo, plan y rutina (reemplaza el activo).
create or replace function public.nutrition_save(
  p_client uuid, p_goal text, p_inputs jsonb, p_results jsonb, p_meal_plan jsonb, p_routine jsonb
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
begin
  if auth.uid() is null or not public.tools_can_edit(p_client) then raise exception 'AUTH'; end if;
  if p_goal not in ('bajar', 'definir', 'mantener', 'musculo', 'peso') then raise exception 'INVALID_GOAL'; end if;
  perform 1 from public.gym_clients where id = p_client;
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into public.client_nutrition_plans(client_id, goal, inputs, results, meal_plan, routine, updated_by, updated_at)
  values (p_client, p_goal, p_inputs, p_results, p_meal_plan, p_routine, auth.uid(), now())
  on conflict (client_id) do update set goal = excluded.goal, inputs = excluded.inputs, results = excluded.results,
    meal_plan = excluded.meal_plan, routine = excluded.routine, updated_by = excluded.updated_by, updated_at = now();
  return p_client;
end;
$$;

-- Lectura: personal con acceso y el propio cliente. Devuelve también si el usuario puede editar.
create or replace function public.nutrition_get(p_client uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_client uuid; v_plan public.client_nutrition_plans; v_settings public.client_tool_settings;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if p_client is null then
    select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  else
    v_client := p_client;
  end if;
  if v_client is null then return null; end if;
  if not (public.progress_can_read_client(v_client)
          or exists(select 1 from public.gym_clients where id = v_client and profile_id = auth.uid())) then
    return null;
  end if;
  select * into v_plan from public.client_nutrition_plans where client_id = v_client;
  if not found then v_plan := null; end if;
  select * into v_settings from public.client_tool_settings where client_id = v_client;
  if not found then v_settings := null; end if;
  -- Los interruptores son internos del personal: el cliente no los ve.
  if public.progress_can_read_client(v_client) then
    return jsonb_build_object(
      'client_id', v_client,
      'plan', case when v_plan.client_id is not null then to_jsonb(v_plan) else null end,
      'can_edit', public.tools_can_edit(v_client),
      'trainer_tools_enabled', coalesce(v_settings.trainer_tools_enabled, true),
      'cashier_tools_enabled', coalesce(v_settings.cashier_tools_enabled, true));
  end if;
  return jsonb_build_object(
    'client_id', v_client,
    'plan', case when v_plan.client_id is not null then to_jsonb(v_plan) else null end,
    'can_edit', false);
end;
$$;

revoke all on function public.tools_can_edit(uuid), public.admin_set_client_tools(uuid,boolean,boolean),
  public.nutrition_save(uuid,text,jsonb,jsonb,jsonb,jsonb), public.nutrition_get(uuid) from public, anon;
grant execute on function public.tools_can_edit(uuid), public.admin_set_client_tools(uuid,boolean,boolean),
  public.nutrition_save(uuid,text,jsonb,jsonb,jsonb,jsonb), public.nutrition_get(uuid) to authenticated;
revoke all on function public.tools_can_edit(uuid) from authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00044_calculadora_cliente.sql
-- ═══════════════════════════════════════════════════════════

-- Aplicada en Supabase (proyecto hcnuepdxmbsmlzdmvwhx) el 2026-10-21 tras pasar scripts/test-productos-sql.mjs.
-- Requiere 00043 (client_nutrition_plans, client_tool_settings, nutrition_save, nutrition_get).
--
-- Reglas:
-- - El cliente calcula su propio plan desde Mi cuenta (nutrition_self_calculate). Queda como source='cliente'.
-- - Si el personal edita o recalcula el plan, queda edited_by_staff=true y el cliente ya no puede recalcularlo.
-- - Editar y recalcular: sólo administrador, o entrenador con acceso aprobado y el interruptor encendido.
-- - La caja ya no edita planes (sólo lectura).
-- - El interruptor del administrador es sólo para el entrenador. La columna cashier_tools_enabled queda sin uso.

begin;
set local lock_timeout = '5s';

alter table public.client_nutrition_plans
  add column if not exists source text not null default 'entrenador' check (source in ('cliente', 'entrenador')),
  add column if not exists edited_by_staff boolean not null default false,
  add column if not exists guide jsonb not null default '[]'::jsonb check (jsonb_typeof(guide) = 'array' and length(guide::text) <= 4000);

-- Sólo administrador o entrenador con acceso e interruptor encendido.
create or replace function public.tools_can_edit(p_client uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_admin()
      or (public.is_trainer() and exists (
            select 1 from public.trainer_client_access a
            where a.trainer_id = auth.uid() and a.client_id = p_client and a.status = 'approved')
          and coalesce((select s.trainer_tools_enabled from public.client_tool_settings s where s.client_id = p_client), true));
$$;

drop function if exists public.admin_set_client_tools(uuid, boolean, boolean);
create or replace function public.admin_set_client_tools(p_client uuid, p_trainer boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  perform 1 from public.gym_clients where id = p_client;
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into public.client_tool_settings(client_id, trainer_tools_enabled, updated_by, updated_at)
  values (p_client, p_trainer, auth.uid(), now())
  on conflict (client_id) do update set trainer_tools_enabled = excluded.trainer_tools_enabled,
    updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('trainer', p_trainer);
end;
$$;

-- Guardado del personal (entrenador o admin).
drop function if exists public.nutrition_save(uuid, text, jsonb, jsonb, jsonb, jsonb);
create or replace function public.nutrition_save(
  p_client uuid, p_goal text, p_inputs jsonb, p_results jsonb, p_meal_plan jsonb, p_routine jsonb, p_guide jsonb
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
begin
  if auth.uid() is null or not public.tools_can_edit(p_client) then raise exception 'AUTH'; end if;
  if p_goal not in ('bajar', 'definir', 'mantener', 'musculo', 'peso') then raise exception 'INVALID_GOAL'; end if;
  perform 1 from public.gym_clients where id = p_client;
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into public.client_nutrition_plans(client_id, goal, inputs, results, meal_plan, routine, guide,
    source, edited_by_staff, updated_by, updated_at)
  values (p_client, p_goal, p_inputs, p_results, p_meal_plan, p_routine, coalesce(p_guide, '[]'::jsonb),
    'entrenador', true, auth.uid(), now())
  on conflict (client_id) do update set goal = excluded.goal, inputs = excluded.inputs, results = excluded.results,
    meal_plan = excluded.meal_plan, routine = excluded.routine, guide = excluded.guide,
    source = 'entrenador', edited_by_staff = true, updated_by = excluded.updated_by, updated_at = now();
  return p_client;
end;
$$;

-- Cálculo del propio cliente desde Mi cuenta.
create or replace function public.nutrition_self_calculate(
  p_goal text, p_inputs jsonb, p_results jsonb, p_meal_plan jsonb, p_routine jsonb, p_guide jsonb
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_client uuid;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  if p_goal not in ('bajar', 'definir', 'mantener', 'musculo', 'peso') then raise exception 'INVALID_GOAL'; end if;
  if exists (select 1 from public.client_nutrition_plans where client_id = v_client and edited_by_staff) then
    raise exception 'LOCKED_BY_STAFF';
  end if;
  insert into public.client_nutrition_plans(client_id, goal, inputs, results, meal_plan, routine, guide,
    source, edited_by_staff, updated_by, updated_at)
  values (v_client, p_goal, p_inputs, p_results, p_meal_plan, p_routine, coalesce(p_guide, '[]'::jsonb),
    'cliente', false, auth.uid(), now())
  on conflict (client_id) do update set goal = excluded.goal, inputs = excluded.inputs, results = excluded.results,
    meal_plan = excluded.meal_plan, routine = excluded.routine, guide = excluded.guide,
    source = 'cliente', edited_by_staff = false, updated_by = excluded.updated_by, updated_at = now();
  return v_client;
end;
$$;

-- Lectura: el cliente ve su plan; el personal con acceso ve el plan y los permisos.
create or replace function public.nutrition_get(p_client uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_client uuid; v_name text; v_plan public.client_nutrition_plans; v_settings public.client_tool_settings;
  v_own boolean; v_staff boolean;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if p_client is null then
    select id, full_name into v_client, v_name from public.gym_clients where profile_id = auth.uid() limit 1;
  else
    select id, full_name into v_client, v_name from public.gym_clients where id = p_client;
  end if;
  if v_client is null then return null; end if;
  v_own := exists (select 1 from public.gym_clients where id = v_client and profile_id = auth.uid());
  v_staff := public.progress_can_read_client(v_client);
  if not (v_own or v_staff) then return null; end if;
  select * into v_plan from public.client_nutrition_plans where client_id = v_client;
  if not found then v_plan := null; end if;
  select * into v_settings from public.client_tool_settings where client_id = v_client;
  if not found then v_settings := null; end if;
  if v_staff then
    return jsonb_build_object(
      'client_id', v_client, 'client_name', v_name,
      'plan', case when v_plan.client_id is not null then to_jsonb(v_plan) else null end,
      'can_edit', public.tools_can_edit(v_client),
      'can_self_calculate', false,
      'trainer_tools_enabled', coalesce(v_settings.trainer_tools_enabled, true));
  end if;
  return jsonb_build_object(
    'client_id', v_client, 'client_name', v_name,
    'plan', case when v_plan.client_id is not null then to_jsonb(v_plan) else null end,
    'can_edit', false,
    'can_self_calculate', not coalesce(v_plan.edited_by_staff, false));
end;
$$;

revoke all on function public.tools_can_edit(uuid), public.admin_set_client_tools(uuid, boolean),
  public.nutrition_save(uuid, text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_self_calculate(text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_get(uuid) from public, anon;
grant execute on function public.admin_set_client_tools(uuid, boolean),
  public.nutrition_save(uuid, text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_self_calculate(text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_get(uuid) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00045_registro_gimnasio_calculadora.sql
-- ═══════════════════════════════════════════════════════════

-- Aplicada en Supabase (proyecto hcnuepdxmbsmlzdmvwhx) el 2026-10-21 tras pasar scripts/test-productos-sql.mjs.
-- Requiere 00039 (body_measurements) y 00044 (nutrición del cliente).
--
-- Reglas:
-- - "Guardar registro en gimnasio" (nutrition_submit_to_gym) sólo lo ejecuta el propio cliente.
--   Agrega una fila a body_measurements con el peso y la altura del cálculo. Así la ficha de
--   progreso del administrador, caja y entrenador muestra el dato nuevo.
-- - Una vez registrado, no se repite: devuelve already=true y no duplica la medición.
-- - Recalcular (nutrition_self_calculate) quita la marca de registro, para poder volver a registrar.
-- - Los planes de administrador/entrenador no crean medición automática.

begin;
set local lock_timeout = '5s';

alter table public.client_nutrition_plans
  add column if not exists submitted_at timestamptz,
  add column if not exists submitted_measurement_id uuid references public.body_measurements(id) on delete set null;

-- Recalcular: el plan nuevo queda sin registrar hasta que el cliente lo guarde en el gimnasio.
create or replace function public.nutrition_self_calculate(
  p_goal text, p_inputs jsonb, p_results jsonb, p_meal_plan jsonb, p_routine jsonb, p_guide jsonb
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_client uuid;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  if p_goal not in ('bajar', 'definir', 'mantener', 'musculo', 'peso') then raise exception 'INVALID_GOAL'; end if;
  if exists (select 1 from public.client_nutrition_plans where client_id = v_client and edited_by_staff) then
    raise exception 'LOCKED_BY_STAFF';
  end if;
  insert into public.client_nutrition_plans(client_id, goal, inputs, results, meal_plan, routine, guide,
    source, edited_by_staff, submitted_at, submitted_measurement_id, updated_by, updated_at)
  values (v_client, p_goal, p_inputs, p_results, p_meal_plan, p_routine, coalesce(p_guide, '[]'::jsonb),
    'cliente', false, null, null, auth.uid(), now())
  on conflict (client_id) do update set goal = excluded.goal, inputs = excluded.inputs, results = excluded.results,
    meal_plan = excluded.meal_plan, routine = excluded.routine, guide = excluded.guide,
    source = 'cliente', edited_by_staff = false, submitted_at = null, submitted_measurement_id = null,
    updated_by = excluded.updated_by, updated_at = now();
  return v_client;
end;
$$;

-- Guardar registro en el gimnasio: crea la medición de peso y altura del cálculo (una vez).
create or replace function public.nutrition_submit_to_gym()
returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_client uuid; v_plan public.client_nutrition_plans; v_measurement uuid; v_weight numeric; v_height numeric;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  select * into v_plan from public.client_nutrition_plans where client_id = v_client for update;
  if not found then raise exception 'NO_PLAN'; end if;
  if v_plan.submitted_at is not null then
    return jsonb_build_object('already', true, 'submitted_at', v_plan.submitted_at,
      'measurement_id', v_plan.submitted_measurement_id);
  end if;
  v_weight := nullif(v_plan.inputs->>'weightKg', '')::numeric;
  v_height := nullif(v_plan.inputs->>'heightCm', '')::numeric;
  if v_weight is null or v_weight <= 0 then raise exception 'NO_WEIGHT'; end if;
  insert into public.body_measurements(client_id, measured_on, weight_kg, height_cm, notes, recorded_by)
  values (v_client, (now() at time zone 'America/Managua')::date, v_weight, v_height,
    'Registro desde la calculadora del cliente (objetivo: ' || v_plan.goal || ')', auth.uid())
  returning id into v_measurement;
  update public.client_nutrition_plans
    set submitted_at = now(), submitted_measurement_id = v_measurement, updated_at = now()
    where client_id = v_client;
  return jsonb_build_object('already', false, 'measurement_id', v_measurement,
    'submitted_at', now());
end;
$$;

revoke all on function public.nutrition_self_calculate(text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_submit_to_gym() from public, anon;
grant execute on function public.nutrition_self_calculate(text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_submit_to_gym() to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00046_meta_rutina_desde_calculadora.sql
-- ═══════════════════════════════════════════════════════════

-- Aplicada en Supabase (proyecto hcnuepdxmbsmlzdmvwhx) como meta_rutina_desde_calculadora tras pasar scripts/test-productos-sql.mjs (87 PASS).
-- Requiere 00039 (client_goals, client_routines) y 00045 (nutrition_submit_to_gym).
--
-- Problema: la calculadora guardaba el objetivo y la rutina en client_nutrition_plans, pero el módulo
-- de progreso (panel del entrenador y administración) lee "Meta activa" y "Rutina activa" de
-- client_goals y client_routines. Por eso aparecían vacías.
--
-- Solución: "Guardar registro en gimnasio" (nutrition_submit_to_gym) también abre la meta activa y la
-- rutina activa a partir del cálculo. Las anteriores quedan canceladas o cerradas (no se borran).
--
-- Correspondencia de objetivos (tipos de meta de 00039):
--   bajar     -> perdida
--   mantener  -> mantenimiento
--   definir   -> otra ("Definición muscular")
--   musculo   -> ganancia ("Ganar músculo")
--   peso      -> ganancia ("Ganar peso")
-- Plazo: semanas estimadas del cálculo / 4 (mínimo 1 mes, máximo 12). Mantener o sin cambio: 3 meses (revisión).
-- Rutina: los días de fuerza son días; las sesiones de cardio se agrupan en un solo día "Cardio (N sesiones)".

begin;
set local lock_timeout = '5s';

create or replace function public.nutrition_submit_to_gym()
returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_client uuid; v_plan public.client_nutrition_plans; v_measurement uuid;
  v_weight numeric; v_height numeric;
  v_today date := (now() at time zone 'America/Managua')::date;
  v_goal_label text; v_goal_type text; v_target_weight numeric; v_weeks int; v_months int; v_target_date date;
  v_days text[] := array[]::text[]; v_exercises jsonb := '[]'::jsonb; v_cardio int := 0;
  v_day jsonb; v_ex jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  select * into v_plan from public.client_nutrition_plans where client_id = v_client for update;
  if not found then raise exception 'NO_PLAN'; end if;
  if v_plan.submitted_at is not null then
    return jsonb_build_object('already', true, 'submitted_at', v_plan.submitted_at,
      'measurement_id', v_plan.submitted_measurement_id);
  end if;
  v_weight := nullif(v_plan.inputs->>'weightKg', '')::numeric;
  v_height := nullif(v_plan.inputs->>'heightCm', '')::numeric;
  if v_weight is null or v_weight <= 0 then raise exception 'NO_WEIGHT'; end if;

  -- 1) Medición (igual que 00045).
  insert into public.body_measurements(client_id, measured_on, weight_kg, height_cm, notes, recorded_by)
  values (v_client, v_today, v_weight, v_height,
    'Registro desde la calculadora del cliente (objetivo: ' || v_plan.goal || ')', auth.uid())
  returning id into v_measurement;

  -- 2) Meta activa (la anterior queda cancelada).
  v_goal_label := case v_plan.goal
    when 'bajar' then 'Bajar de peso' when 'definir' then 'Definición muscular'
    when 'mantener' then 'Mantener físico' when 'musculo' then 'Ganar músculo' when 'peso' then 'Ganar peso' end;
  v_goal_type := case v_plan.goal
    when 'bajar' then 'perdida' when 'mantener' then 'mantenimiento' when 'definir' then 'otra' else 'ganancia' end;
  v_target_weight := nullif(v_plan.results->>'targetWeightKg', '')::numeric;
  if v_goal_type <> 'otra' and v_target_weight is null then raise exception 'NO_TARGET'; end if;
  v_weeks := coalesce(nullif(v_plan.results->>'weeksEstimate', '')::int, 0);
  v_months := case when v_goal_type = 'mantenimiento' or v_weeks <= 0 then 3
                   else least(12, greatest(1, ceil(v_weeks / 4.0)::int)) end;
  v_target_date := (v_today + make_interval(months => v_months))::date;

  update public.client_goals set status = 'cancelada', closed_at = now()
    where client_id = v_client and status = 'activa';
  insert into public.client_goals(client_id, goal_type, other_label, starts_on, target_date, target_weight_kg, created_by)
  values (v_client, v_goal_type, case when v_goal_type = 'otra' then v_goal_label end,
          v_today, v_target_date, v_target_weight, auth.uid());

  -- 3) Rutina activa (la anterior queda cerrada).
  for v_day in select * from jsonb_array_elements(coalesce(v_plan.routine, '[]'::jsonb)) loop
    if (v_day->>'day') like 'Cardio%' then
      v_cardio := v_cardio + 1;
    else
      v_days := v_days || (v_day->>'day');
    end if;
    for v_ex in select * from jsonb_array_elements(coalesce(v_day->'exercises', '[]'::jsonb)) loop
      v_exercises := v_exercises || jsonb_build_array(jsonb_build_object(
        'ejercicio', (v_day->>'day') || ' · ' || (v_day->>'focus') || ': ' || (v_ex->>'name'),
        'series', nullif(v_ex->>'sets', '')::int,
        'reps', v_ex->>'reps',
        'descanso_s', nullif(v_ex->>'restSec', '')::int));
    end loop;
  end loop;
  if v_cardio > 0 then v_days := v_days || ('Cardio (' || v_cardio || ' sesiones)'); end if;
  if jsonb_array_length(v_exercises) = 0 or cardinality(v_days) = 0 then raise exception 'NO_ROUTINE'; end if;

  update public.client_routines set status = 'cerrada', ends_on = v_today
    where client_id = v_client and status = 'activa';
  insert into public.client_routines(client_id, name, days, exercises, starts_on, assigned_by)
  values (v_client, 'Rutina · ' || v_goal_label, v_days, v_exercises, v_today, auth.uid());

  -- 4) Marca de registro.
  update public.client_nutrition_plans
    set submitted_at = now(), submitted_measurement_id = v_measurement, updated_at = now()
    where client_id = v_client;

  return jsonb_build_object('already', false, 'measurement_id', v_measurement,
    'submitted_at', now(), 'goal_type', v_goal_type, 'target_date', v_target_date);
end;
$$;

revoke all on function public.nutrition_submit_to_gym() from public, anon;
grant execute on function public.nutrition_submit_to_gym() to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00047_menores_consentimiento_aprobacion.sql
-- ═══════════════════════════════════════════════════════════

-- 00047 MENORES, CONSENTIMIENTO Y APROBACIÓN DE DIETA/RUTINA.
-- ESTADO: APLICADA EN SUPABASE (proyecto hcnuepdxmbsmlzdmvwhx) tras pasar scripts/test-productos-sql.mjs.
-- Requiere 00043 a 00046.
--
-- Reglas:
-- - Menores de 18 años (fecha de Managua) pueden crear cuenta, pero no usan la calculadora ni
--   registran datos de salud. Sin fecha de nacimiento tampoco.
-- - Datos de salud (calculadora y registro del peso/altura): requieren consentimiento expreso
--   vigente (versión health_consent_version()). Se puede revocar; no tiene efecto retroactivo.
-- - Dieta y rutina sugeridas: el cliente NO las ve hasta que el administrador o el entrenador
--   (con permiso de herramientas) las aprueba. Cada cambio (calcular, editar) vuelve a quedar pendiente.
-- - Al aprobar se abren la meta activa y la rutina activa (antes se abrían al registrar).
-- - La fecha de nacimiento se toma del registro (metadatos "birth_date") y sólo se puede fijar una vez
--   desde la cuenta; después la cambia el personal.

begin;
set local lock_timeout = '5s';

-- 1) Versión vigente del consentimiento de datos de salud (texto en docs/ y src/lib/legal).
create or replace function public.health_consent_version()
returns text language sql immutable as $$ select 'salud-v1-2026-10-21-borrador'::text $$;

-- 2) Consentimientos. Sin acceso directo: sólo por funciones.
create table if not exists public.client_consents (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.gym_clients(id) on delete restrict,
  kind        text not null check (kind in ('datos_salud')),
  version     text not null,
  accepted_at timestamptz not null default now(),
  revoked_at  timestamptz,
  created_by  uuid references public.profiles(id) on delete set null
);
create index if not exists client_consents_client_idx on public.client_consents (client_id, kind);
alter table public.client_consents enable row level security;
revoke all on public.client_consents from anon, authenticated;

-- 3) Aprobación de dieta y rutina.
alter table public.client_nutrition_plans
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by uuid references public.profiles(id) on delete set null;

-- 4) Edad.
create or replace function public.client_age_status(p_client uuid)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select case
      when g.birthdate is null then 'unknown'
      when g.birthdate <= ((now() at time zone 'America/Managua')::date - interval '18 years')::date then 'adult'
      else 'minor'
    end
    from public.gym_clients g where g.id = p_client
  ), 'unknown');
$$;

create or replace function public.my_age_status()
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_client uuid;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then return 'unknown'; end if;
  return public.client_age_status(v_client);
end;
$$;

-- Fijar la fecha de nacimiento desde la cuenta: sólo una vez (después la cambia el personal).
create or replace function public.set_my_birthdate(p_birthdate date)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client uuid; v_today date := (now() at time zone 'America/Managua')::date;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if p_birthdate is null or p_birthdate > v_today or p_birthdate < date '1920-01-01' then
    raise exception 'BIRTHDATE_INVALID';
  end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  update public.gym_clients set birthdate = p_birthdate where id = v_client and birthdate is null;
  if not found then raise exception 'BIRTHDATE_LOCKED'; end if;
  return public.client_age_status(v_client);
end;
$$;

-- El registro copia la fecha de nacimiento de los metadatos del alta (si es válida).
create or replace function public.crm_profile_created()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bd date;
begin
  if new.role = 'member' then
    begin
      select (raw_user_meta_data->>'birth_date')::date into v_bd from auth.users where id = new.id;
    exception when others then
      v_bd := null;
    end;
    if v_bd is not null and (v_bd > (now() at time zone 'America/Managua')::date or v_bd < date '1920-01-01') then
      v_bd := null;
    end if;
    insert into public.gym_clients(profile_id, full_name, phone, email, plan_id, birthdate)
    values (new.id, coalesce(nullif(trim(new.full_name), ''), 'Cliente'), new.phone, new.email, new.plan_id, v_bd)
    on conflict (profile_id) do nothing;
  end if;
  return new;
end;
$$;

-- 5) Consentimiento de datos de salud.
create or replace function public.has_active_health_consent(p_client uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.client_consents c
    where c.client_id = p_client and c.kind = 'datos_salud' and c.revoked_at is null
      and c.version = public.health_consent_version());
$$;

create or replace function public.record_health_consent(p_version text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client uuid; v_id uuid; v_age text;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  v_age := public.client_age_status(v_client);
  if v_age = 'minor' then raise exception 'MINOR'; end if;
  if v_age <> 'adult' then raise exception 'NO_BIRTHDATE'; end if;
  if p_version is distinct from public.health_consent_version() then raise exception 'CONSENT_VERSION'; end if;
  select id into v_id from public.client_consents
    where client_id = v_client and kind = 'datos_salud' and revoked_at is null and version = p_version limit 1;
  if found then return v_id; end if;
  insert into public.client_consents(client_id, kind, version, created_by)
  values (v_client, 'datos_salud', p_version, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Revoca el consentimiento vigente. No borra lo ya tratado (sin efecto retroactivo).
create or replace function public.revoke_health_consent()
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client uuid; v_n integer;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  update public.client_consents set revoked_at = now()
    where client_id = v_client and kind = 'datos_salud' and revoked_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- 6) Calculadora del cliente: edad y consentimiento obligatorios. Cada cálculo queda pendiente de aprobación.
create or replace function public.nutrition_self_calculate(
  p_goal text, p_inputs jsonb, p_results jsonb, p_meal_plan jsonb, p_routine jsonb, p_guide jsonb
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_client uuid; v_age text;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  v_age := public.client_age_status(v_client);
  if v_age = 'minor' then raise exception 'MINOR'; end if;
  if v_age <> 'adult' then raise exception 'NO_BIRTHDATE'; end if;
  if not public.has_active_health_consent(v_client) then raise exception 'NO_CONSENT'; end if;
  if p_goal not in ('bajar', 'definir', 'mantener', 'musculo', 'peso') then raise exception 'INVALID_GOAL'; end if;
  if exists (select 1 from public.client_nutrition_plans where client_id = v_client and edited_by_staff) then
    raise exception 'LOCKED_BY_STAFF';
  end if;
  insert into public.client_nutrition_plans(client_id, goal, inputs, results, meal_plan, routine, guide,
    source, edited_by_staff, submitted_at, submitted_measurement_id, approved_at, approved_by, updated_by, updated_at)
  values (v_client, p_goal, p_inputs, p_results, p_meal_plan, p_routine, coalesce(p_guide, '[]'::jsonb),
    'cliente', false, null, null, null, null, auth.uid(), now())
  on conflict (client_id) do update set goal = excluded.goal, inputs = excluded.inputs, results = excluded.results,
    meal_plan = excluded.meal_plan, routine = excluded.routine, guide = excluded.guide,
    source = 'cliente', edited_by_staff = false, submitted_at = null, submitted_measurement_id = null,
    approved_at = null, approved_by = null, updated_by = excluded.updated_by, updated_at = now();
  return v_client;
end;
$$;

-- 7) Guardar desde el personal: cada cambio vuelve a quedar pendiente hasta aprobarlo.
create or replace function public.nutrition_save(
  p_client uuid, p_goal text, p_inputs jsonb, p_results jsonb, p_meal_plan jsonb, p_routine jsonb, p_guide jsonb
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
begin
  if auth.uid() is null or not public.tools_can_edit(p_client) then raise exception 'AUTH'; end if;
  if p_goal not in ('bajar', 'definir', 'mantener', 'musculo', 'peso') then raise exception 'INVALID_GOAL'; end if;
  perform 1 from public.gym_clients where id = p_client;
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into public.client_nutrition_plans(client_id, goal, inputs, results, meal_plan, routine, guide,
    source, edited_by_staff, approved_at, approved_by, updated_by, updated_at)
  values (p_client, p_goal, p_inputs, p_results, p_meal_plan, p_routine, coalesce(p_guide, '[]'::jsonb),
    'entrenador', true, null, null, auth.uid(), now())
  on conflict (client_id) do update set goal = excluded.goal, inputs = excluded.inputs, results = excluded.results,
    meal_plan = excluded.meal_plan, routine = excluded.routine, guide = excluded.guide,
    source = 'entrenador', edited_by_staff = true, approved_at = null, approved_by = null,
    updated_by = excluded.updated_by, updated_at = now();
  return p_client;
end;
$$;

-- 8) Lectura: el cliente sólo ve dieta y rutina cuando están aprobadas; menores no ven nada.
create or replace function public.nutrition_get(p_client uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_client uuid; v_name text; v_plan public.client_nutrition_plans; v_settings public.client_tool_settings;
  v_own boolean; v_staff boolean; v_age text; v_plan_json jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if p_client is null then
    select id, full_name into v_client, v_name from public.gym_clients where profile_id = auth.uid() limit 1;
  else
    select id, full_name into v_client, v_name from public.gym_clients where id = p_client;
  end if;
  if v_client is null then return null; end if;
  v_own := exists (select 1 from public.gym_clients where id = v_client and profile_id = auth.uid());
  v_staff := public.progress_can_read_client(v_client);
  if not (v_own or v_staff) then return null; end if;
  select * into v_plan from public.client_nutrition_plans where client_id = v_client;
  if not found then v_plan := null; end if;
  select * into v_settings from public.client_tool_settings where client_id = v_client;
  if not found then v_settings := null; end if;
  v_age := public.client_age_status(v_client);
  if v_staff then
    return jsonb_build_object(
      'client_id', v_client, 'client_name', v_name, 'age_status', v_age,
      'plan', case when v_plan.client_id is not null then to_jsonb(v_plan) else null end,
      'can_edit', public.tools_can_edit(v_client),
      'can_self_calculate', false,
      'trainer_tools_enabled', coalesce(v_settings.trainer_tools_enabled, true));
  end if;
  -- Cliente (propio). Menor o sin fecha: sin herramientas ni datos.
  if v_age <> 'adult' then
    return jsonb_build_object('client_id', v_client, 'client_name', v_name, 'age_status', v_age,
      'plan', null, 'can_edit', false, 'can_self_calculate', false);
  end if;
  if v_plan.client_id is null then
    return jsonb_build_object('client_id', v_client, 'client_name', v_name, 'age_status', v_age,
      'plan', null, 'can_edit', false, 'can_self_calculate', true,
      'has_consent', public.has_active_health_consent(v_client), 'consent_version', public.health_consent_version());
  end if;
  v_plan_json := to_jsonb(v_plan) || jsonb_build_object('approved', v_plan.approved_at is not null);
  if v_plan.approved_at is null then
    -- Pendiente de aprobación: no se muestran dieta, rutina, guía ni resultados.
    v_plan_json := v_plan_json - 'results' - 'meal_plan' - 'routine' - 'guide' - 'approved_by';
  end if;
  return jsonb_build_object(
    'client_id', v_client, 'client_name', v_name, 'age_status', v_age,
    'plan', v_plan_json,
    'can_edit', false,
    'can_self_calculate', not coalesce(v_plan.edited_by_staff, false),
    'has_consent', public.has_active_health_consent(v_client), 'consent_version', public.health_consent_version());
end;
$$;

-- 9) Aplicar dieta/rutina aprobada: meta activa y rutina activa (lógica de 00046, interna).
create or replace function public.nutrition_apply_to_gym(p_client uuid, p_plan public.client_nutrition_plans)
returns void language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_today date := (now() at time zone 'America/Managua')::date;
  v_goal_label text; v_goal_type text; v_target_weight numeric; v_weeks int; v_months int; v_target_date date;
  v_days text[] := array[]::text[]; v_exercises jsonb := '[]'::jsonb; v_cardio int := 0;
  v_day jsonb; v_ex jsonb;
begin
  v_goal_label := case p_plan.goal
    when 'bajar' then 'Bajar de peso' when 'definir' then 'Definición muscular'
    when 'mantener' then 'Mantener físico' when 'musculo' then 'Ganar músculo' when 'peso' then 'Ganar peso' end;
  v_goal_type := case p_plan.goal
    when 'bajar' then 'perdida' when 'mantener' then 'mantenimiento' when 'definir' then 'otra' else 'ganancia' end;
  v_target_weight := nullif(p_plan.results->>'targetWeightKg', '')::numeric;
  if v_goal_type <> 'otra' and v_target_weight is null then raise exception 'NO_TARGET'; end if;
  v_weeks := coalesce(nullif(p_plan.results->>'weeksEstimate', '')::int, 0);
  v_months := case when v_goal_type = 'mantenimiento' or v_weeks <= 0 then 3
                   else least(12, greatest(1, ceil(v_weeks / 4.0)::int)) end;
  v_target_date := (v_today + make_interval(months => v_months))::date;

  update public.client_goals set status = 'cancelada', closed_at = now()
    where client_id = p_client and status = 'activa';
  insert into public.client_goals(client_id, goal_type, other_label, starts_on, target_date, target_weight_kg, created_by)
  values (p_client, v_goal_type, case when v_goal_type = 'otra' then v_goal_label end,
          v_today, v_target_date, v_target_weight, auth.uid());

  for v_day in select * from jsonb_array_elements(coalesce(p_plan.routine, '[]'::jsonb)) loop
    if (v_day->>'day') like 'Cardio%' then
      v_cardio := v_cardio + 1;
    else
      v_days := v_days || (v_day->>'day');
    end if;
    for v_ex in select * from jsonb_array_elements(coalesce(v_day->'exercises', '[]'::jsonb)) loop
      v_exercises := v_exercises || jsonb_build_array(jsonb_build_object(
        'ejercicio', (v_day->>'day') || ' · ' || (v_day->>'focus') || ': ' || (v_ex->>'name'),
        'series', nullif(v_ex->>'sets', '')::int,
        'reps', v_ex->>'reps',
        'descanso_s', nullif(v_ex->>'restSec', '')::int));
    end loop;
  end loop;
  if v_cardio > 0 then v_days := v_days || ('Cardio (' || v_cardio || ' sesiones)'); end if;
  if jsonb_array_length(v_exercises) = 0 or cardinality(v_days) = 0 then raise exception 'NO_ROUTINE'; end if;

  update public.client_routines set status = 'cerrada', ends_on = v_today
    where client_id = p_client and status = 'activa';
  insert into public.client_routines(client_id, name, days, exercises, starts_on, assigned_by)
  values (p_client, 'Rutina · ' || v_goal_label, v_days, v_exercises, v_today, auth.uid());
end;
$$;

-- 10) Aprobación por administrador o entrenador con herramientas habilitadas.
create or replace function public.nutrition_approve(p_client uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_plan public.client_nutrition_plans;
begin
  if auth.uid() is null or not public.tools_can_edit(p_client) then raise exception 'AUTH'; end if;
  select * into v_plan from public.client_nutrition_plans where client_id = p_client for update;
  if not found then raise exception 'NO_PLAN'; end if;
  if v_plan.approved_at is not null then
    return jsonb_build_object('already', true, 'approved_at', v_plan.approved_at);
  end if;
  perform public.nutrition_apply_to_gym(p_client, v_plan);
  update public.client_nutrition_plans
    set approved_at = now(), approved_by = auth.uid(), updated_at = now()
    where client_id = p_client;
  return jsonb_build_object('already', false, 'approved_at', now());
end;
$$;

-- 11) Registro del peso y la altura: consentimiento y edad obligatorios; ya no abre meta ni rutina.
create or replace function public.nutrition_submit_to_gym()
returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_client uuid; v_plan public.client_nutrition_plans; v_measurement uuid; v_weight numeric; v_height numeric;
  v_age text;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  if v_client is null then raise exception 'NOT_FOUND'; end if;
  v_age := public.client_age_status(v_client);
  if v_age = 'minor' then raise exception 'MINOR'; end if;
  if v_age <> 'adult' then raise exception 'NO_BIRTHDATE'; end if;
  if not public.has_active_health_consent(v_client) then raise exception 'NO_CONSENT'; end if;
  select * into v_plan from public.client_nutrition_plans where client_id = v_client for update;
  if not found then raise exception 'NO_PLAN'; end if;
  if v_plan.submitted_at is not null then
    return jsonb_build_object('already', true, 'submitted_at', v_plan.submitted_at,
      'measurement_id', v_plan.submitted_measurement_id);
  end if;
  v_weight := nullif(v_plan.inputs->>'weightKg', '')::numeric;
  v_height := nullif(v_plan.inputs->>'heightCm', '')::numeric;
  if v_weight is null or v_weight <= 0 then raise exception 'NO_WEIGHT'; end if;
  insert into public.body_measurements(client_id, measured_on, weight_kg, height_cm, notes, recorded_by)
  values (v_client, (now() at time zone 'America/Managua')::date, v_weight, v_height,
    'Registro desde la calculadora del cliente (objetivo: ' || v_plan.goal || ')', auth.uid())
  returning id into v_measurement;
  update public.client_nutrition_plans
    set submitted_at = now(), submitted_measurement_id = v_measurement, updated_at = now()
    where client_id = v_client;
  return jsonb_build_object('already', false, 'measurement_id', v_measurement, 'submitted_at', now());
end;
$$;

-- 12) Permisos.
revoke all on function public.health_consent_version(), public.client_age_status(uuid), public.my_age_status(),
  public.set_my_birthdate(date), public.has_active_health_consent(uuid), public.record_health_consent(text),
  public.revoke_health_consent(), public.nutrition_approve(uuid), public.nutrition_apply_to_gym(uuid, public.client_nutrition_plans),
  public.nutrition_submit_to_gym(), public.nutrition_self_calculate(text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_save(uuid, text, jsonb, jsonb, jsonb, jsonb, jsonb), public.nutrition_get(uuid),
  public.crm_profile_created() from public, anon;
grant execute on function public.health_consent_version(), public.my_age_status(), public.set_my_birthdate(date),
  public.record_health_consent(text), public.revoke_health_consent(), public.nutrition_approve(uuid),
  public.nutrition_submit_to_gym(), public.nutrition_self_calculate(text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_save(uuid, text, jsonb, jsonb, jsonb, jsonb, jsonb), public.nutrition_get(uuid)
  to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00048_edad_desde_fecha_nacimiento.sql
-- ═══════════════════════════════════════════════════════════

-- 00048 EDAD DESDE LA FECHA DE NACIMIENTO (sólo lectura, sin cambios de datos).
-- ESTADO: APLICADA EN SUPABASE (proyecto hcnuepdxmbsmlzdmvwhx) con autorización del dueño.
-- Requiere 00047.
--
-- El cliente ya no escribe su edad en la calculadora: la calcula el servidor desde gym_clients.birthdate.
-- Devuelve null si no hay fecha de nacimiento. Cliente: sólo su propia ficha. Personal: sólo si
-- progress_can_read_client(p_client) lo permite (mismo criterio que nutrition_get).

begin;
set local lock_timeout = '5s';

create or replace function public.client_age_years(p_client uuid default null)
returns integer language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_client uuid; v_bd date; v_own boolean;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if p_client is null then
    select id into v_client from public.gym_clients where profile_id = auth.uid() limit 1;
  else
    v_client := p_client;
  end if;
  if v_client is null then return null; end if;
  v_own := exists (select 1 from public.gym_clients where id = v_client and profile_id = auth.uid());
  if not (v_own or public.progress_can_read_client(v_client)) then raise exception 'AUTH'; end if;
  select birthdate into v_bd from public.gym_clients where id = v_client;
  if v_bd is null then return null; end if;
  return date_part('year', age((now() at time zone 'America/Managua')::date, v_bd))::int;
end;
$$;

revoke all on function public.client_age_years(uuid) from public, anon;
grant execute on function public.client_age_years(uuid) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00049_personal_datos_y_baja.sql
-- ═══════════════════════════════════════════════════════════

-- 00049 PERSONAL: DATOS FORMALES, ALTA, EDICIÓN Y BAJA (sólo administrador con verificación en dos pasos).
-- ESTADO: APLICADA en producción (hcnuepdxmbsmlzdmvwhx) con autorización del dueño. Verificada: tablas, RLS, funciones y permisos.
-- Requiere 00033 (is_admin), 00034 (admin_set_role, role_changes) y 00036 (personal no es cliente).
--
-- Reglas:
-- - Sólo is_admin() (rol admin + aal2) lee o cambia datos del personal. Nadie escribe directo: sólo funciones.
-- - Alta/edición: staff_save(). Si la persona no tiene rol de personal, lo asigna con admin_set_role (bitácora de roles).
-- - Baja: staff_set_status(false, motivo). Marca la ficha como inactiva y bloquea el inicio de sesión
--   (auth.users.banned_until). No cambia el rol. Reactivar revierte ambas cosas.
-- - Auditoría (staff_audit): guarda quién, cuándo, qué acción y los NOMBRES de los campos cambiados, nunca sus valores.
-- - No se crean cuentas nuevas: la persona crea su cuenta primero y el administrador la da de alta.
--
-- Nota: banned_until existe en auth.users de Supabase. Una sesión ya abierta sigue válida hasta que vence su token
-- (normalmente una hora); no puede renovarla.

begin;
set local lock_timeout = '5s';

-- 1) Ficha formal del personal.
create table if not exists public.staff_members (
  profile_id         uuid primary key references public.profiles(id) on delete restrict,
  full_name          text not null check (char_length(btrim(full_name)) between 3 and 120),
  national_id        text not null check (national_id ~ '^[0-9]{3}-[0-9]{6}-[0-9]{4}[A-Z]$'),
  birth_date         date not null,
  phone              text not null check (char_length(btrim(phone)) between 8 and 20),
  address            text not null check (char_length(btrim(address)) between 5 and 250),
  emergency_name     text not null check (char_length(btrim(emergency_name)) between 3 and 120),
  emergency_phone    text not null check (char_length(btrim(emergency_phone)) between 8 and 20),
  position_title     text not null check (char_length(btrim(position_title)) between 2 and 80),
  hired_on           date not null,
  responsibilities   text check (responsibilities is null or char_length(responsibilities) <= 800),
  internal_notes     text check (internal_notes is null or char_length(internal_notes) <= 800),
  status             text not null default 'activo' check (status in ('activo', 'inactivo')),
  deactivated_on     date,
  deactivation_reason text,
  created_by         uuid references public.profiles(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_by         uuid references public.profiles(id) on delete set null,
  updated_at         timestamptz not null default now(),
  constraint staff_deactivation_consistent check (
    (status = 'activo' and deactivated_on is null and deactivation_reason is null)
    or (status = 'inactivo' and deactivated_on is not null and char_length(btrim(deactivation_reason)) >= 5)
  )
);

alter table public.staff_members enable row level security;
revoke all on public.staff_members from anon, authenticated;
grant select on public.staff_members to authenticated;
drop policy if exists staff_members_admin_read on public.staff_members;
create policy staff_members_admin_read on public.staff_members
  for select to authenticated using (public.is_admin());

-- 2) Auditoría sin valores sensibles.
create table if not exists public.staff_audit (
  id             bigint generated always as identity primary key,
  profile_id     uuid not null references public.profiles(id) on delete cascade,
  action         text not null check (action in ('alta', 'edicion', 'baja', 'reactivacion')),
  changed_fields text[] not null default '{}',
  changed_by     uuid references public.profiles(id) on delete set null,
  changed_at     timestamptz not null default now()
);
alter table public.staff_audit enable row level security;
revoke all on public.staff_audit from anon, authenticated;
grant select on public.staff_audit to authenticated;
drop policy if exists staff_audit_admin_read on public.staff_audit;
create policy staff_audit_admin_read on public.staff_audit
  for select to authenticated using (public.is_admin());

-- 3) Alta y edición.
create or replace function public.staff_save(p_profile uuid, p_role text, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_today date := (now() at time zone 'America/Managua')::date;
  v_old public.staff_members;
  v_new public.staff_members;
  v_fields text[] := '{}';
  v_action text;
  v_name text; v_nid text; v_birth date; v_phone text; v_addr text; v_en text; v_ep text;
  v_pos text; v_hired date; v_resp text; v_notes text;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_profile is null or p_profile = auth.uid() then raise exception 'SELF_STAFF_CHANGE'; end if;
  if p_role not in ('trainer', 'cashier', 'admin') then raise exception 'INVALID_ROLE'; end if;
  if not exists (select 1 from public.profiles where id = p_profile) then raise exception 'NOT_FOUND'; end if;

  v_name  := btrim(coalesce(p_data->>'fullName', ''));
  v_nid   := btrim(coalesce(p_data->>'nationalId', ''));
  v_phone := btrim(coalesce(p_data->>'phone', ''));
  v_addr  := btrim(coalesce(p_data->>'address', ''));
  v_en    := btrim(coalesce(p_data->>'emergencyName', ''));
  v_ep    := btrim(coalesce(p_data->>'emergencyPhone', ''));
  v_pos   := btrim(coalesce(p_data->>'positionTitle', ''));
  v_resp  := nullif(btrim(coalesce(p_data->>'responsibilities', '')), '');
  v_notes := nullif(btrim(coalesce(p_data->>'internalNotes', '')), '');

  if char_length(v_name) < 3 or char_length(v_name) > 120 then raise exception 'NAME_INVALID'; end if;
  if v_nid !~ '^[0-9]{3}-[0-9]{6}-[0-9]{4}[A-Z]$' then raise exception 'NATIONAL_ID_INVALID'; end if;
  begin
    v_birth := (p_data->>'birthDate')::date;
    v_hired := (p_data->>'hiredOn')::date;
  exception when others then
    raise exception 'DATE_INVALID';
  end;
  if v_birth < date '1920-01-01' or v_birth > v_today - interval '18 years' then raise exception 'BIRTH_INVALID'; end if;
  if v_hired > v_today or v_hired < date '2000-01-01' then raise exception 'HIRE_DATE_INVALID'; end if;
  if char_length(v_phone) < 8 or char_length(v_phone) > 20 then raise exception 'PHONE_INVALID'; end if;
  if char_length(v_addr) < 5 or char_length(v_addr) > 250 then raise exception 'ADDRESS_INVALID'; end if;
  if char_length(v_en) < 3 or char_length(v_en) > 120 then raise exception 'EMERGENCY_NAME_INVALID'; end if;
  if char_length(v_ep) < 8 or char_length(v_ep) > 20 then raise exception 'EMERGENCY_PHONE_INVALID'; end if;
  if char_length(v_pos) < 2 or char_length(v_pos) > 80 then raise exception 'POSITION_INVALID'; end if;
  if v_resp is not null and char_length(v_resp) > 800 then raise exception 'RESPONSIBILITIES_TOO_LONG'; end if;
  if v_notes is not null and char_length(v_notes) > 800 then raise exception 'NOTES_TOO_LONG'; end if;

  -- Rol de personal: usa la misma regla y bitácora que el cambio de rol.
  if (select role::text from public.profiles where id = p_profile) is distinct from p_role then
    perform public.admin_set_role(p_profile, p_role);
  end if;

  select * into v_old from public.staff_members where profile_id = p_profile for update;
  if not found then
    v_action := 'alta';
    insert into public.staff_members(profile_id, full_name, national_id, birth_date, phone, address,
      emergency_name, emergency_phone, position_title, hired_on, responsibilities, internal_notes,
      created_by, updated_by)
    values (p_profile, v_name, v_nid, v_birth, v_phone, v_addr, v_en, v_ep, v_pos, v_hired, v_resp, v_notes,
      auth.uid(), auth.uid())
    returning * into v_new;
    v_fields := array['fullName','nationalId','birthDate','phone','address','emergencyName','emergencyPhone','positionTitle','hiredOn','responsibilities','internalNotes','role'];
  else
    v_action := 'edicion';
    update public.staff_members set
      full_name = v_name, national_id = v_nid, birth_date = v_birth, phone = v_phone, address = v_addr,
      emergency_name = v_en, emergency_phone = v_ep, position_title = v_pos, hired_on = v_hired,
      responsibilities = v_resp, internal_notes = v_notes, updated_by = auth.uid(), updated_at = now()
    where profile_id = p_profile
    returning * into v_new;
    if v_old.full_name is distinct from v_new.full_name then v_fields := array_append(v_fields, 'fullName'); end if;
    if v_old.national_id is distinct from v_new.national_id then v_fields := array_append(v_fields, 'nationalId'); end if;
    if v_old.birth_date is distinct from v_new.birth_date then v_fields := array_append(v_fields, 'birthDate'); end if;
    if v_old.phone is distinct from v_new.phone then v_fields := array_append(v_fields, 'phone'); end if;
    if v_old.address is distinct from v_new.address then v_fields := array_append(v_fields, 'address'); end if;
    if v_old.emergency_name is distinct from v_new.emergency_name then v_fields := array_append(v_fields, 'emergencyName'); end if;
    if v_old.emergency_phone is distinct from v_new.emergency_phone then v_fields := array_append(v_fields, 'emergencyPhone'); end if;
    if v_old.position_title is distinct from v_new.position_title then v_fields := array_append(v_fields, 'positionTitle'); end if;
    if v_old.hired_on is distinct from v_new.hired_on then v_fields := array_append(v_fields, 'hiredOn'); end if;
    if v_old.responsibilities is distinct from v_new.responsibilities then v_fields := array_append(v_fields, 'responsibilities'); end if;
    if v_old.internal_notes is distinct from v_new.internal_notes then v_fields := array_append(v_fields, 'internalNotes'); end if;
  end if;

  -- Nombre y teléfono visibles en el directorio.
  update public.profiles set full_name = v_name, phone = v_phone, updated_at = now() where id = p_profile;

  if v_action = 'edicion' and cardinality(v_fields) = 0 then
    return p_profile; -- sin cambios: no se escribe bitácora vacía
  end if;
  insert into public.staff_audit(profile_id, action, changed_fields, changed_by)
    values (p_profile, v_action, v_fields, auth.uid());
  return p_profile;
end;
$$;

-- 4) Baja y reactivación.
create or replace function public.staff_set_status(p_profile uuid, p_active boolean, p_reason text default null)
returns text language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_today date := (now() at time zone 'America/Managua')::date;
  v_role text;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_admins integer;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_profile is null or p_profile = auth.uid() then raise exception 'SELF_STAFF_CHANGE'; end if;
  if not exists (select 1 from public.staff_members where profile_id = p_profile) then raise exception 'NOT_FOUND'; end if;
  select role::text into v_role from public.profiles where id = p_profile for update;

  if p_active then
    update public.staff_members set status = 'activo', deactivated_on = null, deactivation_reason = null,
      updated_by = auth.uid(), updated_at = now()
      where profile_id = p_profile;
    update auth.users set banned_until = null where id = p_profile;
    insert into public.staff_audit(profile_id, action, changed_fields, changed_by)
      values (p_profile, 'reactivacion', '{}', auth.uid());
    return 'activo';
  end if;

  if char_length(v_reason) < 5 or char_length(v_reason) > 300 then raise exception 'REASON_REQUIRED'; end if;
  if v_role = 'admin' then
    select count(*) into v_admins from public.profiles p
      join public.staff_members s on s.profile_id = p.id
      where p.role = 'admin' and s.status = 'activo';
    if v_admins <= 1 then raise exception 'LAST_ADMIN'; end if;
  end if;

  update public.staff_members set status = 'inactivo', deactivated_on = v_today, deactivation_reason = v_reason,
    updated_by = auth.uid(), updated_at = now()
    where profile_id = p_profile;
  update auth.users set banned_until = 'infinity'::timestamptz where id = p_profile;
  insert into public.staff_audit(profile_id, action, changed_fields, changed_by)
    values (p_profile, 'baja', '{status}', auth.uid());
  return 'inactivo';
end;
$$;

revoke all on function public.staff_save(uuid, text, jsonb), public.staff_set_status(uuid, boolean, text)
  from public, anon;
grant execute on function public.staff_save(uuid, text, jsonb), public.staff_set_status(uuid, boolean, text)
  to authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00050_coaches_vista_publica.sql
-- ═══════════════════════════════════════════════════════════

-- 00050 · Proteger datos del personal en la tabla coaches
--
-- Problema: la política "Authenticated can read coaches" dejaba leer TODAS las columnas
-- (monthly_salary, phone, email, notes, hire_date, profile_id) a cualquier usuario con sesión.
--
-- Cambio (aditivo y reversible):
--  1. Vista public.coaches_public con solo las columnas públicas: id, full_name, name (alias
--     de full_name para el detalle de sesión), specialty, is_active.
--  2. Se quita la política de lectura general. Queda solo la política de administrador
--     (is_admin()), que ya existía para escribir y leer.
--  3. La landing y el detalle de sesión leen la vista, no la tabla.
--
-- Reversión (copiar y pegar si hiciera falta):
--   create policy "Authenticated can read coaches" on public.coaches
--     for select to authenticated using (true);
--   drop view if exists public.coaches_public;

begin;

create or replace view public.coaches_public as
select
  id,
  full_name,
  full_name as name,
  specialty,
  is_active
from public.coaches;

grant select on public.coaches_public to anon, authenticated;

drop policy if exists "Authenticated can read coaches" on public.coaches;

commit;

-- ═══════════════════════════════════════════════════════════
--  00051_coaches_vista_landing.sql
-- ═══════════════════════════════════════════════════════════

-- 00051 · La vista de entrenadores que usa la landing
--
-- Contexto: en producción la tabla coaches no tiene sort_order, role_es, bio_es, color,
-- initials, slug ni specialties (ver 00050). La landing falla con 42703 porque ordena por sort_order.
--
-- Cambio (aditivo y reversible): se recrea la vista public.coaches_public con las columnas
-- que espera la landing, calculadas a partir de lo que sí existe. Solo columnas públicas:
-- no incluye monthly_salary, phone, email, notes, hire_date ni profile_id.
--
-- Reversión (copiar y pegar si hiciera falta): regresar a la vista de 00050:
-- ============================================================
--  FIN DE LA PARTE 1
-- ============================================================
