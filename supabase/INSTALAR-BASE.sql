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
--  85 migraciones incluidas de 88.
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
--   drop view if exists public.coaches_public;
--   create view public.coaches_public as
--     select id, full_name, full_name as name, specialty, is_active from public.coaches;
--   grant select on public.coaches_public to anon, authenticated;

begin;

drop view if exists public.coaches_public;

create view public.coaches_public as
select
  c.id::text                                                        as id,
  c.id::text                                                        as slug,
  c.full_name                                                       as name,
  coalesce(c.specialty, '')                                         as role_es,
  coalesce(c.specialty, '')                                         as role_en,
  ''::text                                                          as bio_es,
  ''::text                                                          as bio_en,
  case when coalesce(c.specialty, '') = '' then '{}'::text[]
       else array[c.specialty] end                                  as specialties,
  upper(left(split_part(c.full_name, ' ', 1), 1)
     || left(split_part(c.full_name, ' ', 2), 1))                   as initials,
  '#d81a22'::text                                                   as color,
  row_number() over (order by c.full_name)::int                     as sort_order,
  c.full_name,
  c.specialty,
  c.is_active
from public.coaches c;

grant select on public.coaches_public to anon, authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00052_altura_en_ficha.sql
-- ═══════════════════════════════════════════════════════════

-- 00052 · La altura se guarda una sola vez en la ficha del cliente
--
-- Antes, cada medición traía su propia altura. Ahora:
--  1. gym_clients.height_cm guarda la altura una sola vez.
--  2. Un disparador en body_measurements aplica la regla en todas las rutas de escritura
--     (medición, calculadora y metas), sin cambiar esas funciones:
--     - Si la ficha no tiene altura, la primera medición con altura la guarda.
--     - Si la ficha ya tiene altura, una medición sin altura hereda la de la ficha.
--     - Si una medición trae una altura distinta, se rechaza con un mensaje claro.
--  3. Relleno inicial: la ficha toma la altura de la medición más reciente de cada cliente.
--     Las mediciones anteriores no se modifican (son de solo lectura).
--
-- Reversión (copiar y pegar si hiciera falta):
--   drop trigger if exists body_measurements_altura_ficha on public.body_measurements;
--   drop function if exists public.body_measurements_altura_ficha();
--   alter table public.gym_clients drop column if exists height_cm;

begin;

alter table public.gym_clients
  add column if not exists height_cm numeric(5,1)
  check (height_cm is null or (height_cm > 0 and height_cm <= 250));

update public.gym_clients c
   set height_cm = m.h
  from (
    select distinct on (client_id) client_id, height_cm as h
      from public.body_measurements
     where height_cm is not null
     order by client_id, measured_on desc, created_at desc
  ) m
 where m.client_id = c.id
   and c.height_cm is null;

create or replace function public.body_measurements_altura_ficha()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ficha numeric;
begin
  select height_cm into v_ficha from public.gym_clients where id = new.client_id for update;

  if new.height_cm is null then
    new.height_cm := v_ficha;
    return new;
  end if;

  if v_ficha is null then
    update public.gym_clients set height_cm = new.height_cm where id = new.client_id;
  elsif v_ficha <> new.height_cm then
    raise exception 'ALTURA_DISTINTA: la ficha ya tiene una altura de % cm. Para corregirla, consultá al administrador.', v_ficha;
  end if;
  return new;
end $$;

drop trigger if exists body_measurements_altura_ficha on public.body_measurements;
create trigger body_measurements_altura_ficha
  before insert on public.body_measurements
  for each row execute function public.body_measurements_altura_ficha();

commit;

-- ═══════════════════════════════════════════════════════════
--  00053_correccion_altura_admin.sql
-- ═══════════════════════════════════════════════════════════

-- 00053 · Corrección de la altura de la ficha (solo administrador)
--
-- La altura de la ficha (gym_clients.height_cm, ver 00052) no se cambia desde las mediciones.
-- Esta función es la única vía para corregirla:
--  - Solo el administrador con sesión verificada (is_admin: admin + aal2).
--  - Exige un motivo de al menos 5 caracteres.
--  - Registra el cambio en client_events (acción 'height_corrected') con valor anterior, nuevo y motivo.
--  - No modifica mediciones anteriores (son de solo lectura).
--
-- Reversión (copiar y pegar si hiciera falta):
--   drop function if exists public.admin_corregir_altura(uuid, numeric, text);

begin;

create or replace function public.admin_corregir_altura(p_client uuid, p_height numeric, p_motivo text)
returns numeric language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old numeric;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_height is null or p_height <= 0 or p_height > 250 then raise exception 'ALTURA_INVALIDA'; end if;
  if v_motivo is null or length(v_motivo) < 5 then raise exception 'MOTIVO_REQUERIDO'; end if;

  select height_cm into v_old from public.gym_clients where id = p_client for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old = p_height then return v_old; end if;

  update public.gym_clients set height_cm = p_height where id = p_client;
  insert into public.client_events(client_id, action, details, actor_id)
    values (p_client, 'height_corrected',
            jsonb_build_object('from', v_old, 'to', p_height, 'reason', v_motivo),
            auth.uid());
  return p_height;
end $$;

revoke all on function public.admin_corregir_altura(uuid, numeric, text) from public, anon;
grant execute on function public.admin_corregir_altura(uuid, numeric, text) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00054_mi_progreso_altura_ficha.sql
-- ═══════════════════════════════════════════════════════════

-- 00054 · «Mi progreso» devuelve la altura guardada en la ficha
--
-- Desde 00052 la altura vive una sola vez en gym_clients.height_cm (el
-- administrador puede corregirla con bitácora, 00053), y el panel la lee de
-- ahí. La vista del propio cliente usaba la altura y el IMC con la última
-- medición, porque la función my_progress (00040) no incluía la de la ficha:
-- si el administrador corregía la altura, el cliente seguía viendo la vieja
-- hasta su próxima medición.
--
-- Este cambio solo agrega 'ficha_height_cm' a la respuesta JSON, con el valor
-- de gym_clients.height_cm de la PROPIA ficha del que llama (misma fila que ya
-- se resolvía por profile_id = auth.uid()). No cambia permisos ni expone
-- datos de terceros: las mediciones históricas conservan su height_cm.
--
-- Reversión: re-aplicar la definición de supabase/migrations/00040_mi_progreso_cliente.sql.

begin;

create or replace function public.my_progress()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_client uuid := (select id from public.gym_clients where profile_id = auth.uid());
begin
  if v_client is null then
    return null;
  end if;

  return jsonb_build_object(
    'client_name', (select full_name from public.gym_clients where id = v_client),
    'ficha_height_cm', (select height_cm from public.gym_clients where id = v_client),
    'measurements', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'id', m.id,
                 'measured_on', m.measured_on,
                 'weight_kg', m.weight_kg,
                 'height_cm', m.height_cm,
                 'values', jsonb_build_object(
                   'cintura_cm', m.cintura_cm,
                   'pecho_cm', m.pecho_cm,
                   'biceps_relajado_cm', m.biceps_relajado_cm,
                   'biceps_contraido_cm', m.biceps_contraido_cm,
                   'antebrazo_cm', m.antebrazo_cm,
                   'gluteo_cm', m.gluteo_cm,
                   'muslo_cm', m.muslo_cm,
                   'pantorrilla_cm', m.pantorrilla_cm
                 )
               )
               order by m.measured_on desc, m.created_at desc)
        from public.body_measurements m
       where m.client_id = v_client
    ), '[]'::jsonb),
    'goal', (
      select jsonb_build_object(
               'id', g.id,
               'goal_type', g.goal_type,
               'other_label', g.other_label,
               'starts_on', g.starts_on,
               'target_date', g.target_date,
               'target_weight_kg', g.target_weight_kg)
        from public.client_goals g
       where g.client_id = v_client and g.status = 'activa'
       limit 1
    ),
    'routine', (
      select jsonb_build_object(
               'id', r.id,
               'name', r.name,
               'days', r.days,
               'exercises', r.exercises,
               'starts_on', r.starts_on)
        from public.client_routines r
       where r.client_id = v_client and r.status = 'activa'
       limit 1
    )
  );
end;
$$;

revoke all on function public.my_progress() from public, anon;
grant execute on function public.my_progress() to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00055_menores_rutas_personal.sql
-- ═══════════════════════════════════════════════════════════

-- 00055 · La protección de menores también aplica a las rutas del personal
--
-- La calculadora del cliente ya exigía ser adulto y tener fecha de nacimiento.
-- Sin embargo, las funciones usadas por el administrador o el entrenador para
-- guardar y aprobar un plan no repetían ese control. Esta migración cierra ese
-- hueco en la base de datos reutilizando client_age_status():
--   - minor  => MINOR
--   - unknown => NO_BIRTHDATE
--
-- No se modifica nutrition_get(): el personal sigue pudiendo leer la ficha y
-- ver la edad del cliente. No cambian tablas, datos ni otros permisos.
--
-- Reversión: volver a ejecutar las definiciones de nutrition_save() y
-- nutrition_approve() de 00047_menores_consentimiento_aprobacion.sql.

begin;

create or replace function public.nutrition_save(
  p_client uuid, p_goal text, p_inputs jsonb, p_results jsonb, p_meal_plan jsonb, p_routine jsonb, p_guide jsonb
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_age text;
begin
  if auth.uid() is null or not public.tools_can_edit(p_client) then raise exception 'AUTH'; end if;
  v_age := public.client_age_status(p_client);
  if v_age = 'minor' then raise exception 'MINOR'; end if;
  if v_age <> 'adult' then raise exception 'NO_BIRTHDATE'; end if;
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

create or replace function public.nutrition_approve(p_client uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_plan public.client_nutrition_plans; v_age text;
begin
  if auth.uid() is null or not public.tools_can_edit(p_client) then raise exception 'AUTH'; end if;
  v_age := public.client_age_status(p_client);
  if v_age = 'minor' then raise exception 'MINOR'; end if;
  if v_age <> 'adult' then raise exception 'NO_BIRTHDATE'; end if;
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

revoke all on function public.nutrition_save(uuid, text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_approve(uuid) from public, anon;
grant execute on function public.nutrition_save(uuid, text, jsonb, jsonb, jsonb, jsonb, jsonb),
  public.nutrition_approve(uuid) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00056_permisos_caja_separados.sql
-- ═══════════════════════════════════════════════════════════

-- 00056 · Etapa 3, tanda 2: permisos separados de caja
--
-- Reutiliza public.staff_permissions (00033). No crea otra tabla.
-- Los cinco permisos nuevos nacen apagados. El cierre del día (00037) se
-- conserva tal como esté configurado y no se reinicia en esta migración.
--
-- Alcance aprobado:
--   * Caja conserva su operación diaria: cobros por servicio, abonos,
--     comprobantes y cierre del día si su interruptor actual está encendido.
--   * Resultado mensual, gráficos, saldos de cuentas del gimnasio, gastos
--     (ver y registrar) y lista de cuentas por cobrar se habilitan por
--     separado desde administración.
--   * Administración siempre conserva acceso.
--   * Registrar un abono desde la ficha sigue siendo operación diaria; el
--     permiso de cuentas por cobrar controla la lista consolidada y sus
--     totales, no el formulario operativo de abonos.
--
-- Reversión: volver a las definiciones de finance_read/finance_debt_report
-- de 00028/00038 y de finance_options/finance_receipt/
-- finance_recent_receipts/finance_record_movement de 00024/00028; retirar
-- las políticas restrictivas nuevas. Las claves pueden quedar en
-- staff_permissions sin efecto.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.staff_permissions') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.is_cashier()') is null
     or to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('public.finance_read_before_debts(text,integer)') is null
     or to_regprocedure('public.finance_record_movement_before_debts(uuid,text,uuid,numeric,text,text,text,text,numeric,text)') is null
     or to_regprocedure('public.finance_options()') is null
     or to_regprocedure('public.finance_receipt(uuid)') is null
     or to_regprocedure('public.finance_recent_receipts(text,uuid)') is null then
    raise exception 'CASHIER_PERMISSIONS_PREREQUISITE_MISSING';
  end if;
end $$;

insert into public.staff_permissions(key, enabled)
values
  ('cashier_can_view_monthly_result', false),
  ('cashier_can_view_charts', false),
  ('cashier_can_view_account_balances', false),
  ('cashier_can_manage_expenses', false),
  ('cashier_can_view_receivables', false)
on conflict (key) do nothing;

-- Verdadero para administración; para caja exige aal2 y el interruptor dado.
-- La lista blanca evita usar este helper para permisos ajenos (por ejemplo,
-- trainer_can_request_clients o cashier_can_void).
create or replace function public.finance_permission_enabled(p_key text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_key is null or p_key not in (
      'cashier_can_view_daily_close',
      'cashier_can_view_monthly_result',
      'cashier_can_view_charts',
      'cashier_can_view_account_balances',
      'cashier_can_manage_expenses',
      'cashier_can_view_receivables'
    ) then false
    when public.is_admin() then true
    when public.is_cashier() then coalesce(
      (select enabled from public.staff_permissions where key = p_key),
      false
    )
    else false
  end;
$$;
revoke all on function public.finance_permission_enabled(text) from public, anon, authenticated;
grant execute on function public.finance_permission_enabled(text) to authenticated;

-- Una sola lectura para que el servidor decida qué pedir y qué mostrar.
-- No devuelve importes ni datos de clientes.
create or replace function public.cashier_permissions()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'dailyClose', public.finance_permission_enabled('cashier_can_view_daily_close'),
    'monthlyResult', public.finance_permission_enabled('cashier_can_view_monthly_result'),
    'charts', public.finance_permission_enabled('cashier_can_view_charts'),
    'accountBalances', public.finance_permission_enabled('cashier_can_view_account_balances'),
    'expenses', public.finance_permission_enabled('cashier_can_manage_expenses'),
    'receivables', public.finance_permission_enabled('cashier_can_view_receivables')
  );
$$;
revoke all on function public.cashier_permissions() from public, anon, authenticated;
grant execute on function public.cashier_permissions() to authenticated;

-- Lector financiero: la envoltura de 00028, con guardias por sección y
-- ocultamiento de campos sensibles cuando una sección compartida sí puede
-- leerse para la operación diaria. Se conserva la llamada a
-- finance_read_before_debts, que finance_debt_ready() verifica textualmente.
create or replace function public.finance_read(p_section text, p_limit integer default 30)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v jsonb;
  v_monthly boolean := public.finance_permission_enabled('cashier_can_view_monthly_result');
  v_charts boolean := public.finance_permission_enabled('cashier_can_view_charts');
  v_account_balances boolean := public.finance_permission_enabled('cashier_can_view_account_balances');
  v_expenses boolean := public.finance_permission_enabled('cashier_can_manage_expenses');
  v_receivables boolean := public.finance_permission_enabled('cashier_can_view_receivables');
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if public.crm_finance_layout() <> 'bank_accounts_split' then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;

  if p_section = 'monthly' and not v_monthly then raise exception 'AUTH'; end if;
  if p_section in ('daily', 'method_totals') and not v_charts then raise exception 'AUTH'; end if;
  if p_section = 'receivables' and not v_receivables then raise exception 'AUTH'; end if;
  if p_section = 'categories' and not v_expenses then raise exception 'AUTH'; end if;

  v := public.finance_read_before_debts(p_section, p_limit);

  if p_section = 'summary' then
    v := jsonb_set(v, '{data,totalOwed}', to_jsonb(coalesce((v#>>'{data,totalOwed}')::numeric, 0) + (select coalesce(sum(debt_nio), 0) from public.client_debt_balances)));
    v := jsonb_set(v, '{data,totalOwedUsd}', to_jsonb(coalesce((v#>>'{data,totalOwedUsd}')::numeric, 0) + (select coalesce(sum(debt_usd), 0) from public.client_debt_balances)));
  elsif p_section = 'receivables' then
    select jsonb_set(v, '{data}', coalesce(jsonb_agg(r order by (r->>'total_owed_nio')::numeric desc, r->>'member_id', r->>'client_id'), '[]'::jsonb)) into v from (
      select value as r from jsonb_array_elements(v->'data')
      union all
      select jsonb_build_object('member_id', null, 'client_id', c.id, 'full_name', c.full_name, 'email', c.email, 'phone', c.phone,
        'invoices_open', null, 'total_owed_nio', b.debt_nio, 'total_owed_usd', b.debt_usd, 'oldest_due', null, 'days_overdue', null)
      from public.client_debt_balances b join public.gym_clients c on c.id = b.client_id where b.debt_nio > 0 or b.debt_usd > 0
    ) r;
  end if;

  -- La ficha de resumen sí se usa en la operación diaria; sin permiso se
  -- neutralizan solo los campos mensuales o de deuda consolidada. La
  -- interfaz, además, no pinta esos indicadores.
  if p_section = 'summary' then
    if not v_monthly then
      v := jsonb_set(v, '{data,incomeMonth}', '0'::jsonb);
      v := jsonb_set(v, '{data,expenseMonth}', '0'::jsonb);
      v := jsonb_set(v, '{data,netMonth}', '0'::jsonb);
      v := jsonb_set(v, '{data,txMonth}', '0'::jsonb);
    end if;
    if not v_receivables then
      v := jsonb_set(v, '{data,totalOwed}', '0'::jsonb);
      v := jsonb_set(v, '{data,totalOwedUsd}', '0'::jsonb);
    end if;
  elsif p_section = 'accounts' and not v_account_balances then
    -- Caja sigue viendo qué cuentas existen para cobrar, sin sus saldos.
    select jsonb_set(v, '{data}', coalesce(jsonb_agg(jsonb_set(r, '{balance}', '0'::jsonb) order by ord), '[]'::jsonb)) into v
    from jsonb_array_elements(v->'data') with ordinality as rows(r, ord);
  elsif p_section = 'transactions' and not v_expenses then
    select jsonb_set(v, '{data}', coalesce(jsonb_agg(r order by ord), '[]'::jsonb)) into v
    from jsonb_array_elements(v->'data') with ordinality as rows(r, ord)
    where coalesce(r->>'direction', '') <> 'expense';
  elsif p_section = 'daily' and not v_expenses then
    select jsonb_set(v, '{data}', coalesce(jsonb_agg(
      jsonb_set(jsonb_set(r, '{expense_nio}', '0'::jsonb), '{net_nio}', coalesce(r->'income_nio', '0'::jsonb)) order by ord
    ), '[]'::jsonb)) into v
    from jsonb_array_elements(v->'data') with ordinality as rows(r, ord);
  elsif p_section = 'method_totals' and not v_expenses then
    select jsonb_set(v, '{data}', coalesce(jsonb_agg(
      jsonb_set(jsonb_set(r, '{expense_nio}', '0'::jsonb), '{total_nio}', coalesce(r->'income_nio', '0'::jsonb)) order by ord
    ), '[]'::jsonb)) into v
    from jsonb_array_elements(v->'data') with ordinality as rows(r, ord);
  end if;

  return v;
end $$;
revoke all on function public.finance_read(text, integer) from public, anon, authenticated;
grant execute on function public.finance_read(text, integer) to authenticated;

-- El resumen sigue disponible para la caja diaria (con campos protegidos por
-- finance_read). La lista de cuentas por cobrar exige su permiso propio.
create or replace function public.finance_debt_report(p_section text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_section not in ('summary', 'receivables') or p_section is null then raise exception 'INVALID_FINANCE_SECTION'; end if;
  if p_section = 'receivables'
     and not public.finance_permission_enabled('cashier_can_view_receivables') then
    raise exception 'AUTH';
  end if;
  return public.finance_read(p_section, 30);
end $$;
revoke all on function public.finance_debt_report(text) from public, anon, authenticated;
grant execute on function public.finance_debt_report(text) to authenticated;

-- Escritura de gastos: el cobro por servicio no cambia. La llamada a
-- finance_record_movement_before_debts se conserva (finance_debt_ready).
create or replace function public.finance_record_movement(
  p_request uuid, p_kind text, p_client uuid, p_amount numeric, p_currency text,
  p_method text, p_account text, p_concept text, p_fx numeric, p_category text default null
) returns uuid language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  if p_kind = 'expense'
     and not public.finance_permission_enabled('cashier_can_manage_expenses') then
    raise exception 'AUTH';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text, 0));
  if exists(select 1 from public.client_debt_entries where request_id = p_request) then raise exception 'REQUEST_CONFLICT'; end if;
  return public.finance_record_movement_before_debts(p_request, p_kind, p_client, p_amount, p_currency, p_method, p_account, p_concept, p_fx, p_category);
end $$;
revoke all on function public.finance_record_movement(uuid, text, uuid, numeric, text, text, text, text, numeric, text) from public, anon, authenticated;
grant execute on function public.finance_record_movement(uuid, text, uuid, numeric, text, text, text, text, numeric, text) to authenticated;

-- Opciones de formularios: sin permiso de gastos no se entregan categorías.
-- Las cuentas y métodos necesarios para cobrar no cambian ni incluyen saldos.
create or replace function public.finance_options()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v := public.crm_options();
  return (v - 'payments_enabled' - 'payment_block_reason') || jsonb_build_object(
    'protocol', 'service-v1',
    'writes_enabled', public.finance_writes_ready(),
    'categories', case
      when public.finance_permission_enabled('cashier_can_manage_expenses')
        then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by display_order) from public.expense_categories), '[]'::jsonb)
      else '[]'::jsonb
    end
  );
end $$;
revoke all on function public.finance_options() from public, anon, authenticated;
grant execute on function public.finance_options() to authenticated;

create or replace function public.finance_receipt(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_payload jsonb; v_receipt jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select payload, receipt into v_payload, v_receipt
  from public.finance_entries where transaction_id = p_id;
  if not found then raise exception 'RECEIPT_NOT_FOUND'; end if;
  if coalesce(v_payload->>'kind', v_receipt->>'kind', '') = 'expense'
     and not public.finance_permission_enabled('cashier_can_manage_expenses') then
    raise exception 'AUTH';
  end if;
  return v_receipt;
end $$;
revoke all on function public.finance_receipt(uuid) from public, anon, authenticated;
grant execute on function public.finance_receipt(uuid) to authenticated;

create or replace function public.finance_recent_receipts(p_kind text, p_client uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_kind is null or p_kind not in ('service_income', 'expense')
    or (p_kind = 'service_income' and p_client is null)
    or (p_kind = 'expense' and p_client is not null) then raise exception 'INVALID_PAYMENT'; end if;
  if p_kind = 'expense'
     and not public.finance_permission_enabled('cashier_can_manage_expenses') then
    raise exception 'AUTH';
  end if;
  return coalesce((select jsonb_agg(receipt order by created_at desc, transaction_id) from (
    select receipt, created_at, transaction_id from public.finance_entries
    where payload->>'kind' = p_kind and (p_client is null or payload->>'client' = p_client::text)
    order by created_at desc, transaction_id limit 50
  ) r), '[]'::jsonb);
end $$;
revoke all on function public.finance_recent_receipts(text, uuid) from public, anon, authenticated;
grant execute on function public.finance_recent_receipts(text, uuid) to authenticated;

-- RLS directa para los datos que sí se pueden separar por tabla sin romper
-- la operación diaria. Las funciones SECURITY DEFINER operativas (cobros,
-- abonos y detalle de una ficha) conservan sus propias comprobaciones.
do $$ begin
  if to_regclass('public.bank_accounts') is not null then
    execute 'drop policy if exists cashier_account_balances_restrictive on public.bank_accounts';
    execute 'create policy cashier_account_balances_restrictive on public.bank_accounts as restrictive for select to authenticated using (public.is_admin() or (public.is_cashier() and public.finance_permission_enabled(''cashier_can_view_account_balances'')))';
  end if;

  if to_regclass('public.member_balances') is not null then
    execute 'drop policy if exists cashier_receivables_member_balances on public.member_balances';
    execute 'create policy cashier_receivables_member_balances on public.member_balances as restrictive for select to authenticated using (member_id = (select auth.uid()) or public.is_admin() or (public.is_cashier() and public.finance_permission_enabled(''cashier_can_view_receivables'')))';
  end if;

  if to_regclass('public.client_debt_balances') is not null then
    execute 'drop policy if exists cashier_receivables_client_balances on public.client_debt_balances';
    execute 'create policy cashier_receivables_client_balances on public.client_debt_balances as restrictive for select to authenticated using (public.is_admin() or (public.is_cashier() and public.finance_permission_enabled(''cashier_can_view_receivables'')))';
  end if;

  if to_regclass('public.client_debt_entries') is not null then
    execute 'drop policy if exists cashier_receivables_client_entries on public.client_debt_entries';
    execute 'create policy cashier_receivables_client_entries on public.client_debt_entries as restrictive for select to authenticated using (public.is_admin() or (public.is_cashier() and public.finance_permission_enabled(''cashier_can_view_receivables'')))';
  end if;
end $$;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00057_pase_del_dia_tarifa.sql
-- ═══════════════════════════════════════════════════════════

-- 00057 · Recepción: tarifa en córdobas del pase del día
--
-- Alcance aprobado, pequeño y aditivo:
--   * NO se toca public.plans.price. Ese precio histórico sigue siendo USD
--     (por ejemplo, Boxeo se muestra como US$20). Guardar C$40 allí
--     publicaría por error un pase de US$40.
--   * Se agrega price_nio como tarifa separada en córdobas. El pase del día
--     arranca en C$40 solo si todavía no tiene tarifa; nunca pisa un valor
--     que administración ya haya configurado.
--   * crm_options() expone slug, periodo y price_nio al personal autorizado
--     para que la ficha pueda preparar el cobro existente. No se crea otro
--     motor de cobro ni otra tabla.
--   * Solo un administrador con MFA puede cambiar la tarifa, mediante una
--     función acotada al plan de una sesión `pase-del-dia`.
--
-- Reversión segura: volver crm_options() a la definición de 00022 y retirar
-- admin_set_day_pass_price_nio(numeric). La columna price_nio puede quedar
-- sin uso; no hace falta borrar datos para revertir el flujo.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.plans') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('public.crm_finance_layout()') is null then
    raise exception 'DAY_PASS_TARIFF_PREREQUISITE_MISSING';
  end if;
end $$;

alter table public.plans
  add column if not exists price_nio numeric(12, 2);

do $$ begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'plans_price_nio_nonnegative_chk'
       and conrelid = 'public.plans'::regclass
  ) then
    alter table public.plans
      add constraint plans_price_nio_nonnegative_chk
      check (price_nio is null or price_nio >= 0);
  end if;
end $$;

comment on column public.plans.price_nio is
  'Tarifa opcional en córdobas (NIO). No reemplaza plans.price, que sigue siendo USD.';

-- Tarifa inicial ANULADA en la plantilla: el precio del pase del día
-- se configura en PERSONALIZAR-GIMNASIO.sql o en Administración → Planes.

-- Misma función de 00022; el único cambio es que cada plan también trae
-- slug, period y price_nio para identificar la tarifa del pase del día.
create or replace function public.crm_options()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_layout text; v_methods jsonb; v_accounts jsonb; v_plans jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v_layout := public.crm_finance_layout();
  if v_layout='unsupported' then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;
  select coalesce(jsonb_agg(to_jsonb(p) order by sort_order),'[]'::jsonb) into v_plans
    from (select id,name_es,slug,period,price_nio,sort_order from public.plans where is_active) p;
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

-- Editor acotado: no acepta un id arbitrario ni permite tocar otros planes.
-- NULL quita la tarifa rápida y la web vuelve a mostrar "Consultar".
create or replace function public.admin_set_day_pass_price_nio(p_price numeric)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id text;
  v_slug text;
  v_name text;
  v_price numeric;
  v_active boolean;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_price is not null
     and (p_price <= 0 or p_price > 99999999 or p_price <> round(p_price, 2)) then
    raise exception 'INVALID_PRICE';
  end if;

  update public.plans
     set price_nio = p_price
   where slug = 'pase-del-dia'
     and period = 'session'
  returning id, slug, name_es, price_nio, is_active
       into v_id, v_slug, v_name, v_price, v_active;

  if not found then raise exception 'NOT_FOUND'; end if;

  return jsonb_build_object(
    'id', v_id,
    'slug', v_slug,
    'name_es', v_name,
    'price_nio', v_price,
    'is_active', v_active
  );
end $$;
revoke all on function public.admin_set_day_pass_price_nio(numeric) from public, anon, authenticated;
grant execute on function public.admin_set_day_pass_price_nio(numeric) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00058_tarifas_gimnasio_nio.sql
-- ═══════════════════════════════════════════════════════════

-- 00058 · Tarifas en córdobas de pesas y máquinas
--
-- Tarifas confirmadas por el dueño:
--   Día C$40 (ya estaba en 00057) · Semana C$150 · Quincena C$280 · Mes C$560.
--
-- Alcance aprobado:
--   * Solo pesas y máquinas. Boxeo queda aparte y no se toca: sigue con su
--     precio histórico `plans.price` en USD y sin usar estas tarifas NIO.
--   * Se reutiliza `public.plans` y `plans.price_nio` de 00057. No se crea
--     otra tabla ni otro motor de cobro.
--   * Cobrar Semana, Quincena o Mes solo registra el ingreso. Esta migración
--     NO activa, renueva ni calcula vigencia de membresía.
--   * La quincena usa el nuevo periodo `fortnight`. El editor nuevo solo
--     acepta los cuatro slugs de pesas y máquinas y exige administrador+MFA.
--
-- Reversión segura: poner `is_active = false` en los planes nuevos y dejar
-- sus `price_nio` en NULL; retirar `admin_set_plan_price_nio(text, numeric)`.
-- No hace falta borrar filas ni cobros. El periodo `fortnight` puede quedar
-- permitido sin uso.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.plans') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('public.crm_finance_layout()') is null
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'plans'
          and column_name = 'price_nio'
     ) then
    raise exception 'GYM_TARIFFS_PREREQUISITE_MISSING';
  end if;
end $$;

-- Permitir `fortnight` sin tocar otras restricciones de la tabla.
do $$
declare
  r record;
begin
  for r in
    select distinct c.conname
      from pg_constraint c
      join pg_attribute a
        on a.attrelid = c.conrelid
       and a.attnum = any (c.conkey)
     where c.conrelid = 'public.plans'::regclass
       and c.contype = 'c'
       and a.attname = 'period'
  loop
    execute format('alter table public.plans drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.plans
  add constraint plans_period_check
  check (period in ('month', 'week', 'fortnight', 'session'));

-- Catálogo de planes ANULADO en la plantilla: los cuatro planes base
-- (sin precio) los crea PERSONALIZAR-GIMNASIO.sql. Las tarifas se
-- cargan en Administración → Planes, no se heredan de nadie.

-- Relleno de tarifas ANULADO en la plantilla: ningún plan nace con
-- precio; los define cada gimnasio.

-- Orden público por duración, después de Boxeo: día, semana, quincena y mes.
update public.plans
   set sort_order = case slug
     when 'pase-del-dia' then 2
     when 'gimnasio-semanal' then 3
     when 'gimnasio-quincenal' then 4
     when 'gimnasio-mensual' then 5
   end
 where (slug = 'pase-del-dia' and period = 'session')
    or (slug = 'gimnasio-semanal' and period = 'week')
    or (slug = 'gimnasio-quincenal' and period = 'fortnight')
    or (slug = 'gimnasio-mensual' and period = 'month');

-- Editor acotado a las cuatro tarifas NIO de pesas y máquinas. Boxeo y
-- cualquier otro slug se rechazan; NULL quita el cobro rápido de esa tarifa.
create or replace function public.admin_set_plan_price_nio(p_slug text, p_price numeric)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id text;
  v_slug text;
  v_period text;
  v_expected_period text;
  v_name text;
  v_price numeric;
  v_active boolean;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  v_expected_period := case p_slug
    when 'pase-del-dia' then 'session'
    when 'gimnasio-semanal' then 'week'
    when 'gimnasio-quincenal' then 'fortnight'
    when 'gimnasio-mensual' then 'month'
    else null
  end;
  if v_expected_period is null then
    raise exception 'INVALID_PLAN';
  end if;
  if p_price is not null
     and (p_price <= 0 or p_price > 99999999 or p_price <> round(p_price, 2)) then
    raise exception 'INVALID_PRICE';
  end if;

  update public.plans
     set price_nio = p_price
   where slug = p_slug
     and period = v_expected_period
  returning id, slug, period, name_es, price_nio, is_active
       into v_id, v_slug, v_period, v_name, v_price, v_active;

  if not found then raise exception 'NOT_FOUND'; end if;

  return jsonb_build_object(
    'id', v_id,
    'slug', v_slug,
    'period', v_period,
    'name_es', v_name,
    'price_nio', v_price,
    'is_active', v_active
  );
end $$;
revoke all on function public.admin_set_plan_price_nio(text, numeric) from public, anon, authenticated;
grant execute on function public.admin_set_plan_price_nio(text, numeric) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00059_cobro_con_productos.sql
-- ═══════════════════════════════════════════════════════════

-- Cobro combinado de un servicio y productos desde la ficha del cliente.
--
-- Decisiones de esta tanda:
-- - El cliente siempre está seleccionado o creado con el alta rápida; no se
--   inventa un cliente genérico para ventas de mostrador.
-- - Se puede cobrar solo el servicio (flujo anterior), servicio + productos o
--   solo productos. Si hay productos, todo el cobro usa NIO, un método y una
--   cuenta, porque el catálogo de productos ya trabaja en córdobas.
-- - El servidor bloquea los productos en orden, comprueba precio y stock y
--   registra cada línea con finance_record_movement. Todo ocurre en una sola
--   transacción: si falla un producto, tampoco queda registrado el servicio.
-- - La referencia principal es idempotente. Reintentar el mismo payload
--   devuelve el mismo grupo; cambiarlo con la misma referencia es conflicto.
-- - Reversión: retirar primero el uso en la aplicación; después se pueden
--   eliminar finance_record_checkout, product_sale_catalog y la tabla de
--   grupos sin tocar transactions, finance_entries ni stock_movements.

begin;
set local lock_timeout = '5s';

create table if not exists public.finance_checkout_groups (
  request_id uuid primary key,
  client_id uuid not null references public.gym_clients(id) on delete restrict,
  payload jsonb not null,
  result jsonb not null,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists finance_checkout_groups_client_idx
  on public.finance_checkout_groups(client_id, created_at desc);

alter table public.finance_checkout_groups enable row level security;
revoke all on public.finance_checkout_groups from public, anon, authenticated;
grant select on public.finance_checkout_groups to authenticated;
drop policy if exists finance_checkout_groups_staff_read on public.finance_checkout_groups;
create policy finance_checkout_groups_staff_read
  on public.finance_checkout_groups for select to authenticated
  using (public.crm_is_staff());

-- La tabla nueva también debe quedar cerrada a escritura directa y sin
-- disparadores desconocidos para habilitar la escritura financiera.
create or replace function public.finance_writes_ready()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.crm_finance_layout() = 'bank_accounts_split'
    and not exists(
      select 1 from pg_trigger
      where tgrelid in (
        'public.transactions'::regclass,
        'public.bank_accounts'::regclass,
        'public.finance_entries'::regclass,
        'public.finance_checkout_groups'::regclass
      ) and not tgisinternal and tgenabled <> 'D'
    )
    and not exists(
      select 1 from unnest(array[
        'public.transactions',
        'public.bank_accounts',
        'public.finance_entries',
        'public.finance_checkout_groups'
      ]) as targets(tab)
      where has_table_privilege('authenticated', tab, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         or has_table_privilege('anon', tab, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    );
$$;
revoke all on function public.finance_writes_ready() from public, anon, authenticated;

-- Catálogo mínimo para la venta en recepción. No expone costo ni ganancia.
create or replace function public.product_sale_catalog()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  return jsonb_build_object('products', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'category', p.category,
      'subcategory', p.subcategory,
      'attributes', p.attributes,
      'price', p.price,
      'stock', s.stock,
      'low_stock', s.stock <= p.stock_min
    ) order by p.category, p.name)
    from public.products p
    cross join lateral (
      select coalesce(sum(qty), 0)::integer as stock
      from public.stock_movements sm
      where sm.product_id = p.id
    ) s
    where p.status = 'activo' and p.price > 0 and s.stock > 0
  ), '[]'::jsonb));
end;
$$;

create or replace function public.finance_record_checkout(
  p_request uuid,
  p_client uuid,
  p_service_amount numeric,
  p_service_concept text,
  p_currency text,
  p_method text,
  p_account text,
  p_fx numeric,
  p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_actor uuid := auth.uid();
  v_payload jsonb;
  v_existing public.finance_checkout_groups;
  v_concept text := nullif(trim(coalesce(p_service_concept, '')), '');
  v_items jsonb := '[]'::jsonb;
  v_seen uuid[] := '{}';
  v_row record;
  v_product uuid;
  v_qty integer;
  v_unit_price numeric;
  v_product_name text;
  v_product_status text;
  v_product_price numeric;
  v_stock integer;
  v_line_total numeric;
  v_products_total numeric := 0;
  v_total numeric;
  v_child_request uuid;
  v_service_tx uuid;
  v_tx uuid;
  v_transaction_ids jsonb := '[]'::jsonb;
  v_receipts jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  if p_client is null then raise exception 'CLIENT_REQUIRED'; end if;
  if p_service_amount is null or p_service_amount < 0 or p_service_amount > 99999999
    or p_service_amount <> round(p_service_amount, 2)
    or p_currency is distinct from 'NIO'
    or p_method is null or length(trim(p_method)) not between 1 and 80
    or p_account is null or length(trim(p_account)) not between 1 and 80
    or p_fx is null or p_fx < 0.0001 or p_fx > 10000 or p_fx <> round(p_fx, 4) then
    raise exception 'INVALID_PAYMENT';
  end if;
  if p_service_amount > 0 and (v_concept is null or length(v_concept) not between 2 and 200) then
    raise exception 'INVALID_PAYMENT';
  end if;
  if p_service_amount = 0 then
    -- El concepto no se usa en la venta de solo productos; las líneas llevan
    -- el nombre de cada producto en su comprobante.
    v_concept := null;
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) not between 1 and 50 then
    raise exception 'INVALID_ITEMS';
  end if;

  -- Normaliza y ordena el payload antes de bloquear productos. Ordenar por
  -- producto evita interbloqueos entre dos cobros simultáneos.
  for v_row in
    select item
    from jsonb_array_elements(p_items) as items(item)
    order by coalesce(item->>'product', '')
  loop
    if jsonb_typeof(v_row.item) <> 'object'
      or not (v_row.item ?& array['product', 'qty', 'unit_price'])
      or coalesce(v_row.item->>'product', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      or coalesce(v_row.item->>'qty', '') !~ '^[0-9]{1,4}$'
      or jsonb_typeof(v_row.item->'unit_price') <> 'number' then
      raise exception 'INVALID_ITEMS';
    end if;
    v_product := (v_row.item->>'product')::uuid;
    v_qty := (v_row.item->>'qty')::integer;
    v_unit_price := (v_row.item->>'unit_price')::numeric;
    if v_qty < 1 or v_qty > 1000
      or v_unit_price <= 0 or v_unit_price > 9999999
      or v_unit_price <> round(v_unit_price, 2)
      or v_product = any(v_seen) then
      raise exception 'INVALID_ITEMS';
    end if;
    v_seen := array_append(v_seen, v_product);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product', v_product,
      'qty', v_qty,
      'unit_price', v_unit_price
    ));
  end loop;

  v_payload := jsonb_build_object(
    'client', p_client,
    'service_amount', p_service_amount,
    'service_concept', v_concept,
    'currency', p_currency,
    'method', trim(p_method),
    'account', trim(p_account),
    'fx', p_fx,
    'items', v_items
  );

  perform pg_advisory_xact_lock(hashtextextended('checkout:' || p_request::text, 0));
  select * into v_existing
  from public.finance_checkout_groups
  where request_id = p_request;
  if found then
    if v_existing.payload is distinct from v_payload then
      raise exception 'REQUEST_CONFLICT';
    end if;
    return v_existing.result;
  end if;
  if exists(select 1 from public.finance_entries where request_id = p_request) then
    raise exception 'REQUEST_CONFLICT';
  end if;
  if not public.finance_writes_ready() then
    raise exception 'FINANCE_REVIEW_REQUIRED';
  end if;

  perform 1 from public.gym_clients where id = p_client for share;
  if not found then raise exception 'NOT_FOUND'; end if;

  -- Primero se bloquea y comprueba todo el inventario. Si algo falla, la
  -- transacción completa se revierte y no queda dinero registrado.
  for v_row in
    select item from jsonb_array_elements(v_items) as items(item)
  loop
    v_product := (v_row.item->>'product')::uuid;
    v_qty := (v_row.item->>'qty')::integer;
    v_unit_price := (v_row.item->>'unit_price')::numeric;
    select name, status, price
      into v_product_name, v_product_status, v_product_price
    from public.products
    where id = v_product
    for update;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
    if v_product_status <> 'activo' then raise exception 'PRODUCT_INACTIVE'; end if;
    if v_product_price <= 0 then raise exception 'INVALID_PRODUCT_PRICE'; end if;
    if v_product_price <> v_unit_price then raise exception 'PRICE_CHANGED'; end if;
    v_stock := public.product_stock_of(v_product);
    if v_stock < v_qty then raise exception 'SIN_STOCK'; end if;
    v_line_total := round(v_qty * v_product_price, 2);
    v_products_total := v_products_total + v_line_total;
    if v_products_total > 99999999 then raise exception 'INVALID_PAYMENT'; end if;
  end loop;

  v_total := p_service_amount + v_products_total;
  if v_total <= 0 or v_total > 99999999 then raise exception 'INVALID_PAYMENT'; end if;

  if p_service_amount > 0 then
    v_child_request := gen_random_uuid();
    v_service_tx := public.finance_record_movement(
      v_child_request,
      'service_income',
      p_client,
      p_service_amount,
      'NIO',
      trim(p_method),
      trim(p_account),
      v_concept,
      p_fx,
      null
    );
    v_transaction_ids := v_transaction_ids || jsonb_build_array(v_service_tx);
    v_receipts := v_receipts || jsonb_build_array(jsonb_build_object(
      'id', v_service_tx,
      'label', v_concept,
      'amount', p_service_amount
    ));
  end if;

  for v_row in
    select item from jsonb_array_elements(v_items) as items(item)
  loop
    v_product := (v_row.item->>'product')::uuid;
    v_qty := (v_row.item->>'qty')::integer;
    v_unit_price := (v_row.item->>'unit_price')::numeric;
    select name into v_product_name from public.products where id = v_product;
    v_line_total := round(v_qty * v_unit_price, 2);
    v_child_request := gen_random_uuid();
    v_tx := public.finance_record_movement(
      v_child_request,
      'service_income',
      p_client,
      v_line_total,
      'NIO',
      trim(p_method),
      trim(p_account),
      'Venta: ' || v_product_name || ' x' || v_qty,
      p_fx,
      null
    );
    insert into public.stock_movements(
      product_id, kind, qty, unit_price, client_id, transaction_id, request_id, created_by
    ) values (
      v_product, 'venta', -v_qty, v_unit_price, p_client, v_tx, v_child_request, v_actor
    );
    v_transaction_ids := v_transaction_ids || jsonb_build_array(v_tx);
    v_receipts := v_receipts || jsonb_build_array(jsonb_build_object(
      'id', v_tx,
      'label', 'Venta: ' || v_product_name || ' x' || v_qty,
      'amount', v_line_total
    ));
  end loop;

  v_result := jsonb_build_object(
    'id', coalesce(v_service_tx, (v_transaction_ids->>0)::uuid),
    'transactionIds', v_transaction_ids,
    'receipts', v_receipts,
    'serviceTransactionId', v_service_tx,
    'serviceAmount', p_service_amount,
    'productsTotal', v_products_total,
    'total', v_total,
    'currency', 'NIO'
  );

  insert into public.finance_checkout_groups(request_id, client_id, payload, result, created_by)
  values (p_request, p_client, v_payload, v_result, v_actor);

  return v_result;
end;
$$;

revoke all on function public.product_sale_catalog() from public, anon, authenticated;
revoke all on function public.finance_record_checkout(uuid, uuid, numeric, text, text, text, text, numeric, jsonb)
  from public, anon, authenticated;
grant execute on function public.product_sale_catalog() to authenticated;
grant execute on function public.finance_record_checkout(uuid, uuid, numeric, text, text, text, text, numeric, jsonb)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00060_catalogo_venta_con_imagen.sql
-- ═══════════════════════════════════════════════════════════

-- El catálogo de venta en recepción también devuelve la imagen del producto.
--
-- Motivo: recepción debe reconocer el producto por su foto al venderlo desde
-- la ficha, igual que en «Productos y stock». Sigue sin exponer costo ni
-- ganancia y solo lo ejecuta el personal de caja/administración con MFA
-- (crm_is_staff). La imagen ya se guarda reducida (≤ 600 KB) en products.
--
-- Reversión: recrear product_sale_catalog() sin la clave image_data, como en
-- la migración 00059. No se tocan tablas ni datos.

begin;
set local lock_timeout = '5s';

create or replace function public.product_sale_catalog()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  return jsonb_build_object('products', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'category', p.category,
      'subcategory', p.subcategory,
      'attributes', p.attributes,
      'price', p.price,
      'stock', s.stock,
      'low_stock', s.stock <= p.stock_min,
      'image_data', p.image_data
    ) order by p.category, p.name)
    from public.products p
    cross join lateral (
      select coalesce(sum(qty), 0)::integer as stock
      from public.stock_movements sm
      where sm.product_id = p.id
    ) s
    where p.status = 'activo' and p.price > 0 and s.stock > 0
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.product_sale_catalog() from public, anon, authenticated;
grant execute on function public.product_sale_catalog() to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00061_estado_reservas_personal.sql
-- ═══════════════════════════════════════════════════════════

-- 00061 · Estado administrativo de reservas (OP-01)
--
-- Problema: la pantalla de Operación marcaba asistencia, inasistencia y
-- cancelación solo en React. Al recargar, la reserva volvía a su estado real.
--
-- Solución acotada:
--   * `staff_set_booking_status()` es la única vía de escritura administrativa.
--   * Solo administración o caja con MFA (`crm_is_staff()` = rol + AAL2).
--   * `cancelled` es terminal desde esta vía; un cliente puede volver a
--     reservar con `book_session()` si la sesión sigue disponible.
--   * Marcar de nuevo el mismo estado es idempotente: no reescribe la fila.
--   * `p_expected_status` evita pisar un cambio hecho por otra persona.
--   * Al pasar de `no_show` a `attended` se vuelve a comprobar el cupo,
--     bloqueando primero la sesión igual que `book_session()`.
--   * Se retiran de `bookings` los grants/políticas de escritura directa
--     heredadas; las escrituras quedan en las RPC existentes y esta RPC.
--
-- Reversión segura: eliminar solo la función nueva. No hace falta revertir
-- estados ni datos:
--   drop function if exists public.staff_set_booking_status(uuid, text, text);
-- Volver a abrir escritura directa requeriría una migración deliberada; no
-- forma parte de la reversión recomendada.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.bookings') is null
     or to_regclass('public.sessions') is null
     or to_regprocedure('public.crm_is_staff()') is null then
    raise exception 'BOOKING_STATUS_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.staff_set_booking_status(
  p_booking_id uuid,
  p_status text,
  p_expected_status text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_session_id text;
  v_session public.sessions;
  v_booking public.bookings;
  v_previous_status public.booking_status;
  v_occupied integer;
begin
  if not public.crm_is_staff() then
    raise exception 'AUTH';
  end if;

  if p_booking_id is null
     or p_status is null
     or p_status not in ('attended', 'no_show', 'cancelled')
     or (
       p_expected_status is not null
       and p_expected_status not in ('confirmed', 'cancelled', 'attended', 'no_show')
     ) then
    raise exception 'INVALID_STATUS';
  end if;

  select session_id into v_session_id
    from public.bookings
   where id = p_booking_id;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  -- Mismo orden de bloqueo que book_session(): primero la sesión y después
  -- la reserva. Así el control de cupo no compite a ciegas con una reserva.
  select * into v_session
    from public.sessions
   where id = v_session_id
   for update;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  select * into v_booking
    from public.bookings
   where id = p_booking_id
   for update;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  v_previous_status := v_booking.status;

  -- Reintento seguro: una respuesta perdida o un doble clic no reescribe
  -- `cancelled_at` ni convierte el segundo intento en un error falso.
  if v_previous_status::text = p_status then
    return jsonb_build_object(
      'id', v_booking.id,
      'session_id', v_booking.session_id,
      'status', v_booking.status,
      'previous_status', v_previous_status,
      'changed', false,
      'cancelled_at', v_booking.cancelled_at
    );
  end if;

  if p_expected_status is not null
     and v_previous_status::text <> p_expected_status then
    raise exception 'STALE_STATUS';
  end if;

  if v_previous_status = 'cancelled' then
    raise exception 'INVALID_TRANSITION';
  end if;

  if v_session.status <> 'scheduled' and p_status <> 'cancelled' then
    raise exception 'SESSION_CANCELLED';
  end if;

  -- Una sesión que ya terminó no se "cancela" hacia atrás: corresponde
  -- corregir la reserva como asistida o ausente.
  if p_status = 'cancelled' and v_session.ends_at <= now() then
    raise exception 'SESSION_ENDED';
  end if;

  -- `attended` ocupa cupo igual que `confirmed`. Solo hay que comprobarlo
  -- cuando se vuelve desde un estado que no ocupaba (`no_show`).
  if p_status = 'attended'
     and v_previous_status not in ('confirmed', 'attended') then
    select count(*)::integer into v_occupied
      from public.bookings
     where session_id = v_session.id
       and id <> v_booking.id
       and status in ('confirmed', 'attended');

    if v_occupied >= v_session.capacity then
      raise exception 'FULL';
    end if;
  end if;

  update public.bookings
     set status = p_status::public.booking_status,
         cancelled_at = case
           when p_status = 'cancelled' then now()
           else null
         end
   where id = v_booking.id
  returning * into v_booking;

  return jsonb_build_object(
    'id', v_booking.id,
    'session_id', v_booking.session_id,
    'status', v_booking.status,
    'previous_status', v_previous_status,
    'changed', true,
    'cancelled_at', v_booking.cancelled_at
  );
end;
$$;

revoke all on function public.staff_set_booking_status(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.staff_set_booking_status(uuid, text, text)
  to authenticated;

-- La lectura sigue por la política vigente; ninguna escritura del cliente va
-- directo a la tabla. Las RPC SECURITY DEFINER no necesitan estos grants.
alter table public.bookings enable row level security;
drop policy if exists "reservas: cancelar la propia" on public.bookings;
drop policy if exists "reservas: el staff gestiona" on public.bookings;
revoke all on table public.bookings from anon;
revoke insert, update, delete, truncate, references, trigger
  on table public.bookings from authenticated;
grant select on table public.bookings to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00062_mensajes_leidos_personal.sql
-- ═══════════════════════════════════════════════════════════

-- 00062 · Mensajes leídos/no leídos del personal (OP-02)
--
-- Problema: Operación cambiaba `readMessages` solo en React. Además, en
-- producción `public.messages` conserva la política pública de INSERT, pero
-- no tiene una política de SELECT para el personal ni una vía acotada para
-- actualizar `is_read`.
--
-- Solución acotada:
--   * `staff_set_message_read()` es la única vía para cambiar `is_read`.
--   * Solo administración o caja con MFA (`crm_is_staff()` = rol + AAL2).
--   * Marcar el estado que ya tiene el mensaje es idempotente.
--   * `p_expected_is_read` evita pisar un cambio hecho por otra persona.
--   * Se restablece la lectura para administración/caja y el formulario
--     público sigue pudiendo insertar, siempre como mensaje no leído.
--   * No se abren UPDATE ni DELETE directos sobre la tabla.
--
-- Reversión segura: eliminar solo la función nueva. No hace falta tocar los
-- mensajes ni revertir estados:
--   drop function if exists public.staff_set_message_read(uuid, boolean, boolean);
-- Volver a abrir escritura directa requeriría una migración deliberada; no
-- forma parte de la reversión recomendada.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.messages') is null
     or to_regprocedure('public.crm_is_staff()') is null
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'messages'
          and column_name = 'is_read'
          and data_type = 'boolean'
     ) then
    raise exception 'MESSAGE_READ_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.staff_set_message_read(
  p_message_id uuid,
  p_is_read boolean,
  p_expected_is_read boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_message public.messages;
  v_previous_is_read boolean;
begin
  if not public.crm_is_staff() then
    raise exception 'AUTH';
  end if;

  if p_message_id is null or p_is_read is null then
    raise exception 'INVALID_READ_STATE';
  end if;

  select * into v_message
    from public.messages
   where id = p_message_id
   for update;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  v_previous_is_read := v_message.is_read;

  -- Reintento seguro: si el mensaje ya quedó en el estado pedido, la
  -- respuesta es éxito sin volver a escribir la fila.
  if v_previous_is_read = p_is_read then
    return jsonb_build_object(
      'id', v_message.id,
      'is_read', v_message.is_read,
      'previous_is_read', v_previous_is_read,
      'changed', false
    );
  end if;

  if p_expected_is_read is not null
     and v_previous_is_read is distinct from p_expected_is_read then
    raise exception 'STALE_READ_STATE';
  end if;

  update public.messages
     set is_read = p_is_read
   where id = v_message.id
  returning * into v_message;

  return jsonb_build_object(
    'id', v_message.id,
    'is_read', v_message.is_read,
    'previous_is_read', v_previous_is_read,
    'changed', true
  );
end;
$$;

revoke all on function public.staff_set_message_read(uuid, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.staff_set_message_read(uuid, boolean, boolean)
  to authenticated;

alter table public.messages enable row level security;

-- El formulario público sigue insertando, pero nunca puede nacer como
-- mensaje ya leído. La validación completa del contenido sigue en la API.
drop policy if exists "consultas: cualquiera puede escribir" on public.messages;
drop policy if exists messages_insert_public_v1 on public.messages;
create policy messages_insert_public_v1
  on public.messages
  for insert
  to anon, authenticated
  with check (is_read = false);

-- Operación vuelve a leer las consultas, solo administración/caja con MFA.
drop policy if exists "consultas: el staff lee" on public.messages;
drop policy if exists messages_read_staff_v1 on public.messages;
create policy messages_read_staff_v1
  on public.messages
  for select
  to authenticated
  using (public.crm_is_staff());

-- Sin actualización ni borrado directos: `is_read` cambia solo por la RPC.
drop policy if exists "consultas: el staff actualiza" on public.messages;

revoke all on table public.messages from anon, authenticated;
grant insert on table public.messages to anon, authenticated;
grant select on table public.messages to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00063_mensajes_leidos_personal_alineacion.sql
-- ═══════════════════════════════════════════════════════════

-- 00063 · Alineación de mensajes leídos del personal (OP-02)
--
-- La migración 00062 ya dejó en producción las políticas y permisos
-- correctos de `public.messages`. Esta alineación acotada deja también el
-- cuerpo de `staff_set_message_read()` exactamente igual al contrato probado
-- junto con la API: error `AUTH`, una sola lectura con bloqueo de fila y
-- `lock_timeout` de 5 segundos.
--
-- No cambia mensajes, estados de lectura ni las políticas v1 ya creadas.
-- Solo elimina, si todavía existieran en una base reconstruida, las dos
-- políticas históricas de staff anteriores a la 00062.

begin;
set local lock_timeout = '5s';

create or replace function public.staff_set_message_read(
  p_message_id uuid,
  p_is_read boolean,
  p_expected_is_read boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_message public.messages;
  v_previous_is_read boolean;
begin
  if not public.crm_is_staff() then
    raise exception 'AUTH';
  end if;

  if p_message_id is null or p_is_read is null then
    raise exception 'INVALID_READ_STATE';
  end if;

  select * into v_message
    from public.messages
   where id = p_message_id
   for update;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  v_previous_is_read := v_message.is_read;

  -- Reintento seguro: si el mensaje ya quedó en el estado pedido, la
  -- respuesta es éxito sin volver a escribir la fila.
  if v_previous_is_read = p_is_read then
    return jsonb_build_object(
      'id', v_message.id,
      'is_read', v_message.is_read,
      'previous_is_read', v_previous_is_read,
      'changed', false
    );
  end if;

  if p_expected_is_read is not null
     and v_previous_is_read is distinct from p_expected_is_read then
    raise exception 'STALE_READ_STATE';
  end if;

  update public.messages
     set is_read = p_is_read
   where id = v_message.id
  returning * into v_message;

  return jsonb_build_object(
    'id', v_message.id,
    'is_read', v_message.is_read,
    'previous_is_read', v_previous_is_read,
    'changed', true
  );
end;
$$;

revoke all on function public.staff_set_message_read(uuid, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.staff_set_message_read(uuid, boolean, boolean)
  to authenticated;

drop policy if exists "consultas: el staff lee" on public.messages;
drop policy if exists "consultas: el staff actualiza" on public.messages;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00064_disciplinas_activas.sql
-- ═══════════════════════════════════════════════════════════

-- 00064 · Activación/desactivación persistente de disciplinas (OP-03)
--
-- Problema: Operación cambiaba `classActive` solo en React. Además, Horarios
-- y `book_session()` ignoraban `classes.is_active`, así que guardar el
-- interruptor no bastaba para ocultar la oferta ni frenar reservas nuevas.
--
-- Regla aprobada:
--   * Desactivar solo cambia `classes.is_active` a false. La aplicación deja
--     de ofrecer la disciplina y sus sesiones futuras, y `book_session()`
--     rechaza reservas nuevas con `CLASS_INACTIVE`.
--   * No se cancelan sesiones ni reservas ya hechas. Quedan intactas para su
--     dueño y para el personal.
--   * Reactivar vuelve a permitir reservas nuevas en sesiones programadas.
--   * Solo administración con MFA puede cambiar el estado. Caja no escribe
--     catálogos en la Fase B.
--
-- Reversión segura: eliminar `admin_set_class_active()` y restaurar la
-- versión histórica de `book_session()` de 00001_schema.sql. No hace falta
-- tocar disciplinas, sesiones ni reservas. Volver a abrir escritura directa
-- requeriría una migración deliberada; no forma parte de la reversión.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.classes') is null
     or to_regclass('public.sessions') is null
     or to_regclass('public.bookings') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.book_session(text)') is null
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'classes'
          and column_name = 'id'
          and data_type = 'text'
     )
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'classes'
          and column_name = 'is_active'
          and data_type = 'boolean'
     )
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'sessions'
          and column_name = 'class_id'
          and data_type = 'text'
     ) then
    raise exception 'CLASS_ACTIVE_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.admin_set_class_active(
  p_class_id text,
  p_is_active boolean,
  p_expected_is_active boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_class public.classes;
  v_previous_is_active boolean;
begin
  if not public.is_admin() then
    raise exception 'AUTH';
  end if;

  if p_class_id is null
     or p_is_active is null
     or char_length(p_class_id) < 1
     or char_length(p_class_id) > 160
     or p_class_id ~ '\s' then
    raise exception 'INVALID_ACTIVE_STATE';
  end if;

  select * into v_class
    from public.classes
   where id = p_class_id
   for update;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  v_previous_is_active := v_class.is_active;

  -- Reintento seguro: si la disciplina ya quedó en el estado pedido, se
  -- confirma sin escribir de nuevo.
  if v_previous_is_active = p_is_active then
    return jsonb_build_object(
      'id', v_class.id,
      'is_active', v_class.is_active,
      'previous_is_active', v_previous_is_active,
      'changed', false
    );
  end if;

  if p_expected_is_active is not null
     and v_previous_is_active is distinct from p_expected_is_active then
    raise exception 'STALE_ACTIVE_STATE';
  end if;

  update public.classes
     set is_active = p_is_active
   where id = v_class.id
  returning * into v_class;

  return jsonb_build_object(
    'id', v_class.id,
    'is_active', v_class.is_active,
    'previous_is_active', v_previous_is_active,
    'changed', true
  );
end;
$$;

revoke all on function public.admin_set_class_active(text, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_set_class_active(text, boolean, boolean)
  to authenticated;

-- Reservar: misma lógica histórica, con una única guarda nueva. Primero se
-- bloquea la sesión, igual que siempre; después se toma la disciplina FOR
-- SHARE para que una desactivación concurrente no pueda colarse a mitad de
-- una reserva. La guarda corre antes de crear o revivir una reserva, pero no
-- cambia las reservas que ya existen.
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
  v_existing boolean := false;
  v_booked   integer;
  v_active   integer;
  v_max      integer := 3;
  v_class_is_active boolean;
begin
  if v_user_id is null then
    raise exception 'AUTH: tenés que iniciar sesión';
  end if;

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

  select is_active into v_class_is_active
    from public.classes
   where id = v_session.class_id
   for share;

  if not found or v_class_is_active is distinct from true then
    raise exception 'CLASS_INACTIVE: esta disciplina está desactivada';
  end if;

  select * into v_booking
  from public.bookings
  where session_id = p_session_id and user_id = v_user_id;

  if found then
    if v_booking.status in ('confirmed', 'attended') then
      raise exception 'ALREADY_BOOKED: ya tenés una reserva en esa clase';
    end if;
    v_existing := true;
  end if;

  select count(*) into v_booked
  from public.bookings
  where session_id = p_session_id and status in ('confirmed', 'attended');

  if v_booked >= v_session.capacity then
    raise exception 'FULL: no quedan lugares';
  end if;

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

revoke all on function public.book_session(text)
  from public, anon, authenticated;
grant execute on function public.book_session(text) to authenticated;

alter table public.classes enable row level security;

-- La lectura del catálogo se conserva: la aplicación filtra la oferta activa
-- y las reservas ya hechas deben seguir pudiendo resolver su disciplina.
-- La escritura directa queda cerrada; is_active cambia solo por la RPC.
drop policy if exists "clases: lectura pública" on public.classes;
drop policy if exists classes_read_public_v1 on public.classes;
create policy classes_read_public_v1
  on public.classes
  for select
  to anon, authenticated
  using (true);

drop policy if exists "clases: el staff escribe" on public.classes;
drop policy if exists "clases: el admin escribe" on public.classes;

revoke all on table public.classes from anon, authenticated;
grant select on table public.classes to anon, authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00065_generar_sesiones_futuras.sql
-- ═══════════════════════════════════════════════════════════

-- 00065 · Generar sesiones futuras desde Operación (OP-04)
--
-- Problema: `generate_week_sessions()` ya crea la grilla de una semana sin
-- duplicar y respeta `classes.is_active`, pero después del endurecimiento de
-- accesos quedó reservada a mantenimiento SQL. Operación no tenía ninguna
-- acción para extender el calendario y las sesiones futuras terminaban el
-- 5 de noviembre de 2026.
--
-- Regla de esta tanda:
--   * Solo administración con MFA puede generar sesiones desde la app.
--   * Se reutiliza la plantilla existente; no se crea una segunda grilla.
--   * Se generan semanas completas desde el próximo lunes, sin crear
--     sesiones pasadas ni duplicar las que ya existen.
--   * Un candado por transacción ordena dos generaciones simultáneas.
--   * No se cancelan ni modifican sesiones o reservas ya existentes.
--
-- Reversión segura: eliminar `admin_generate_future_sessions()`. Las
-- sesiones ya generadas se conservan y `generate_week_sessions()` sigue
-- disponible solo para mantenimiento autorizado fuera de la API.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.classes') is null
     or to_regclass('public.sessions') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.generate_week_sessions(date)') is null
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'classes'
          and column_name = 'is_active'
          and data_type = 'boolean'
     )
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'sessions'
          and column_name = 'class_id'
          and data_type = 'text'
     )
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'sessions'
          and column_name = 'starts_at'
          and data_type = 'timestamp with time zone'
     )
     or not exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name = 'sessions'
          and column_name = 'status'
     ) then
    raise exception 'FUTURE_SESSIONS_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.admin_generate_future_sessions(
  p_weeks integer default 4
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_today date := (now() at time zone 'America/Managua')::date;
  v_first_monday date;
  v_last_sunday date;
  v_created integer := 0;
  v_week_created integer;
  v_scheduled integer;
  v_offset integer;
begin
  if not public.is_admin() then
    raise exception 'AUTH';
  end if;

  if p_weeks is null or p_weeks < 1 or p_weeks > 8 then
    raise exception 'INVALID_FUTURE_WEEKS';
  end if;

  -- Dos administraciones pueden tocar el botón a la vez. La segunda espera
  -- a la primera y luego encuentra las sesiones ya creadas, sin duplicar.
  perform pg_advisory_xact_lock(
    hashtext('strong_gym_admin_generate_future_sessions')
  );

  -- Solo semanas completas futuras: la semana actual ya debió quedar
  -- generada en el ciclo anterior y así nunca se inventan sesiones pasadas.
  v_first_monday := date_trunc('week', v_today::timestamp)::date + 7;
  v_last_sunday := v_first_monday + (p_weeks * 7 - 1);

  for v_offset in 0..p_weeks - 1 loop
    v_week_created := public.generate_week_sessions(
      v_first_monday + (v_offset * 7)
    );
    v_created := v_created + coalesce(v_week_created, 0);
  end loop;

  select count(*)::int into v_scheduled
    from public.sessions
   where status = 'scheduled'
     and starts_at >= (
       v_first_monday::timestamp at time zone 'America/Managua'
     )
     and starts_at < (
       (v_last_sunday + 1)::timestamp at time zone 'America/Managua'
     );

  return jsonb_build_object(
    'weeks', p_weeks,
    'first_monday', v_first_monday,
    'last_sunday', v_last_sunday,
    'created_count', v_created,
    'scheduled_count', v_scheduled
  );
end;
$$;

revoke all on function public.admin_generate_future_sessions(integer)
  from public, anon, authenticated;
grant execute on function public.admin_generate_future_sessions(integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00066_coaches_specialties_generador.sql
-- ═══════════════════════════════════════════════════════════

-- 00066 · Compatibilidad de coaches para generar sesiones (corrección OP-04)
--
-- La primera pulsación real del botón de OP-04 falló en producción con
-- 42703: `generate_week_sessions()` busca `coaches.specialties`, pero la
-- tabla productiva divergió del esquema inicial y solo tiene el texto
-- visible `specialty`. Las migraciones 00050/00051 adaptaron las lecturas
-- con `coaches_public`, pero el generador histórico siguió dependiendo de
-- la columna estructurada original.
--
-- Corrección aditiva:
--   * Se restaura `specialties text[]` con el mismo tipo y valor inicial
--     del esquema 00001.
--   * No se infieren slugs desde textos como «Boxeo y acondicionamiento»:
--     las filas existentes quedan con '{}', igual que las sesiones ya
--     creadas conservaron `coach_id` nulo.
--   * No se modifican entrenadores, disciplinas, sesiones ni reservas.
--   * Esta migración no genera sesiones; solo deja operativo el botón.
--
-- Reversión: quitar la columna volvería a romper el generador, así que solo
-- debe hacerse después de reemplazar esa dependencia:
--   alter table public.coaches drop column if exists specialties;

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.coaches') is null
     or to_regprocedure('public.generate_week_sessions(date)') is null then
    raise exception 'COACHES_SPECIALTIES_PREREQUISITE_MISSING';
  end if;

  if exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name = 'coaches'
       and column_name = 'specialties'
       and not (data_type = 'ARRAY' and udt_name = '_text')
  ) then
    raise exception 'COACHES_SPECIALTIES_TYPE_MISMATCH';
  end if;
end $$;

alter table public.coaches
  add column if not exists specialties text[] not null default '{}'::text[];

comment on column public.coaches.specialties is
  'Slugs estructurados de disciplinas para el generador de sesiones. '
  'No confundir con specialty, que es el texto visible del entrenador.';

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00067_vigencias_planes.sql
-- ═══════════════════════════════════════════════════════════

-- CLI-01: vigencias reales de planes.
--
-- Decisiones aplicadas:
-- - Un cobro estructurado (con plan explícito) crea el periodo en la misma
--   operación que registra el dinero. Un cobro genérico, un abono, un descuento
--   o un pago parcial nunca crean vigencia.
-- - Duraciones contando el día del pago como día 1: Día 1, Semana 7,
--   Quincena 15, Mes y Boxeo 30.
-- - Renovar o cambiar antes de vencer encadena desde el día siguiente al
--   vencimiento vigente o futuro. Si ya venció, empieza el día del pago.
-- - Gimnasio y Boxeo son accesos separados y pueden coexistir.
-- - Ningún cobro anterior inventa vigencia: si la referencia ya existía antes
--   de esta llamada, no se crea segmento.
-- - Recepción no bloquea por vencimiento ni deuda. El único bloqueo nuevo es
--   reservar Boxeo sin vigencia para la fecha local de la clase.
--
-- Reutiliza `public.payment_plans` (vacía en producción) como tabla de
-- segmentos. Si ya existe con la forma legada, se adapta sin borrar filas; si
-- hay filas que no se pueden mapear con seguridad, la migración falla.
--
-- Reversión: retirar primero el uso en la aplicación (campo `planId`, RPC
-- `*_plan`), después se pueden eliminar esas RPC y `payment_plans` sin tocar
-- transactions, finance_entries ni gym_clients. `frozen_since` puede quedar
-- sin uso. No se borra ningún dato histórico.

begin;
set local lock_timeout = '5s';

-- 1. Ficha: fecha de congelamiento para desplazar vigencias al reactivar.
alter table public.gym_clients add column if not exists frozen_since date;

-- 2. Tabla de segmentos de vigencia. Cada fila es una compra concreta.
create table if not exists public.payment_plans (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.gym_clients(id) on delete restrict,
  plan_id text references public.plans(id) on delete restrict,
  access text,
  started_on date,
  expires_on date,
  price_paid numeric(12, 2),
  currency text,
  request_id uuid,
  transaction_id uuid references public.transactions(id) on delete set null,
  source text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Adaptación de una tabla legada. Solo agrega columnas y afloja obligatorios
-- que la forma nueva ya no usa; no borra ni renombra nada.
alter table public.payment_plans add column if not exists client_id uuid;
alter table public.payment_plans add column if not exists plan_id text;
alter table public.payment_plans add column if not exists access text;
alter table public.payment_plans add column if not exists started_on date;
alter table public.payment_plans add column if not exists expires_on date;
alter table public.payment_plans add column if not exists price_paid numeric(12, 2);
alter table public.payment_plans add column if not exists currency text;
alter table public.payment_plans add column if not exists request_id uuid;
alter table public.payment_plans add column if not exists transaction_id uuid;
alter table public.payment_plans add column if not exists source text;
alter table public.payment_plans add column if not exists created_by uuid;
alter table public.payment_plans add column if not exists created_at timestamptz default now();

do $$
declare v_type text; v_col text;
begin
  -- Moneda y plan como texto: el esquema canónico guarda texto y así la
  -- tabla legada puede reutilizarse aunque use enum o uuid.
  select data_type into v_type from information_schema.columns
   where table_schema = 'public' and table_name = 'payment_plans' and column_name = 'currency';
  if v_type is not null and v_type not in ('text', 'character varying') then
    execute 'alter table public.payment_plans alter column currency type text using currency::text';
  end if;
  select data_type into v_type from information_schema.columns
   where table_schema = 'public' and table_name = 'payment_plans' and column_name = 'plan_id';
  if v_type is not null and v_type not in ('text', 'character varying') then
    execute 'alter table public.payment_plans alter column plan_id type text using plan_id::text';
  end if;

  -- Columnas legadas que la forma nueva no llena: se afloja el NOT NULL para
  -- no romper filas históricas ni bloquear compras nuevas.
  for v_col in
    select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'payment_plans'
       and is_nullable = 'NO'
       and column_name in ('member_id', 'started_at', 'expires_at', 'is_active', 'notes')
  loop
    execute format('alter table public.payment_plans alter column %I drop not null', v_col);
  end loop;
end $$;

-- Relleno de la forma legada hacia la nueva, solo cuando esas columnas existen.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'payment_plans' and column_name = 'started_at') then
    execute 'update public.payment_plans set started_on = started_at::date where started_on is null and started_at is not null';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'payment_plans' and column_name = 'expires_at') then
    execute 'update public.payment_plans set expires_on = expires_at::date where expires_on is null and expires_at is not null';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'payment_plans' and column_name = 'member_id') then
    execute 'update public.payment_plans p set client_id = c.id
               from public.gym_clients c
              where p.client_id is null and p.member_id is not null and c.profile_id = p.member_id';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'payment_plans' and column_name = 'is_active') then
    execute 'update public.payment_plans set is_active = (expires_on >= (now() at time zone ''America/Managua'')::date)
              where expires_on is not null and is_active is distinct from (expires_on >= (now() at time zone ''America/Managua'')::date)';
  end if;
end $$;

update public.payment_plans p
   set access = case when pl.slug = 'boxeo' then 'boxing' else 'gym' end
  from public.plans pl
 where p.access is null and p.plan_id is not null and pl.id = p.plan_id::text;

update public.payment_plans set currency = 'NIO' where currency is null;
update public.payment_plans set source = 'legacy' where source is null;
update public.payment_plans set created_at = now() where created_at is null;
update public.payment_plans set request_id = gen_random_uuid() where request_id is null;

-- Si alguna fila legada no se puede mapear con seguridad, se detiene todo.
do $$
declare v_bad integer;
begin
  select count(*) into v_bad from public.payment_plans
   where client_id is null or plan_id is null or access is null
      or started_on is null or expires_on is null or request_id is null;
  if v_bad > 0 then
    raise exception 'PAYMENT_PLANS_LEGACY_UNMAPPABLE: % fila(s) sin ficha, plan, acceso o fechas', v_bad;
  end if;
end $$;

alter table public.payment_plans alter column client_id set not null;
alter table public.payment_plans alter column plan_id set not null;
alter table public.payment_plans alter column access set not null;
alter table public.payment_plans alter column started_on set not null;
alter table public.payment_plans alter column expires_on set not null;
alter table public.payment_plans alter column currency set not null;
alter table public.payment_plans alter column request_id set not null;
alter table public.payment_plans alter column source set not null;
alter table public.payment_plans alter column created_at set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'payment_plans_access_chk') then
    alter table public.payment_plans add constraint payment_plans_access_chk
      check (access in ('gym', 'boxing'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_plans_source_chk') then
    alter table public.payment_plans add constraint payment_plans_source_chk
      check (source in ('movement', 'checkout', 'crm', 'legacy'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_plans_dates_chk') then
    alter table public.payment_plans add constraint payment_plans_dates_chk
      check (expires_on >= started_on);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_plans_price_chk') then
    alter table public.payment_plans add constraint payment_plans_price_chk
      check (price_paid is null or price_paid >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_plans_client_fk') then
    alter table public.payment_plans add constraint payment_plans_client_fk
      foreign key (client_id) references public.gym_clients(id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_plans_transaction_fk') then
    alter table public.payment_plans add constraint payment_plans_transaction_fk
      foreign key (transaction_id) references public.transactions(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_plans_created_by_fk') then
    alter table public.payment_plans add constraint payment_plans_created_by_fk
      foreign key (created_by) references public.profiles(id) on delete set null;
  end if;
end $$;

create unique index if not exists payment_plans_request_uidx on public.payment_plans(request_id);
create unique index if not exists payment_plans_transaction_uidx
  on public.payment_plans(transaction_id) where transaction_id is not null;
create index if not exists payment_plans_client_idx
  on public.payment_plans(client_id, access, expires_on desc);

-- La tabla legada tenía una política de escritura para "staff" y permisos
-- amplios. Se cierran ambos: el acceso pasa solo por las RPC de abajo.
alter table public.payment_plans enable row level security;
drop policy if exists "Staff can write payment_plans" on public.payment_plans;
revoke all on public.payment_plans from public, anon, authenticated;

-- 3. Fecha local única.
create or replace function public.plan_local_today()
returns date language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone 'America/Managua')::date;
$$;
revoke all on function public.plan_local_today() from public, anon, authenticated;

-- 4. Términos estrictos por plan. Un plan sin duración definida devuelve NULL
--    y no crea vigencia; solo falla si el plan no existe.
create or replace function public.plan_validity_terms(p_plan text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_slug text; v_period text; v_days integer; v_access text; v_currency text; v_amount numeric;
begin
  select slug, period into v_slug, v_period from public.plans where id = p_plan;
  if not found then raise exception 'PLAN_NOT_FOUND'; end if;
  v_days := case
    when v_slug = 'pase-del-dia' and v_period = 'session' then 1
    when v_slug = 'gimnasio-semanal' and v_period = 'week' then 7
    when v_slug = 'gimnasio-quincenal' and v_period = 'fortnight' then 15
    when v_slug = 'gimnasio-mensual' and v_period = 'month' then 30
    when v_slug = 'boxeo' and v_period = 'month' then 30
  end;
  if v_days is null then return null; end if;
  v_access := case when v_slug = 'boxeo' then 'boxing' else 'gym' end;
  select case when v_slug = 'boxeo' then price else price_nio end into v_amount
    from public.plans where id = p_plan;
  v_currency := case when v_slug = 'boxeo' then 'USD' else 'NIO' end;
  return jsonb_build_object(
    'plan_id', p_plan,
    'slug', v_slug,
    'period', v_period,
    'access', v_access,
    'days', v_days,
    'currency', v_currency,
    'amount', v_amount
  );
end $$;
revoke all on function public.plan_validity_terms(text) from public, anon;
-- Lectura de términos: solo datos del catálogo de planes, sin fichas ni importes cobrados.
grant execute on function public.plan_validity_terms(text) to authenticated;

-- 5. Estado por acceso: vigente, próximo o vencido. Incluye días restantes.
create or replace function public.plan_access_state(p_client uuid, p_access text, p_today date)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_row record;
begin
  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client and access = p_access
     and started_on <= p_today and expires_on >= p_today
   order by expires_on desc
   limit 1;
  if found then
    return jsonb_build_object(
      'state', 'active',
      'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on,
      'expires_on', v_row.expires_on,
      'days_left', v_row.expires_on - p_today + 1
    );
  end if;
  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client and access = p_access and started_on > p_today
   order by started_on asc
   limit 1;
  if found then
    return jsonb_build_object(
      'state', 'upcoming',
      'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on,
      'expires_on', v_row.expires_on,
      'days_left', 0
    );
  end if;
  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client and access = p_access
   order by expires_on desc
   limit 1;
  if found then
    return jsonb_build_object(
      'state', 'expired',
      'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on,
      'expires_on', v_row.expires_on,
      'days_left', 0
    );
  end if;
  return jsonb_build_object('state', 'none', 'plan_id', null, 'starts_on', null, 'expires_on', null, 'days_left', 0);
end $$;
revoke all on function public.plan_access_state(uuid, text, date) from public, anon, authenticated;

create or replace function public.plan_validity_summary(p_client uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_today date := public.plan_local_today();
begin
  return jsonb_build_object(
    'today', v_today,
    'gym', public.plan_access_state(p_client, 'gym', v_today),
    'boxing', public.plan_access_state(p_client, 'boxing', v_today),
    'segments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'plan_id', s.plan_id,
        'access', s.access,
        'started_on', s.started_on,
        'expires_on', s.expires_on,
        'price', s.price_paid,
        'currency', s.currency
      ) order by s.started_on desc, s.expires_on desc)
      from public.payment_plans s where s.client_id = p_client
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.plan_validity_summary(uuid) from public, anon, authenticated;

-- 6. Registro de una compra estructurada. Idempotente por referencia.
create or replace function public.plan_register_segment(
  p_client uuid,
  p_plan text,
  p_amount numeric,
  p_currency text,
  p_request uuid,
  p_transaction uuid,
  p_source text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_terms jsonb;
  v_existing public.payment_plans;
  v_today date;
  v_chain date;
  v_start date;
  v_end date;
  v_id uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_amount is null
     or p_amount <> (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;
  if p_source not in ('movement', 'checkout', 'crm') then raise exception 'INVALID_REQUEST'; end if;

  select * into v_existing from public.payment_plans where request_id = p_request;
  if found then
    if v_existing.client_id is distinct from p_client
       or v_existing.plan_id::text is distinct from p_plan then
      raise exception 'REQUEST_CONFLICT';
    end if;
    return jsonb_build_object(
      'id', v_existing.id,
      'plan_id', v_existing.plan_id,
      'access', v_existing.access,
      'started_on', v_existing.started_on,
      'expires_on', v_existing.expires_on,
      'days', v_existing.expires_on - v_existing.started_on + 1,
      'validity', public.plan_validity_summary(p_client)
    );
  end if;

  -- Bloqueo de la ficha: serializa dos compras simultáneas del mismo cliente.
  perform 1 from public.gym_clients where id = p_client for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_transaction is not null and exists(
    select 1 from public.payment_plans where transaction_id = p_transaction
  ) then
    raise exception 'REQUEST_CONFLICT';
  end if;

  v_today := public.plan_local_today();
  select max(expires_on) into v_chain
    from public.payment_plans
   where client_id = p_client
     and access = (v_terms->>'access')
     and expires_on >= v_today;
  v_start := case when v_chain is null then v_today else v_chain + 1 end;
  v_end := v_start + ((v_terms->>'days')::integer - 1);

  insert into public.payment_plans(
    client_id, plan_id, access, started_on, expires_on, price_paid,
    currency, request_id, transaction_id, source, created_by
  ) values (
    p_client, p_plan, (v_terms->>'access'), v_start, v_end, p_amount,
    p_currency, p_request, p_transaction, p_source, auth.uid()
  ) returning id into v_id;

  return jsonb_build_object(
    'id', v_id,
    'plan_id', p_plan,
    'access', (v_terms->>'access'),
    'started_on', v_start,
    'expires_on', v_end,
    'days', (v_terms->>'days')::integer,
    'validity', public.plan_validity_summary(p_client)
  );
end $$;
revoke all on function public.plan_register_segment(uuid, text, numeric, text, uuid, uuid, text) from public, anon, authenticated;

-- 7. Envoltorios: cobran el dinero con los escritores existentes y crean el
--    periodo en la misma transacción. No reinterpretan cobros genéricos.
create or replace function public.finance_record_movement_plan(
  p_request uuid,
  p_client uuid,
  p_amount numeric,
  p_concept text,
  p_currency text,
  p_method text,
  p_account text,
  p_fx numeric,
  p_plan text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_terms jsonb;
  v_pre boolean;
  v_id uuid;
  v_plan jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_plan is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_amount is distinct from (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;

  select exists(select 1 from public.finance_entries where request_id = p_request) into v_pre;

  v_id := public.finance_record_movement(
    p_request, 'service_income', p_client, p_amount, p_currency,
    p_method, p_account, p_concept, p_fx, null
  );

  if v_pre then
    -- Reintento de un cobro que ya existía: no se inventa vigencia.
    select jsonb_build_object(
      'id', s.id, 'plan_id', s.plan_id, 'access', s.access,
      'started_on', s.started_on, 'expires_on', s.expires_on,
      'days', s.expires_on - s.started_on + 1
    ) into v_plan
    from public.payment_plans s where s.request_id = p_request;
  else
    v_plan := public.plan_register_segment(p_client, p_plan, p_amount, p_currency, p_request, v_id, 'movement');
    v_plan := v_plan - 'validity';
  end if;

  return jsonb_build_object('id', v_id, 'plan', v_plan);
end $$;
revoke all on function public.finance_record_movement_plan(uuid, uuid, numeric, text, text, text, text, numeric, text) from public, anon, authenticated;
grant execute on function public.finance_record_movement_plan(uuid, uuid, numeric, text, text, text, text, numeric, text) to authenticated;

create or replace function public.finance_record_checkout_plan(
  p_request uuid,
  p_client uuid,
  p_service_amount numeric,
  p_service_concept text,
  p_currency text,
  p_method text,
  p_account text,
  p_fx numeric,
  p_items jsonb,
  p_plan text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_terms jsonb;
  v_pre boolean;
  v_result jsonb;
  v_tx uuid;
  v_plan jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_plan is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if (v_terms->>'access') = 'boxing' then raise exception 'PLAN_NOT_COMBINABLE'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_service_amount is distinct from (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;

  select exists(select 1 from public.finance_checkout_groups where request_id = p_request) into v_pre;

  v_result := public.finance_record_checkout(
    p_request, p_client, p_service_amount, p_service_concept,
    p_currency, p_method, p_account, p_fx, p_items
  );

  if v_pre then
    select jsonb_build_object(
      'id', s.id, 'plan_id', s.plan_id, 'access', s.access,
      'started_on', s.started_on, 'expires_on', s.expires_on,
      'days', s.expires_on - s.started_on + 1
    ) into v_plan
    from public.payment_plans s where s.request_id = p_request;
  elsif p_service_amount > 0 then
    v_tx := nullif(v_result->>'serviceTransactionId', '')::uuid;
    v_plan := public.plan_register_segment(
      p_client, p_plan, p_service_amount, p_currency, p_request, v_tx, 'checkout'
    );
    v_plan := v_plan - 'validity';
  end if;

  return v_result || jsonb_build_object('plan', v_plan);
end $$;
revoke all on function public.finance_record_checkout_plan(uuid, uuid, numeric, text, text, text, text, numeric, jsonb, text) from public, anon, authenticated;
grant execute on function public.finance_record_checkout_plan(uuid, uuid, numeric, text, text, text, text, numeric, jsonb, text) to authenticated;

create or replace function public.crm_record_payment_plan(
  p_id uuid,
  p_request uuid,
  p_amount numeric,
  p_currency text,
  p_method text,
  p_account text,
  p_concept text,
  p_fx numeric,
  p_plan text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_terms jsonb;
  v_pre boolean;
  v_id uuid;
  v_plan jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_plan is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_amount is distinct from (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;

  select exists(select 1 from public.transactions where crm_request_id = p_request) into v_pre;

  v_id := public.crm_record_payment(p_id, p_request, p_amount, p_currency, p_method, p_account, p_concept, p_fx);

  if v_pre then
    select jsonb_build_object(
      'id', s.id, 'plan_id', s.plan_id, 'access', s.access,
      'started_on', s.started_on, 'expires_on', s.expires_on,
      'days', s.expires_on - s.started_on + 1
    ) into v_plan
    from public.payment_plans s where s.request_id = p_request;
  else
    v_plan := public.plan_register_segment(p_id, p_plan, p_amount, p_currency, p_request, v_id, 'crm');
    v_plan := v_plan - 'validity';
  end if;

  return jsonb_build_object('id', v_id, 'plan', v_plan);
end $$;
revoke all on function public.crm_record_payment_plan(uuid, uuid, numeric, text, text, text, text, numeric, text) from public, anon, authenticated;
grant execute on function public.crm_record_payment_plan(uuid, uuid, numeric, text, text, text, text, numeric, text) to authenticated;

-- 8. Lectura de vigencia para el personal y para el propio cliente.
create or replace function public.crm_client_validity(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if not exists(select 1 from public.gym_clients where id = p_id) then raise exception 'NOT_FOUND'; end if;
  return public.plan_validity_summary(p_id);
end $$;
revoke all on function public.crm_client_validity(uuid) from public, anon, authenticated;
grant execute on function public.crm_client_validity(uuid) to authenticated;

create or replace function public.crm_my_assigned_plan()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_plan text;
  v_details jsonb;
  v_client uuid;
  v_validity jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select id, plan_id into v_client, v_plan from public.gym_clients where profile_id = auth.uid();
  if not found then
    return jsonb_build_object('linked', false, 'plan', null, 'validity', null);
  end if;
  if v_plan is not null then
    select jsonb_build_object('id', id, 'name_es', name_es, 'name_en', name_en, 'is_active', is_active)
      into v_details from public.plans where id = v_plan;
    if not found then raise exception 'PLAN_NOT_FOUND'; end if;
  end if;
  v_validity := public.plan_validity_summary(v_client);
  return jsonb_build_object('linked', true, 'plan', v_details, 'validity', v_validity);
end $$;
revoke all on function public.crm_my_assigned_plan() from public, anon, authenticated;
grant execute on function public.crm_my_assigned_plan() to authenticated;

-- 9. Opciones de cobro: cada plan informa su vigencia y el importe exacto.
create or replace function public.crm_options()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_layout text; v_methods jsonb; v_accounts jsonb; v_plans jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v_layout := public.crm_finance_layout();
  if v_layout = 'unsupported' then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name_es', p.name_es, 'slug', p.slug, 'period', p.period,
      'price_nio', p.price_nio, 'sort_order', p.sort_order
    ) || jsonb_strip_nulls(jsonb_build_object(
      'access', t->>'access',
      'duration_days', case when t is null then null else (t->>'days')::integer end,
      'validity_currency', t->>'currency',
      'validity_amount', (t->>'amount')
    )) order by p.sort_order), '[]'::jsonb) into v_plans
    from public.plans p
    left join lateral (select public.plan_validity_terms(p.id) as t) x on true
   where p.is_active;
  if v_layout = 'repository' then
    select coalesce(jsonb_agg(to_jsonb(m) order by sort_order), '[]'::jsonb) into v_methods
      from (select id, name_es, accepts_nio, accepts_usd, sort_order from public.payment_methods where is_active) m;
    select coalesce(jsonb_agg(to_jsonb(a) order by name), '[]'::jsonb) into v_accounts
      from (select id, name, currency from public.accounts where is_active) a;
  else
    select coalesce(jsonb_agg(to_jsonb(m) order by display_order), '[]'::jsonb) into v_methods
      from (select id, name as name_es, currency in ('NIO', 'BOTH') as accepts_nio,
        currency in ('USD', 'BOTH') as accepts_usd, display_order from public.payment_methods where is_active) m;
    select coalesce(jsonb_agg(to_jsonb(a) order by display_order), '[]'::jsonb) into v_accounts
      from (select id, name, currency, display_order from public.bank_accounts where is_active) a;
  end if;
  return jsonb_build_object('plans', v_plans, 'methods', v_methods, 'accounts', v_accounts,
    'finance_layout', v_layout, 'payments_enabled', v_layout = 'repository',
    'payment_block_reason', case when v_layout <> 'repository' then
      'Cobros CRM pendientes de compatibilidad con esta Caja. No se guardará ningún cobro desde esta ficha; no lo repitas en otra pantalla sin revisar el historial.' else null end);
end $$;
revoke all on function public.crm_options() from public, anon, authenticated;
grant execute on function public.crm_options() to authenticated;

-- 10. Ficha: detalle con vigencia.
create or replace function public.crm_detail(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_client public.gym_clients; v_layout text; v_balance numeric;
  v_balances jsonb; v_state text; v_collections jsonb; v_payments jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into v_client from public.gym_clients where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_layout := public.crm_finance_layout();
  v_state := case when v_layout = 'unsupported' then 'unsupported'
    when v_client.profile_id is null then 'unlinked' else 'missing' end;
  if v_layout = 'bank_accounts_split' then
    v_balances := public.finance_client_balance(p_id)->'balances';
    if v_balances is not null and v_balances <> 'null'::jsonb then v_state := 'ready'; else v_balances := null; end if;
  elsif v_layout = 'repository' and v_client.profile_id is not null then
    select balance_nio into v_balance from public.member_balances where member_id = v_client.profile_id;
    if found then v_state := 'ready'; end if;
  end if;
  if v_layout in ('repository', 'bank_accounts_split') then
    -- Sólo ingresos: el vínculo explícito de ficha prevalece sobre member_id legado.
    with income as (
      select t.* from public.transactions t
      where (t.client_id = p_id or (t.client_id is null and v_client.profile_id is not null and t.member_id = v_client.profile_id))
        and (case when v_layout = 'repository' then to_jsonb(t)->>'direction' else to_jsonb(t)->>'type' end) = 'income'
    )
    select jsonb_build_object(
      'count_nio', count(*) filter (where status::text = 'completed' and currency::text = 'NIO'),
      'amount_nio', coalesce(sum(amount) filter (where status::text = 'completed' and currency::text = 'NIO'), 0),
      'count_usd', count(*) filter (where status::text = 'completed' and currency::text = 'USD'),
      'amount_usd', coalesce(sum(amount) filter (where status::text = 'completed' and currency::text = 'USD'), 0))
    into v_collections from income;
    select coalesce(jsonb_agg(to_jsonb(t) order by t.occurred_at desc, t.id desc), '[]'::jsonb)
    into v_payments from (
      select id, occurred_at, concept, amount, currency, status from public.transactions t
      where (t.client_id = p_id or (t.client_id is null and v_client.profile_id is not null and t.member_id = v_client.profile_id))
        and (case when v_layout = 'repository' then to_jsonb(t)->>'direction' else to_jsonb(t)->>'type' end) = 'income'
      order by occurred_at desc, id desc limit 40
    ) t;
  end if;
  return jsonb_build_object('client', to_jsonb(v_client), 'card', public.crm_get_card(p_id),
    'visits', coalesce((select jsonb_agg(to_jsonb(v)) from (select * from public.client_visits where client_id = p_id order by visited_at desc limit 60) v), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e)) from (select * from public.client_events where client_id = p_id order by created_at desc limit 40) e), '[]'::jsonb),
    'payments', coalesce(v_payments, '[]'::jsonb), 'balance', v_balance, 'balances', v_balances, 'finance_layout', v_layout,
    'plan_validity', public.plan_validity_summary(p_id),
    'finance', jsonb_build_object('version', 1, 'client_id', p_id, 'profile_id', v_client.profile_id,
      'source', case when v_client.profile_id is null then 'client' else 'profile' end, 'layout', v_layout, 'balance_status', v_state, 'balance_nio', v_balance, 'balances', v_balances,
      'collections', v_collections));
end $$;
revoke all on function public.crm_detail(uuid) from public, anon, authenticated;
grant execute on function public.crm_detail(uuid) to authenticated;

-- 11. Directorio: cada fila trae su vigencia sin quitar campos.
create or replace function public.crm_directory(p_search text default '', p_category text default '', p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select jsonb_build_object('total', (select count(*) from public.gym_clients c where
    (p_category = '' or c.category = p_category) and (p_search = '' or c.full_name ilike '%' || p_search || '%' or coalesce(c.phone, '') ilike '%' || p_search || '%' or c.client_number::text = p_search)
    and not public.is_staff_profile(c.profile_id)),
    'rows', coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)) into result from (
    select c.*, p.name_es as plan_name,
      (select count(*)::int from public.client_visits v where v.client_id = c.id and v.local_day >= (now() at time zone 'America/Managua')::date - 29) as visits_30,
      (select max(v.visited_at) from public.client_visits v where v.client_id = c.id) as last_visit,
      public.plan_validity_summary(c.id) as plan_validity
    from public.gym_clients c left join public.plans p on p.id = c.plan_id
    where (p_category = '' or c.category = p_category) and (p_search = '' or c.full_name ilike '%' || p_search || '%' or coalesce(c.phone, '') ilike '%' || p_search || '%' or c.client_number::text = p_search)
      and not public.is_staff_profile(c.profile_id)
    order by c.full_name, c.id limit 30 offset greatest(0, least(coalesce(p_offset, 0), 1000000))
  ) r;
  return result;
end $$;
revoke all on function public.crm_directory(text, text, integer) from public, anon;
grant execute on function public.crm_directory(text, text, integer) to authenticated;

-- 12. Congelamiento: al congelar se recuerda la fecha; al reactivar se
--     desplazan los segmentos vigentes y futuros para no perder días.
create or replace function public.crm_update_client(p_id uuid, p_name text, p_phone text, p_email text, p_category text, p_status text, p_plan text, p_notes text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  old_row public.gym_clients;
  v_admin boolean;
  v_today date := public.plan_local_today();
  v_shift integer := 0;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into old_row from public.gym_clients where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select role = 'admin' into v_admin from public.profiles where id = auth.uid();
  if p_category <> old_row.category and not coalesce(v_admin, false) then raise exception 'ADMIN_ONLY'; end if;
  if p_email is not null and trim(p_email) <> '' and p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'INVALID_EMAIL'; end if;

  if p_status = 'frozen' and old_row.status <> 'frozen' then
    update public.gym_clients set full_name = trim(p_name), phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), ''),
      category = p_category, status = p_status, plan_id = nullif(p_plan, ''), notes = coalesce(p_notes, ''),
      frozen_since = v_today, updated_at = now() where id = p_id;
  elsif old_row.status = 'frozen' and p_status = 'active' then
    if old_row.frozen_since is not null then
      v_shift := v_today - old_row.frozen_since;
    end if;
    if v_shift > 0 then
      update public.payment_plans
         set started_on = started_on + v_shift, expires_on = expires_on + v_shift
       where client_id = p_id and expires_on >= old_row.frozen_since;
    end if;
    update public.gym_clients set full_name = trim(p_name), phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), ''),
      category = p_category, status = p_status, plan_id = nullif(p_plan, ''), notes = coalesce(p_notes, ''),
      frozen_since = null, updated_at = now() where id = p_id;
  else
    update public.gym_clients set full_name = trim(p_name), phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), ''),
      category = p_category, status = p_status, plan_id = nullif(p_plan, ''), notes = coalesce(p_notes, ''),
      updated_at = now() where id = p_id;
  end if;

  insert into public.client_events(client_id, action, details, actor_id) values(p_id, 'updated',
    jsonb_build_object('category_before', old_row.category, 'category_after', p_category,
      'status_before', old_row.status, 'status_after', p_status,
      'frozen_days_shifted', v_shift), auth.uid());
end $$;

-- 13. Reservas: Boxeo exige vigencia en la fecha local de la clase. La entrada
--     a recepción no se bloquea y las demás disciplinas no cambian.
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
  v_existing boolean := false;
  v_booked   integer;
  v_active   integer;
  v_max      integer := 3;
  v_class_is_active boolean;
  v_class_slug text;
  v_session_day date;
begin
  if v_user_id is null then
    raise exception 'AUTH: tenés que iniciar sesión';
  end if;

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

  select is_active, slug into v_class_is_active, v_class_slug
    from public.classes
   where id = v_session.class_id
   for share;

  if not found or v_class_is_active is distinct from true then
    raise exception 'CLASS_INACTIVE: esta disciplina está desactivada';
  end if;

  if v_class_slug = 'boxeo' then
    v_session_day := (v_session.starts_at at time zone 'America/Managua')::date;
    if not exists (
      select 1 from public.payment_plans s
       where s.client_id = (select id from public.gym_clients where profile_id = v_user_id)
         and s.access = 'boxing'
         and s.started_on <= v_session_day
         and s.expires_on >= v_session_day
    ) then
      raise exception 'PLAN_REQUIRED: necesitás tu mensualidad de Boxeo vigente para esa fecha';
    end if;
  end if;

  select * into v_booking
  from public.bookings
  where session_id = p_session_id and user_id = v_user_id;

  if found then
    if v_booking.status in ('confirmed', 'attended') then
      raise exception 'ALREADY_BOOKED: ya tenés una reserva en esa clase';
    end if;
    v_existing := true;
  end if;

  select count(*) into v_booked
  from public.bookings
  where session_id = p_session_id and status in ('confirmed', 'attended');

  if v_booked >= v_session.capacity then
    raise exception 'FULL: no quedan lugares';
  end if;

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

revoke all on function public.book_session(text)
  from public, anon, authenticated;
grant execute on function public.book_session(text) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00068_catalogo_planes.sql
-- ═══════════════════════════════════════════════════════════

-- CLI-06: catálogo de planes y modalidades (modelo C).
--
-- Problema que corrige: la vigencia estaba escrita por nombre de plan dentro de
-- `plan_validity_terms()` y las tarifas rápidas eran una lista fija. Un plan
-- nuevo (Zumba, Estudiante, cualquier modalidad) no se podía cobrar con fechas.
--
-- Decisión aplicada: la vigencia sale de DATOS del plan, no de su slug.
--  - `access_kind = 'gym'`    → todo el gimnasio (pesas y máquinas, sin reserva).
--  - `access_kind = 'class'`  → una disciplina concreta de `public.classes`.
--  - `duration_days`          → días de vigencia contando el pago como día 1.
--  - `validity_currency` / `validity_amount` → importe exacto que dispara la vigencia.
--
-- Un plan sin `duration_days` sigue siendo un cobro genérico: registra dinero y
-- no inventa fechas. Eso mantiene compatibles los planes ya existentes.
--
-- Reversión: dejar de enviar `planId` desde la aplicación; después se pueden
-- quitar `admin_plans_catalog()` y `admin_save_plan(...)`. Las columnas nuevas
-- pueden quedar vacías sin afectar cobros, reservas ni vigencias ya creadas.

begin;
set local lock_timeout = '5s';

-- 1. Configuración de vigencia en el catálogo de planes.
alter table public.plans add column if not exists updated_at timestamptz not null default now();
alter table public.plans add column if not exists access_kind text;
alter table public.plans add column if not exists class_id text references public.classes(id) on delete restrict;
alter table public.plans add column if not exists duration_days integer;
alter table public.plans add column if not exists validity_currency text;
alter table public.plans add column if not exists validity_amount numeric(12, 2);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'plans_access_kind_chk') then
    alter table public.plans add constraint plans_access_kind_chk
      check (access_kind is null or access_kind in ('gym', 'class'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_duration_chk') then
    alter table public.plans add constraint plans_duration_chk
      check (duration_days is null or duration_days between 1 and 3660);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_validity_currency_chk') then
    alter table public.plans add constraint plans_validity_currency_chk
      check (validity_currency is null or validity_currency in ('NIO', 'USD'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_validity_amount_chk') then
    alter table public.plans add constraint plans_validity_amount_chk
      check (validity_amount is null or validity_amount > 0);
  end if;
  -- Un plan con disciplina exige la disciplina; uno sin disciplina no la usa.
  if not exists (select 1 from pg_constraint where conname = 'plans_access_class_chk') then
    alter table public.plans add constraint plans_access_class_chk
      check (
        (access_kind = 'class' and class_id is not null)
        or (access_kind is distinct from 'class' and class_id is null)
        or access_kind is null
      );
  end if;
end $$;

create index if not exists plans_access_idx on public.plans(access_kind, class_id);

-- 2. Traslado de los planes existentes a la forma nueva. Solo rellena vacíos:
--    no cambia precios ni sobrescribe configuración ya cargada.
update public.plans p
   set access_kind = 'gym',
       duration_days = coalesce(p.duration_days, x.days),
       validity_currency = coalesce(p.validity_currency, 'NIO'),
       validity_amount = coalesce(p.validity_amount, p.price_nio)
  from (values
    ('pase-del-dia', 1),
    ('gimnasio-semanal', 7),
    ('gimnasio-quincenal', 15),
    ('gimnasio-mensual', 30)
  ) as x(slug, days)
 where p.slug = x.slug
   and p.access_kind is null
   and p.price_nio is not null;

-- Boxeo queda como disciplina, no como excepción escrita a mano.
do $$
declare v_class text;
begin
  select id into v_class from public.classes where slug = 'boxeo' limit 1;
  if v_class is not null then
    update public.plans
       set access_kind = 'class',
           class_id = v_class,
           duration_days = coalesce(duration_days, 30),
           validity_currency = coalesce(validity_currency, 'USD'),
           validity_amount = coalesce(validity_amount, price)
     where slug = 'boxeo'
       and access_kind is null;
  end if;
end $$;

-- 3. Segmentos de vigencia: pasan a poder apuntar a cualquier disciplina.
alter table public.payment_plans add column if not exists class_id text
  references public.classes(id) on delete restrict;
create index if not exists payment_plans_class_idx
  on public.payment_plans(client_id, class_id, expires_on desc);

alter table public.payment_plans drop constraint if exists payment_plans_access_chk;
alter table public.payment_plans add constraint payment_plans_access_chk
  check (access in ('gym', 'class', 'boxing'));

-- Los segmentos históricos de Boxeo quedan como disciplina.
do $$
declare v_class text;
begin
  select id into v_class from public.classes where slug = 'boxeo' limit 1;
  if v_class is not null then
    update public.payment_plans
       set access = 'class', class_id = coalesce(class_id, v_class)
     where access = 'boxing';
  end if;
end $$;

-- 4. Términos por DATOS. Un plan sin duración devuelve NULL: cobro genérico.
create or replace function public.plan_validity_terms(p_plan text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_plan public.plans;
  v_currency text;
  v_amount numeric;
begin
  select * into v_plan from public.plans where id = p_plan;
  if not found then raise exception 'PLAN_NOT_FOUND'; end if;
  if v_plan.duration_days is null or v_plan.access_kind is null then
    return null;
  end if;
  -- Compatibilidad: un plan antiguo sin importe de vigencia usa su tarifa.
  v_currency := coalesce(v_plan.validity_currency, case when v_plan.price_nio is null then 'USD' else 'NIO' end);
  v_amount := coalesce(
    v_plan.validity_amount,
    case when v_currency = 'USD' then v_plan.price else v_plan.price_nio end
  );
  return jsonb_build_object(
    'plan_id', v_plan.id,
    'slug', v_plan.slug,
    'period', v_plan.period,
    'access', v_plan.access_kind,
    'class_id', v_plan.class_id,
    'class_name', (select name_es from public.classes where id = v_plan.class_id),
    'days', v_plan.duration_days,
    'currency', v_currency,
    'amount', v_amount
  );
end $$;
revoke all on function public.plan_validity_terms(text) from public, anon;
grant execute on function public.plan_validity_terms(text) to authenticated;

-- 5. Estado de vigencia por acceso. `p_class_id` nulo = todo el gimnasio.
create or replace function public.plan_class_state(p_client uuid, p_class_id text, p_today date)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_row record;
  v_key text := coalesce(p_class_id, 'gym');
  v_label text;
begin
  select name_es into v_label from public.classes where id = p_class_id;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
     and started_on <= p_today and expires_on >= p_today
   order by expires_on desc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'active', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on,
      'days_left', v_row.expires_on - p_today + 1
    );
  end if;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
     and started_on > p_today
   order by started_on asc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'upcoming', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on, 'days_left', 0
    );
  end if;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
   order by expires_on desc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'expired', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on, 'days_left', 0
    );
  end if;

  return jsonb_build_object(
    'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
    'state', 'none', 'plan_id', null,
    'starts_on', null, 'expires_on', null, 'days_left', 0
  );
end $$;
revoke all on function public.plan_class_state(uuid, text, date) from public, anon, authenticated;

-- Puente de compatibilidad: acepta 'gym', 'boxing' o el id/slug de una
-- disciplina. La aplicación usa `plan_class_state`.
create or replace function public.plan_access_state(p_client uuid, p_access text, p_today date)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select public.plan_class_state(
    p_client,
    case
      when p_access is null or p_access = 'gym' then null
      when p_access = 'boxing' then (select id from public.classes where slug = 'boxeo' limit 1)
      else (select id from public.classes where id = p_access or slug = p_access limit 1)
    end,
    p_today
  );
$$;
revoke all on function public.plan_access_state(uuid, text, date) from public, anon, authenticated;

-- 6. Resumen: gimnasio + una fila por disciplina con plan o vigencia.
create or replace function public.plan_validity_summary(p_client uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_today date := public.plan_local_today();
begin
  return jsonb_build_object(
    'today', v_today,
    'gym', public.plan_class_state(p_client, null::text, v_today),
    'classes', coalesce((
      select jsonb_agg(public.plan_class_state(p_client, c.id, v_today) order by c.sort_order, c.name_es)
      from public.classes c
      where c.is_active
        and (
          exists(select 1 from public.payment_plans s where s.client_id = p_client and s.class_id = c.id)
          or exists(select 1 from public.plans p
                     where p.is_active and p.access_kind = 'class' and p.class_id = c.id
                       and p.duration_days is not null)
        )
    ), '[]'::jsonb),
    'segments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'plan_id', s.plan_id,
        'access', case when s.class_id is null then 'gym' else 'class' end,
        'class_id', s.class_id,
        'class_name', (select name_es from public.classes where id = s.class_id),
        'started_on', s.started_on,
        'expires_on', s.expires_on,
        'price', s.price_paid,
        'currency', s.currency
      ) order by s.started_on desc, s.expires_on desc)
      from public.payment_plans s where s.client_id = p_client
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.plan_validity_summary(uuid) from public, anon, authenticated;

-- 7. Registro de compra: guarda la disciplina del plan.
create or replace function public.plan_register_segment(
  p_client uuid,
  p_plan text,
  p_amount numeric,
  p_currency text,
  p_request uuid,
  p_transaction uuid,
  p_source text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_terms jsonb;
  v_existing public.payment_plans;
  v_today date;
  v_chain date;
  v_start date;
  v_end date;
  v_id uuid;
  v_class text;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_amount is null
     or p_amount <> (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;
  if p_source not in ('movement', 'checkout', 'crm') then raise exception 'INVALID_REQUEST'; end if;

  v_class := nullif(v_terms->>'class_id', '');

  select * into v_existing from public.payment_plans where request_id = p_request;
  if found then
    if v_existing.client_id is distinct from p_client
       or v_existing.plan_id::text is distinct from p_plan then
      raise exception 'REQUEST_CONFLICT';
    end if;
    return jsonb_build_object(
      'id', v_existing.id, 'plan_id', v_existing.plan_id,
      'access', case when v_existing.class_id is null then 'gym' else 'class' end,
      'class_id', v_existing.class_id,
      'started_on', v_existing.started_on, 'expires_on', v_existing.expires_on,
      'days', v_existing.expires_on - v_existing.started_on + 1,
      'validity', public.plan_validity_summary(p_client)
    );
  end if;

  perform 1 from public.gym_clients where id = p_client for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_transaction is not null and exists(
    select 1 from public.payment_plans where transaction_id = p_transaction
  ) then
    raise exception 'REQUEST_CONFLICT';
  end if;

  v_today := public.plan_local_today();
  -- Encadena solo dentro del mismo acceso: gimnasio con gimnasio, Zumba con
  -- Zumba. Dos accesos distintos no se roban días entre sí.
  select max(expires_on) into v_chain
    from public.payment_plans
   where client_id = p_client
     and ((v_class is null and access = 'gym') or (v_class is not null and class_id = v_class))
     and expires_on >= v_today;
  v_start := case when v_chain is null then v_today else v_chain + 1 end;
  v_end := v_start + ((v_terms->>'days')::integer - 1);

  insert into public.payment_plans(
    client_id, plan_id, access, class_id, started_on, expires_on, price_paid,
    currency, request_id, transaction_id, source, created_by
  ) values (
    p_client, p_plan, case when v_class is null then 'gym' else 'class' end, v_class,
    v_start, v_end, p_amount, p_currency, p_request, p_transaction, p_source, auth.uid()
  ) returning id into v_id;

  return jsonb_build_object(
    'id', v_id, 'plan_id', p_plan,
    'access', case when v_class is null then 'gym' else 'class' end,
    'class_id', v_class,
    'started_on', v_start, 'expires_on', v_end,
    'days', (v_terms->>'days')::integer,
    'validity', public.plan_validity_summary(p_client)
  );
end $$;
revoke all on function public.plan_register_segment(uuid, text, numeric, text, uuid, uuid, text) from public, anon, authenticated;

-- 8. Envoltorios: solo cambia el rechazo de Boxeo con productos, que ahora se
--    deduce del plan (una disciplina con vencimiento propio no se combina).
create or replace function public.finance_record_checkout_plan(
  p_request uuid, p_client uuid, p_service_amount numeric, p_service_concept text,
  p_currency text, p_method text, p_account text, p_fx numeric, p_items jsonb, p_plan text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_terms jsonb; v_pre boolean; v_result jsonb; v_tx uuid; v_plan jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_plan is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if (v_terms->>'access') = 'class' then raise exception 'PLAN_NOT_COMBINABLE'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_service_amount is distinct from (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;

  select exists(select 1 from public.finance_checkout_groups where request_id = p_request) into v_pre;

  v_result := public.finance_record_checkout(
    p_request, p_client, p_service_amount, p_service_concept,
    p_currency, p_method, p_account, p_fx, p_items
  );

  if v_pre then
    select jsonb_build_object(
      'id', s.id, 'plan_id', s.plan_id,
      'access', case when s.class_id is null then 'gym' else 'class' end,
      'class_id', s.class_id,
      'started_on', s.started_on, 'expires_on', s.expires_on,
      'days', s.expires_on - s.started_on + 1
    ) into v_plan
    from public.payment_plans s where s.request_id = p_request;
  elsif p_service_amount > 0 then
    v_tx := nullif(v_result->>'serviceTransactionId', '')::uuid;
    v_plan := public.plan_register_segment(
      p_client, p_plan, p_service_amount, p_currency, p_request, v_tx, 'checkout'
    );
    v_plan := v_plan - 'validity';
  end if;

  return v_result || jsonb_build_object('plan', v_plan);
end $$;

-- 9. Reservas: se exige vigencia cuando la disciplina tiene planes con
--    duración. Si no hay ninguno configurado, no se bloquea nada.
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
  v_existing boolean := false;
  v_booked   integer;
  v_active   integer;
  v_max      integer := 3;
  v_class_is_active boolean;
  v_session_day date;
  v_requires_plan boolean;
  v_class_name text;
begin
  if v_user_id is null then
    raise exception 'AUTH: tenés que iniciar sesión';
  end if;

  select * into v_session from public.sessions where id = p_session_id for update;
  if not found then raise exception 'NOT_FOUND: la clase no existe'; end if;
  if v_session.status <> 'scheduled' then raise exception 'CANCELLED: la clase fue cancelada'; end if;
  if v_session.starts_at <= now() then raise exception 'PAST: la clase ya comenzó'; end if;

  select is_active, name_es into v_class_is_active, v_class_name
    from public.classes where id = v_session.class_id for share;
  if not found or v_class_is_active is distinct from true then
    raise exception 'CLASS_INACTIVE: esta disciplina está desactivada';
  end if;

  -- Solo se exige vigencia si alguien configuró al menos un plan con duración
  -- para esta disciplina. Así ninguna disciplina queda bloqueada por defecto.
  select exists(
    select 1 from public.plans p
     where p.is_active and p.access_kind = 'class'
       and p.class_id = v_session.class_id and p.duration_days is not null
  ) into v_requires_plan;

  if v_requires_plan then
    v_session_day := (v_session.starts_at at time zone 'America/Managua')::date;
    if not exists (
      select 1 from public.payment_plans s
       where s.client_id = (select id from public.gym_clients where profile_id = v_user_id)
         and s.class_id = v_session.class_id
         and s.started_on <= v_session_day
         and s.expires_on >= v_session_day
    ) then
      raise exception 'PLAN_REQUIRED: necesitás tu plan de % vigente para esa fecha', v_class_name;
    end if;
  end if;

  select * into v_booking from public.bookings
   where session_id = p_session_id and user_id = v_user_id;
  if found then
    if v_booking.status in ('confirmed', 'attended') then
      raise exception 'ALREADY_BOOKED: ya tenés una reserva en esa clase';
    end if;
    v_existing := true;
  end if;

  select count(*) into v_booked from public.bookings
   where session_id = p_session_id and status in ('confirmed', 'attended');
  if v_booked >= v_session.capacity then raise exception 'FULL: no quedan lugares'; end if;

  select count(*) into v_active
    from public.bookings b join public.sessions s on s.id = b.session_id
   where b.user_id = v_user_id and b.status in ('confirmed', 'attended')
     and s.starts_at > now();
  if v_active >= v_max then
    raise exception 'LIMIT: ya tenés % reservas activas a la vez', v_max;
  end if;

  if v_existing then
    update public.bookings set status = 'confirmed', cancelled_at = null, created_at = now()
     where id = v_booking.id returning * into v_booking;
  else
    insert into public.bookings (session_id, user_id, status)
    values (p_session_id, v_user_id, 'confirmed') returning * into v_booking;
  end if;

  return jsonb_build_object('id', v_booking.id, 'session_id', v_booking.session_id, 'status', v_booking.status);
end;
$$;
revoke all on function public.book_session(text) from public, anon, authenticated;
grant execute on function public.book_session(text) to authenticated;

-- 10. Catálogo administrable. Solo administrador; sin borrar filas.
create or replace function public.admin_plans_catalog()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  return jsonb_build_object(
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'slug', p.slug, 'name_es', p.name_es, 'name_en', p.name_en,
        'period', p.period, 'price_nio', p.price_nio, 'price', p.price,
        'access_kind', p.access_kind, 'class_id', p.class_id,
        'class_name', (select name_es from public.classes where id = p.class_id),
        'duration_days', p.duration_days,
        'validity_currency', p.validity_currency,
        'validity_amount', p.validity_amount,
        'is_active', p.is_active, 'sort_order', p.sort_order,
        'updated_at', p.updated_at
      ) order by p.sort_order, p.name_es)
      from public.plans p
    ), '[]'::jsonb),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'slug', c.slug, 'name_es', c.name_es, 'is_active', c.is_active)
        order by c.sort_order, c.name_es)
      from public.classes c
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.admin_plans_catalog() from public, anon, authenticated;
grant execute on function public.admin_plans_catalog() to authenticated;

create or replace function public.admin_save_plan(
  p_id text,
  p_name_es text,
  p_name_en text,
  p_slug text,
  p_period text,
  p_price_nio numeric,
  p_access_kind text,
  p_class_id text,
  p_duration_days integer,
  p_validity_currency text,
  p_validity_amount numeric,
  p_is_active boolean,
  p_sort_order integer
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id text;
  v_slug text := lower(trim(coalesce(p_slug, '')));
  v_access text := nullif(trim(coalesce(p_access_kind, '')), '');
  v_class text := nullif(trim(coalesce(p_class_id, '')), '');
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if length(trim(coalesce(p_name_es, ''))) not between 2 and 80
     or length(trim(coalesce(p_name_en, ''))) not between 2 and 80 then
    raise exception 'INVALID_NAME';
  end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(v_slug) not between 2 and 48 then
    raise exception 'INVALID_SLUG';
  end if;
  if p_period is null or p_period not in ('session', 'week', 'fortnight', 'month') then
    raise exception 'INVALID_PERIOD';
  end if;
  if p_price_nio is not null and (p_price_nio <= 0 or p_price_nio > 99999999 or p_price_nio <> round(p_price_nio, 2)) then
    raise exception 'INVALID_PRICE';
  end if;
  if v_access is not null and v_access not in ('gym', 'class') then
    raise exception 'INVALID_ACCESS';
  end if;
  if v_access = 'class' then
    if v_class is null or not exists(select 1 from public.classes where id = v_class) then
      raise exception 'INVALID_CLASS';
    end if;
  else
    v_class := null;
  end if;
  -- Con vigencia, los tres datos van juntos; sin vigencia, ninguno.
  if p_duration_days is not null then
    if p_duration_days not between 1 and 3660 then raise exception 'INVALID_DURATION'; end if;
    if p_validity_currency is null or p_validity_currency not in ('NIO', 'USD') then
      raise exception 'INVALID_CURRENCY';
    end if;
    if p_validity_amount is null or p_validity_amount <= 0 or p_validity_amount > 99999999
       or p_validity_amount <> round(p_validity_amount, 2) then
      raise exception 'INVALID_AMOUNT';
    end if;
    if v_access is null then raise exception 'INVALID_ACCESS'; end if;
  else
    if v_access is not null or p_validity_currency is not null or p_validity_amount is not null then
      raise exception 'INVALID_VALIDITY';
    end if;
    v_class := null;
  end if;

  if p_id is null or trim(p_id) = '' then
    v_id := 'pln_' || replace(v_slug, '-', '_');
    if exists(select 1 from public.plans where id = v_id or slug = v_slug) then
      raise exception 'PLAN_EXISTS';
    end if;
    insert into public.plans(
      id, slug, name_es, name_en, period, price_nio, access_kind, class_id,
      duration_days, validity_currency, validity_amount, is_active, sort_order, updated_at
    ) values (
      v_id, v_slug, trim(p_name_es), trim(p_name_en), p_period, p_price_nio, v_access, v_class,
      p_duration_days, case when p_duration_days is null then null else p_validity_currency end,
      case when p_duration_days is null then null else p_validity_amount end,
      coalesce(p_is_active, true), coalesce(p_sort_order, 100), now()
    );
  else
    if exists(select 1 from public.plans where slug = v_slug and id <> p_id) then
      raise exception 'PLAN_EXISTS';
    end if;
    update public.plans
       set slug = v_slug, name_es = trim(p_name_es), name_en = trim(p_name_en),
           period = p_period, price_nio = p_price_nio,
           access_kind = v_access, class_id = v_class,
           duration_days = p_duration_days,
           validity_currency = case when p_duration_days is null then null else p_validity_currency end,
           validity_amount = case when p_duration_days is null then null else p_validity_amount end,
           is_active = coalesce(p_is_active, true),
           sort_order = coalesce(p_sort_order, sort_order),
           updated_at = now()
     where id = p_id;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_id := p_id;
  end if;

  return (select jsonb_build_object(
    'id', p.id, 'slug', p.slug, 'name_es', p.name_es, 'name_en', p.name_en,
    'period', p.period, 'price_nio', p.price_nio,
    'access_kind', p.access_kind, 'class_id', p.class_id,
    'duration_days', p.duration_days,
    'validity_currency', p.validity_currency, 'validity_amount', p.validity_amount,
    'is_active', p.is_active, 'sort_order', p.sort_order, 'updated_at', p.updated_at
  ) from public.plans p where p.id = v_id);
end $$;
revoke all on function public.admin_save_plan(text, text, text, text, text, numeric, text, text, integer, text, numeric, boolean, integer) from public, anon, authenticated;
grant execute on function public.admin_save_plan(text, text, text, text, text, numeric, text, text, integer, text, numeric, boolean, integer) to authenticated;

-- 11. Opciones de cobro: incluyen la disciplina y la forma de acceso.
create or replace function public.crm_options()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_layout text; v_methods jsonb; v_accounts jsonb; v_plans jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v_layout := public.crm_finance_layout();
  if v_layout = 'unsupported' then raise exception 'FINANCE_SCHEMA_UNSUPPORTED'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name_es', p.name_es, 'slug', p.slug, 'period', p.period,
      'price_nio', p.price_nio, 'sort_order', p.sort_order
    ) || jsonb_strip_nulls(jsonb_build_object(
      'access', t->>'access',
      'class_id', t->>'class_id',
      'class_name', t->>'class_name',
      'duration_days', case when t is null then null else (t->>'days')::integer end,
      'validity_currency', t->>'currency',
      'validity_amount', (t->>'amount')
    )) order by p.sort_order), '[]'::jsonb) into v_plans
    from public.plans p
    left join lateral (select public.plan_validity_terms(p.id) as t) x on true
   where p.is_active;
  if v_layout = 'repository' then
    select coalesce(jsonb_agg(to_jsonb(m) order by sort_order), '[]'::jsonb) into v_methods
      from (select id, name_es, accepts_nio, accepts_usd, sort_order from public.payment_methods where is_active) m;
    select coalesce(jsonb_agg(to_jsonb(a) order by name), '[]'::jsonb) into v_accounts
      from (select id, name, currency from public.accounts where is_active) a;
  else
    select coalesce(jsonb_agg(to_jsonb(m) order by display_order), '[]'::jsonb) into v_methods
      from (select id, name as name_es, currency in ('NIO', 'BOTH') as accepts_nio,
        currency in ('USD', 'BOTH') as accepts_usd, display_order from public.payment_methods where is_active) m;
    select coalesce(jsonb_agg(to_jsonb(a) order by display_order), '[]'::jsonb) into v_accounts
      from (select id, name, currency, display_order from public.bank_accounts where is_active) a;
  end if;
  return jsonb_build_object('plans', v_plans, 'methods', v_methods, 'accounts', v_accounts,
    'finance_layout', v_layout, 'payments_enabled', v_layout = 'repository',
    'payment_block_reason', case when v_layout <> 'repository' then
      'Cobros CRM pendientes de compatibilidad con esta Caja. No se guardará ningún cobro desde esta ficha; no lo repitas en otra pantalla sin revisar el historial.' else null end);
end $$;
revoke all on function public.crm_options() from public, anon, authenticated;
grant execute on function public.crm_options() to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00069_catalogo_planes_plan_class_state.sql
-- ═══════════════════════════════════════════════════════════

-- CLI-06 · corrección de `plan_class_state`.
--
-- La migración 00068 se transcribió a mano al aplicarla en producción y quedó
-- `v_row.starts_on` en dos ramas (columna inexistente: `started_on`). Toda
-- vigencia en estado «por comenzar» o «vencida» fallaba al leerse.
--
-- Este archivo repite la función tal como quedó escrita en 00068, para que el
-- repositorio y la base remota tengan exactamente la misma definición.
-- No borra ni modifica datos; solo reemplaza la función.

begin;

create or replace function public.plan_class_state(p_client uuid, p_class_id text, p_today date)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_row record;
  v_key text := coalesce(p_class_id, 'gym');
  v_label text;
begin
  select name_es into v_label from public.classes where id = p_class_id;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
     and started_on <= p_today and expires_on >= p_today
   order by expires_on desc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'active', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on,
      'days_left', v_row.expires_on - p_today + 1
    );
  end if;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
     and started_on > p_today
   order by started_on asc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'upcoming', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on, 'days_left', 0
    );
  end if;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
   order by expires_on desc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'expired', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on, 'days_left', 0
    );
  end if;

  return jsonb_build_object(
    'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
    'state', 'none', 'plan_id', null,
    'starts_on', null, 'expires_on', null, 'days_left', 0
  );
end $$;
revoke all on function public.plan_class_state(uuid, text, date) from public, anon, authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00070_categorias_automaticas.sql
-- ═══════════════════════════════════════════════════════════

-- CLI-02: categoría automática basada en la vigencia real (CLI-06).
--
-- Problema que corrige: `client_category()` miraba `gym_clients.plan_id` y el
-- periodo de ese plan asignado, sin fechas. Un cliente con el mes pagado y otro
-- vencido hace tres semanas daban la misma categoría, porque la etiqueta no
-- cambia sola al vencer.
--
-- Decisión aplicada:
--  - La vigencia sale de `payment_plans` (fechas reales), igual que el cobro.
--  - Las reglas de las cuatro categorías son DATOS editables por el
--    administrador desde Administración → Categorías, con su orden de
--    prioridad. Cambiar los números no requiere código.
--  - El administrador puede fijar a mano la categoría de un cliente con un
--    motivo obligatorio; esa decisión gana sobre el cálculo y queda auditada.
--  - El «plan asignado» sigue existiendo como etiqueta, pero ya no decide.
--
-- Reversión: dejar de llamar `client_category_apply()`; las columnas nuevas
-- pueden quedar vacías y la aplicación vuelve a calcular en el momento. No se
-- borran datos ni eventos.

begin;
set local lock_timeout = '5s';

-- 1. Estado de categoría en la ficha. No reemplaza `gym_clients.category`
--    (la etiqueta histórica client/friend/family).
alter table public.gym_clients add column if not exists category_auto text;
alter table public.gym_clients add column if not exists category_auto_at timestamptz;
alter table public.gym_clients add column if not exists category_override text;
alter table public.gym_clients add column if not exists category_override_reason text;
alter table public.gym_clients add column if not exists category_override_by uuid references public.profiles(id) on delete set null;
alter table public.gym_clients add column if not exists category_override_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'gym_clients_category_auto_chk') then
    alter table public.gym_clients add constraint gym_clients_category_auto_chk
      check (category_auto is null or category_auto in ('strong_gym', 'familia', 'amigo', 'comun'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'gym_clients_category_override_chk') then
    alter table public.gym_clients add constraint gym_clients_category_override_chk
      check (category_override is null or category_override in ('strong_gym', 'familia', 'amigo', 'comun'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'gym_clients_category_override_reason_chk') then
    alter table public.gym_clients add constraint gym_clients_category_override_reason_chk
      check (category_override is null or length(trim(coalesce(category_override_reason, ''))) between 4 and 200);
  end if;
end $$;

create index if not exists gym_clients_category_auto_idx on public.gym_clients(category_auto);
create index if not exists gym_clients_category_override_idx on public.gym_clients(category_override);

-- 2. Reglas editables. Una fila por categoría; el administrador cambia los
--    números y el orden. `comun` es el resto y no se evalúa como condición.
create table if not exists public.category_rules (
  category text primary key check (category in ('strong_gym', 'familia', 'amigo', 'comun')),
  sort_order integer not null default 100 check (sort_order between 1 and 999),
  is_active boolean not null default true,
  is_fallback boolean not null default false,
  requires_validity boolean not null default false,
  forbids_validity boolean not null default false,
  validity_days_min integer not null default 1 check (validity_days_min between 0 and 3660),
  requires_purchase_window_days integer
    check (requires_purchase_window_days is null or requires_purchase_window_days between 1 and 3650),
  visits_min integer not null default 0 check (visits_min between 0 and 1000),
  visits_window_days integer not null default 30 check (visits_window_days between 1 and 365),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null,
  constraint category_rules_validity_chk check (not (requires_validity and forbids_validity)),
  constraint category_rules_fallback_chk check (
    (is_fallback and category = 'comun') or (not is_fallback and category <> 'comun')
  )
);

-- Valores por defecto acordados: mes vigente + compra = categoría del gimnasio; cualquier
-- vigencia = Familia; sin vigencia y 3 visitas en 30 días = Amigo; el resto Común.
insert into public.category_rules(
  category, sort_order, is_active, is_fallback, requires_validity, forbids_validity,
  validity_days_min, requires_purchase_window_days, visits_min, visits_window_days
) values
  ('strong_gym', 1, true, false, true,  false, 30, 90,   0, 30),
  ('familia',    2, true, false, true,  false, 1,  null, 0, 30),
  ('amigo',      3, true, false, false, true,  0,  null, 3, 30),
  ('comun',     99, true, true,  false, false, 0,  null, 0, 30)
on conflict (category) do nothing;

-- Historial de las reglas: quién cambió los números y cuándo, sin tocar la
-- bitácora de clientes (que exige un cliente).
create table if not exists public.category_rules_history (
  id uuid primary key default gen_random_uuid(),
  rules jsonb not null,
  changed_by uuid references public.profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);
create index if not exists category_rules_history_idx on public.category_rules_history(changed_at desc);

alter table public.category_rules enable row level security;
alter table public.category_rules_history enable row level security;
revoke all on public.category_rules, public.category_rules_history from public, anon, authenticated;

-- 3. Evaluación interna: categoría sugerida, motivo y datos usados.
create or replace function public.client_category_eval(p_client uuid, p_today date)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_gym jsonb;
  v_classes jsonb;
  v_gym_days integer := 0;
  v_class_days integer := 0;
  v_valid_days integer := 0;
  v_has_validity boolean := false;
  v_visits integer := 0;
  v_purchases integer := 0;
  v_visit_rule integer := 0;
  v_counts integer := 0;
  v_rule public.category_rules;
  v_matched boolean := false;
  v_cat text;
  v_label text := 'sin vigencia';
begin
  v_gym := public.plan_class_state(p_client, null::text, p_today);

  -- Días comprados del segmento vigente más largo de cada acceso.
  select coalesce(max(expires_on - started_on + 1), 0) into v_gym_days
    from public.payment_plans
   where client_id = p_client and access = 'gym'
     and started_on <= p_today and expires_on >= p_today;
  select coalesce(max(expires_on - started_on + 1), 0) into v_class_days
    from public.payment_plans
   where client_id = p_client and class_id is not null
     and started_on <= p_today and expires_on >= p_today;

  v_valid_days := greatest(v_gym_days, v_class_days);
  v_has_validity := v_valid_days > 0;

  v_classes := coalesce((
    select jsonb_agg(jsonb_build_object(
      'class_id', s.class_id,
      'class_name', (select name_es from public.classes where id = s.class_id),
      'plan_id', s.plan_id,
      'started_on', s.started_on,
      'expires_on', s.expires_on,
      'days', s.expires_on - s.started_on + 1
    ) order by s.expires_on desc)
    from public.payment_plans s
   where s.client_id = p_client and s.class_id is not null
     and s.started_on <= p_today and s.expires_on >= p_today
  ), '[]'::jsonb);

  -- Datos informativos, siempre con la ventana de la regla «amigo» vigente.
  select coalesce(max(visits_window_days), 30) into v_visit_rule
    from public.category_rules where category = 'amigo';
  select count(*) into v_visits from public.client_visits
   where client_id = p_client
     and local_day > p_today - v_visit_rule
     and local_day <= p_today;
  select count(*) into v_purchases from public.stock_movements
   where client_id = p_client and kind = 'venta'
     and created_at >= now() - interval '90 days';

  -- Primera regla activa que cumple, en el orden que fijó el administrador.
  for v_rule in
    select * from public.category_rules
     where is_active and not is_fallback
     order by sort_order, category
  loop
    if v_rule.requires_validity and v_valid_days < v_rule.validity_days_min then
      continue;
    end if;
    if v_rule.forbids_validity and v_has_validity then
      continue;
    end if;
    if v_rule.requires_purchase_window_days is not null then
      select count(*) into v_counts from public.stock_movements m
       where m.client_id = p_client and m.kind = 'venta'
         and m.created_at >= now() - make_interval(days => v_rule.requires_purchase_window_days);
      if v_counts = 0 then continue; end if;
    end if;
    if v_rule.visits_min > 0 then
      select count(*) into v_counts from public.client_visits v
       where v.client_id = p_client
         and v.local_day > p_today - v_rule.visits_window_days
         and v.local_day <= p_today;
      if v_counts < v_rule.visits_min then continue; end if;
    end if;
    v_cat := v_rule.category;
    v_matched := true;
    exit;
  end loop;

  -- Si ninguna regla cumple, la categoría de reserva configurada.
  if not v_matched then
    select category into v_cat from public.category_rules
     where is_fallback and is_active order by sort_order limit 1;
    v_cat := coalesce(v_cat, 'comun');
  end if;

  if v_gym_days > 0 then
    v_label := 'gimnasio vigente';
  elsif v_class_days > 0 then
    v_label := 'plan de disciplina vigente';
  elsif v_visits > 0 then
    v_label := v_visits || case when v_visits = 1 then ' visita en ' else ' visitas en ' end
               || v_visit_rule || ' días';
  end if;

  return jsonb_build_object(
    'category', v_cat,
    'reason', v_label,
    'validity_days', v_valid_days,
    'gym_days', v_gym_days,
    'class_days', v_class_days,
    'gym', v_gym,
    'classes', v_classes,
    'visits_30_days', v_visits,
    'purchases_90_days', v_purchases,
    'visits_window_days', v_visit_rule
  );
end $$;
revoke all on function public.client_category_eval(uuid, date) from public, anon, authenticated;

-- 4. Lectura para la aplicación. Mantiene los campos anteriores y agrega el
--    motivo, la fuente y la vigencia real.
create or replace function public.client_category(p_client uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_client uuid; v_today date := public.plan_local_today();
  v_eval jsonb; v_period text; v_status text;
  v_override text; v_reason text; v_by uuid; v_at timestamptz;
  v_auto text;
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

  select g.category_override, g.category_override_reason, g.category_override_by,
         g.category_override_at, g.category_auto, pl.period, g.status
    into v_override, v_reason, v_by, v_at, v_auto, v_period, v_status
    from public.gym_clients g
    left join public.plans pl on pl.id = g.plan_id
   where g.id = v_client;

  v_eval := public.client_category_eval(v_client, v_today);

  return v_eval || jsonb_build_object(
    'source', case when v_override is null then 'auto' else 'manual' end,
    'category', coalesce(v_override, v_eval->>'category'),
    'auto_category', v_eval->>'category',
    'saved_auto_category', v_auto,
    'manual', v_override is not null,
    'manual_reason', v_reason,
    'manual_by', v_by,
    'manual_at', v_at,
    -- Compatibilidad con lectores anteriores: ya no decide la categoría.
    'membership_period', v_period,
    'membership_active', (v_eval->>'validity_days')::integer > 0,
    'membership_source', 'payment_plans',
    'client_status', v_status,
    'today', v_today
  );
end $$;
revoke all on function public.client_category(uuid) from public, anon;
grant execute on function public.client_category(uuid) to authenticated;

-- 5. Guardar la categoría calculada y auditar el cambio. `p_client` nulo =
--    todos los clientes del gimnasio. Devuelve cuántos revisó y cambiaron.
create or replace function public.client_category_apply(p_client uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_today date := public.plan_local_today();
  v_row record; v_new text; v_before text; v_changed integer := 0; v_seen integer := 0;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  for v_row in
    select id, category_auto from public.gym_clients
     where (p_client is null or id = p_client)
       and not public.is_staff_profile(profile_id)
     order by full_name, id
     limit 5000
  loop
    v_seen := v_seen + 1;
    v_new := public.client_category_eval(v_row.id, v_today)->>'category';
    v_before := v_row.category_auto;
    if v_before is distinct from v_new then
      update public.gym_clients
         set category_auto = v_new, category_auto_at = now()
       where id = v_row.id;
      insert into public.client_events(client_id, action, details, actor_id)
      values (v_row.id, 'category_changed',
        jsonb_build_object('from', v_before, 'to', v_new, 'source', 'auto', 'today', v_today),
        auth.uid());
      v_changed := v_changed + 1;
    end if;
  end loop;
  return jsonb_build_object('reviewed', v_seen, 'changed', v_changed);
end $$;
revoke all on function public.client_category_apply(uuid) from public, anon;
grant execute on function public.client_category_apply(uuid) to authenticated;

-- 6. Fijar o liberar la categoría a mano. Solo administrador; motivo obligatorio.
create or replace function public.crm_set_client_category(
  p_client uuid, p_category text, p_reason text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_before text; v_auto text;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_category is null or p_category not in ('strong_gym', 'familia', 'amigo', 'comun') then
    raise exception 'INVALID_CATEGORY';
  end if;
  if length(trim(coalesce(p_reason, ''))) not between 4 and 200 then
    raise exception 'INVALID_REASON';
  end if;
  select category_override, category_auto into v_before, v_auto
    from public.gym_clients where id = p_client for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.gym_clients
     set category_override = p_category,
         category_override_reason = trim(p_reason),
         category_override_by = auth.uid(),
         category_override_at = now()
   where id = p_client;
  insert into public.client_events(client_id, action, details, actor_id)
  values (p_client, 'category_override_set',
    jsonb_build_object('from', v_before, 'to', p_category, 'auto', v_auto, 'reason', trim(p_reason)),
    auth.uid());
  return jsonb_build_object('category', p_category, 'source', 'manual');
end $$;
revoke all on function public.crm_set_client_category(uuid, text, text) from public, anon, authenticated;
grant execute on function public.crm_set_client_category(uuid, text, text) to authenticated;

create or replace function public.crm_clear_client_category(p_client uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_before text; v_auto text; v_back text;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if length(trim(coalesce(p_reason, ''))) not between 4 and 200 then
    raise exception 'INVALID_REASON';
  end if;
  select category_override, category_auto into v_before, v_auto
    from public.gym_clients where id = p_client for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_back := coalesce(v_auto, public.client_category_eval(p_client, public.plan_local_today())->>'category');
  if v_before is null then return jsonb_build_object('category', v_back, 'source', 'auto'); end if;
  update public.gym_clients
     set category_override = null, category_override_reason = null,
         category_override_by = null, category_override_at = null
   where id = p_client;
  insert into public.client_events(client_id, action, details, actor_id)
  values (p_client, 'category_override_cleared',
    jsonb_build_object('from', v_before, 'to', v_back, 'reason', trim(p_reason)),
    auth.uid());
  return jsonb_build_object('category', v_back, 'source', 'auto');
end $$;
revoke all on function public.crm_clear_client_category(uuid, text) from public, anon, authenticated;
grant execute on function public.crm_clear_client_category(uuid, text) to authenticated;

-- 7. Reglas para el panel, guardado validado e historial.
create or replace function public.admin_category_rules()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  return jsonb_build_object(
    'rules', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.sort_order, r.category)
      from public.category_rules r
    ), '[]'::jsonb),
    'counts', coalesce((
      select jsonb_object_agg(x.cat, x.count)
      from (
        select coalesce(c.category_override, c.category_auto, 'sin_calcular') as cat, count(*)::int as count
        from public.gym_clients c
        where not public.is_staff_profile(c.profile_id)
        group by 1
      ) x
    ), '{}'::jsonb),
    'pending', (select count(*)::int from public.gym_clients c
                 where c.category_auto is null and not public.is_staff_profile(c.profile_id)),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('changed_at', h.changed_at, 'changed_by', h.changed_by, 'rules', h.rules)
        order by h.changed_at desc)
      from (select * from public.category_rules_history order by changed_at desc limit 5) h
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.admin_category_rules() from public, anon, authenticated;
grant execute on function public.admin_category_rules() to authenticated;

create or replace function public.admin_save_category_rules(p_rules jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rule jsonb; v_cat text; v_count integer := 0; v_fallback integer := 0;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' or jsonb_array_length(p_rules) <> 4 then
    raise exception 'INVALID_RULES';
  end if;
  if (select count(distinct (r->>'category')) from jsonb_array_elements(p_rules) r) <> 4 then
    raise exception 'INVALID_RULES';
  end if;

  for v_rule in select * from jsonb_array_elements(p_rules) loop
    v_cat := v_rule->>'category';
    if v_cat is null or v_cat not in ('strong_gym', 'familia', 'amigo', 'comun') then
      raise exception 'INVALID_CATEGORY';
    end if;
    if (v_rule->>'sort_order') is null
       or (v_rule->>'sort_order')::integer not between 1 and 999 then
      raise exception 'INVALID_ORDER';
    end if;
    if coalesce((v_rule->>'is_fallback')::boolean, false) then
      v_fallback := v_fallback + 1;
      if v_cat <> 'comun' then raise exception 'INVALID_FALLBACK'; end if;
    end if;
    if coalesce((v_rule->>'requires_validity')::boolean, false)
       and coalesce((v_rule->>'forbids_validity')::boolean, false) then
      raise exception 'INVALID_VALIDITY_RULE';
    end if;
    if coalesce((v_rule->>'validity_days_min')::integer, 0) not between 0 and 3660 then
      raise exception 'INVALID_VALIDITY_DAYS';
    end if;
    if (v_rule->>'requires_purchase_window_days') is not null
       and (v_rule->>'requires_purchase_window_days')::integer not between 1 and 3650 then
      raise exception 'INVALID_PURCHASE_WINDOW';
    end if;
    if coalesce((v_rule->>'visits_min')::integer, 0) not between 0 and 1000 then
      raise exception 'INVALID_VISITS';
    end if;
    if coalesce((v_rule->>'visits_window_days')::integer, 30) not between 1 and 365 then
      raise exception 'INVALID_VISITS_WINDOW';
    end if;
    v_count := v_count + 1;
  end loop;

  if v_count <> 4 or v_fallback <> 1 then raise exception 'INVALID_RULES'; end if;

  for v_rule in select * from jsonb_array_elements(p_rules) loop
    update public.category_rules
       set sort_order = (v_rule->>'sort_order')::integer,
           is_active = coalesce((v_rule->>'is_active')::boolean, true),
           requires_validity = coalesce((v_rule->>'requires_validity')::boolean, false),
           forbids_validity = coalesce((v_rule->>'forbids_validity')::boolean, false),
           validity_days_min = coalesce((v_rule->>'validity_days_min')::integer, 0),
           requires_purchase_window_days = nullif(v_rule->>'requires_purchase_window_days', '')::integer,
           visits_min = coalesce((v_rule->>'visits_min')::integer, 0),
           visits_window_days = coalesce((v_rule->>'visits_window_days')::integer, 30),
           updated_at = now(),
           updated_by = auth.uid()
     where category = v_rule->>'category';
  end loop;

  insert into public.category_rules_history(rules, changed_by)
  select jsonb_agg(to_jsonb(r) order by r.sort_order, r.category), auth.uid()
  from public.category_rules r;

  return public.admin_category_rules();
end $$;
revoke all on function public.admin_save_category_rules(jsonb) from public, anon, authenticated;
grant execute on function public.admin_save_category_rules(jsonb) to authenticated;

-- 8. Directorio: filtra por categoría calculada cuando el filtro usa una de
--    las cuatro nuevas; mantiene los valores históricos de la etiqueta.
create or replace function public.crm_directory(p_search text default '', p_category text default '', p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb; v_calc boolean;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v_calc := coalesce(p_category, '') in ('strong_gym', 'familia', 'amigo', 'comun');
  select jsonb_build_object('total', (select count(*) from public.gym_clients c where
    (coalesce(p_category, '') = ''
      or (v_calc and coalesce(c.category_override, c.category_auto) = p_category)
      or (not v_calc and c.category = p_category))
    and (p_search = '' or c.full_name ilike '%' || p_search || '%' or coalesce(c.phone, '') ilike '%' || p_search || '%' or c.client_number::text = p_search)
    and not public.is_staff_profile(c.profile_id)),
    'rows', coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)) into result from (
    select c.*, p.name_es as plan_name,
      coalesce(c.category_override, c.category_auto) as category_calc,
      case when c.category_override is null then 'auto' else 'manual' end as category_source,
      (select count(*)::int from public.client_visits v where v.client_id = c.id and v.local_day >= (now() at time zone 'America/Managua')::date - 29) as visits_30,
      (select max(v.visited_at) from public.client_visits v where v.client_id = c.id) as last_visit,
      public.plan_validity_summary(c.id) as plan_validity
    from public.gym_clients c left join public.plans p on p.id = c.plan_id
    where (coalesce(p_category, '') = ''
      or (v_calc and coalesce(c.category_override, c.category_auto) = p_category)
      or (not v_calc and c.category = p_category))
      and (p_search = '' or c.full_name ilike '%' || p_search || '%' or coalesce(c.phone, '') ilike '%' || p_search || '%' or c.client_number::text = p_search)
      and not public.is_staff_profile(c.profile_id)
    order by c.full_name, c.id limit 30 offset greatest(0, least(coalesce(p_offset, 0), 1000000))
  ) r;
  return result;
end $$;
revoke all on function public.crm_directory(text, text, integer) from public, anon;
grant execute on function public.crm_directory(text, text, integer) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00071_directorio_categoria_en_vivo.sql
-- ═══════════════════════════════════════════════════════════

-- CLI-02: el directorio calcula la categoría cuando todavía no se guardó.
--
-- Problema que corrige: `client_category_apply()` deja `category_auto` guardada,
-- pero un cliente creado después del último recálculo no tiene ese valor. Su
-- fila mostraba la etiqueta histórica y no aparecía al filtrar por la categoría
-- real, aunque su vigencia fuera correcta. Ahora el directorio evalúa la
-- categoría en el momento solo para esas filas; el valor guardado manda.
--
-- Reversión: volver a la versión anterior de `crm_directory`; no se borran
-- datos ni se cambia ninguna columna.

create or replace function public.crm_directory(
  p_search text default '', p_category text default '', p_offset integer default 0
) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_today date := public.plan_local_today();
  v_calc boolean;
  result jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v_calc := coalesce(p_category, '') in ('strong_gym', 'familia', 'amigo', 'comun');

  with base as (
    select c.*, p.name_es as plan_name,
      coalesce(
        c.category_override,
        c.category_auto,
        public.client_category_eval(c.id, v_today)->>'category'
      ) as category_calc,
      case when c.category_override is null then 'auto' else 'manual' end as category_source,
      c.category_auto is not null as category_saved,
      (select count(*)::int from public.client_visits v
        where v.client_id = c.id and v.local_day >= v_today - 29) as visits_30,
      (select max(v.visited_at) from public.client_visits v where v.client_id = c.id) as last_visit,
      public.plan_validity_summary(c.id) as plan_validity
    from public.gym_clients c
    left join public.plans p on p.id = c.plan_id
    where not public.is_staff_profile(c.profile_id)
      and (p_search = ''
        or c.full_name ilike '%' || p_search || '%'
        or coalesce(c.phone, '') ilike '%' || p_search || '%'
        or c.client_number::text = p_search)
  ), filtered as (
    select * from base
    where coalesce(p_category, '') = ''
      or (v_calc and category_calc = p_category)
      or (not v_calc and category = p_category)
  ), page as (
    select * from filtered
    order by full_name, id
    limit 30 offset greatest(0, least(coalesce(p_offset, 0), 1000000))
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', coalesce((select jsonb_agg(to_jsonb(p) order by p.full_name, p.id) from page p), '[]'::jsonb)
  ) into result;

  return result;
end $$;
revoke all on function public.crm_directory(text, text, integer) from public, anon;
grant execute on function public.crm_directory(text, text, integer) to authenticated;

notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════
--  00072_grilla_horarios.sql
-- ═══════════════════════════════════════════════════════════

-- 00072 · Grilla semanal administrable (OP-05, primera etapa)
--
-- Problema: `generate_week_sessions()` armaba las sesiones desde una plantilla
-- fija escrita en SQL (solo Boxeo, martes y jueves). Para abrir Zumba u otra
-- disciplina no había forma de cargar su horario desde la aplicación: había
-- que editar código y migrar. Tampoco existía dónde ver ni corregir la grilla.
--
-- Decisión de esta etapa:
--   * La grilla pasa a ser DATOS: `class_schedule_slots` (una fila por
--     disciplina, día de la semana y hora), con sala, cupo, duración,
--     entrenador y vigencia opcional.
--   * `generate_week_sessions()` lee esa tabla; la plantilla fija deja de usarse.
--     La migración carga como semilla las nueve sesiones de Boxeo que ya
--     existían, así el calendario no cambia por sí solo.
--   * Solo administración con MFA edita, activa o anula horarios.
--   * Guardar un horario crea sus sesiones de las próximas semanas, sin
--     duplicar y sin tocar las que ya tienen reservas.
--   * Anular un horario es `is_active = false`: no se borra la fila ni las
--     sesiones ya creadas.
--   * Se rechazan choques de sala o de entrenador en el mismo día y horario.
--
-- Reversión segura: `create or replace` de `generate_week_sessions()` con la
-- versión de 00003 y quitar las funciones `admin_*` de esta migración. La tabla
-- puede quedarse: no la usa nada más y no borra datos.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.classes') is null
     or to_regclass('public.sessions') is null
     or to_regclass('public.coaches') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.generate_week_sessions(date)') is null then
    raise exception 'SCHEDULE_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. La grilla: una fila = una clase fija en un día y hora.
--    `day_of_week` sigue la convención que ya usaba la plantilla: 0 = lunes.
create table if not exists public.class_schedule_slots (
  id           uuid primary key default gen_random_uuid(),
  class_id     text not null references public.classes (id) on delete restrict,
  day_of_week  integer not null check (day_of_week between 0 and 6),
  start_time   time not null,
  duration_min integer not null check (duration_min between 10 and 180),
  capacity     integer not null check (capacity between 1 and 200),
  room         text not null default 'Salón principal'
               check (length(trim(room)) between 2 and 60),
  coach_id     text references public.coaches (id) on delete set null,
  valid_from   date,
  valid_to     date,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  updated_by   uuid references public.profiles (id) on delete set null,
  constraint class_schedule_slots_dates_chk
    check (valid_from is null or valid_to is null or valid_to >= valid_from)
);

create index if not exists class_schedule_slots_order_idx
  on public.class_schedule_slots (day_of_week, start_time) where is_active;

alter table public.class_schedule_slots enable row level security;
revoke all on public.class_schedule_slots from public, anon, authenticated;

-- 2. Semilla ANULADA en la plantilla: la grilla del gimnasio nuevo se
--    carga en el panel (Horarios y clases). No se hereda la grilla de
--    nadie: class_schedule_slots nace vacía.

-- 3. El generador de semana ahora lee la grilla. Misma firma y mismo permiso
--    que la versión anterior para no romper a quien ya lo llamaba.
create or replace function public.generate_week_sessions(p_monday date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer := 0;
  v_slot record;
  v_start timestamptz;
  v_coach text;
  v_duration integer;
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'staff')
  ) and auth.uid() is not null then
    raise exception 'AUTH: sólo el staff puede generar horarios';
  end if;

  for v_slot in
    select s.*, c.slug, c.duration_min as class_duration, c.capacity as class_capacity
    from public.class_schedule_slots s
    join public.classes c on c.id = s.class_id and c.is_active
    where s.is_active
      and (s.valid_from is null or s.valid_from <= p_monday + s.day_of_week)
      and (s.valid_to is null or s.valid_to >= p_monday + s.day_of_week)
    order by s.day_of_week, s.start_time, c.sort_order
  loop
    -- `fecha + hora` sin zona, interpretada como hora local de Managua.
    v_start := ((p_monday + v_slot.day_of_week) + v_slot.start_time)
               at time zone 'America/Managua';

    if exists (
      select 1 from public.sessions
      where class_id = v_slot.class_id and starts_at = v_start
    ) then
      continue;
    end if;

    v_coach := v_slot.coach_id;
    if v_coach is null then
      select id into v_coach
      from public.coaches
      where is_active and v_slot.slug = any (specialties)
      order by id
      limit 1;
    end if;

    v_duration := coalesce(v_slot.duration_min, v_slot.class_duration);

    insert into public.sessions (class_id, coach_id, starts_at, ends_at, capacity, room)
    values (
      v_slot.class_id,
      v_coach,
      v_start,
      v_start + make_interval(mins => v_duration),
      coalesce(v_slot.capacity, v_slot.class_capacity),
      coalesce(nullif(trim(v_slot.room), ''), 'Salón principal')
    );

    v_inserted := v_inserted + 1;
  end loop;

  return v_inserted;
end $$;

revoke all on function public.generate_week_sessions(date) from public, anon;
grant execute on function public.generate_week_sessions(date) to authenticated;

-- 4. Rellenar las próximas semanas con la grilla vigente. Es idempotente:
--    nunca duplica una sesión que ya existe ni toca las reservas.
create or replace function public.schedule_generate_weeks(p_weeks integer default 4)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.plan_local_today();
  v_monday date := date_trunc('week', v_today::timestamp)::date;
  v_offset integer;
  v_created integer := 0;
begin
  if p_weeks is null or p_weeks < 1 or p_weeks > 8 then
    raise exception 'INVALID_WEEKS';
  end if;

  perform pg_advisory_xact_lock(hashtext('strong_gym_schedule_generate'));

  for v_offset in 0..p_weeks - 1 loop
    v_created := v_created + public.generate_week_sessions(v_monday + (v_offset * 7));
  end loop;

  return v_created;
end $$;
revoke all on function public.schedule_generate_weeks(integer) from public, anon, authenticated;

-- 5. Pantalla de grilla.
create or replace function public.admin_schedule_board()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.plan_local_today();
  v_monday date := date_trunc('week', v_today::timestamp)::date;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  return jsonb_build_object(
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'class_id', s.class_id,
        'class_name', c.name_es,
        'class_slug', c.slug,
        'class_active', c.is_active,
        'day_of_week', s.day_of_week,
        'start_time', to_char(s.start_time, 'HH24:MI'),
        'duration_min', s.duration_min,
        'capacity', s.capacity,
        'room', s.room,
        'coach_id', s.coach_id,
        'coach_name', co.name,
        'is_active', s.is_active
      ) order by s.day_of_week, s.start_time, c.sort_order)
      from public.class_schedule_slots s
      join public.classes c on c.id = s.class_id
      left join public.coaches co on co.id = s.coach_id
    ), '[]'::jsonb),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name_es, 'active', c.is_active)
        order by c.sort_order, c.id)
      from public.classes c
    ), '[]'::jsonb),
    'coaches', coalesce((
      select jsonb_agg(jsonb_build_object('id', co.id, 'name', co.name, 'specialties', co.specialties)
        order by co.id)
      from public.coaches co
      where co.is_active
    ), '[]'::jsonb),
    'room_hint', 'Usá la misma sala para que el choque de horario se detecte.',
    'weeks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'week_start', (v_monday + (w * 7)),
        'scheduled', (
          select count(*)::int from public.sessions s
          where s.status = 'scheduled'
            and s.starts_at >= ((v_monday + (w * 7)) + time '00:00') at time zone 'America/Managua'
            and s.starts_at < ((v_monday + ((w + 1) * 7)) + time '00:00') at time zone 'America/Managua'
        )
      ) order by w)
      from generate_series(0, 3) as w
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.admin_schedule_board() from public, anon, authenticated;
grant execute on function public.admin_schedule_board() to authenticated;

-- 6. Guardar un horario (crear o editar). Rechaza choques de sala o entrenador.
create or replace function public.admin_save_schedule_slot(
  p_id uuid,
  p_class_id text,
  p_day integer,
  p_start text,
  p_duration integer,
  p_capacity integer,
  p_room text,
  p_coach text,
  p_active boolean default true,
  p_weeks integer default 4
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_class public.classes;
  v_start time;
  v_room text := trim(coalesce(p_room, ''));
  v_id uuid;
  v_conflict record;
  v_created integer := 0;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_class_id is null then raise exception 'INVALID_CLASS'; end if;
  select * into v_class from public.classes where id = p_class_id;
  if not found then raise exception 'INVALID_CLASS'; end if;
  if p_day is null or p_day not between 0 and 6 then raise exception 'INVALID_DAY'; end if;
  begin
    v_start := coalesce(nullif(trim(coalesce(p_start, '')), ''), '18:00')::time;
  exception when others then
    raise exception 'INVALID_TIME';
  end;
  if p_duration is null or p_duration not between 10 and 180 then raise exception 'INVALID_DURATION'; end if;
  if p_capacity is null or p_capacity not between 1 and 200 then raise exception 'INVALID_CAPACITY'; end if;
  if length(v_room) not between 2 and 60 then raise exception 'INVALID_ROOM'; end if;
  if p_coach is not null and not exists (
    select 1 from public.coaches where id = p_coach and is_active
  ) then
    raise exception 'INVALID_COACH';
  end if;

  -- Choque: misma sala o mismo entrenador, mismo día, horarios que se pisan.
  select s.id, s.start_time, s.duration_min, s.room, s.coach_id into v_conflict
  from public.class_schedule_slots s
  where s.is_active
    and s.day_of_week = p_day
    and (p_id is null or s.id <> p_id)
    and (s.room = v_room or (p_coach is not null and s.coach_id = p_coach))
    and v_start < (s.start_time + make_interval(mins => s.duration_min))
    and (v_start + make_interval(mins => p_duration)) > s.start_time
  limit 1;
  if found then
    raise exception 'SCHEDULE_CONFLICT';
  end if;

  perform pg_advisory_xact_lock(hashtext('strong_gym_admin_schedule'));

  if p_id is null then
    insert into public.class_schedule_slots
      (class_id, day_of_week, start_time, duration_min, capacity, room, coach_id, is_active, updated_by)
    values
      (p_class_id, p_day, v_start, p_duration, p_capacity, v_room, p_coach, coalesce(p_active, true), auth.uid())
    returning id into v_id;
  else
    update public.class_schedule_slots
       set class_id = p_class_id,
           day_of_week = p_day,
           start_time = v_start,
           duration_min = p_duration,
           capacity = p_capacity,
           room = v_room,
           coach_id = p_coach,
           is_active = coalesce(p_active, is_active),
           updated_at = now(),
           updated_by = auth.uid()
     where id = p_id
     returning id into v_id;
    if not found then raise exception 'NOT_FOUND'; end if;
  end if;

  if coalesce(p_active, true) then
    v_created := public.schedule_generate_weeks(coalesce(p_weeks, 4));
  end if;

  return public.admin_schedule_board() || jsonb_build_object('created_sessions', v_created, 'slot_id', v_id);
end $$;
revoke all on function public.admin_save_schedule_slot(uuid,text,integer,text,integer,integer,text,text,boolean,integer)
  from public, anon, authenticated;
grant execute on function public.admin_save_schedule_slot(uuid,text,integer,text,integer,integer,text,text,boolean,integer)
  to authenticated;

-- 7. Anular o reactivar un horario. No borra la fila ni las sesiones creadas.
create or replace function public.admin_set_schedule_slot_active(
  p_id uuid, p_active boolean, p_weeks integer default 4
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_created integer := 0;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_id is null or p_active is null then raise exception 'INVALID_REQUEST'; end if;

  update public.class_schedule_slots
     set is_active = p_active, updated_at = now(), updated_by = auth.uid()
   where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  -- Reactivar vuelve a crear las sesiones que falten; anular no cancela las
  -- que ya existen, para no quitarle la clase a quien ya reservó.
  if p_active then
    v_created := public.schedule_generate_weeks(coalesce(p_weeks, 4));
  end if;

  return public.admin_schedule_board() || jsonb_build_object('created_sessions', v_created);
end $$;
revoke all on function public.admin_set_schedule_slot_active(uuid, boolean, integer)
  from public, anon, authenticated;
grant execute on function public.admin_set_schedule_slot_active(uuid, boolean, integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00073_grilla_nombre_entrenador.sql
-- ═══════════════════════════════════════════════════════════

-- 00073 · La grilla lee el nombre del entrenador del esquema real
--
-- Problema detectado al probar la pantalla en producción: la tabla `coaches`
-- productiva no tiene la columna `name` (nació con `full_name`), así que
-- `admin_schedule_board()` fallaba con «column co.name does not exist» y la
-- pantalla mostraba «No pudimos confirmar estos datos».
--
-- Corrección: el nombre se lee con `to_jsonb(co)`, que no depende de que la
-- columna exista con un nombre u otro. Se prefiere `full_name` y, si no hay,
-- se usa `name`; en ningún caso se inventa un nombre: si ambos faltan se
-- devuelve el identificador.
--
-- Reversión segura: volver a la definición de 00072. No se tocan datos ni
-- columnas.

begin;
set local lock_timeout = '5s';

create or replace function public.admin_schedule_board()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.plan_local_today();
  v_monday date := date_trunc('week', v_today::timestamp)::date;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  return jsonb_build_object(
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'class_id', s.class_id,
        'class_name', c.name_es,
        'class_slug', c.slug,
        'class_active', c.is_active,
        'day_of_week', s.day_of_week,
        'start_time', to_char(s.start_time, 'HH24:MI'),
        'duration_min', s.duration_min,
        'capacity', s.capacity,
        'room', s.room,
        'coach_id', s.coach_id,
        -- `coaches` no tiene las mismas columnas en todas las bases: la
        -- productiva usa `full_name`, la de las migraciones usa `name`.
        'coach_name', coalesce(
          nullif(to_jsonb(co) ->> 'full_name', ''),
          nullif(to_jsonb(co) ->> 'name', ''),
          s.coach_id
        ),
        'is_active', s.is_active
      ) order by s.day_of_week, s.start_time, c.sort_order)
      from public.class_schedule_slots s
      join public.classes c on c.id = s.class_id
      left join public.coaches co on co.id = s.coach_id
    ), '[]'::jsonb),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name_es, 'active', c.is_active)
        order by c.sort_order, c.id)
      from public.classes c
    ), '[]'::jsonb),
    'coaches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', co.id,
        'name', coalesce(
          nullif(to_jsonb(co) ->> 'full_name', ''),
          nullif(to_jsonb(co) ->> 'name', ''),
          co.id
        ),
        'specialties', to_jsonb(co) -> 'specialties'
      ) order by co.id)
      from public.coaches co
      where co.is_active
    ), '[]'::jsonb),
    'room_hint', 'Usá la misma sala para que el choque de horario se detecte.',
    'weeks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'week_start', (v_monday + (w * 7)),
        'scheduled', (
          select count(*)::int from public.sessions s
          where s.status = 'scheduled'
            and s.starts_at >= ((v_monday + (w * 7)) + time '00:00') at time zone 'America/Managua'
            and s.starts_at < ((v_monday + ((w + 1) * 7)) + time '00:00') at time zone 'America/Managua'
        )
      ) order by w)
      from generate_series(0, 3) as w
    ), '[]'::jsonb)
  );
end $$;

revoke all on function public.admin_schedule_board() from public, anon, authenticated;
grant execute on function public.admin_schedule_board() to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00074_generar_sesiones_preview.sql
-- ═══════════════════════════════════════════════════════════

-- 00074 · Generar sesiones con previsualización (OP-05, segunda etapa)
--
-- Problema: hasta ahora la grilla generaba sesiones de forma implícita —
-- cuatro semanas al guardar un horario y lo mismo desde el botón de
-- Operación— sin decir antes qué se iba a crear ni qué se iba a omitir. Si
-- alguien cargaba un horario, no sabía si su clase entraba al calendario o
-- quedaba afuera por duplicado o por choque.
--
-- Decisión de esta etapa:
--   * El plan de generación se calcula aparte y se puede mirar sin escribir
--     nada: `admin_preview_schedule(desde, semanas)`.
--   * Se puede generar para una fecha de inicio elegida y de 1 a 8 semanas:
--     `admin_apply_schedule(desde, semanas)`. Solo inserta lo que el plan
--     marcó como "crear".
--   * Cada clase candidata queda clasificada con un motivo legible:
--     se crea, ya existe, choca la sala, choca el entrenador, ya pasó o la
--     disciplina está desactivada.
--   * No se borra ni se modifica ninguna sesión existente ni ninguna reserva.
--     Generar dos veces seguidas no duplica: la segunda no crea nada.
--   * Solo administración con MFA. Usa el mismo cerrojo que
--     `schedule_generate_weeks()` para que dos generaciones simultáneas no se
--     pisen.
--
-- Reversión segura: eliminar `admin_preview_schedule`, `admin_apply_schedule`
-- y `_schedule_plan`. No se toca ninguna tabla ni datos.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.class_schedule_slots') is null
     or to_regclass('public.sessions') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'SCHEDULE_PLAN_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. El plan: qué pasaría si se generara el rango pedido. No escribe nada.
--    `p_from` puede ser cualquier día; se recorre esa fecha y las semanas
--    siguientes, y cada horario cae en su día de la semana.
create or replace function public._schedule_plan(p_from date, p_weeks integer)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with rango as (
    select p_from as desde, (p_from + (p_weeks * 7) - 1) as hasta
  ),
  dias as (
    select g::date as dia
    from rango, generate_series(rango.desde::timestamp, rango.hasta::timestamp, interval '1 day') g
  ),
  candidatas as (
    select
      d.dia,
      s.id as slot_id,
      s.day_of_week,
      to_char(s.start_time, 'HH24:MI') as hora,
      s.class_id,
      c.name_es as class_name,
      c.is_active as class_active,
      c.sort_order,
      s.room,
      s.coach_id,
      coalesce(
        nullif(to_jsonb(co) ->> 'full_name', ''),
        nullif(to_jsonb(co) ->> 'name', ''),
        s.coach_id
      ) as coach_name,
      ((d.dia + s.start_time) at time zone 'America/Managua') as starts_at,
      ((d.dia + s.start_time) at time zone 'America/Managua')
        + make_interval(mins => s.duration_min) as ends_at
    from dias d
    join public.class_schedule_slots s
      on s.day_of_week = ((extract(dow from d.dia)::integer + 6) % 7)
     and s.is_active
     and (s.valid_from is null or s.valid_from <= d.dia)
     and (s.valid_to is null or s.valid_to >= d.dia)
    join public.classes c on c.id = s.class_id
    left join public.coaches co on co.id = s.coach_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'date', to_char(x.dia, 'YYYY-MM-DD'),
      'slot_id', x.slot_id,
      'day_of_week', x.day_of_week,
      'start_time', x.hora,
      'class_id', x.class_id,
      'class_name', x.class_name,
      'room', x.room,
      'coach_id', x.coach_id,
      'coach_name', x.coach_name,
      'status', x.estado
    )
    order by x.dia, x.starts_at, x.sort_order, x.class_id
  ), '[]'::jsonb)
  from (
    select
      cc.*,
      case
        when not cc.class_active then 'inactive'
        when cc.starts_at <= now() then 'past'
        when exists (
          select 1 from public.sessions s
           where s.class_id = cc.class_id and s.starts_at = cc.starts_at
        ) then 'duplicate'
        when exists (
          select 1 from public.sessions s
           where s.status = 'scheduled'
             and s.room = cc.room
             and s.starts_at < cc.ends_at
             and s.ends_at > cc.starts_at
        ) then 'room_conflict'
        when cc.coach_id is not null and exists (
          select 1 from public.sessions s
           where s.status = 'scheduled'
             and s.coach_id = cc.coach_id
             and s.starts_at < cc.ends_at
             and s.ends_at > cc.starts_at
        ) then 'coach_conflict'
        else 'create'
      end as estado
    from candidatas cc
  ) x
$$;

revoke all on function public._schedule_plan(date, integer)
  from public, anon, authenticated;

-- 2. Mirar el plan sin escribir nada.
create or replace function public.admin_preview_schedule(
  p_from date default null,
  p_weeks integer default 4
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_from date;
  v_plan jsonb;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_weeks is null or p_weeks < 1 or p_weeks > 8 then
    raise exception 'INVALID_WEEKS';
  end if;

  v_from := coalesce(
    p_from,
    date_trunc('week', public.plan_local_today()::timestamp)::date
  );
  v_plan := public._schedule_plan(v_from, p_weeks);

  return jsonb_build_object(
    'from', to_char(v_from, 'YYYY-MM-DD'),
    'to', to_char(v_from + (p_weeks * 7) - 1, 'YYYY-MM-DD'),
    'weeks', p_weeks,
    'created', 0,
    'totals', jsonb_build_object(
      'create', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'create'),
      'duplicate', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'duplicate'),
      'room_conflict', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'room_conflict'),
      'coach_conflict', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'coach_conflict'),
      'past', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'past'),
      'inactive', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'inactive')
    ),
    'items', v_plan
  );
end $$;

revoke all on function public.admin_preview_schedule(date, integer)
  from public, anon, authenticated;
grant execute on function public.admin_preview_schedule(date, integer)
  to authenticated;

-- 3. Generar exactamente lo que el plan marcó como "crear".
create or replace function public.admin_apply_schedule(
  p_from date default null,
  p_weeks integer default 4
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_from date;
  v_plan jsonb;
  v_item jsonb;
  v_created integer := 0;
  v_preview jsonb;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_weeks is null or p_weeks < 1 or p_weeks > 8 then
    raise exception 'INVALID_WEEKS';
  end if;

  v_from := coalesce(
    p_from,
    date_trunc('week', public.plan_local_today()::timestamp)::date
  );

  -- Mismo cerrojo que `schedule_generate_weeks()`: dos generaciones
  -- simultáneas no pueden crear la misma sesión dos veces.
  perform pg_advisory_xact_lock(hashtext('strong_gym_schedule_generate'));

  v_plan := public._schedule_plan(v_from, p_weeks);

  for v_item in
    select value from jsonb_array_elements(v_plan)
     where value ->> 'status' = 'create'
     order by value ->> 'date', value ->> 'start_time'
  loop
    -- Se inserta a partir del horario exacto del plan (`slot_id`), así no se
    -- repite la búsqueda ni se confunde un horario con otro parecido.
    insert into public.sessions (class_id, coach_id, starts_at, ends_at, capacity, room)
    select
      s.class_id,
      s.coach_id,
      ((v_item ->> 'date')::date + s.start_time) at time zone 'America/Managua',
      (((v_item ->> 'date')::date + s.start_time) at time zone 'America/Managua')
        + make_interval(mins => s.duration_min),
      s.capacity,
      s.room
    from public.class_schedule_slots s
    where s.id = (v_item ->> 'slot_id')::uuid
      and not exists (
        select 1 from public.sessions x
         where x.class_id = s.class_id
           and x.starts_at = ((v_item ->> 'date')::date + s.start_time)
                              at time zone 'America/Managua'
      );

    if found then
      v_created := v_created + 1;
    end if;
  end loop;

  v_preview := public.admin_preview_schedule(v_from, p_weeks);

  return v_preview || jsonb_build_object(
    'created', v_created,
    'planned', (select count(*)::int
                  from jsonb_array_elements(v_plan) i
                 where i ->> 'status' = 'create')
  );
end $$;

revoke all on function public.admin_apply_schedule(date, integer)
  from public, anon, authenticated;
grant execute on function public.admin_apply_schedule(date, integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00075_bloqueos_calendario.sql
-- ═══════════════════════════════════════════════════════════

-- 00075 · Bloqueos y cierres del calendario (OP-05, tercera etapa)
--
-- Problema: si el gimnasio cierra por feriado, una disciplina para vacaciones
-- o un entrenador se enferma, no había forma de decirlo en la aplicación. Las
-- sesiones seguían programadas, el generador las volvía a crear y la gente
-- quedaba con una reserva para una clase que no va a existir.
--
-- Decisión de esta etapa:
--   * `schedule_blocks` guarda el cierre o bloqueo: todo el gimnasio, una
--     disciplina o un entrenador, entre dos fechas y horas, con motivo
--     —feriado, vacaciones, enfermedad, mantenimiento u otro— y una nota.
--   * Antes de aplicar se ve qué sesiones y cuántas reservas se tocan. Si hay
--     reservas, hace falta confirmar explícitamente.
--   * Aplicar cancela las sesiones afectadas y deja las reservas canceladas
--     con el motivo. No se borra nada: la sesión y la reserva quedan con su
--     historial.
--   * Si el bloqueo es de un entrenador y se elige un sustituto, en vez de
--     cancelar se reasigna la sesión al sustituto.
--   * El generador omite lo bloqueado: `_schedule_plan()` lo marca como
--     `blocked` y `generate_week_sessions()` no lo crea.
--   * Levantar un bloqueo lo deja `is_active = false`; no resucita sesiones
--     canceladas. Volver a programarlas es una acción explícita.
--
-- Reversión segura: eliminar las funciones `admin_*` y `_session_blocked` de
-- esta migración, restaurar `generate_week_sessions()` de 00072 y desmarcar
-- `schedule_blocks`. Las columnas nuevas de `bookings` son opcionales y no
-- rompen nada si quedan vacías.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.classes') is null
     or to_regclass('public.sessions') is null
     or to_regclass('public.bookings') is null
     or to_regclass('public.coaches') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'SCHEDULE_BLOCK_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. El motivo con el que se canceló una reserva queda escrito en la reserva.
alter table public.bookings
  add column if not exists cancel_reason text,
  add column if not exists cancelled_by uuid references public.profiles (id) on delete set null;

-- 2. La tabla de bloqueos.
create table if not exists public.schedule_blocks (
  id                  uuid primary key default gen_random_uuid(),
  scope               text not null check (scope in ('gym', 'class', 'coach')),
  class_id            text references public.classes (id) on delete restrict,
  coach_id            text references public.coaches (id) on delete restrict,
  starts_at           timestamptz not null,
  ends_at             timestamptz not null,
  reason_kind         text not null
                      check (reason_kind in ('holiday', 'vacation', 'sick', 'maintenance', 'other')),
  reason              text not null check (length(trim(reason)) between 3 and 200),
  substitute_coach_id text references public.coaches (id) on delete set null,
  is_active           boolean not null default true,
  created_by          uuid references public.profiles (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint schedule_blocks_range_chk check (ends_at > starts_at),
  constraint schedule_blocks_scope_chk check (
    (scope = 'gym' and class_id is null and coach_id is null)
    or (scope = 'class' and class_id is not null and coach_id is null)
    or (scope = 'coach' and coach_id is not null and class_id is null)
  ),
  constraint schedule_blocks_substitute_chk check (
    substitute_coach_id is null or scope = 'coach'
  )
);

create index if not exists schedule_blocks_range_idx
  on public.schedule_blocks (starts_at, ends_at) where is_active;

-- Un mismo bloqueo no se carga dos veces; editar es otra cosa.
create unique index if not exists schedule_blocks_unique_idx
  on public.schedule_blocks (
    scope,
    coalesce(class_id, ''),
    coalesce(coach_id, ''),
    starts_at,
    ends_at
  )
  where is_active;

alter table public.schedule_blocks enable row level security;
revoke all on public.schedule_blocks from public, anon, authenticated;

-- 3. ¿Esta clase, con este entrenador y en este horario, cae en un bloqueo?
create or replace function public._session_blocked(
  p_class_id text,
  p_coach_id text,
  p_starts_at timestamptz,
  p_ends_at timestamptz
) returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.schedule_blocks b
     where b.is_active
       and b.starts_at < p_ends_at
       and b.ends_at > p_starts_at
       and (
         b.scope = 'gym'
         or (b.scope = 'class' and b.class_id = p_class_id)
         or (b.scope = 'coach' and p_coach_id is not null and b.coach_id = p_coach_id)
       )
  )
$$;

revoke all on function public._session_blocked(text, text, timestamptz, timestamptz)
  from public, anon, authenticated;

-- 4. El generador deja de crear sesiones bloqueadas.
create or replace function public.generate_week_sessions(p_monday date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer := 0;
  v_slot record;
  v_start timestamptz;
  v_coach text;
  v_duration integer;
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'staff')
  ) and auth.uid() is not null then
    raise exception 'AUTH: sólo el staff puede generar horarios';
  end if;

  for v_slot in
    select s.*, c.slug, c.duration_min as class_duration, c.capacity as class_capacity
    from public.class_schedule_slots s
    join public.classes c on c.id = s.class_id and c.is_active
    where s.is_active
      and (s.valid_from is null or s.valid_from <= p_monday + s.day_of_week)
      and (s.valid_to is null or s.valid_to >= p_monday + s.day_of_week)
    order by s.day_of_week, s.start_time, c.sort_order
  loop
    -- `fecha + hora` sin zona, interpretada como hora local de Managua.
    v_start := ((p_monday + v_slot.day_of_week) + v_slot.start_time)
               at time zone 'America/Managua';

    if exists (
      select 1 from public.sessions
      where class_id = v_slot.class_id and starts_at = v_start
    ) then
      continue;
    end if;

    v_coach := v_slot.coach_id;
    if v_coach is null then
      select id into v_coach
      from public.coaches
      where is_active and v_slot.slug = any (specialties)
      order by id
      limit 1;
    end if;

    v_duration := coalesce(v_slot.duration_min, v_slot.class_duration);

    -- Lo bloqueado no se programa: feriado, cierre, vacaciones o enfermedad.
    if public._session_blocked(
         v_slot.class_id,
         v_coach,
         v_start,
         v_start + make_interval(mins => v_duration)
       ) then
      continue;
    end if;

    insert into public.sessions (class_id, coach_id, starts_at, ends_at, capacity, room)
    values (
      v_slot.class_id,
      v_coach,
      v_start,
      v_start + make_interval(mins => v_duration),
      coalesce(v_slot.capacity, v_slot.class_capacity),
      coalesce(nullif(trim(v_slot.room), ''), 'Salón principal')
    );

    v_inserted := v_inserted + 1;
  end loop;

  return v_inserted;
end $$;

revoke all on function public.generate_week_sessions(date) from public, anon;
grant execute on function public.generate_week_sessions(date) to authenticated;

-- 5. El plan de generación también distingue lo bloqueado.
create or replace function public._schedule_plan(p_from date, p_weeks integer)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with rango as (
    select p_from as desde, (p_from + (p_weeks * 7) - 1) as hasta
  ),
  dias as (
    select g::date as dia
    from rango, generate_series(rango.desde::timestamp, rango.hasta::timestamp, interval '1 day') g
  ),
  candidatas as (
    select
      d.dia,
      s.id as slot_id,
      s.day_of_week,
      to_char(s.start_time, 'HH24:MI') as hora,
      s.class_id,
      c.name_es as class_name,
      c.is_active as class_active,
      c.sort_order,
      s.room,
      s.coach_id,
      coalesce(
        nullif(to_jsonb(co) ->> 'full_name', ''),
        nullif(to_jsonb(co) ->> 'name', ''),
        s.coach_id
      ) as coach_name,
      ((d.dia + s.start_time) at time zone 'America/Managua') as starts_at,
      ((d.dia + s.start_time) at time zone 'America/Managua')
        + make_interval(mins => s.duration_min) as ends_at
    from dias d
    join public.class_schedule_slots s
      on s.day_of_week = ((extract(dow from d.dia)::integer + 6) % 7)
     and s.is_active
     and (s.valid_from is null or s.valid_from <= d.dia)
     and (s.valid_to is null or s.valid_to >= d.dia)
    join public.classes c on c.id = s.class_id
    left join public.coaches co on co.id = s.coach_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'date', to_char(x.dia, 'YYYY-MM-DD'),
      'slot_id', x.slot_id,
      'day_of_week', x.day_of_week,
      'start_time', x.hora,
      'class_id', x.class_id,
      'class_name', x.class_name,
      'room', x.room,
      'coach_id', x.coach_id,
      'coach_name', x.coach_name,
      'status', x.estado
    )
    order by x.dia, x.starts_at, x.sort_order, x.class_id
  ), '[]'::jsonb)
  from (
    select
      cc.*,
      case
        when not cc.class_active then 'inactive'
        when cc.starts_at <= now() then 'past'
        when public._session_blocked(cc.class_id, cc.coach_id, cc.starts_at, cc.ends_at)
          then 'blocked'
        when exists (
          select 1 from public.sessions s
           where s.class_id = cc.class_id and s.starts_at = cc.starts_at
        ) then 'duplicate'
        when exists (
          select 1 from public.sessions s
           where s.status = 'scheduled'
             and s.room = cc.room
             and s.starts_at < cc.ends_at
             and s.ends_at > cc.starts_at
        ) then 'room_conflict'
        when cc.coach_id is not null and exists (
          select 1 from public.sessions s
           where s.status = 'scheduled'
             and s.coach_id = cc.coach_id
             and s.starts_at < cc.ends_at
             and s.ends_at > cc.starts_at
        ) then 'coach_conflict'
        else 'create'
      end as estado
    from candidatas cc
  ) x
$$;

revoke all on function public._schedule_plan(date, integer)
  from public, anon, authenticated;

-- 6. Previsualizar y aplicar comparten el total de "bloqueado".
create or replace function public.admin_preview_schedule(
  p_from date default null,
  p_weeks integer default 4
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_from date;
  v_plan jsonb;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_weeks is null or p_weeks < 1 or p_weeks > 8 then
    raise exception 'INVALID_WEEKS';
  end if;

  v_from := coalesce(
    p_from,
    date_trunc('week', public.plan_local_today()::timestamp)::date
  );
  v_plan := public._schedule_plan(v_from, p_weeks);

  return jsonb_build_object(
    'from', to_char(v_from, 'YYYY-MM-DD'),
    'to', to_char(v_from + (p_weeks * 7) - 1, 'YYYY-MM-DD'),
    'weeks', p_weeks,
    'created', 0,
    'totals', jsonb_build_object(
      'create', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'create'),
      'duplicate', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'duplicate'),
      'room_conflict', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'room_conflict'),
      'coach_conflict', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'coach_conflict'),
      'blocked', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'blocked'),
      'past', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'past'),
      'inactive', (select count(*)::int from jsonb_array_elements(v_plan) i where i ->> 'status' = 'inactive')
    ),
    'items', v_plan
  );
end $$;

revoke all on function public.admin_preview_schedule(date, integer)
  from public, anon, authenticated;
grant execute on function public.admin_preview_schedule(date, integer)
  to authenticated;

-- 7. Lo que toca un bloqueo, sin escribir nada.
create or replace function public._schedule_block_impact(
  p_scope text,
  p_class_id text,
  p_coach_id text,
  p_starts timestamptz,
  p_ends timestamptz,
  p_substitute text
) returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with afectadas as (
    select
      s.id,
      s.class_id,
      c.name_es as class_name,
      s.starts_at,
      s.room,
      s.coach_id,
      coalesce(
        nullif(to_jsonb(co) ->> 'full_name', ''),
        nullif(to_jsonb(co) ->> 'name', ''),
        s.coach_id
      ) as coach_name,
      (
        select count(*)::int from public.bookings b
         where b.session_id = s.id and b.status in ('confirmed', 'attended')
      ) as bookings
    from public.sessions s
    join public.classes c on c.id = s.class_id
    left join public.coaches co on co.id = s.coach_id
    where s.status = 'scheduled'
      and s.starts_at < p_ends
      and s.ends_at > p_starts
      and (
        p_scope = 'gym'
        or (p_scope = 'class' and s.class_id = p_class_id)
        or (p_scope = 'coach' and s.coach_id = p_coach_id)
      )
  )
  select jsonb_build_object(
    'sessions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'class_id', a.class_id,
        'class_name', a.class_name,
        'starts_at', a.starts_at,
        'room', a.room,
        'coach_id', a.coach_id,
        'coach_name', a.coach_name,
        'bookings', a.bookings
      ) order by a.starts_at)
      from afectadas a
    ), '[]'::jsonb),
    'session_count', (select count(*)::int from afectadas),
    'booking_count', (select coalesce(sum(bookings), 0)::int from afectadas),
    'action', case when p_substitute is not null then 'reassign' else 'cancel' end
  )
$$;

revoke all on function public._schedule_block_impact(text, text, text, timestamptz, timestamptz, text)
  from public, anon, authenticated;

-- 8. Ver qué tocaría un bloqueo antes de cargarlo.
create or replace function public.admin_preview_schedule_block(
  p_scope text,
  p_class_id text,
  p_coach_id text,
  p_starts text,
  p_ends text,
  p_substitute text default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_starts timestamptz;
  v_ends timestamptz;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_scope is null or p_scope not in ('gym', 'class', 'coach') then
    raise exception 'INVALID_SCOPE';
  end if;
  if p_scope = 'class' and not exists (
    select 1 from public.classes where id = p_class_id
  ) then
    raise exception 'INVALID_CLASS';
  end if;
  if p_scope = 'coach' and not exists (
    select 1 from public.coaches where id = p_coach_id
  ) then
    raise exception 'INVALID_COACH';
  end if;
  begin
    v_starts := (p_starts::timestamp) at time zone 'America/Managua';
    v_ends := (p_ends::timestamp) at time zone 'America/Managua';
  exception when others then
    raise exception 'INVALID_RANGE';
  end;
  if v_ends <= v_starts then raise exception 'INVALID_RANGE'; end if;
  if p_scope <> 'coach' and p_substitute is not null then
    raise exception 'INVALID_SUBSTITUTE';
  end if;
  if p_substitute is not null then
    if not exists (select 1 from public.coaches where id = p_substitute and is_active) then
      raise exception 'INVALID_SUBSTITUTE';
    end if;
    if p_substitute = p_coach_id then raise exception 'INVALID_SUBSTITUTE'; end if;
  end if;

  return public._schedule_block_impact(
    p_scope, p_class_id, p_coach_id, v_starts, v_ends, p_substitute
  ) || jsonb_build_object(
    'scope', p_scope,
    'class_id', p_class_id,
    'coach_id', p_coach_id,
    'starts_at', v_starts,
    'ends_at', v_ends,
    'substitute_coach_id', p_substitute
  );
end $$;

revoke all on function public.admin_preview_schedule_block(text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.admin_preview_schedule_block(text, text, text, text, text, text)
  to authenticated;

-- 9. Lista de bloqueos con lo que afectan hoy.
create or replace function public.admin_schedule_blocks()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id,
      'scope', b.scope,
      'class_id', b.class_id,
      'class_name', c.name_es,
      'coach_id', b.coach_id,
      'coach_name', coalesce(
        nullif(to_jsonb(co) ->> 'full_name', ''),
        nullif(to_jsonb(co) ->> 'name', ''),
        b.coach_id
      ),
      'starts_at', b.starts_at,
      'ends_at', b.ends_at,
      'reason_kind', b.reason_kind,
      'reason', b.reason,
      'substitute_coach_id', b.substitute_coach_id,
      'substitute_coach_name', coalesce(
        nullif(to_jsonb(su) ->> 'full_name', ''),
        nullif(to_jsonb(su) ->> 'name', ''),
        b.substitute_coach_id
      ),
      'is_active', b.is_active,
      'cancelled_sessions', (
        select count(*)::int from public.sessions s
         where s.status = 'cancelled'
           and s.starts_at < b.ends_at
           and s.ends_at > b.starts_at
           and (
             b.scope = 'gym'
             or (b.scope = 'class' and s.class_id = b.class_id)
             or (b.scope = 'coach' and s.coach_id = b.coach_id)
           )
      )
    ) order by b.is_active desc, b.starts_at desc)
    from public.schedule_blocks b
    left join public.classes c on c.id = b.class_id
    left join public.coaches co on co.id = b.coach_id
    left join public.coaches su on su.id = b.substitute_coach_id
  ), '[]'::jsonb);
end $$;

revoke all on function public.admin_schedule_blocks()
  from public, anon, authenticated;
grant execute on function public.admin_schedule_blocks()
  to authenticated;

-- 10. Guardar un bloqueo y aplicarlo a las sesiones.
create or replace function public.admin_save_schedule_block(
  p_id uuid,
  p_scope text,
  p_class_id text,
  p_coach_id text,
  p_starts text,
  p_ends text,
  p_reason_kind text,
  p_reason text,
  p_substitute text default null,
  p_confirmed boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_starts timestamptz;
  v_ends timestamptz;
  v_reason text := trim(coalesce(p_reason, ''));
  v_id uuid := p_id;
  v_impact jsonb;
  v_blocking integer;
  v_cancelled integer := 0;
  v_reassigned integer := 0;
  v_booking record;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_scope is null or p_scope not in ('gym', 'class', 'coach') then
    raise exception 'INVALID_SCOPE';
  end if;
  if p_scope = 'class' and not exists (
    select 1 from public.classes where id = p_class_id
  ) then
    raise exception 'INVALID_CLASS';
  end if;
  if p_scope = 'coach' and not exists (
    select 1 from public.coaches where id = p_coach_id
  ) then
    raise exception 'INVALID_COACH';
  end if;
  begin
    v_starts := (p_starts::timestamp) at time zone 'America/Managua';
    v_ends := (p_ends::timestamp) at time zone 'America/Managua';
  exception when others then
    raise exception 'INVALID_RANGE';
  end;
  if v_ends <= v_starts then raise exception 'INVALID_RANGE'; end if;
  if p_reason_kind is null
     or p_reason_kind not in ('holiday', 'vacation', 'sick', 'maintenance', 'other') then
    raise exception 'INVALID_REASON';
  end if;
  if length(v_reason) < 3 or length(v_reason) > 200 then
    raise exception 'INVALID_REASON';
  end if;
  if p_scope <> 'coach' and p_substitute is not null then
    raise exception 'INVALID_SUBSTITUTE';
  end if;
  if p_substitute is not null then
    if not exists (select 1 from public.coaches where id = p_substitute and is_active)
       or p_substitute = p_coach_id then
      raise exception 'INVALID_SUBSTITUTE';
    end if;
  end if;

  -- Dos administradores a la vez no pueden aplicar el mismo bloqueo dos veces.
  perform pg_advisory_xact_lock(hashtext('strong_gym_schedule_block'));

  v_impact := public._schedule_block_impact(
    p_scope, p_class_id, p_coach_id, v_starts, v_ends, p_substitute
  );
  v_blocking := coalesce((v_impact ->> 'booking_count')::int, 0);

  -- Con reservas encima, no se cancela nada sin confirmación explícita.
  if v_blocking > 0 and not coalesce(p_confirmed, false) then
    raise exception 'CONFIRM_REQUIRED';
  end if;

  if v_id is null then
    if exists (
      select 1 from public.schedule_blocks b
       where b.is_active
         and b.scope = p_scope
         and b.class_id is not distinct from p_class_id
         and b.coach_id is not distinct from p_coach_id
         and b.starts_at = v_starts
         and b.ends_at = v_ends
    ) then
      raise exception 'BLOCK_EXISTS';
    end if;

    insert into public.schedule_blocks
      (scope, class_id, coach_id, starts_at, ends_at, reason_kind, reason,
       substitute_coach_id, created_by)
    values
      (p_scope, p_class_id, p_coach_id, v_starts, v_ends, p_reason_kind, v_reason,
       p_substitute, auth.uid())
    returning id into v_id;
  else
    update public.schedule_blocks
       set scope = p_scope,
           class_id = p_class_id,
           coach_id = p_coach_id,
           starts_at = v_starts,
           ends_at = v_ends,
           reason_kind = p_reason_kind,
           reason = v_reason,
           substitute_coach_id = p_substitute,
           updated_at = now()
     where id = v_id
     returning id into v_id;
    if not found then raise exception 'NOT_FOUND'; end if;
  end if;

  -- Aplicar: reasignar si hay sustituto; si no, cancelar sin borrar.
  if p_substitute is not null then
    update public.sessions s
       set coach_id = p_substitute
     where s.status = 'scheduled'
       and s.starts_at < v_ends
       and s.ends_at > v_starts
       and s.coach_id = p_coach_id;
    get diagnostics v_reassigned = row_count;
  else
    for v_booking in
      select b.id
        from public.bookings b
        join public.sessions s on s.id = b.session_id
       where s.status = 'scheduled'
         and s.starts_at < v_ends
         and s.ends_at > v_starts
         and b.status in ('confirmed', 'attended')
         and (
           p_scope = 'gym'
           or (p_scope = 'class' and s.class_id = p_class_id)
           or (p_scope = 'coach' and s.coach_id = p_coach_id)
         )
    loop
      update public.bookings
         set status = 'cancelled',
             cancelled_at = now(),
             cancel_reason = v_reason,
             cancelled_by = auth.uid()
       where id = v_booking.id;
    end loop;

    update public.sessions s
       set status = 'cancelled'
     where s.status = 'scheduled'
       and s.starts_at < v_ends
       and s.ends_at > v_starts
       and (
         p_scope = 'gym'
         or (p_scope = 'class' and s.class_id = p_class_id)
         or (p_scope = 'coach' and s.coach_id = p_coach_id)
       );
    get diagnostics v_cancelled = row_count;
  end if;

  return jsonb_build_object(
    'id', v_id,
    'impact', v_impact,
    'cancelled_sessions', v_cancelled,
    'reassigned_sessions', v_reassigned,
    'blocks', public.admin_schedule_blocks()
  );
end $$;

revoke all on function public.admin_save_schedule_block(uuid,text,text,text,text,text,text,text,text,boolean)
  from public, anon, authenticated;
grant execute on function public.admin_save_schedule_block(uuid,text,text,text,text,text,text,text,text,boolean)
  to authenticated;

-- 11. Levantar un bloqueo no resucita nada: solo deja de bloquear.
create or replace function public.admin_lift_schedule_block(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_id is null then raise exception 'INVALID_REQUEST'; end if;

  update public.schedule_blocks
     set is_active = false, updated_at = now()
   where id = p_id and is_active;
  if not found then raise exception 'NOT_FOUND'; end if;

  return jsonb_build_object('id', p_id, 'blocks', public.admin_schedule_blocks());
end $$;

revoke all on function public.admin_lift_schedule_block(uuid)
  from public, anon, authenticated;
grant execute on function public.admin_lift_schedule_block(uuid)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00076_horario_no_genera_solo.sql
-- ═══════════════════════════════════════════════════════════

-- 00076 · Un paso, un efecto: guardar un horario ya no crea clases solo
--
-- Problema de lógica detectado al usar la pantalla: al guardar un horario
-- fijo (o al reactivarlo) la base creaba de golpe las clases de las próximas
-- cuatro semanas. Nadie lo pedía en ese momento y nadie veía qué se había
-- creado. La misma consecuencia llegaba por dos caminos distintos —guardar un
-- horario y el botón de generar— así que no había forma de saber de dónde
-- salió cada clase del calendario.
--
-- Regla nueva:
--   * Guardar, editar, suspender o reactivar un horario fijo NO escribe en el
--     calendario. Solo cambia la semana fija.
--   * Las clases con fecha se crean en un único lugar: la generación con
--     previsualización (`admin_apply_schedule`, migración 00074) y el
--     generador histórico de semanas que usa Operación.
--   * Las firmas no cambian: `p_weeks` se conserva por compatibilidad con las
--     llamadas existentes, pero ya no tiene efecto. `created_sessions` sigue
--     viniendo en la respuesta, ahora siempre en 0, para que la pantalla no
--     tenga que cambiar de contrato.
--
-- Reversión segura: volver a las definiciones de 00072 (las funciones que
-- llamaban a `schedule_generate_weeks()`). No se toca ningún dato.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.class_schedule_slots') is null
     or to_regprocedure('public.schedule_generate_weeks(integer)') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'SCHEDULE_SLOT_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. Guardar un horario: misma validación y mismos choques, sin generar clases.
create or replace function public.admin_save_schedule_slot(
  p_id uuid,
  p_class_id text,
  p_day integer,
  p_start text,
  p_duration integer,
  p_capacity integer,
  p_room text,
  p_coach text,
  p_active boolean default true,
  p_weeks integer default 4
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_class public.classes;
  v_start time;
  v_room text := trim(coalesce(p_room, ''));
  v_id uuid;
  v_conflict record;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_class_id is null then raise exception 'INVALID_CLASS'; end if;
  select * into v_class from public.classes where id = p_class_id;
  if not found then raise exception 'INVALID_CLASS'; end if;
  if p_day is null or p_day not between 0 and 6 then raise exception 'INVALID_DAY'; end if;
  begin
    v_start := coalesce(nullif(trim(coalesce(p_start, '')), ''), '18:00')::time;
  exception when others then
    raise exception 'INVALID_TIME';
  end;
  if p_duration is null or p_duration not between 10 and 180 then raise exception 'INVALID_DURATION'; end if;
  if p_capacity is null or p_capacity not between 1 and 200 then raise exception 'INVALID_CAPACITY'; end if;
  if length(v_room) not between 2 and 60 then raise exception 'INVALID_ROOM'; end if;
  if p_coach is not null and not exists (
    select 1 from public.coaches where id = p_coach and is_active
  ) then
    raise exception 'INVALID_COACH';
  end if;

  -- Choque: misma sala o mismo entrenador, mismo día, horarios que se pisan.
  select s.id, s.start_time, s.duration_min, s.room, s.coach_id into v_conflict
  from public.class_schedule_slots s
  where s.is_active
    and s.day_of_week = p_day
    and (p_id is null or s.id <> p_id)
    and (s.room = v_room or (p_coach is not null and s.coach_id = p_coach))
    and v_start < (s.start_time + make_interval(mins => s.duration_min))
    and (v_start + make_interval(mins => p_duration)) > s.start_time
  limit 1;
  if found then
    raise exception 'SCHEDULE_CONFLICT';
  end if;

  perform pg_advisory_xact_lock(hashtext('strong_gym_admin_schedule'));

  if p_id is null then
    insert into public.class_schedule_slots
      (class_id, day_of_week, start_time, duration_min, capacity, room, coach_id, is_active, updated_by)
    values
      (p_class_id, p_day, v_start, p_duration, p_capacity, v_room, p_coach, coalesce(p_active, true), auth.uid())
    returning id into v_id;
  else
    update public.class_schedule_slots
       set class_id = p_class_id,
           day_of_week = p_day,
           start_time = v_start,
           duration_min = p_duration,
           capacity = p_capacity,
           room = v_room,
           coach_id = p_coach,
           is_active = coalesce(p_active, is_active),
           updated_at = now(),
           updated_by = auth.uid()
     where id = p_id
     returning id into v_id;
    if not found then raise exception 'NOT_FOUND'; end if;
  end if;

  -- Ninguna clase se crea acá: eso pasa en el paso de "pasar al calendario".
  return public.admin_schedule_board() || jsonb_build_object(
    'created_sessions', 0,
    'slot_id', v_id
  );
end $$;
revoke all on function public.admin_save_schedule_slot(uuid,text,integer,text,integer,integer,text,text,boolean,integer)
  from public, anon, authenticated;
grant execute on function public.admin_save_schedule_slot(uuid,text,integer,text,integer,integer,text,text,boolean,integer)
  to authenticated;

-- 2. Suspender o reactivar: tampoco genera. Reactivar no resucita clases.
create or replace function public.admin_set_schedule_slot_active(
  p_id uuid, p_active boolean, p_weeks integer default 4
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_id is null or p_active is null then raise exception 'INVALID_REQUEST'; end if;

  update public.class_schedule_slots
     set is_active = p_active, updated_at = now(), updated_by = auth.uid()
   where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  return public.admin_schedule_board() || jsonb_build_object('created_sessions', 0);
end $$;
revoke all on function public.admin_set_schedule_slot_active(uuid, boolean, integer)
  from public, anon, authenticated;
grant execute on function public.admin_set_schedule_slot_active(uuid, boolean, integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00077_disciplinas_administrables.sql
-- ═══════════════════════════════════════════════════════════

-- 00077 · Disciplinas administrables (OP-05, cuarta etapa)
--
-- Problema: `public.classes` ya existía y Operación podía prender y apagar una
-- disciplina, pero no había forma de crearla ni de corregir su nombre, sus
-- descripciones, su duración, su cupo, su intensidad, su color o su orden sin
-- editar una migración. Zumba existía en la base pero apagada, sin manera de
-- cargarla desde el panel.
--
-- Decisión de esta etapa:
--   * `admin_save_class()` crea y edita una disciplina. No borra nada: la baja
--     es el interruptor que ya existe (`admin_set_class_active`, migración
--     00064), con una sola implementación del cambio de estado.
--   * Toda alta o edición queda en `class_audit`, con quién, cuándo, qué acción
--     y los NOMBRES de los campos que cambiaron. Nunca los valores.
--   * El identificador estable (`id`) se arma con el slug al crear y no cambia
--     después: sesiones, reservas y planes ya apuntan a él.
--   * `admin_classes_catalog()` devuelve el catálogo con lo que cada disciplina
--     tiene encima (horarios fijos activos, clases futuras y planes), para que
--     quien edita sepa qué está tocando antes de tocarlo.
--
-- Reversión segura: eliminar `admin_save_class`, `admin_classes_catalog` y
-- `class_audit`, y volver a la versión de `admin_set_class_active` de 00064.
-- Las disciplinas creadas siguen existiendo: no se borra ningún dato.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.classes') is null
     or to_regclass('public.profiles') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'CLASS_ADMIN_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. Bitácora de disciplinas: mismos criterios que `staff_audit` (00049).
create table if not exists public.class_audit (
  id             bigint generated always as identity primary key,
  class_id       text not null references public.classes (id) on delete cascade,
  action         text not null check (action in ('alta', 'edicion', 'baja', 'reactivacion')),
  changed_fields text[] not null default '{}',
  changed_by     uuid references public.profiles (id) on delete set null,
  changed_at     timestamptz not null default now()
);

create index if not exists class_audit_class_idx
  on public.class_audit (class_id, changed_at desc);

alter table public.class_audit enable row level security;
revoke all on public.class_audit from public, anon, authenticated;
grant select on public.class_audit to authenticated;
drop policy if exists class_audit_admin_read on public.class_audit;
create policy class_audit_admin_read on public.class_audit
  for select to authenticated using (public.is_admin());

-- 2. Catálogo con lo que cada disciplina tiene encima.
create or replace function public.admin_classes_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  return jsonb_build_object(
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'slug', c.slug,
        'name_es', c.name_es,
        'name_en', c.name_en,
        'description_es', c.description_es,
        'description_en', c.description_en,
        'intensity', c.intensity,
        'duration_min', c.duration_min,
        'capacity', c.capacity,
        'color', c.color,
        'sort_order', c.sort_order,
        'is_active', c.is_active,
        'slots_active', (
          select count(*)::int from public.class_schedule_slots s
           where s.class_id = c.id and s.is_active
        ),
        'sessions_upcoming', (
          select count(*)::int from public.sessions s
           where s.class_id = c.id and s.status = 'scheduled' and s.starts_at > now()
        ),
        'plans', (
          select count(*)::int from public.plans p
           where p.class_id = c.id and p.is_active
        )
      ) order by c.sort_order, c.name_es)
      from public.classes c
    ), '[]'::jsonb),
    'intensities', jsonb_build_array('low', 'medium', 'high'),
    'audit', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'class_id', a.class_id,
        'class_name', (select name_es from public.classes where id = a.class_id),
        'action', a.action,
        'changed_fields', a.changed_fields,
        'changed_by_name', (
          select coalesce(pr.full_name, '')
          from public.profiles pr where pr.id = a.changed_by
        ),
        'changed_at', a.changed_at
      ) order by a.changed_at desc, a.id desc)
      from (
        select * from public.class_audit order by changed_at desc, id desc limit 20
      ) a
    ), '[]'::jsonb)
  );
end $$;

revoke all on function public.admin_classes_catalog()
  from public, anon, authenticated;
grant execute on function public.admin_classes_catalog()
  to authenticated;

-- 3. Crear o editar una disciplina.
create or replace function public.admin_save_class(
  p_id text,
  p_slug text,
  p_name_es text,
  p_name_en text,
  p_description_es text,
  p_description_en text,
  p_intensity text,
  p_duration integer,
  p_capacity integer,
  p_color text,
  p_sort_order integer default 100
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id text := nullif(trim(coalesce(p_id, '')), '');
  v_slug text := lower(trim(coalesce(p_slug, '')));
  v_name_es text := trim(coalesce(p_name_es, ''));
  v_name_en text := trim(coalesce(p_name_en, ''));
  v_desc_es text := trim(coalesce(p_description_es, ''));
  v_desc_en text := trim(coalesce(p_description_en, ''));
  v_color text := lower(trim(coalesce(p_color, '#d81a22')));
  v_old public.classes;
  v_new public.classes;
  v_action text;
  v_fields text[] := '{}';
  v_new_id text;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  if length(v_name_es) not between 2 and 80 or length(v_name_en) not between 2 and 80 then
    raise exception 'INVALID_NAME';
  end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(v_slug) not between 2 and 48 then
    raise exception 'INVALID_SLUG';
  end if;
  if length(v_desc_es) > 400 or length(v_desc_en) > 400 then
    raise exception 'INVALID_DESCRIPTION';
  end if;
  if p_intensity is null or p_intensity not in ('low', 'medium', 'high') then
    raise exception 'INVALID_INTENSITY';
  end if;
  if p_duration is null or p_duration not between 10 and 180 then
    raise exception 'INVALID_DURATION';
  end if;
  if p_capacity is null or p_capacity not between 1 and 200 then
    raise exception 'INVALID_CAPACITY';
  end if;
  if v_color !~ '^#[0-9a-f]{6}$' then
    raise exception 'INVALID_COLOR';
  end if;
  if p_sort_order is not null and p_sort_order not between 0 and 9999 then
    raise exception 'INVALID_ORDER';
  end if;

  -- Dos administradores a la vez no pueden crear la misma disciplina.
  perform pg_advisory_xact_lock(hashtext('strong_gym_admin_classes'));

  if v_id is null then
    v_new_id := 'cls_' || replace(v_slug, '-', '_');
    if exists (select 1 from public.classes where id = v_new_id or slug = v_slug) then
      raise exception 'CLASS_EXISTS';
    end if;

    insert into public.classes
      (id, slug, name_es, name_en, description_es, description_en, intensity,
       duration_min, capacity, color, sort_order, is_active)
    values
      (v_new_id, v_slug, v_name_es, v_name_en, coalesce(v_desc_es, ''), coalesce(v_desc_en, ''),
       p_intensity::public.intensity_level, p_duration, p_capacity, v_color,
       coalesce(p_sort_order, 100), true)
    returning * into v_new;

    insert into public.class_audit (class_id, action, changed_fields, changed_by)
    values (v_new.id, 'alta', array['slug', 'name_es', 'name_en'], auth.uid());

    v_id := v_new.id;
    v_action := 'alta';
  else
    select * into v_old from public.classes where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;

    if exists (select 1 from public.classes where slug = v_slug and id <> v_id) then
      raise exception 'CLASS_EXISTS';
    end if;

    -- El estado (activo/apagado) no se toca acá: tiene su propio interruptor.
    update public.classes
       set slug = v_slug,
           name_es = v_name_es,
           name_en = v_name_en,
           description_es = v_desc_es,
           description_en = v_desc_en,
           intensity = p_intensity::public.intensity_level,
           duration_min = p_duration,
           capacity = p_capacity,
           color = v_color,
           sort_order = coalesce(p_sort_order, sort_order)
     where id = v_id
    returning * into v_new;

    if v_old.slug <> v_new.slug then v_fields := array_append(v_fields, 'slug'); end if;
    if v_old.name_es <> v_new.name_es then v_fields := array_append(v_fields, 'name_es'); end if;
    if v_old.name_en <> v_new.name_en then v_fields := array_append(v_fields, 'name_en'); end if;
    if v_old.description_es is distinct from v_new.description_es then
      v_fields := array_append(v_fields, 'description_es');
    end if;
    if v_old.description_en is distinct from v_new.description_en then
      v_fields := array_append(v_fields, 'description_en');
    end if;
    if v_old.intensity <> v_new.intensity then v_fields := array_append(v_fields, 'intensity'); end if;
    if v_old.duration_min <> v_new.duration_min then v_fields := array_append(v_fields, 'duration_min'); end if;
    if v_old.capacity <> v_new.capacity then v_fields := array_append(v_fields, 'capacity'); end if;
    if v_old.color <> v_new.color then v_fields := array_append(v_fields, 'color'); end if;
    if v_old.sort_order <> v_new.sort_order then v_fields := array_append(v_fields, 'sort_order'); end if;

    if cardinality(v_fields) = 0 then
      v_action := 'sin_cambios';
    else
      insert into public.class_audit (class_id, action, changed_fields, changed_by)
      values (v_id, 'edicion', v_fields, auth.uid());
      v_action := 'edicion';
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'action', v_action,
    'changed_fields', v_fields,
    'class', (select jsonb_build_object(
      'id', c.id, 'slug', c.slug, 'name_es', c.name_es, 'name_en', c.name_en,
      'description_es', c.description_es, 'description_en', c.description_en,
      'intensity', c.intensity, 'duration_min', c.duration_min,
      'capacity', c.capacity, 'color', c.color, 'sort_order', c.sort_order,
      'is_active', c.is_active
    ) from public.classes c where c.id = v_id)
  );
end $$;

revoke all on function public.admin_save_class(text, text, text, text, text, text, text, integer, integer, text, integer)
  from public, anon, authenticated;
grant execute on function public.admin_save_class(text, text, text, text, text, text, text, integer, integer, text, integer)
  to authenticated;

-- 4. El interruptor de 00064, ahora también con bitácora. Misma firma, misma
--    respuesta: la aplicación no cambia, pero queda registro de quién apagó o
--    reactivó una disciplina y cuándo.
create or replace function public.admin_set_class_active(
  p_class_id text,
  p_is_active boolean,
  p_expected_is_active boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_class public.classes;
  v_previous_is_active boolean;
begin
  if not public.is_admin() then
    raise exception 'AUTH';
  end if;

  if p_class_id is null
     or p_is_active is null
     or char_length(p_class_id) < 1
     or char_length(p_class_id) > 160
     or p_class_id ~ '\s' then
    raise exception 'INVALID_ACTIVE_STATE';
  end if;

  select * into v_class
    from public.classes
   where id = p_class_id
   for update;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  v_previous_is_active := v_class.is_active;

  if v_previous_is_active = p_is_active then
    return jsonb_build_object(
      'id', v_class.id,
      'is_active', v_class.is_active,
      'previous_is_active', v_previous_is_active,
      'changed', false
    );
  end if;

  if p_expected_is_active is not null
     and v_previous_is_active is distinct from p_expected_is_active then
    raise exception 'STALE_ACTIVE_STATE';
  end if;

  update public.classes
     set is_active = p_is_active
   where id = v_class.id
  returning * into v_class;

  insert into public.class_audit (class_id, action, changed_by)
  values (v_class.id, case when p_is_active then 'reactivacion' else 'baja' end, auth.uid());

  return jsonb_build_object(
    'id', v_class.id,
    'is_active', v_class.is_active,
    'previous_is_active', v_previous_is_active,
    'changed', true
  );
end;
$$;

revoke all on function public.admin_set_class_active(text, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_set_class_active(text, boolean, boolean)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00078_sesiones_sueltas.sql
-- ═══════════════════════════════════════════════════════════

-- 00078 · Sesiones sueltas y días especiales (OP-05, quinta etapa)
--
-- Problema: la grilla crea la clase de todos los martes a las 06:00, pero la
-- vida real no es tan prolija. Un sábado hay una clase especial a las 10:00,
-- un feriado se corre el horario, una sesión se suspende porque el entrenador
-- se enfermó, o el cupo de una fecha puntual cambió. Sin tocar la grilla, no
-- había forma de resolver eso: o se cambiaba la semana fija —y con ella todas
-- las semanas— o se quedaba como estaba.
--
-- Decisión de esta etapa:
--   * `admin_save_session()` crea o edita **una** clase con fecha: día, hora,
--     duración, cupo, sala, entrenador y una nota para el día especial. No
--     toca la grilla semanal y no crea clases como efecto colateral.
--   * `admin_cancel_session()` suspende **una** clase y deja canceladas sus
--     reservas con el motivo y quién las canceló. No borra nada.
--   * Para suspender varios días seguidos sigue estando **Bloqueos y
--     cierres**: no se duplica esa herramienta.
--   * La clase suelta se marca con `origin = 'manual'`, así la pantalla puede
--     distinguirla de las que crea la grilla sin adivinar.
--   * Mover una clase con reservas encima es válido —las reservas siguen a su
--     clase—, pero no se puede bajar el cupo por debajo de lo ya reservado ni
--     cambiar de disciplina con reservas.
--   * Se rechazan choques de sala y de entrenador, días bloqueados y fechas
--     pasadas. Cancelar una clase no la resucita al generar la semana: la fila
--     sigue ahí y el generador la cuenta como existente.
--
-- Reversión segura: eliminar `admin_save_session`, `admin_cancel_session` y
-- `admin_schedule_sessions`. Las columnas nuevas de `sessions` son opcionales
-- y quedan sin uso; no se borra ninguna clase ni ninguna reserva.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.sessions') is null
     or to_regclass('public.bookings') is null
     or to_regclass('public.classes') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.plan_local_today()') is null
     or to_regprocedure('public._session_blocked(text, text, timestamptz, timestamptz)') is null then
    raise exception 'SESSION_ADMIN_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. Rastro en la clase: de dónde salió, quién la tocó y por qué se canceló.
alter table public.sessions
  add column if not exists origin text not null default 'grid',
  add column if not exists note text,
  add column if not exists created_by uuid references public.profiles (id) on delete set null,
  add column if not exists updated_by uuid references public.profiles (id) on delete set null,
  add column if not exists updated_at timestamptz,
  add column if not exists cancel_reason text,
  add column if not exists cancelled_by uuid references public.profiles (id) on delete set null,
  add column if not exists cancelled_at timestamptz;

do $$ begin
  alter table public.sessions drop constraint if exists sessions_origin_chk;
  alter table public.sessions
    add constraint sessions_origin_chk check (origin in ('grid', 'manual'));
  alter table public.sessions drop constraint if exists sessions_note_chk;
  alter table public.sessions
    add constraint sessions_note_chk
    check (note is null or length(trim(note)) between 3 and 200);
end $$;

-- 2. Las clases de un período, con lo que cada una tiene encima.
create or replace function public.admin_schedule_sessions(
  p_from date default null,
  p_to date default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.plan_local_today();
  v_from date;
  v_to date;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  v_from := coalesce(p_from, v_today);
  v_to := coalesce(p_to, v_today + 27);
  if v_to < v_from then raise exception 'INVALID_RANGE'; end if;
  if (v_to - v_from) > 120 then raise exception 'RANGE_TOO_LONG'; end if;

  return jsonb_build_object(
    'from', to_char(v_from, 'YYYY-MM-DD'),
    'to', to_char(v_to, 'YYYY-MM-DD'),
    'today', to_char(v_today, 'YYYY-MM-DD'),
    'sessions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', x.id,
        'class_id', x.class_id,
        'class_name', x.class_name,
        'class_color', x.class_color,
        'class_active', x.class_active,
        'coach_id', x.coach_id,
        'coach_name', x.coach_name,
        'room', x.room,
        'starts_at', x.starts_at,
        'ends_at', x.ends_at,
        'duration_min', (extract(epoch from (x.ends_at - x.starts_at)) / 60)::int,
        'capacity', x.capacity,
        'booked', x.booked,
        'status', x.status,
        'origin', x.origin,
        'note', x.note,
        'cancel_reason', x.cancel_reason,
        'cancelled_at', x.cancelled_at,
        'is_past', x.starts_at <= now()
      ) order by x.starts_at, x.class_name)
      from (
        select
          s.id,
          s.class_id,
          c.name_es as class_name,
          c.color as class_color,
          c.is_active as class_active,
          s.coach_id,
          coalesce(
            nullif(to_jsonb(co) ->> 'full_name', ''),
            nullif(to_jsonb(co) ->> 'name', ''),
            s.coach_id
          ) as coach_name,
          s.room,
          s.starts_at,
          s.ends_at,
          s.capacity,
          s.status,
          s.origin,
          s.note,
          s.cancel_reason,
          s.cancelled_at,
          (
            select count(*)::int from public.bookings b
             where b.session_id = s.id and b.status in ('confirmed', 'attended')
          ) as booked
        from public.sessions s
        join public.classes c on c.id = s.class_id
        left join public.coaches co on co.id = s.coach_id
        where s.starts_at >= (v_from::timestamp at time zone 'America/Managua')
          and s.starts_at <  ((v_to + 1)::timestamp at time zone 'America/Managua')
        order by s.starts_at
        limit 300
      ) x
    ), '[]'::jsonb)
  );
end $$;

revoke all on function public.admin_schedule_sessions(date, date)
  from public, anon, authenticated;
grant execute on function public.admin_schedule_sessions(date, date)
  to authenticated;

-- 3. Crear o editar una clase con fecha, sin tocar la semana fija.
create or replace function public.admin_save_session(
  p_id text,
  p_class_id text,
  p_date text,
  p_time text,
  p_duration integer,
  p_capacity integer,
  p_room text,
  p_coach text,
  p_note text default null,
  p_expected_starts text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id text := nullif(trim(coalesce(p_id, '')), '');
  v_class public.classes;
  v_day date;
  v_clock time;
  v_starts timestamptz;
  v_ends timestamptz;
  v_room text := trim(coalesce(p_room, ''));
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_old public.sessions;
  v_new public.sessions;
  v_booked integer := 0;
  v_action text;
  v_fields text[] := '{}';
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  if p_class_id is null then raise exception 'INVALID_CLASS'; end if;
  select * into v_class from public.classes where id = p_class_id;
  if not found then raise exception 'INVALID_CLASS'; end if;

  begin
    v_day := (p_date)::date;
  exception when others then
    raise exception 'INVALID_DATE';
  end;
  begin
    v_clock := (p_time)::time;
  exception when others then
    raise exception 'INVALID_TIME';
  end;
  if p_duration is null or p_duration not between 10 and 180 then
    raise exception 'INVALID_DURATION';
  end if;
  if p_capacity is null or p_capacity not between 1 and 200 then
    raise exception 'INVALID_CAPACITY';
  end if;
  if length(v_room) not between 2 and 60 then
    raise exception 'INVALID_ROOM';
  end if;
  if p_coach is not null and not exists (
    select 1 from public.coaches where id = p_coach and is_active
  ) then
    raise exception 'INVALID_COACH';
  end if;
  if v_note is not null and length(v_note) > 200 then
    raise exception 'INVALID_NOTE';
  end if;

  -- Fecha y hora se interpretan en la hora del gimnasio, no en UTC.
  v_starts := (v_day + v_clock) at time zone 'America/Managua';
  v_ends := v_starts + make_interval(mins => p_duration);

  perform pg_advisory_xact_lock(hashtext('strong_gym_admin_sessions'));

  if v_id is null then
    if not v_class.is_active then raise exception 'CLASS_INACTIVE'; end if;
    if v_starts <= now() then raise exception 'PAST_SESSION'; end if;
    if exists (
      select 1 from public.sessions
       where class_id = p_class_id and starts_at = v_starts and status = 'scheduled'
    ) then
      raise exception 'SESSION_EXISTS';
    end if;
  else
    select * into v_old from public.sessions where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_old.status <> 'scheduled' then raise exception 'SESSION_CANCELLED'; end if;
    if v_old.starts_at <= now() then raise exception 'PAST_SESSION'; end if;
    if p_expected_starts is not null
       and to_char(v_old.starts_at at time zone 'America/Managua', 'YYYY-MM-DD"T"HH24:MI')
           <> p_expected_starts then
      raise exception 'STALE_SESSION';
    end if;

    select count(*)::int into v_booked
      from public.bookings
     where session_id = v_id and status in ('confirmed', 'attended');

    if p_capacity < v_booked then
      raise exception 'CAPACITY_BELOW_BOOKINGS';
    end if;
    if v_old.class_id <> p_class_id and v_booked > 0 then
      raise exception 'CLASS_CHANGE_WITH_BOOKINGS';
    end if;
  end if;

  if public._session_blocked(p_class_id, p_coach, v_starts, v_ends) then
    raise exception 'BLOCKED';
  end if;

  if exists (
    select 1 from public.sessions s
     where s.status = 'scheduled'
       and s.id <> coalesce(v_id, '')
       and s.room = v_room
       and s.starts_at < v_ends
       and s.ends_at > v_starts
  ) then
    raise exception 'SCHEDULE_CONFLICT';
  end if;

  if p_coach is not null and exists (
    select 1 from public.sessions s
     where s.status = 'scheduled'
       and s.id <> coalesce(v_id, '')
       and s.coach_id = p_coach
       and s.starts_at < v_ends
       and s.ends_at > v_starts
  ) then
    raise exception 'SCHEDULE_CONFLICT';
  end if;

  if v_id is null then
    insert into public.sessions
      (class_id, coach_id, starts_at, ends_at, capacity, room, origin, note,
       created_by, updated_by, updated_at)
    values
      (p_class_id, p_coach, v_starts, v_ends, p_capacity, v_room, 'manual', v_note,
       auth.uid(), auth.uid(), now())
    returning * into v_new;

    v_id := v_new.id;
    v_action := 'alta';
    v_fields := array['starts_at', 'duration_min', 'capacity', 'room'];
  else
    update public.sessions
       set class_id = p_class_id,
           coach_id = p_coach,
           starts_at = v_starts,
           ends_at = v_ends,
           capacity = p_capacity,
           room = v_room,
           note = v_note,
           updated_by = auth.uid(),
           updated_at = now()
     where id = v_id
    returning * into v_new;

    if v_old.class_id <> v_new.class_id then
      v_fields := array_append(v_fields, 'class_id');
    end if;
    if v_old.starts_at <> v_new.starts_at then
      v_fields := array_append(v_fields, 'starts_at');
    end if;
    if (v_new.ends_at - v_new.starts_at) <> (v_old.ends_at - v_old.starts_at) then
      v_fields := array_append(v_fields, 'duration_min');
    end if;
    if v_old.capacity <> v_new.capacity then
      v_fields := array_append(v_fields, 'capacity');
    end if;
    if v_old.room <> v_new.room then
      v_fields := array_append(v_fields, 'room');
    end if;
    if v_old.coach_id is distinct from v_new.coach_id then
      v_fields := array_append(v_fields, 'coach_id');
    end if;
    if v_old.note is distinct from v_new.note then
      v_fields := array_append(v_fields, 'note');
    end if;

    if cardinality(v_fields) = 0 then
      v_action := 'sin_cambios';
    else
      v_action := 'edicion';
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'action', v_action,
    'changed_fields', v_fields,
    'session', jsonb_build_object(
      'id', v_new.id,
      'class_id', v_new.class_id,
      'class_name', v_class.name_es,
      'coach_id', v_new.coach_id,
      'room', v_new.room,
      'starts_at', v_new.starts_at,
      'ends_at', v_new.ends_at,
      'capacity', v_new.capacity,
      'booked', v_booked,
      'status', v_new.status,
      'origin', v_new.origin,
      'note', v_new.note
    )
  );
end $$;

revoke all on function public.admin_save_session(text, text, text, text, integer, integer, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.admin_save_session(text, text, text, text, integer, integer, text, text, text, text)
  to authenticated;

-- 4. Suspender una sola clase, sin borrar nada.
create or replace function public.admin_cancel_session(
  p_id text,
  p_reason text,
  p_confirmed boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session public.sessions;
  v_reason text := trim(coalesce(p_reason, ''));
  v_booked integer := 0;
  v_cancelled integer := 0;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  if length(v_reason) < 3 or length(v_reason) > 200 then
    raise exception 'INVALID_REASON';
  end if;

  select * into v_session from public.sessions where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  -- Cancelar dos veces no cambia nada: la pantalla puede reintentar segura.
  if v_session.status = 'cancelled' then
    return jsonb_build_object(
      'ok', true,
      'changed', false,
      'session_id', v_session.id,
      'cancelled_bookings', 0
    );
  end if;

  if v_session.starts_at <= now() then
    raise exception 'PAST_SESSION';
  end if;

  select count(*)::int into v_booked
    from public.bookings
   where session_id = p_id and status in ('confirmed', 'attended');

  -- Con reservas encima, primero se ve a quién afecta y después se confirma.
  if v_booked > 0 and not coalesce(p_confirmed, false) then
    raise exception 'CONFIRM_REQUIRED';
  end if;

  update public.bookings
     set status = 'cancelled',
         cancelled_at = now(),
         cancel_reason = v_reason,
         cancelled_by = auth.uid()
   where session_id = p_id
     and status in ('confirmed', 'attended');
  get diagnostics v_cancelled = row_count;

  update public.sessions
     set status = 'cancelled',
         cancel_reason = v_reason,
         cancelled_by = auth.uid(),
         cancelled_at = now(),
         updated_by = auth.uid(),
         updated_at = now()
   where id = p_id;

  return jsonb_build_object(
    'ok', true,
    'changed', true,
    'session_id', p_id,
    'cancelled_bookings', v_cancelled
  );
end $$;

revoke all on function public.admin_cancel_session(text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_cancel_session(text, text, boolean)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00079_entrenadores_admin.sql
-- ═══════════════════════════════════════════════════════════

-- 00079 · Entrenadores: catálogo y asignación con detección de choques
--        (OP-05, sexta etapa)
--
-- Problema: `public.coaches` existía, pero sin manera de administrarla desde el
-- panel. Para poner un entrenador había que tocar la base a mano. Además la
-- lista `specialties` estaba vacía en los tres entrenadores, así que el
-- generador de sesiones no podía asignar a nadie y las 79 clases quedaron sin
-- entrenador; y el plan de generación enseñaba el entrenador del horario, no el
-- que el generador realmente iba a poner.
--
-- Decisión de esta etapa:
--   * `admin_save_coach()` crea y edita un entrenador: nombre, especialidad en
--     texto y **disciplinas que dicta** (las de `classes`, elegidas de una
--     lista, sin adivinar texto libre). Eso es lo que alimenta `specialties`.
--   * `admin_set_coach_active()` es el único interruptor de alta/baja. No se
--     borra ningún entrenador: se apaga, y sus clases quedan como están.
--   * Toda alta o edición queda en `coach_audit`, con quién, cuándo y los
--     NOMBRES de los campos cambiados. Nunca los valores.
--   * `admin_slot_coach_plan()` y `admin_apply_slot_coach()` pasan el
--     entrenador de un horario fijo a las clases que ya están en el calendario,
--     mirando primero cuántas se asignan y cuáles chocan. Es una acción
--     explícita: guardar un horario sigue sin tocar las clases existentes.
--   * `_schedule_plan()` y `admin_apply_schedule()` resuelven el entrenador igual
--     que el generador (el del horario y, si no hay, el primero activo que dicte
--     esa disciplina), así la previsualización dice la verdad y también detecta
--     los choques del entrenador que se va a asignar.
--
-- La tabla `coaches` no tiene las mismas columnas en todas las bases: la
-- productiva usa `full_name` y no tiene `slug`, `name` ni `sort_order`; las
-- migraciones del repo sí. Las altas y ediciones se arman según lo que exista,
-- igual que se hizo con el nombre en 00073.
--
-- Reversión segura: eliminar `admin_save_coach`, `admin_set_coach_active`,
-- `admin_coaches_catalog`, `admin_slot_coach_plan`, `admin_apply_slot_coach` y
-- `coach_audit`, y volver a las versiones de `_schedule_plan` (00075) y
-- `admin_apply_schedule` (00074). Los entrenadores creados siguen existiendo y
-- ninguna clase ni reserva se toca.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.coaches') is null
     or to_regclass('public.classes') is null
     or to_regclass('public.class_schedule_slots') is null
     or to_regclass('public.sessions') is null
     or to_regclass('public.profiles') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'COACH_ADMIN_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. Bitácora de entrenadores: mismos criterios que `class_audit` (00077).
create table if not exists public.coach_audit (
  id             bigint generated always as identity primary key,
  coach_id       text not null references public.coaches (id) on delete cascade,
  action         text not null check (action in ('alta', 'edicion', 'baja', 'reactivacion')),
  changed_fields text[] not null default '{}',
  changed_by     uuid references public.profiles (id) on delete set null,
  changed_at     timestamptz not null default now()
);

create index if not exists coach_audit_coach_idx
  on public.coach_audit (coach_id, changed_at desc);

alter table public.coach_audit enable row level security;
revoke all on public.coach_audit from public, anon, authenticated;
grant select on public.coach_audit to authenticated;
drop policy if exists coach_audit_admin_read on public.coach_audit;
create policy coach_audit_admin_read on public.coach_audit
  for select to authenticated using (public.is_admin());

-- 2. El catálogo: entrenadores, disciplinas para elegir y bitácora.
create or replace function public.admin_coaches_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  return jsonb_build_object(
    'coaches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', co.id,
        'full_name', coalesce(
          nullif(to_jsonb(co) ->> 'full_name', ''),
          nullif(to_jsonb(co) ->> 'name', ''),
          co.id
        ),
        'specialty', coalesce(to_jsonb(co) ->> 'specialty', ''),
        'specialties', coalesce(to_jsonb(co) -> 'specialties', '[]'::jsonb),
        'specialty_labels', coalesce((
          select jsonb_agg(c.name_es order by c.sort_order, c.name_es)
          from public.classes c
          where c.slug in (
            select jsonb_array_elements_text(
              coalesce(to_jsonb(co) -> 'specialties', '[]'::jsonb)
            )
          )
        ), '[]'::jsonb),
        'is_active', co.is_active,
        'slots_active', (
          select count(*)::int from public.class_schedule_slots s
           where s.coach_id = co.id and s.is_active
        ),
        'sessions_upcoming', (
          select count(*)::int from public.sessions se
           where se.coach_id = co.id and se.status = 'scheduled' and se.starts_at > now()
        ),
        'sessions_unassigned', (
          select count(*)::int from public.sessions se
           where se.class_id = any (
             select s.class_id from public.class_schedule_slots s
              where s.coach_id = co.id and s.is_active
           )
             and se.coach_id is null
             and se.status = 'scheduled'
             and se.starts_at > now()
        )
      ) order by co.is_active desc,
        coalesce(
          nullif(to_jsonb(co) ->> 'full_name', ''),
          nullif(to_jsonb(co) ->> 'name', ''),
          co.id
        ))
      from public.coaches co
    ), '[]'::jsonb),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'slug', c.slug,
        'name_es', c.name_es,
        'is_active', c.is_active
      ) order by c.sort_order, c.name_es)
      from public.classes c
    ), '[]'::jsonb),
    'audit', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'coach_id', a.coach_id,
        'coach_name', (
          select coalesce(
            nullif(to_jsonb(co) ->> 'full_name', ''),
            nullif(to_jsonb(co) ->> 'name', ''),
            a.coach_id
          ) from public.coaches co where co.id = a.coach_id
        ),
        'action', a.action,
        'changed_fields', a.changed_fields,
        'changed_by_name', (
          select coalesce(pr.full_name, '')
          from public.profiles pr where pr.id = a.changed_by
        ),
        'changed_at', a.changed_at
      ) order by a.changed_at desc, a.id desc)
      from (
        select * from public.coach_audit order by changed_at desc, id desc limit 20
      ) a
    ), '[]'::jsonb)
  );
end $$;

revoke all on function public.admin_coaches_catalog()
  from public, anon, authenticated;
grant execute on function public.admin_coaches_catalog()
  to authenticated;

-- 3. Crear o editar un entrenador.
--
-- `coaches` no tiene las mismas columnas en todas las bases: las migraciones del
-- repo traen `slug` y `name`; la productiva trae `full_name` y `specialty`. Las
-- altas y ediciones se arman según lo que exista, sin depender de una forma.
create or replace function public.admin_save_coach(
  p_id text,
  p_full_name text,
  p_specialty text default null,
  p_specialties text[] default '{}'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id text := nullif(trim(coalesce(p_id, '')), '');
  v_name text := trim(coalesce(p_full_name, ''));
  v_specialty text := nullif(trim(coalesce(p_specialty, '')), '');
  v_specialties text[] := coalesce(p_specialties, '{}');
  v_base text;
  v_new_id text;
  v_suffix integer := 1;
  v_fields text[] := '{}';
  v_action text;
  v_old jsonb;
  v_new jsonb;
  v_has_slug boolean;
  v_has_name boolean;
  v_has_full_name boolean;
  v_has_specialty boolean;
  v_cols text[] := array['id'];
  v_vals text[] := array['$1'];
  v_set text[] := array[]::text[];
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  if length(v_name) not between 3 and 80 then
    raise exception 'INVALID_NAME';
  end if;
  if v_specialty is not null and length(v_specialty) > 80 then
    raise exception 'INVALID_SPECIALTY';
  end if;
  if coalesce(array_length(v_specialties, 1), 0) > 12 then
    raise exception 'TOO_MANY_SPECIALTIES';
  end if;
  if exists (
    select 1 from unnest(v_specialties) as t(x)
     where x is null or not exists (select 1 from public.classes c where c.slug = x)
  ) then
    raise exception 'INVALID_CLASS_SLUG';
  end if;

  perform pg_advisory_xact_lock(hashtext('strong_gym_admin_coaches'));

  select
    bool_or(column_name = 'slug'),
    bool_or(column_name = 'name'),
    bool_or(column_name = 'full_name'),
    bool_or(column_name = 'specialty')
  into v_has_slug, v_has_name, v_has_full_name, v_has_specialty
  from information_schema.columns
  where table_schema = 'public' and table_name = 'coaches';

  if v_id is null then
    if exists (
      select 1 from public.coaches co
       where coalesce(
         nullif(to_jsonb(co) ->> 'full_name', ''),
         nullif(to_jsonb(co) ->> 'name', '')
       ) is not distinct from v_name
    ) then
      raise exception 'COACH_EXISTS';
    end if;

    v_base := 'coa_' || btrim(
      regexp_replace(
        lower(translate(v_name, 'áéíóúÁÉÍÓÚñÑüÜ', 'aeiouAEIOUnNuU')),
        '[^a-z0-9]+', '_', 'g'
      ),
      '_'
    );
    if length(v_base) < 5 then v_base := 'coa_entrenador'; end if;
    v_base := left(v_base, 40);
    v_new_id := v_base;
    while exists (select 1 from public.coaches co where co.id = v_new_id) loop
      v_suffix := v_suffix + 1;
      v_new_id := v_base || '_' || v_suffix;
    end loop;

    if v_has_slug then
      v_cols := array_append(v_cols, 'slug');
      v_vals := array_append(v_vals, '$1');
    end if;
    if v_has_name then
      v_cols := array_append(v_cols, 'name');
      v_vals := array_append(v_vals, '$2');
    end if;
    if v_has_full_name then
      v_cols := array_append(v_cols, 'full_name');
      v_vals := array_append(v_vals, '$2');
    end if;
    if v_has_specialty then
      v_cols := array_append(v_cols, 'specialty');
      v_vals := array_append(v_vals, '$3');
    end if;
    v_cols := array_append(v_cols, 'specialties');
    v_vals := array_append(v_vals, '$4');
    v_cols := array_append(v_cols, 'is_active');
    v_vals := array_append(v_vals, '$5');

    execute format(
      'insert into public.coaches (%s) values (%s)',
      array_to_string(v_cols, ', '),
      array_to_string(v_vals, ', ')
    ) using v_new_id, v_name, v_specialty, v_specialties, true;

    insert into public.coach_audit (coach_id, action, changed_fields, changed_by)
    values (v_new_id, 'alta', array['full_name', 'specialty', 'specialties'], auth.uid());

    v_id := v_new_id;
    v_action := 'alta';
  else
    select to_jsonb(co) into v_old
      from public.coaches co where co.id = v_id for update;
    if v_old is null then raise exception 'NOT_FOUND'; end if;

    if exists (
      select 1 from public.coaches co
       where co.id <> v_id
         and coalesce(
           nullif(to_jsonb(co) ->> 'full_name', ''),
           nullif(to_jsonb(co) ->> 'name', '')
         ) is not distinct from v_name
    ) then
      raise exception 'COACH_EXISTS';
    end if;

    if v_has_name then v_set := array_append(v_set, 'name = $2'); end if;
    if v_has_full_name then v_set := array_append(v_set, 'full_name = $2'); end if;
    if v_has_specialty then v_set := array_append(v_set, 'specialty = $3'); end if;
    v_set := array_append(v_set, 'specialties = $4');

    execute format(
      'update public.coaches set %s where id = $1',
      array_to_string(v_set, ', ')
    ) using v_id, v_name, v_specialty, v_specialties;

    if coalesce(v_old ->> 'full_name', v_old ->> 'name', '') <> v_name then
      v_fields := array_append(v_fields, 'full_name');
    end if;
    if coalesce(v_old ->> 'specialty', '') is distinct from coalesce(v_specialty, '') then
      v_fields := array_append(v_fields, 'specialty');
    end if;
    if coalesce(v_old -> 'specialties', '[]'::jsonb) is distinct from to_jsonb(v_specialties) then
      v_fields := array_append(v_fields, 'specialties');
    end if;

    if cardinality(v_fields) = 0 then
      v_action := 'sin_cambios';
    else
      insert into public.coach_audit (coach_id, action, changed_fields, changed_by)
      values (v_id, 'edicion', v_fields, auth.uid());
      v_action := 'edicion';
    end if;
  end if;

  select to_jsonb(co) into v_new from public.coaches co where co.id = v_id;

  return jsonb_build_object(
    'ok', true,
    'action', v_action,
    'changed_fields', v_fields,
    'coach', jsonb_build_object(
      'id', v_id,
      'full_name', coalesce(
        nullif(v_new ->> 'full_name', ''),
        nullif(v_new ->> 'name', ''),
        v_id
      ),
      'specialty', coalesce(v_new ->> 'specialty', ''),
      'specialties', coalesce(v_new -> 'specialties', '[]'::jsonb),
      'is_active', coalesce((v_new ->> 'is_active')::boolean, true)
    )
  );
end $$;

revoke all on function public.admin_save_coach(text, text, text, text[])
  from public, anon, authenticated;
grant execute on function public.admin_save_coach(text, text, text, text[])
  to authenticated;

-- 4. El interruptor de alta/baja del entrenador. No borra nada.
create or replace function public.admin_set_coach_active(
  p_coach_id text,
  p_is_active boolean,
  p_expected_is_active boolean default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_previous boolean;
  v_upcoming integer := 0;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  if p_coach_id is null
     or p_is_active is null
     or char_length(p_coach_id) < 1
     or char_length(p_coach_id) > 160
     or p_coach_id ~ '\s' then
    raise exception 'INVALID_ACTIVE_STATE';
  end if;

  select co.is_active into v_previous
    from public.coaches co where co.id = p_coach_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if v_previous = p_is_active then
    return jsonb_build_object(
      'id', p_coach_id,
      'is_active', v_previous,
      'previous_is_active', v_previous,
      'changed', false,
      'sessions_upcoming', (
        select count(*)::int from public.sessions
         where coach_id = p_coach_id and status = 'scheduled' and starts_at > now()
      )
    );
  end if;

  if p_expected_is_active is not null and v_previous is distinct from p_expected_is_active then
    raise exception 'STALE_ACTIVE_STATE';
  end if;

  update public.coaches set is_active = p_is_active where id = p_coach_id;

  select count(*)::int into v_upcoming
    from public.sessions
   where coach_id = p_coach_id and status = 'scheduled' and starts_at > now();

  insert into public.coach_audit (coach_id, action, changed_by)
  values (p_coach_id, case when p_is_active then 'reactivacion' else 'baja' end, auth.uid());

  return jsonb_build_object(
    'id', p_coach_id,
    'is_active', p_is_active,
    'previous_is_active', v_previous,
    'changed', true,
    'sessions_upcoming', v_upcoming
  );
end $$;

revoke all on function public.admin_set_coach_active(text, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_set_coach_active(text, boolean, boolean)
  to authenticated;

-- 5. Qué pasaría si se pasa el entrenador del horario a las clases ya creadas.
--    No escribe nada.
create or replace function public._slot_coach_plan(p_slot_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_slot record;
  v_items jsonb;
begin
  select s.id, s.class_id, s.day_of_week, s.start_time, s.coach_id, s.is_active
    into v_slot
    from public.class_schedule_slots s
   where s.id = p_slot_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'session_id', x.id,
    'starts_at', x.starts_at,
    'capacity', x.capacity,
    'booked', x.booked,
    'current_coach_id', x.coach_id,
    'current_coach_name', x.current_coach_name,
    'status', case
      when v_slot.coach_id is null then 'no_coach'
      when x.coach_id = v_slot.coach_id then 'same'
      when exists (
        select 1 from public.sessions o
         where o.status = 'scheduled'
           and o.coach_id = v_slot.coach_id
           and o.id <> x.id
           and o.starts_at < x.ends_at
           and o.ends_at > x.starts_at
      ) then 'conflict'
      else 'assign'
    end
  ) order by x.starts_at), '[]'::jsonb)
  into v_items
  from (
    select se.id, se.starts_at, se.ends_at, se.capacity, se.coach_id,
           (
             select coalesce(
               nullif(to_jsonb(co) ->> 'full_name', ''),
               nullif(to_jsonb(co) ->> 'name', ''),
               se.coach_id
             )
             from public.coaches co where co.id = se.coach_id
           ) as current_coach_name,
           (
             select count(*)::int from public.bookings b
              where b.session_id = se.id and b.status in ('confirmed', 'attended')
           ) as booked
      from public.sessions se
     where se.class_id = v_slot.class_id
       and se.status = 'scheduled'
       and se.starts_at > now()
       and ((extract(dow from (se.starts_at at time zone 'America/Managua'))::int + 6) % 7)
           = v_slot.day_of_week
       and (se.starts_at at time zone 'America/Managua')::time = v_slot.start_time
  ) x;

  return jsonb_build_object(
    'slot_id', p_slot_id,
    'class_id', v_slot.class_id,
    'coach_id', v_slot.coach_id,
    'coach_name', (
      select coalesce(
        nullif(to_jsonb(co) ->> 'full_name', ''),
        nullif(to_jsonb(co) ->> 'name', ''),
        v_slot.coach_id
      ) from public.coaches co where co.id = v_slot.coach_id
    ),
    'slot_active', v_slot.is_active,
    'totals', jsonb_build_object(
      'sessions', (select count(*)::int from jsonb_array_elements(v_items) i),
      'assign', (select count(*)::int from jsonb_array_elements(v_items) i
                  where i ->> 'status' = 'assign'),
      'same', (select count(*)::int from jsonb_array_elements(v_items) i
                where i ->> 'status' = 'same'),
      'conflict', (select count(*)::int from jsonb_array_elements(v_items) i
                    where i ->> 'status' = 'conflict'),
      'bookings', (select coalesce(sum((i ->> 'booked')::int), 0)::int
                     from jsonb_array_elements(v_items) i)
    ),
    'items', v_items
  );
end $$;

revoke all on function public._slot_coach_plan(uuid)
  from public, anon, authenticated;

create or replace function public.admin_slot_coach_plan(p_slot_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  return public._slot_coach_plan(p_slot_id);
end $$;

revoke all on function public.admin_slot_coach_plan(uuid)
  from public, anon, authenticated;
grant execute on function public.admin_slot_coach_plan(uuid)
  to authenticated;

-- 6. Aplicar: asigna el entrenador del horario a las clases ya creadas que no
--    choquen. No toca horarios, no borra clases ni reservas.
create or replace function public.admin_apply_slot_coach(p_slot_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan jsonb;
  v_coach text;
  v_assigned integer := 0;
  v_slot record;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  select s.id, s.class_id, s.day_of_week, s.start_time, s.coach_id
    into v_slot
    from public.class_schedule_slots s
   where s.id = p_slot_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_slot.coach_id is null then raise exception 'NO_COACH'; end if;

  perform pg_advisory_xact_lock(hashtext('strong_gym_admin_sessions'));

  v_plan := public._slot_coach_plan(p_slot_id);

  update public.sessions se
     set coach_id = v_slot.coach_id,
         updated_by = auth.uid(),
         updated_at = now()
   where se.id in (
     select (i ->> 'session_id')::text
       from jsonb_array_elements(v_plan -> 'items') i
      where i ->> 'status' = 'assign'
   )
     and se.status = 'scheduled';

  get diagnostics v_assigned = row_count;
  v_coach := v_slot.coach_id;

  return jsonb_build_object(
    'ok', true,
    'coach_id', v_coach,
    'assigned', v_assigned,
    'skipped_same', coalesce((v_plan -> 'totals' ->> 'same')::int, 0),
    'skipped_conflict', coalesce((v_plan -> 'totals' ->> 'conflict')::int, 0),
    'remaining', (select count(*)::int from public.sessions
                   where class_id = v_slot.class_id
                     and status = 'scheduled'
                     and starts_at > now()
                     and coach_id is null),
    'plan', public._slot_coach_plan(p_slot_id)
  );
end $$;

revoke all on function public.admin_apply_slot_coach(uuid)
  from public, anon, authenticated;
grant execute on function public.admin_apply_slot_coach(uuid)
  to authenticated;

-- 7. El plan de generación resuelve el entrenador igual que el generador, así
--    la previsualización muestra a quién se le va a asignar la clase y detecta
--    los choques de ese entrenador.
create or replace function public._schedule_plan(p_from date, p_weeks integer)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with rango as (
    select p_from as desde, (p_from + (p_weeks * 7) - 1) as hasta
  ),
  dias as (
    select g::date as dia
    from rango, generate_series(rango.desde::timestamp, rango.hasta::timestamp, interval '1 day') g
  ),
  candidatas as (
    select
      d.dia,
      s.id as slot_id,
      s.day_of_week,
      to_char(s.start_time, 'HH24:MI') as hora,
      s.class_id,
      c.slug as class_slug,
      c.name_es as class_name,
      c.is_active as class_active,
      c.sort_order,
      s.room,
      resolved.coach_id,
      resolved.coach_auto,
      coalesce(
        nullif(to_jsonb(co) ->> 'full_name', ''),
        nullif(to_jsonb(co) ->> 'name', ''),
        resolved.coach_id
      ) as coach_name,
      ((d.dia + s.start_time) at time zone 'America/Managua') as starts_at,
      ((d.dia + s.start_time) at time zone 'America/Managua')
        + make_interval(mins => s.duration_min) as ends_at
    from dias d
    join public.class_schedule_slots s
      on s.day_of_week = ((extract(dow from d.dia)::integer + 6) % 7)
     and s.is_active
     and (s.valid_from is null or s.valid_from <= d.dia)
     and (s.valid_to is null or s.valid_to >= d.dia)
    join public.classes c on c.id = s.class_id
    cross join lateral (
      -- El entrenador del horario manda; si no hay, se usa el primero activo
      -- que dicte esa disciplina (`specialties` guarda slugs de `classes`).
      select
        v.coach_id,
        (s.coach_id is null and v.coach_id is not null) as coach_auto
      from (
        select coalesce(s.coach_id, (
          select co2.id from public.coaches co2
           where co2.is_active
             and c.slug in (
               select jsonb_array_elements_text(
                 coalesce(to_jsonb(co2) -> 'specialties', '[]'::jsonb)
               )
             )
           order by co2.id
           limit 1
        )) as coach_id
      ) v
    ) resolved
    left join public.coaches co on co.id = resolved.coach_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'date', to_char(x.dia, 'YYYY-MM-DD'),
      'slot_id', x.slot_id,
      'day_of_week', x.day_of_week,
      'start_time', x.hora,
      'class_id', x.class_id,
      'class_name', x.class_name,
      'room', x.room,
      'coach_id', x.coach_id,
      'coach_name', x.coach_name,
      'coach_auto', x.coach_auto,
      'status', x.estado
    )
    order by x.dia, x.starts_at, x.sort_order, x.class_id
  ), '[]'::jsonb)
  from (
    select
      cc.*,
      case
        when not cc.class_active then 'inactive'
        when cc.starts_at <= now() then 'past'
        when public._session_blocked(cc.class_id, cc.coach_id, cc.starts_at, cc.ends_at)
          then 'blocked'
        when exists (
          select 1 from public.sessions s
           where s.class_id = cc.class_id and s.starts_at = cc.starts_at
        ) then 'duplicate'
        when exists (
          select 1 from public.sessions s
           where s.status = 'scheduled'
             and s.room = cc.room
             and s.starts_at < cc.ends_at
             and s.ends_at > cc.starts_at
        ) then 'room_conflict'
        when cc.coach_id is not null and exists (
          select 1 from public.sessions s
           where s.status = 'scheduled'
             and s.coach_id = cc.coach_id
             and s.starts_at < cc.ends_at
             and s.ends_at > cc.starts_at
        ) then 'coach_conflict'
        else 'create'
      end as estado
    from candidatas cc
  ) x
$$;

revoke all on function public._schedule_plan(date, integer)
  from public, anon, authenticated;

-- 8. Aplicar el plan asigna el mismo entrenador que mostró la previsualización.
create or replace function public.admin_apply_schedule(
  p_from date default null,
  p_weeks integer default 4
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_from date;
  v_plan jsonb;
  v_item jsonb;
  v_created integer := 0;
  v_preview jsonb;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_weeks is null or p_weeks < 1 or p_weeks > 8 then
    raise exception 'INVALID_WEEKS';
  end if;

  v_from := coalesce(
    p_from,
    date_trunc('week', public.plan_local_today()::timestamp)::date
  );

  perform pg_advisory_xact_lock(hashtext('strong_gym_schedule_generate'));

  v_plan := public._schedule_plan(v_from, p_weeks);

  for v_item in
    select value from jsonb_array_elements(v_plan)
     where value ->> 'status' = 'create'
     order by value ->> 'date', value ->> 'start_time'
  loop
    insert into public.sessions (class_id, coach_id, starts_at, ends_at, capacity, room)
    select
      s.class_id,
      nullif(v_item ->> 'coach_id', '')::text,
      ((v_item ->> 'date')::date + s.start_time) at time zone 'America/Managua',
      (((v_item ->> 'date')::date + s.start_time) at time zone 'America/Managua')
        + make_interval(mins => s.duration_min),
      s.capacity,
      s.room
    from public.class_schedule_slots s
    where s.id = (v_item ->> 'slot_id')::uuid
      and not exists (
        select 1 from public.sessions x
         where x.class_id = s.class_id
           and x.starts_at = ((v_item ->> 'date')::date + s.start_time)
                              at time zone 'America/Managua'
      );

    if found then
      v_created := v_created + 1;
    end if;
  end loop;

  v_preview := public.admin_preview_schedule(v_from, p_weeks);

  return v_preview || jsonb_build_object(
    'created', v_created,
    'planned', (select count(*)::int
                  from jsonb_array_elements(v_plan) i
                 where i ->> 'status' = 'create')
  );
end $$;

revoke all on function public.admin_apply_schedule(date, integer)
  from public, anon, authenticated;
grant execute on function public.admin_apply_schedule(date, integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00080_anulacion_controlada.sql
-- ═══════════════════════════════════════════════════════════

-- 00080 · FIN-01: anulación controlada de un movimiento
--
-- Problema: un cobro o un gasto cargado por error no se podía deshacer. La
-- única salida era tocar el saldo a mano o borrar la fila, y ninguna de las dos
-- deja rastro de quién lo hizo ni por qué. El interruptor `cashier_can_void`
-- existía desde la 00033 pero no hacía nada.
--
-- Decisión de esta etapa:
--   * Anular **no borra nada**: se inserta un movimiento de reversa con el
--     signo contrario, en la misma cuenta, moneda, método y cliente, y la
--     cuenta vuelve al saldo que tenía. El movimiento original queda como está.
--   * Un original solo se puede anular **una vez**: `finance_voids.original_id`
--     es único y una reversa no se puede volver a anular.
--   * Quién puede: administración siempre; caja **solo si** el interruptor
--     `cashier_can_void` está encendido, **solo sus propios movimientos** y
--     **solo los del día en curso** (America/Managua). Si el interruptor está
--     apagado, caja no ve el botón y la base igual lo rechaza.
--   * Motivo obligatorio (5 a 300 caracteres), actor, rol y fecha quedan
--     guardados en `finance_voids`.
--   * Idempotente por `request_id`: el mismo pedido repetido devuelve el mismo
--     comprobante; un pedido con el mismo id y otro contenido se rechaza.
--   * La reversa se puede leer desde Caja como «anulada», pero no se puede
--     editar ni borrar: la tabla solo tiene `select` para el personal.
--
-- Reversión segura: eliminar `finance_void_movement`, `finance_void_plan`,
-- `finance_voids_recent` y `finance_voids`. Los movimientos de reversa ya
-- creados quedan como movimientos normales y los saldos no cambian; no se
-- borra ningún dato existente.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.transactions') is null
     or to_regclass('public.bank_accounts') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.staff_permissions') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.is_cashier()') is null
     or to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('public.finance_writes_ready()') is null
     or to_regprocedure('public.finance_permission_enabled(text)') is null
     or to_regprocedure('public.plan_local_today()') is null then
    raise exception 'VOID_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. El interruptor nace apagado si todavía no existe (00033 lo creó; esto es
--    idempotente y no cambia una decisión ya tomada).
insert into public.staff_permissions(key, enabled)
values ('cashier_can_void', false)
on conflict (key) do nothing;

-- 2. `cashier_can_void` entra en la lista blanca del helper existente. Sin esto,
--    la pantalla nunca podría mostrar el permiso y la base lo negaría siempre.
create or replace function public.finance_permission_enabled(p_key text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_key is null or p_key not in (
      'cashier_can_view_daily_close',
      'cashier_can_view_monthly_result',
      'cashier_can_view_charts',
      'cashier_can_view_account_balances',
      'cashier_can_manage_expenses',
      'cashier_can_view_receivables',
      'cashier_can_void'
    ) then false
    when public.is_admin() then true
    when public.is_cashier() then coalesce(
      (select enabled from public.staff_permissions where key = p_key),
      false
    )
    else false
  end;
$$;
revoke all on function public.finance_permission_enabled(text) from public, anon, authenticated;

-- 3. El permiso viaja al panel junto con los demás.
create or replace function public.cashier_permissions()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'dailyClose', public.finance_permission_enabled('cashier_can_view_daily_close'),
    'monthlyResult', public.finance_permission_enabled('cashier_can_view_monthly_result'),
    'charts', public.finance_permission_enabled('cashier_can_view_charts'),
    'accountBalances', public.finance_permission_enabled('cashier_can_view_account_balances'),
    'expenses', public.finance_permission_enabled('cashier_can_manage_expenses'),
    'receivables', public.finance_permission_enabled('cashier_can_view_receivables'),
    'void', public.finance_permission_enabled('cashier_can_void')
  );
$$;
revoke all on function public.cashier_permissions() from public, anon, authenticated;
grant execute on function public.cashier_permissions() to authenticated;

-- 4. La bitácora de anulaciones.
create table if not exists public.finance_voids (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null unique,
  original_id  uuid not null unique references public.transactions (id) on delete restrict,
  reversal_id  uuid not null unique references public.transactions (id) on delete restrict,
  reason       text not null check (char_length(reason) between 5 and 300),
  actor_id     uuid references public.profiles (id) on delete set null,
  actor_name   text,
  actor_role   text,
  payload      jsonb not null,
  receipt      jsonb not null,
  created_at   timestamptz not null default now()
);

create index if not exists finance_voids_created_idx
  on public.finance_voids (created_at desc);

alter table public.finance_voids enable row level security;
revoke all on public.finance_voids from public, anon, authenticated;
grant select on public.finance_voids to authenticated;
drop policy if exists finance_voids_staff_read on public.finance_voids;
create policy finance_voids_staff_read on public.finance_voids
  for select to authenticated using (public.crm_is_staff());

-- 5. Consulta previa: qué pasaría si se anulara, sin escribir nada. La usa la
--    pantalla antes de pedir el motivo y la vuelve a aplicar el escritor.
create or replace function public.finance_void_plan(p_transaction uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_t public.transactions;
  v_void public.finance_voids;
  v_is_reversal boolean;
  v_admin boolean;
  v_cashier boolean;
  v_today boolean;
  v_own boolean;
  v_code text;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into v_t from public.transactions where id = p_transaction;
  if not found then raise exception 'NOT_FOUND'; end if;

  select * into v_void from public.finance_voids where original_id = p_transaction;
  v_is_reversal := exists (
    select 1 from public.finance_voids where reversal_id = p_transaction
  );
  v_admin := public.is_admin();
  v_cashier := public.is_cashier();
  v_own := v_t.created_by is not null and v_t.created_by = auth.uid();
  v_today := (v_t.occurred_at at time zone 'America/Managua')::date
    = public.plan_local_today();

  v_code := case
    -- Una transferencia mueve las dos puntas de una misma operación: no se
    -- anula con una sola reversa. Se corrige registrando otra transferencia.
    when v_t.type::text = 'transfer' then 'NOT_VOIDABLE'
    when v_void.id is not null then 'ALREADY_VOIDED'
    when v_is_reversal then 'IS_REVERSAL'
    when v_admin then 'ALLOWED'
    when v_cashier
      and public.finance_permission_enabled('cashier_can_void')
      and v_own and v_today then 'ALLOWED'
    when not v_cashier then 'NOT_ALLOWED'
    when not public.finance_permission_enabled('cashier_can_void') then 'PERMISSION_OFF'
    when not v_own then 'NOT_YOURS'
    when not v_today then 'NOT_TODAY'
    else 'NOT_ALLOWED'
  end;

  return jsonb_build_object(
    'transactionId', v_t.id,
    'concept', v_t.concept,
    'type', v_t.type::text,
    'amount', v_t.amount,
    'currency', v_t.currency,
    'occurredAt', v_t.occurred_at,
    'accountId', v_t.account_id,
    'isReversal', v_is_reversal,
    'alreadyVoided', v_void.id is not null,
    'voidedAt', v_void.created_at,
    'allowed', v_code = 'ALLOWED',
    'code', v_code
  );
end $$;
revoke all on function public.finance_void_plan(uuid) from public, anon, authenticated;
grant execute on function public.finance_void_plan(uuid) to authenticated;

-- 6. El escritor: inserta la reversa, mueve el saldo y guarda la bitácora.
create or replace function public.finance_void_movement(
  p_request uuid,
  p_transaction uuid,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
set lock_timeout = '5s' as $$
declare
  v_t public.transactions;
  v_account public.bank_accounts;
  v_plan jsonb;
  v_existing public.finance_voids;
  v_payload jsonb;
  v_reason text := trim(coalesce(p_reason, ''));
  v_reversal uuid;
  v_actor_name text;
  v_actor_role text;
  v_after numeric;
  v_delta numeric;
  v_at timestamptz := clock_timestamp();
  v_receipt jsonb;
  v_void_id uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  if p_transaction is null then raise exception 'NOT_FOUND'; end if;
  if char_length(v_reason) not between 5 and 300 then
    raise exception 'INVALID_REASON';
  end if;

  v_payload := jsonb_build_object(
    'transaction', p_transaction,
    'reason', v_reason
  );

  perform pg_advisory_xact_lock(hashtextextended(p_request::text, 0));
  select * into v_existing from public.finance_voids where request_id = p_request;
  if found then
    if v_existing.payload is distinct from v_payload then
      raise exception 'REQUEST_CONFLICT';
    end if;
    return v_existing.receipt;
  end if;

  if not public.finance_writes_ready() then raise exception 'FINANCE_REVIEW_REQUIRED'; end if;

  select * into v_t from public.transactions where id = p_transaction for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  v_plan := public.finance_void_plan(p_transaction);
  if not coalesce((v_plan ->> 'allowed')::boolean, false) then
    raise exception '%', coalesce(v_plan ->> 'code', 'NOT_ALLOWED');
  end if;

  select full_name into v_actor_name from public.profiles where id = auth.uid() for share;
  if not found then raise exception 'AUTH'; end if;
  select role::text into v_actor_role from public.profiles where id = auth.uid();

  -- Lock en el mismo orden que los demás escritores: cuenta al final.
  select * into v_account from public.bank_accounts where id = v_t.account_id for update;
  if not found then raise exception 'INVALID_ACCOUNT'; end if;
  if v_account.currency <> v_t.currency then raise exception 'INVALID_ACCOUNT'; end if;

  -- La reversa devuelve el efecto: si entró plata, sale; si salió, entra.
  v_delta := case when v_t.type::text = 'expense' then v_t.amount else -v_t.amount end;
  v_after := v_account.balance + v_delta;
  if abs(v_after) > 9999999999.99 then raise exception 'INVALID_PAYMENT'; end if;

  insert into public.transactions(
    type, status, occurred_at, account_id, method_id, category_id, member_id,
    client_id, crm_request_id, amount, currency, amount_nio, amount_usd,
    fx_used, concept, created_by, created_at, updated_at
  ) values (
    case when v_t.type::text = 'expense'
      then 'income'::public.transaction_type
      else 'expense'::public.transaction_type end,
    'completed', v_at, v_t.account_id, v_t.method_id, v_t.category_id,
    v_t.member_id, v_t.client_id, p_request, v_t.amount, v_t.currency,
    v_t.amount_nio, v_t.amount_usd, v_t.fx_used,
    left('Anulación: ' || v_t.concept, 200), auth.uid(), v_at, v_at
  ) returning id into v_reversal;

  update public.bank_accounts set balance = v_after where id = v_t.account_id;

  v_receipt := jsonb_build_object(
    'id', v_reversal,
    'reference', 'SG-' || v_reversal::text,
    'requestId', p_request,
    'kind', 'void',
    'originalId', v_t.id,
    'reversalId', v_reversal,
    'reason', v_reason,
    'occurredAt', v_at,
    'amount', v_t.amount,
    'currency', v_t.currency,
    'amountNio', v_t.amount_nio,
    'amountUsd', v_t.amount_usd,
    'originalConcept', v_t.concept,
    'concept', left('Anulación: ' || v_t.concept, 200),
    'clientId', v_t.client_id,
    'accountId', v_t.account_id,
    'accountName', v_account.name,
    'accountBefore', v_account.balance,
    'accountAfter', v_after,
    'actorId', auth.uid(),
    'actorName', v_actor_name
  );

  insert into public.finance_voids(
    request_id, original_id, reversal_id, reason, actor_id, actor_name,
    actor_role, payload, receipt
  ) values (
    p_request, v_t.id, v_reversal, v_reason, auth.uid(), v_actor_name,
    v_actor_role, v_payload, v_receipt
  ) returning id into v_void_id;

  if v_t.client_id is not null then
    insert into public.client_events(client_id, action, details, actor_id)
    values (
      v_t.client_id,
      'payment_void',
      jsonb_build_object(
        'transaction_id', v_t.id,
        'reversal_id', v_reversal,
        'void_id', v_void_id,
        'amount', v_t.amount,
        'currency', v_t.currency,
        'reason', v_reason
      ),
      auth.uid()
    );
  end if;

  return v_receipt;
end $$;
revoke all on function public.finance_void_movement(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.finance_void_movement(uuid, uuid, text) to authenticated;

-- 7. Lectura para la pantalla: qué movimientos de la lista ya están anulados.
create or replace function public.finance_voids_recent(p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'originalId', original_id,
      'reversalId', reversal_id,
      'reason', reason,
      'actorName', actor_name,
      'createdAt', created_at
    ) order by created_at desc)
    from (
      select original_id, reversal_id, reason, actor_name, created_at
      from public.finance_voids
      order by created_at desc
      limit v_limit
    ) v
  ), '[]'::jsonb);
end $$;
revoke all on function public.finance_voids_recent(integer) from public, anon, authenticated;
grant execute on function public.finance_voids_recent(integer) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00081_efectivo_y_vuelto.sql
-- ═══════════════════════════════════════════════════════════

-- 00081 · FIN-02: efectivo recibido y vuelto en todos los cobros
--
-- Problema: hoy el vuelto solo existe en los abonos de deuda
-- (`finance_debt_record_with_cash`, 00029). Un cobro por servicio, un cobro con
-- productos o un cobro de plan no registran cuánto entregó la persona ni
-- cuánto se le devolvió, así que el cierre de caja no puede cuadrar el
-- efectivo físico contra lo registrado.
--
-- Decisión de esta etapa:
--   * Se agrega un parámetro opcional `p_cash_received` a los cuatro escritores
--     de cobro. Si viene vacío, todo sigue exactamente igual que antes: no se
--     inventa efectivo histórico.
--   * El efectivo recibido solo aplica a ingresos por servicio. Un gasto no
--     recibe efectivo del cliente: si llega, se rechaza.
--   * Se exige que la cuenta sea de caja (`account_type = 'caja_fuerte'`),
--     activa y de la misma moneda del cobro: el vuelto es dinero físico.
--   * El importe recibido debe ser mayor o igual al total del cobro, tener dos
--     decimales y no pasar de 99 999 999 (`INVALID_CASH_RECEIVED`).
--   * El vuelto queda guardado en el comprobante (`finance_entries.receipt`),
--     en el evento del cliente y —en los cobros con productos— en el grupo del
--     checkout, que es donde se conoce el total del servicio más los productos.
--   * Nada de esto borra o reescribe movimientos anteriores: solo completa
--     comprobantes nuevos.
--
-- Reglas compartidas en dos funciones chicas (`finance_cash_change` y
-- `finance_cash_stamp`) para no repetir la misma validación cuatro veces.

begin;
set local lock_timeout = '5s';

do $$ begin
  if public.crm_finance_layout() <> 'bank_accounts_split'
     or to_regprocedure('public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text)') is null
     or to_regprocedure('public.finance_record_checkout(uuid,uuid,numeric,text,text,text,text,numeric,jsonb)') is null
     or to_regprocedure('public.finance_record_movement_plan(uuid,uuid,numeric,text,text,text,text,numeric,text)') is null
     or to_regprocedure('public.finance_record_checkout_plan(uuid,uuid,numeric,text,text,text,text,numeric,jsonb,text)') is null
     or to_regclass('public.finance_entries') is null
     or to_regclass('public.bank_accounts') is null then
    raise exception 'CASH_CHANGE_PREREQUISITE_MISSING';
  end if;
end $$;

-- El escritor de checkout gana un parámetro, así que su cuerpo actual se
-- conserva con otro nombre y el nuevo lo envuelve. Se copia con
-- `pg_get_functiondef` para no reescribir a mano las validaciones de stock.
do $$ begin
  if to_regprocedure('public.finance_record_checkout_before_cash(uuid,uuid,numeric,text,text,text,text,numeric,jsonb)') is null then
    execute replace(
      pg_get_functiondef('public.finance_record_checkout(uuid,uuid,numeric,text,text,text,text,numeric,jsonb)'::regprocedure),
      'FUNCTION public.finance_record_checkout(',
      'FUNCTION public.finance_record_checkout_before_cash('
    );
  end if;
end $$;
revoke all on function public.finance_record_checkout_before_cash(uuid, uuid, numeric, text, text, text, text, numeric, jsonb)
  from public, anon, authenticated;

-- Cambiar la firma exige recrear: cada versión vieja se retira justo antes de
-- su reemplazo, así no quedan dos funciones iguales y PostgREST no duda.

-- 1. Regla única de efectivo: devuelve el vuelto o null si no hubo efectivo.
create or replace function public.finance_cash_change(
  p_amount numeric,
  p_currency text,
  p_account text,
  p_cash_received numeric
) returns numeric
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_cash_received is null then return null; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 99999999
     or p_amount <> round(p_amount, 2) then
    raise exception 'INVALID_CASH_RECEIVED';
  end if;
  if p_cash_received < p_amount or p_cash_received > 99999999
     or p_cash_received <> round(p_cash_received, 2) then
    raise exception 'INVALID_CASH_RECEIVED';
  end if;
  -- No se infiere efectivo por el nombre del método: manda la cuenta elegida.
  perform 1 from public.bank_accounts
   where id = p_account and is_active
     and account_type = 'caja_fuerte' and currency = p_currency;
  if not found then raise exception 'CASH_ACCOUNT_REQUIRED'; end if;
  return p_cash_received - p_amount;
end $$;
revoke all on function public.finance_cash_change(numeric, text, text, numeric)
  from public, anon, authenticated;

-- 2. Deja el efectivo en el comprobante y en el evento del cliente.
create or replace function public.finance_cash_stamp(
  p_transaction uuid,
  p_cash_received numeric,
  p_change numeric
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows integer;
begin
  update public.finance_entries
     set receipt = receipt || jsonb_build_object(
       'cashReceived', p_cash_received,
       'changeGiven', p_change
     )
   where transaction_id = p_transaction;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then raise exception 'CASH_RECEIPT_UNCONFIRMED'; end if;

  -- Puede no haber evento si el cobro no tenía ficha de cliente.
  update public.client_events
     set details = details || jsonb_build_object(
       'cash_received', p_cash_received,
       'change_given', p_change
     )
   where details->>'transaction_id' = p_transaction::text;
end $$;
revoke all on function public.finance_cash_stamp(uuid, numeric, numeric)
  from public, anon, authenticated;

-- 3. Cobro simple, con o sin plan.
drop function if exists public.finance_record_movement(uuid, text, uuid, numeric, text, text, text, text, numeric, text);

create or replace function public.finance_record_movement(
  p_request uuid, p_kind text, p_client uuid, p_amount numeric, p_currency text,
  p_method text, p_account text, p_concept text, p_fx numeric,
  p_category text default null, p_cash_received numeric default null
) returns uuid
language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_change numeric;
  v_id uuid;
  v_existing numeric;
  v_found boolean := false;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  if p_kind = 'expense'
     and not public.finance_permission_enabled('cashier_can_manage_expenses') then
    raise exception 'AUTH';
  end if;
  -- Un gasto no recibe efectivo del cliente.
  if p_cash_received is not null and p_kind is distinct from 'service_income' then
    raise exception 'INVALID_CASH_RECEIVED';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_request::text, 0));
  if exists(select 1 from public.client_debt_entries where request_id = p_request) then
    raise exception 'REQUEST_CONFLICT';
  end if;

  -- Reintento con otro efectivo declarado es otro contenido: se rechaza.
  if p_cash_received is not null then
    select (receipt->>'cashReceived')::numeric
      into v_existing
      from public.finance_entries
     where request_id = p_request;
    v_found := found;
    if v_found and coalesce(v_existing, -1) <> p_cash_received then
      raise exception 'REQUEST_CONFLICT';
    end if;
  end if;

  v_change := public.finance_cash_change(p_amount, p_currency, p_account, p_cash_received);

  v_id := public.finance_record_movement_before_debts(
    p_request, p_kind, p_client, p_amount, p_currency,
    p_method, p_account, p_concept, p_fx, p_category
  );

  if p_cash_received is not null then
    perform public.finance_cash_stamp(v_id, p_cash_received, v_change);
  end if;

  return v_id;
end $$;
revoke all on function public.finance_record_movement(uuid, text, uuid, numeric, text, text, text, text, numeric, text, numeric)
  from public, anon, authenticated;
grant execute on function public.finance_record_movement(uuid, text, uuid, numeric, text, text, text, text, numeric, text, numeric)
  to authenticated;

drop function if exists public.finance_record_movement_plan(uuid, uuid, numeric, text, text, text, text, numeric, text);

create or replace function public.finance_record_movement_plan(
  p_request uuid,
  p_client uuid,
  p_amount numeric,
  p_concept text,
  p_currency text,
  p_method text,
  p_account text,
  p_fx numeric,
  p_plan text,
  p_cash_received numeric default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_terms jsonb;
  v_pre boolean;
  v_id uuid;
  v_plan jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_plan is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_amount is distinct from (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;

  select exists(select 1 from public.finance_entries where request_id = p_request) into v_pre;

  -- El cobro base es quien valida y guarda el efectivo.
  v_id := public.finance_record_movement(
    p_request, 'service_income', p_client, p_amount, p_currency,
    p_method, p_account, p_concept, p_fx, null, p_cash_received
  );

  if v_pre then
    -- Reintento de un cobro que ya existía: no se inventa vigencia.
    select jsonb_build_object(
      'id', s.id, 'plan_id', s.plan_id, 'access', s.access,
      'started_on', s.started_on, 'expires_on', s.expires_on,
      'days', s.expires_on - s.started_on + 1
    ) into v_plan
    from public.payment_plans s where s.request_id = p_request;
  else
    v_plan := public.plan_register_segment(p_client, p_plan, p_amount, p_currency, p_request, v_id, 'movement');
    v_plan := v_plan - 'validity';
  end if;

  return jsonb_build_object('id', v_id, 'plan', v_plan);
end $$;
revoke all on function public.finance_record_movement_plan(uuid, uuid, numeric, text, text, text, text, numeric, text, numeric)
  from public, anon, authenticated;
grant execute on function public.finance_record_movement_plan(uuid, uuid, numeric, text, text, text, text, numeric, text, numeric)
  to authenticated;

-- 4. Cobro con productos: el vuelto es del total (servicio + productos).
drop function if exists public.finance_record_checkout(uuid, uuid, numeric, text, text, text, text, numeric, jsonb);

create or replace function public.finance_record_checkout(
  p_request uuid, p_client uuid, p_service_amount numeric, p_service_concept text,
  p_currency text, p_method text, p_account text, p_fx numeric, p_items jsonb,
  p_cash_received numeric default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_result jsonb;
  v_total numeric;
  v_change numeric;
  v_first uuid;
  v_existing numeric;
  v_found boolean := false;
begin
  -- Se mira el grupo antes de escribir para no repetir un cobro con otro efectivo.
  if p_cash_received is not null then
    -- El efectivo se guarda en `result`, no en `payload`: el escritor base
    -- compara `payload` en los reintentos y agregarle algo lo volvería un
    -- conflicto falso.
    select (result->>'cashReceived')::numeric
      into v_existing
      from public.finance_checkout_groups
     where request_id = p_request;
    v_found := found;
    if v_found and coalesce(v_existing, -1) <> p_cash_received then
      raise exception 'REQUEST_CONFLICT';
    end if;
  end if;

  v_result := public.finance_record_checkout_before_cash(
    p_request, p_client, p_service_amount, p_service_concept,
    p_currency, p_method, p_account, p_fx, p_items
  );

  if p_cash_received is null then return v_result; end if;

  v_total := (v_result->>'total')::numeric;
  v_change := public.finance_cash_change(v_total, p_currency, p_account, p_cash_received);

  v_first := coalesce(
    nullif(v_result->>'serviceTransactionId', '')::uuid,
    nullif(v_result->'transactionIds'->>0, '')::uuid
  );
  if v_first is not null then
    perform public.finance_cash_stamp(v_first, p_cash_received, v_change);
  end if;

  update public.finance_checkout_groups
     set result = result || jsonb_build_object(
           'cashReceived', p_cash_received,
           'changeGiven', v_change
         )
   where request_id = p_request;

  return v_result || jsonb_build_object(
    'cashReceived', p_cash_received,
    'changeGiven', v_change
  );
end $$;
revoke all on function public.finance_record_checkout(uuid, uuid, numeric, text, text, text, text, numeric, jsonb, numeric)
  from public, anon, authenticated;
grant execute on function public.finance_record_checkout(uuid, uuid, numeric, text, text, text, text, numeric, jsonb, numeric)
  to authenticated;

drop function if exists public.finance_record_checkout_plan(uuid, uuid, numeric, text, text, text, text, numeric, jsonb, text);

create or replace function public.finance_record_checkout_plan(
  p_request uuid, p_client uuid, p_service_amount numeric, p_service_concept text,
  p_currency text, p_method text, p_account text, p_fx numeric, p_items jsonb,
  p_plan text, p_cash_received numeric default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_terms jsonb;
  v_pre boolean;
  v_result jsonb;
  v_tx uuid;
  v_plan jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_plan is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if (v_terms->>'access') = 'class' then raise exception 'PLAN_NOT_COMBINABLE'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_service_amount is distinct from (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;

  select exists(select 1 from public.finance_checkout_groups where request_id = p_request) into v_pre;

  v_result := public.finance_record_checkout(
    p_request, p_client, p_service_amount, p_service_concept,
    p_currency, p_method, p_account, p_fx, p_items, p_cash_received
  );

  if v_pre then
    select jsonb_build_object(
      'id', s.id, 'plan_id', s.plan_id,
      'access', case when s.class_id is null then 'gym' else 'class' end,
      'class_id', s.class_id,
      'started_on', s.started_on, 'expires_on', s.expires_on,
      'days', s.expires_on - s.started_on + 1
    ) into v_plan
    from public.payment_plans s where s.request_id = p_request;
  elsif p_service_amount > 0 then
    v_tx := nullif(v_result->>'serviceTransactionId', '')::uuid;
    v_plan := public.plan_register_segment(
      p_client, p_plan, p_service_amount, p_currency, p_request, v_tx, 'checkout'
    );
    v_plan := v_plan - 'validity';
  end if;

  return v_result || jsonb_build_object('plan', v_plan);
end $$;
revoke all on function public.finance_record_checkout_plan(uuid, uuid, numeric, text, text, text, text, numeric, jsonb, text, numeric)
  from public, anon, authenticated;
grant execute on function public.finance_record_checkout_plan(uuid, uuid, numeric, text, text, text, text, numeric, jsonb, text, numeric)
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00082_anulacion_devuelve_stock.sql
-- ═══════════════════════════════════════════════════════════

-- 00082 · FIN-08: al anular una venta, devolver el stock
--
-- Problema: FIN-01 anula el cobro y devuelve el dinero, pero la venta había
-- descontado stock y la anulación no lo reponía. El inventario quedaba corto
-- para siempre y la única salida era un ajuste manual sin rastro.
--
-- Decisión de esta etapa:
--   * La devolución ocurre en la misma transacción que la anulación: si algo
--     falla, no queda ni dinero revertido ni stock devuelto a medias.
--   * Se repone exactamente lo que esa venta descontó: una fila por cada
--     movimiento `venta` de la transacción original. No se borra ni se edita
--     ningún movimiento de stock anterior; se agrega una entrada nueva.
--   * La entrada lleva `note = 'Anulación de venta'`, la transacción de la
--     reversa y el precio unitario de la venta, para rastrear de dónde salió.
--   * Un solo tope: no se repone dos veces. Si la reversa ya tiene su entrada,
--     la función devuelve lo registrado y no agrega nada.
--   * Si el cobro no tenía productos, no hace nada y el comprobante no cambia.
--
-- El cuerpo de `finance_void_movement` es el de la 00080 con una línea nueva:
-- la llamada a la devolución. Las reglas de FIN-01 no cambian.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regprocedure('public.finance_void_movement(uuid,uuid,text)') is null
     or to_regclass('public.stock_movements') is null
     or to_regclass('public.products') is null then
    raise exception 'VOID_STOCK_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. Devolución de stock: función chica, una sola regla.
create or replace function public.finance_void_stock_restore(
  p_original uuid,
  p_reversal uuid
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb := '[]'::jsonb;
  v_line record;
  v_name text;
begin
  -- Idempotencia: si la reversa ya tiene su entrada de stock, se devuelve eso.
  if exists (
    select 1 from public.stock_movements where transaction_id = p_reversal
  ) then
    select coalesce(jsonb_agg(jsonb_build_object(
             'productId', s.product_id, 'name', p.name, 'qty', s.qty
           ) order by p.name), '[]'::jsonb)
      into v_rows
      from public.stock_movements s
      join public.products p on p.id = s.product_id
     where s.transaction_id = p_reversal;
    return v_rows;
  end if;

  for v_line in
    select s.product_id, s.qty, s.unit_price, s.client_id
      from public.stock_movements s
     where s.transaction_id = p_original
       and s.kind = 'venta'
       and s.qty < 0
     order by s.product_id
  loop
    insert into public.stock_movements(
      product_id, kind, qty, unit_price, client_id, transaction_id,
      request_id, note, created_by
    ) values (
      v_line.product_id, 'entrada', -v_line.qty, v_line.unit_price,
      v_line.client_id, p_reversal, gen_random_uuid(),
      'Anulación de venta', auth.uid()
    );
    select name into v_name from public.products where id = v_line.product_id;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'productId', v_line.product_id, 'name', v_name, 'qty', -v_line.qty
    ));
  end loop;

  return v_rows;
end $$;
revoke all on function public.finance_void_stock_restore(uuid, uuid)
  from public, anon, authenticated;

-- 2. Anulación: mismo cuerpo de la 00080, con la devolución adentro.

create or replace function public.finance_void_movement(
  p_request uuid,
  p_transaction uuid,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
set lock_timeout = '5s' as $$
declare
  v_t public.transactions;
  v_account public.bank_accounts;
  v_plan jsonb;
  v_existing public.finance_voids;
  v_payload jsonb;
  v_reason text := trim(coalesce(p_reason, ''));
  v_reversal uuid;
  v_actor_name text;
  v_actor_role text;
  v_after numeric;
  v_delta numeric;
  v_at timestamptz := clock_timestamp();
  v_receipt jsonb;
  v_void_id uuid;
  v_stock jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  if p_transaction is null then raise exception 'NOT_FOUND'; end if;
  if char_length(v_reason) not between 5 and 300 then
    raise exception 'INVALID_REASON';
  end if;

  v_payload := jsonb_build_object(
    'transaction', p_transaction,
    'reason', v_reason
  );

  perform pg_advisory_xact_lock(hashtextextended(p_request::text, 0));
  select * into v_existing from public.finance_voids where request_id = p_request;
  if found then
    if v_existing.payload is distinct from v_payload then
      raise exception 'REQUEST_CONFLICT';
    end if;
    return v_existing.receipt;
  end if;

  if not public.finance_writes_ready() then raise exception 'FINANCE_REVIEW_REQUIRED'; end if;

  select * into v_t from public.transactions where id = p_transaction for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  v_plan := public.finance_void_plan(p_transaction);
  if not coalesce((v_plan ->> 'allowed')::boolean, false) then
    raise exception '%', coalesce(v_plan ->> 'code', 'NOT_ALLOWED');
  end if;

  select full_name into v_actor_name from public.profiles where id = auth.uid() for share;
  if not found then raise exception 'AUTH'; end if;
  select role::text into v_actor_role from public.profiles where id = auth.uid();

  select * into v_account from public.bank_accounts where id = v_t.account_id for update;
  if not found then raise exception 'INVALID_ACCOUNT'; end if;
  if v_account.currency <> v_t.currency then raise exception 'INVALID_ACCOUNT'; end if;

  v_delta := case when v_t.type::text = 'expense' then v_t.amount else -v_t.amount end;
  v_after := v_account.balance + v_delta;
  if abs(v_after) > 9999999999.99 then raise exception 'INVALID_PAYMENT'; end if;

  insert into public.transactions(
    type, status, occurred_at, account_id, method_id, category_id, member_id,
    client_id, crm_request_id, amount, currency, amount_nio, amount_usd,
    fx_used, concept, created_by, created_at, updated_at
  ) values (
    case when v_t.type::text = 'expense'
      then 'income'::public.transaction_type
      else 'expense'::public.transaction_type end,
    'completed', v_at, v_t.account_id, v_t.method_id, v_t.category_id,
    v_t.member_id, v_t.client_id, p_request, v_t.amount, v_t.currency,
    v_t.amount_nio, v_t.amount_usd, v_t.fx_used,
    left('Anulación: ' || v_t.concept, 200), auth.uid(), v_at, v_at
  ) returning id into v_reversal;

  update public.bank_accounts set balance = v_after where id = v_t.account_id;

  -- FIN-08: la venta había descontado stock; la anulación lo devuelve.
  v_stock := public.finance_void_stock_restore(v_t.id, v_reversal);

  v_receipt := jsonb_build_object(
    'id', v_reversal,
    'reference', 'SG-' || v_reversal::text,
    'requestId', p_request,
    'kind', 'void',
    'originalId', v_t.id,
    'reversalId', v_reversal,
    'reason', v_reason,
    'occurredAt', v_at,
    'amount', v_t.amount,
    'currency', v_t.currency,
    'amountNio', v_t.amount_nio,
    'amountUsd', v_t.amount_usd,
    'originalConcept', v_t.concept,
    'concept', left('Anulación: ' || v_t.concept, 200),
    'clientId', v_t.client_id,
    'accountId', v_t.account_id,
    'accountName', v_account.name,
    'accountBefore', v_account.balance,
    'accountAfter', v_after,
    'stockRestored', v_stock,
    'actorId', auth.uid(),
    'actorName', v_actor_name
  );

  insert into public.finance_voids(
    request_id, original_id, reversal_id, reason, actor_id, actor_name,
    actor_role, payload, receipt
  ) values (
    p_request, v_t.id, v_reversal, v_reason, auth.uid(), v_actor_name,
    v_actor_role, v_payload, v_receipt
  ) returning id into v_void_id;


  if v_t.client_id is not null then
    insert into public.client_events(client_id, action, details, actor_id)
    values (
      v_t.client_id,
      'payment_void',
      jsonb_build_object(
        'transaction_id', v_t.id,
        'reversal_id', v_reversal,
        'void_id', v_void_id,
        'amount', v_t.amount,
        'currency', v_t.currency,
        'reason', v_reason
      ),
      auth.uid()
    );
  end if;

  return v_receipt;
end $$;
revoke all on function public.finance_void_movement(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.finance_void_movement(uuid, uuid, text) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00083_permiso_de_caja_ejecutable.sql
-- ═══════════════════════════════════════════════════════════

-- 00083 · La función que leen las políticas de caja vuelve a ser ejecutable
--
-- Qué pasó: la 00056 creó `finance_permission_enabled(text)` y, a propósito,
-- la dejó ejecutable por `authenticated`, porque **cuatro políticas RLS la
-- llaman directamente** dentro de su condición:
--
--   * `cashier_account_balances_restrictive` (bank_accounts)
--   * `cashier_receivables_member_balances` (member_balances)
--   * `cashier_receivables_client_balances` (client_debt_balances)
--   * `cashier_receivables_client_entries` (client_debt_entries)
--
-- La 00080 (anulación controlada) volvió a crear la misma función para sumar
-- el interruptor `cashier_can_void` y copió el `revoke all ...` sin el
-- `grant execute` que la 00056 sí tenía. Desde ese momento, cualquier lectura
-- de esas cuatro tablas por una sesión con rol `authenticated` fallaba con
-- `42501 permission denied for function finance_permission_enabled`, incluso
-- para administración: el permiso se comprueba al empezar la consulta, antes
-- de decidir si el `or` de la condición hacía falta. Lo que se veía en la app:
-- Reportes con «Información financiera no disponible · FIN_REPORT_DEBT_42501».
--
-- Qué hace esta migración:
--   1. Devuelve el `grant execute` a `authenticated`, que es lo que la 00056
--      ya había decidido. No se abre a `anon`: sin sesión no hay permiso que
--      consultar.
--   2. Deja una auditoría que falla si vuelve a pasar: si alguna política del
--      esquema `public` llama a una función que `authenticated` no puede
--      ejecutar, la migración se corta con el nombre de la función. Así el
--      error aparece al aplicar el SQL y no en la cara del dueño.
--
-- Nada de esto cambia datos, políticas ni permisos guardados: la función solo
-- devuelve verdadero o falso y no lee ninguna tabla del gimnasio que no sea
-- `staff_permissions`.
--
-- Reversible: volver a ejecutar el `revoke` de la 00080 deja el sistema como
-- estaba (roto para leer deudas). No se borra nada.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regprocedure('public.finance_permission_enabled(text)') is null then
    raise exception 'CASHIER_PERMISSION_PREREQUISITE_MISSING';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise exception 'CASHIER_PERMISSION_ROLE_MISSING';
  end if;
end $$;

grant execute on function public.finance_permission_enabled(text) to authenticated;

-- Auditoría: toda función usada dentro de una política tiene que poder ser
-- ejecutada por `authenticated`. Si no, la política hace fallar la lectura
-- entera con 42501 en vez de permitir o negar filas.
do $$
declare
  v_missing text;
begin
  select string_agg(distinct p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_missing
    from pg_policies pol
    cross join lateral regexp_matches(
      coalesce(pol.qual, '') || ' ' || coalesce(pol.with_check, ''),
      '([a-z_][a-z0-9_]*)[[:space:]]*\(', 'g'
    ) as m(nombre)
    join pg_proc p on p.proname = m.nombre[1]
    join pg_namespace ns on ns.oid = p.pronamespace and ns.nspname = 'public'
   where pol.schemaname = 'public'
     and not has_function_privilege('authenticated', p.oid, 'execute');

  if v_missing is not null then
    raise exception 'POLICY_FUNCTION_NOT_EXECUTABLE: %', v_missing;
  end if;
end $$;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00084_movimientos_paginados.sql
-- ═══════════════════════════════════════════════════════════

-- 00084 · Buscar y paginar todo el historial de movimientos desde el servidor
--
-- Qué faltaba (FIN-05): la pantalla de Caja leía los **últimos 30** movimientos
-- y los filtraba en el navegador. Eso alcanza para mirar el día, pero no para
-- encontrar un cobro viejo: el movimiento existía y la pantalla no podía
-- mostrarlo. "Buscar" solo buscaba dentro de esos 30.
--
-- Qué agrega esta migración:
--   `finance_movements_page(...)` devuelve, en una sola consulta, la cantidad
--   total que cumple los filtros y **solo la página pedida** (25 por defecto).
--   Filtra por búsqueda de texto (concepto, notas, nombre del cliente y del
--   socio), tipo, estado, moneda y método de pago, y ordena siempre igual
--   (`occurred_at desc, id desc`) para que la paginación no repita ni saltee
--   filas.
--
-- Reglas de seguridad:
--   · Devuelve el mismo perfil que ya lee Caja: `crm_is_staff()` (sesión con
--     segundo factor y rol de administración o caja). Sin eso: `AUTH`.
--   · `p_hide_expenses` lo manda el servidor cuando el interruptor de gastos
--     de caja está apagado. No se confía en el navegador para ocultar egresos:
--     se excluyen en la consulta y tampoco se cuentan en el total.
--   · La búsqueda escapa `%`, `_` y `\`: escribir un comodín no cambia el
--     resultado ni permite traer todo.
--   · Es de solo lectura: no escribe, no bloquea filas y no borra nada.
--
-- Qué NO cambia: la RLS de `transactions` ni sus políticas, las funciones de
-- escritura, los comprobantes, los reportes ni las exportaciones (esas ya
-- leían por páginas). Ninguna tabla ni columna nueva.
--
-- Reversible: `drop function public.finance_movements_page(text, text, text,
-- text, text, boolean, integer, integer);` deja el sistema como estaba. No se
-- borra ni se migra ningún dato.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.transactions') is null
     or to_regclass('public.gym_clients') is null
     or to_regclass('public.finance_voids') is null
     or to_regprocedure('public.crm_is_staff()') is null then
    raise exception 'MOVEMENTS_PREREQUISITE_MISSING';
  end if;
  -- Las columnas que lee la función. Si el modelo de movimientos cambia otra
  -- vez, esto corta al aplicar el SQL y no en la cara del dueño.
  if exists (
    select 1
    from unnest(array[
      'id', 'type', 'status', 'occurred_at', 'amount', 'currency',
      'amount_nio', 'fx_used', 'method_id', 'account_id', 'member_id',
      'category_id', 'concept', 'notes', 'created_by', 'client_id'
    ]) required(column_name)
    where not exists (
      select 1 from pg_catalog.pg_attribute a
      where a.attrelid = 'public.transactions'::regclass
        and a.attname = required.column_name
        and a.attnum > 0
        and not a.attisdropped
    )
  ) then
    raise exception 'MOVEMENTS_COLUMNS_MISSING';
  end if;
end $$;

-- El historial se ordena y se pagina por fecha: el índice ya existe
-- (`transactions_occurred_idx`). Este otro acompaña el desempate por `id`,
-- que es lo que evita filas repetidas entre páginas.
create index if not exists transactions_occurred_id_idx
  on public.transactions (occurred_at desc, id desc);

create or replace function public.finance_movements_page(
  p_search text default '',
  p_direction text default '',
  p_status text default '',
  p_currency text default '',
  p_method text default 'all',
  p_hide_expenses boolean default false,
  p_limit integer default 25,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := btrim(coalesce(p_search, ''));
  v_pattern text;
  v_direction text := nullif(btrim(coalesce(p_direction, '')), '');
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_currency text := nullif(btrim(coalesce(p_currency, '')), '');
  v_method text := nullif(btrim(coalesce(p_method, '')), '');
  v_total integer;
  v_rows jsonb;
begin
  if not public.crm_is_staff() then
    raise exception 'AUTH';
  end if;

  if char_length(v_search) > 80 then
    raise exception 'INVALID_SEARCH';
  end if;
  -- Los valores válidos se leen del enum real: si mañana se agrega un tipo de
  -- movimiento, esta función lo acepta sin tocar el código.
  if v_direction is not null
     and v_direction not in (
       select unnest(enum_range(null::public.transaction_type))::text
     ) then
    raise exception 'INVALID_DIRECTION';
  end if;
  -- `reversed` no está en el enum de la base pero sí en la lista de la
  -- pantalla (movimientos revertidos del modelo anterior): se acepta y
  -- devuelve lo que haya, en vez de un error por una opción visible.
  if v_status is not null
     and v_status <> 'reversed'
     and v_status not in (
       select unnest(enum_range(null::public.transaction_status))::text
     ) then
    raise exception 'INVALID_STATUS';
  end if;
  -- Las monedas del gimnasio son las mismas dos que elige el navegador y que
  -- acepta el cobro. Se listan acá a propósito: la columna es de texto libre,
  -- así que validarla contra el enum de otra tabla sería adivinar.
  if v_currency is not null and v_currency not in ('NIO', 'USD') then
    raise exception 'INVALID_CURRENCY';
  end if;

  -- Comodines literales: sin esto, buscar "%" traería todo el historial.
  v_pattern := '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  -- Total y página en una sola consulta: el CTE no se puede reutilizar entre
  -- dos sentencias, y contar dos veces podría dar números distintos si alguien
  -- cobra en el medio.
  with filtered as (
    select
      t.id, t.occurred_at, t.type, t.status, t.amount, t.currency,
      t.fx_used, t.amount_nio, t.method_id, t.account_id, t.member_id,
      t.category_id, t.concept, t.notes, t.created_by,
      c.full_name as client_name,
      p.full_name as member_name,
      v.reason as voided_reason
    from public.transactions t
    left join public.gym_clients c on c.id = t.client_id
    left join public.profiles p on p.id = t.member_id
    left join public.finance_voids v on v.original_id = t.id
    where (not coalesce(p_hide_expenses, false) or t.type <> 'expense')
      and (v_direction is null or t.type::text = v_direction)
      and (v_status is null or t.status::text = v_status)
      and (v_currency is null or t.currency::text = v_currency)
      and (
        v_method is null
        or v_method = 'all'
        or (v_method = 'none' and t.method_id is null)
        or t.method_id = v_method
      )
      and (
        v_search = ''
        or t.concept ilike v_pattern
        or coalesce(t.notes, '') ilike v_pattern
        or coalesce(c.full_name, '') ilike v_pattern
        or coalesce(p.full_name, '') ilike v_pattern
      )
  ), page as (
    select * from filtered
    order by occurred_at desc, id desc
    limit v_limit offset v_offset
  )
  select
    (select count(*) from filtered)::integer,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', page.id,
            'occurred_at', page.occurred_at,
            -- El panel llama «dirección» a lo que la base guarda como tipo.
            'direction', page.type,
            'status', page.status,
            'amount', page.amount,
            'currency', page.currency,
            'fx_rate', page.fx_used,
            'base_amount', page.amount_nio,
            'payment_method_id', page.method_id,
            'account_id', page.account_id,
            'member_id', page.member_id,
            'member', case
              when page.member_name is null then null
              else jsonb_build_object('full_name', page.member_name)
            end,
            'expense_category_id', page.category_id,
            'concept', page.concept,
            'notes', page.notes,
            'created_by', page.created_by,
            'client', case
              when page.client_name is null then null
              else jsonb_build_object('full_name', page.client_name)
            end,
            'voided_reason', page.voided_reason
          )
          order by page.occurred_at desc, page.id desc
        )
        from page
      ),
      '[]'::jsonb
    )
  into v_total, v_rows;

  return jsonb_build_object(
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'rows', v_rows
  );
end $$;

revoke all on function public.finance_movements_page(text, text, text, text, text, boolean, integer, integer) from public, anon;
grant execute on function public.finance_movements_page(text, text, text, text, text, boolean, integer, integer) to authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00085_anular_da_de_baja_la_vigencia.sql
-- ═══════════════════════════════════════════════════════════

-- 00085 · Anular un cobro da de baja la vigencia que activó
--
-- Qué estaba mal: se anulaba el cobro, el dinero volvía a la caja y la
-- membresía seguía corriendo como si nada. La persona conservaba los días
-- aunque no había pagado: era una fuga de dinero silenciosa, y ninguna
-- pantalla lo decía.
--
-- Qué hace ahora, con una sola regla:
--   * El segmento de vigencia que nació de ese cobro queda **anulado**
--     (`voided_at`, `voided_reason`, `voided_by`, `void_id`). No se borra.
--   * Los segmentos que venían encadenados detrás se **adelantan** los días
--     que se quitaron, para que nadie pierda ni gane días: si se anula un mes,
--     el mes siguiente empieza donde empezaba el anulado.
--   * Un hueco real (la persona dejó vencer y volvió después) **no se toca**:
--     solo se encoge una cadena contigua.
--   * Todo movimiento de fechas queda en `plan_validity_log` con las fechas de
--     antes y de después, quién lo hizo y por qué. Reversible: las fechas
--     originales están guardadas ahí.
--
-- Cómo se engancha: un disparador en `finance_voids` aplica esto a **toda**
-- anulación, venga de la pantalla de Caja o de una ruta interna. Anular una
-- venta de producto o un gasto no tiene segmentos y no cambia nada.
--
-- Qué NO cambia: la anulación sigue siendo solo de administración o caja con
-- segundo factor, solo del día en curso para caja, con el interruptor de
-- anulación y con motivo escrito. Sigue sin borrar nada: la reversa, el
-- movimiento original y el segmento anulado quedan en la base.
--
-- Reversible: `drop trigger ... ; drop function plan_void_segments, plan_relayout_segments;
-- alter table public.payment_plans drop column voided_at, ... ; drop table plan_validity_log;`
-- Las fechas adelantadas se pueden reponer desde `plan_validity_log`.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.payment_plans') is null
     or to_regclass('public.plans') is null
     or to_regclass('public.classes') is null
     or to_regclass('public.finance_voids') is null
     or to_regprocedure('public.crm_is_staff()') is null then
    raise exception 'PLAN_VOID_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. La marca de anulación. Nada se borra: el segmento sigue en la ficha.
alter table public.payment_plans add column if not exists voided_at timestamptz;
alter table public.payment_plans add column if not exists voided_reason text;
alter table public.payment_plans add column if not exists voided_by uuid;
alter table public.payment_plans add column if not exists void_id uuid;

create index if not exists payment_plans_transaction_idx
  on public.payment_plans (transaction_id)
  where transaction_id is not null;
create index if not exists payment_plans_live_idx
  on public.payment_plans (client_id, started_on)
  where voided_at is null;

-- 2. Bitácora de fechas. Solo la leen las funciones de abajo.
create table if not exists public.plan_validity_log (
  id         uuid primary key default gen_random_uuid(),
  plan_row   uuid,
  client_id  uuid,
  action     text not null,
  before     jsonb,
  after      jsonb,
  reason     text,
  actor_id   uuid,
  void_id    uuid,
  created_at timestamptz not null default now()
);
alter table public.plan_validity_log enable row level security;
revoke all on public.plan_validity_log from public, anon, authenticated;
create index if not exists plan_validity_log_client_idx
  on public.plan_validity_log (client_id, created_at desc);

create or replace function public.plan_class_state(p_client uuid, p_class_id text, p_today date)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_row record;
  v_key text := coalesce(p_class_id, 'gym');
  v_label text;
begin
  select name_es into v_label from public.classes where id = p_class_id;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and voided_at is null
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
     and started_on <= p_today and expires_on >= p_today
   order by expires_on desc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'active', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on,
      'days_left', v_row.expires_on - p_today + 1
    );
  end if;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and voided_at is null
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
     and started_on > p_today
   order by started_on asc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'upcoming', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on, 'days_left', 0
    );
  end if;

  select plan_id, started_on, expires_on into v_row
    from public.payment_plans
   where client_id = p_client
     and voided_at is null
     and ((p_class_id is null and access = 'gym') or (p_class_id is not null and class_id = p_class_id))
   order by expires_on desc
   limit 1;
  if found then
    return jsonb_build_object(
      'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
      'state', 'expired', 'plan_id', v_row.plan_id,
      'starts_on', v_row.started_on, 'expires_on', v_row.expires_on, 'days_left', 0
    );
  end if;

  return jsonb_build_object(
    'key', v_key, 'label', coalesce(v_label, 'Gimnasio'),
    'state', 'none', 'plan_id', null,
    'starts_on', null, 'expires_on', null, 'days_left', 0
  );
end $$;
revoke all on function public.plan_class_state(uuid, text, date) from public, anon, authenticated;
create or replace function public.plan_validity_summary(p_client uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_today date := public.plan_local_today();
begin
  return jsonb_build_object(
    'today', v_today,
    'gym', public.plan_class_state(p_client, null::text, v_today),
    'classes', coalesce((
      select jsonb_agg(public.plan_class_state(p_client, c.id, v_today) order by c.sort_order, c.name_es)
      from public.classes c
      where c.is_active
        and (
          exists(select 1 from public.payment_plans s where s.client_id = p_client and s.class_id = c.id and s.voided_at is null)
          or exists(select 1 from public.plans p
                     where p.is_active and p.access_kind = 'class' and p.class_id = c.id
                       and p.duration_days is not null)
        )
    ), '[]'::jsonb),
    'segments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'plan_id', s.plan_id,
        'access', case when s.class_id is null then 'gym' else 'class' end,
        'class_id', s.class_id,
        'class_name', (select name_es from public.classes where id = s.class_id),
        'started_on', s.started_on,
        'expires_on', s.expires_on,
        'price', s.price_paid,
        'currency', s.currency
      ) order by s.started_on desc, s.expires_on desc)
      from public.payment_plans s
     where s.client_id = p_client and s.voided_at is null
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.plan_validity_summary(uuid) from public, anon, authenticated;
create or replace function public.plan_register_segment(
  p_client uuid,
  p_plan text,
  p_amount numeric,
  p_currency text,
  p_request uuid,
  p_transaction uuid,
  p_source text
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_terms jsonb;
  v_existing public.payment_plans;
  v_today date;
  v_chain date;
  v_start date;
  v_end date;
  v_id uuid;
  v_class text;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  v_terms := public.plan_validity_terms(p_plan);
  if v_terms is null then raise exception 'PLAN_TERMS_INVALID'; end if;
  if (v_terms->>'amount') is null then raise exception 'PLAN_PRICE_MISSING'; end if;
  if p_currency is distinct from (v_terms->>'currency')
     or p_amount is null
     or p_amount <> (v_terms->>'amount')::numeric then
    raise exception 'PLAN_PRICE_MISMATCH';
  end if;
  if p_source not in ('movement', 'checkout', 'crm') then raise exception 'INVALID_REQUEST'; end if;

  v_class := nullif(v_terms->>'class_id', '');

  select * into v_existing from public.payment_plans where request_id = p_request;
  if found then
    if v_existing.client_id is distinct from p_client
       or v_existing.plan_id::text is distinct from p_plan then
      raise exception 'REQUEST_CONFLICT';
    end if;
    return jsonb_build_object(
      'id', v_existing.id, 'plan_id', v_existing.plan_id,
      'access', case when v_existing.class_id is null then 'gym' else 'class' end,
      'class_id', v_existing.class_id,
      'started_on', v_existing.started_on, 'expires_on', v_existing.expires_on,
      'days', v_existing.expires_on - v_existing.started_on + 1,
      'validity', public.plan_validity_summary(p_client)
    );
  end if;

  perform 1 from public.gym_clients where id = p_client for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_transaction is not null and exists(
    select 1 from public.payment_plans where transaction_id = p_transaction
  ) then
    raise exception 'REQUEST_CONFLICT';
  end if;

  v_today := public.plan_local_today();
  -- Encadena solo dentro del mismo acceso: gimnasio con gimnasio, Zumba con
  -- Zumba. Dos accesos distintos no se roban días entre sí.
  select max(expires_on) into v_chain
    from public.payment_plans
   where client_id = p_client
     and voided_at is null
     and ((v_class is null and access = 'gym') or (v_class is not null and class_id = v_class))
     and expires_on >= v_today;
  v_start := case when v_chain is null then v_today else v_chain + 1 end;
  v_end := v_start + ((v_terms->>'days')::integer - 1);

  insert into public.payment_plans(
    client_id, plan_id, access, class_id, started_on, expires_on, price_paid,
    currency, request_id, transaction_id, source, created_by
  ) values (
    p_client, p_plan, case when v_class is null then 'gym' else 'class' end, v_class,
    v_start, v_end, p_amount, p_currency, p_request, p_transaction, p_source, auth.uid()
  ) returning id into v_id;

  return jsonb_build_object(
    'id', v_id, 'plan_id', p_plan,
    'access', case when v_class is null then 'gym' else 'class' end,
    'class_id', v_class,
    'started_on', v_start, 'expires_on', v_end,
    'days', (v_terms->>'days')::integer,
    'validity', public.plan_validity_summary(p_client)
  );
end $$;
revoke all on function public.plan_register_segment(uuid, text, numeric, text, uuid, uuid, text) from public, anon, authenticated;
create or replace function public.client_category_eval(p_client uuid, p_today date)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_gym jsonb;
  v_classes jsonb;
  v_gym_days integer := 0;
  v_class_days integer := 0;
  v_valid_days integer := 0;
  v_has_validity boolean := false;
  v_visits integer := 0;
  v_purchases integer := 0;
  v_visit_rule integer := 0;
  v_counts integer := 0;
  v_rule public.category_rules;
  v_matched boolean := false;
  v_cat text;
  v_label text := 'sin vigencia';
begin
  v_gym := public.plan_class_state(p_client, null::text, p_today);

  -- Días comprados del segmento vigente más largo de cada acceso.
  select coalesce(max(expires_on - started_on + 1), 0) into v_gym_days
    from public.payment_plans
   where client_id = p_client and access = 'gym' and voided_at is null
     and started_on <= p_today and expires_on >= p_today;
  select coalesce(max(expires_on - started_on + 1), 0) into v_class_days
    from public.payment_plans
   where client_id = p_client and class_id is not null and voided_at is null
     and started_on <= p_today and expires_on >= p_today;

  v_valid_days := greatest(v_gym_days, v_class_days);
  v_has_validity := v_valid_days > 0;

  v_classes := coalesce((
    select jsonb_agg(jsonb_build_object(
      'class_id', s.class_id,
      'class_name', (select name_es from public.classes where id = s.class_id),
      'plan_id', s.plan_id,
      'started_on', s.started_on,
      'expires_on', s.expires_on,
      'days', s.expires_on - s.started_on + 1
    ) order by s.expires_on desc)
    from public.payment_plans s
   where s.client_id = p_client and s.class_id is not null and s.voided_at is null
     and s.started_on <= p_today and s.expires_on >= p_today
  ), '[]'::jsonb);

  -- Datos informativos, siempre con la ventana de la regla «amigo» vigente.
  select coalesce(max(visits_window_days), 30) into v_visit_rule
    from public.category_rules where category = 'amigo';
  select count(*) into v_visits from public.client_visits
   where client_id = p_client
     and local_day > p_today - v_visit_rule
     and local_day <= p_today;
  select count(*) into v_purchases from public.stock_movements
   where client_id = p_client and kind = 'venta'
     and created_at >= now() - interval '90 days';

  -- Primera regla activa que cumple, en el orden que fijó el administrador.
  for v_rule in
    select * from public.category_rules
     where is_active and not is_fallback
     order by sort_order, category
  loop
    if v_rule.requires_validity and v_valid_days < v_rule.validity_days_min then
      continue;
    end if;
    if v_rule.forbids_validity and v_has_validity then
      continue;
    end if;
    if v_rule.requires_purchase_window_days is not null then
      select count(*) into v_counts from public.stock_movements m
       where m.client_id = p_client and m.kind = 'venta'
         and m.created_at >= now() - make_interval(days => v_rule.requires_purchase_window_days);
      if v_counts = 0 then continue; end if;
    end if;
    if v_rule.visits_min > 0 then
      select count(*) into v_counts from public.client_visits v
       where v.client_id = p_client
         and v.local_day > p_today - v_rule.visits_window_days
         and v.local_day <= p_today;
      if v_counts < v_rule.visits_min then continue; end if;
    end if;
    v_cat := v_rule.category;
    v_matched := true;
    exit;
  end loop;

  -- Si ninguna regla cumple, la categoría de reserva configurada.
  if not v_matched then
    select category into v_cat from public.category_rules
     where is_fallback and is_active order by sort_order limit 1;
    v_cat := coalesce(v_cat, 'comun');
  end if;

  if v_gym_days > 0 then
    v_label := 'gimnasio vigente';
  elsif v_class_days > 0 then
    v_label := 'plan de disciplina vigente';
  elsif v_visits > 0 then
    v_label := v_visits || case when v_visits = 1 then ' visita en ' else ' visitas en ' end
               || v_visit_rule || ' días';
  end if;

  return jsonb_build_object(
    'category', v_cat,
    'reason', v_label,
    'validity_days', v_valid_days,
    'gym_days', v_gym_days,
    'class_days', v_class_days,
    'gym', v_gym,
    'classes', v_classes,
    'visits_30_days', v_visits,
    'purchases_90_days', v_purchases,
    'visits_window_days', v_visit_rule
  );
end $$;
revoke all on function public.client_category_eval(uuid, date) from public, anon, authenticated;

-- 3. Recolocar una cadena de vigencia de un acceso (gimnasio o una clase).
--
-- La regla es simple: se recorre la línea de tiempo en orden; los segmentos
-- anulados no consumen días; los que venían pegados al anterior se corren
-- para atrás; si había un hueco real, la fecha se respeta. Correr esto dos
-- veces deja el mismo resultado (se recalcula desde las fechas guardadas y,
-- como todos los segmentos de la cadena se corren igual, la cadena sigue
-- siendo contigua).
create or replace function public.plan_relayout_segments(
  p_client uuid,
  p_class text,
  p_reason text,
  p_void uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_prev_end date;   -- fin guardado del segmento anterior, para ver si había hueco
  v_cursor date;     -- primer día libre de la cadena
  v_start date;
  v_end date;
  v_days integer;
  v_changed jsonb := '[]'::jsonb;
begin
  for v_row in
    select id, started_on, expires_on, voided_at
      from public.payment_plans
     where client_id = p_client
       and ((p_class is null and access = 'gym') or (p_class is not null and class_id = p_class))
     order by started_on, created_at, id
  loop
    if v_cursor is null then
      v_cursor := v_row.started_on;
    elsif v_row.started_on > v_prev_end + 1 then
      -- La persona dejó vencer y volvió otro día: ese hueco no se rellena.
      v_cursor := v_row.started_on;
    end if;

    if v_row.voided_at is null then
      v_days := v_row.expires_on - v_row.started_on + 1;
      v_start := v_cursor;
      v_end := v_cursor + v_days - 1;
      if v_start <> v_row.started_on or v_end <> v_row.expires_on then
        update public.payment_plans
           set started_on = v_start, expires_on = v_end
         where id = v_row.id;
        insert into public.plan_validity_log(
          plan_row, client_id, action, before, after, reason, actor_id, void_id
        ) values (
          v_row.id, p_client, 'shift',
          jsonb_build_object('started_on', v_row.started_on, 'expires_on', v_row.expires_on),
          jsonb_build_object('started_on', v_start, 'expires_on', v_end),
          p_reason, auth.uid(), p_void
        );
        v_changed := v_changed || jsonb_build_array(jsonb_build_object(
          'id', v_row.id, 'startedOn', v_start, 'expiresOn', v_end
        ));
      end if;
      v_cursor := v_end + 1;
    end if;

    v_prev_end := v_row.expires_on;
  end loop;
  return v_changed;
end $$;
revoke all on function public.plan_relayout_segments(uuid, text, text, uuid) from public, anon, authenticated;

-- 4. Dar de baja las vigencias de un cobro anulado.
create or replace function public.plan_void_segments(
  p_transaction uuid,
  p_reason text,
  p_void uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key record;
  v_marked integer := 0;
  v_changed jsonb := '[]'::jsonb;
begin
  if not public.crm_is_staff() then
    raise exception 'AUTH';
  end if;
  if p_transaction is null then
    raise exception 'INVALID_TRANSACTION';
  end if;

  update public.payment_plans
     set voided_at = now(),
         voided_reason = nullif(btrim(coalesce(p_reason, '')), ''),
         voided_by = auth.uid(),
         void_id = p_void
   where transaction_id = p_transaction
     and voided_at is null;
  get diagnostics v_marked = row_count;

  if v_marked > 0 then
    insert into public.plan_validity_log(
      plan_row, client_id, action, before, after, reason, actor_id, void_id
    )
    select s.id, s.client_id, 'void_segment',
           jsonb_build_object('started_on', s.started_on, 'expires_on', s.expires_on),
           jsonb_build_object('voided', true, 'transaction_id', s.transaction_id),
           p_reason, auth.uid(), p_void
      from public.payment_plans s
     where s.transaction_id = p_transaction;

    for v_key in
      select distinct client_id, class_id
        from public.payment_plans
       where transaction_id = p_transaction
    loop
      v_changed := v_changed || public.plan_relayout_segments(
        v_key.client_id, v_key.class_id, p_reason, p_void
      );
    end loop;
  end if;

  return jsonb_build_object('voided', v_marked, 'shifted', v_changed);
end $$;
revoke all on function public.plan_void_segments(uuid, text, uuid) from public, anon, authenticated;

-- 5. Enganche: cualquier anulación registrada da de baja sus vigencias.
create or replace function public.plan_void_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Si esto falla, falla la anulación completa: es preferible a dejar el
  -- dinero devuelto y la membresía corriendo sin que nadie lo note.
  perform public.plan_void_segments(new.original_id, new.reason, new.id);
  return new;
end $$;
revoke all on function public.plan_void_after_insert() from public, anon, authenticated;

drop trigger if exists plan_void_after_insert on public.finance_voids;
create trigger plan_void_after_insert
  after insert on public.finance_voids
  for each row execute function public.plan_void_after_insert();

-- 6. Alinear lo que ya estaba anulado antes de esta migración.
--
-- No se inventa nada: se marca el segmento cuyo cobro ya tiene una anulación
-- guardada en `finance_voids` y se corre la misma recolocación. Queda en la
-- bitácora con el motivo real de aquella anulación.
update public.payment_plans s
   set voided_at = fv.created_at,
       voided_reason = fv.reason,
       voided_by = fv.actor_id,
       void_id = fv.id
  from public.finance_voids fv
 where fv.original_id = s.transaction_id
   and s.voided_at is null;

do $$
declare v_key record;
begin
  for v_key in
    select distinct s.client_id, s.class_id
      from public.payment_plans s
      join public.finance_voids fv on fv.original_id = s.transaction_id
  loop
    perform public.plan_relayout_segments(
      v_key.client_id, v_key.class_id, 'alineación de anulaciones anteriores', null
    );
  end loop;
end $$;

-- 7. Lecturas: los segmentos anulados no cuentan para la vigencia.

-- 8. Qué vigencia activó un cobro (para avisar antes de anular y contarlo
-- después). La pantalla de Caja lo usa; no decide nada.
create or replace function public.finance_void_plan_impact(p_transaction uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := (now() at time zone 'America/Managua')::date;
  v_rows jsonb;
begin
  if not public.crm_is_staff() then
    raise exception 'AUTH';
  end if;
  if p_transaction is null then
    raise exception 'INVALID_TRANSACTION';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'planId', s.plan_id,
        'planName', coalesce(nullif(pl.name_es, ''), s.plan_id),
        'access', case when s.class_id is null then 'gym' else 'class' end,
        'startedOn', s.started_on,
        'expiresOn', s.expires_on,
        'pricePaid', s.price_paid,
        'currency', s.currency,
        'voided', s.voided_at is not null,
        'state', case
          when s.voided_at is not null then 'voided'
          when s.started_on <= v_today and s.expires_on >= v_today then 'active'
          when s.started_on > v_today then 'upcoming'
          else 'expired'
        end
      )
      order by s.started_on
    ),
    '[]'::jsonb
  )
  into v_rows
  from public.payment_plans s
  left join public.plans pl on pl.id = s.plan_id
  where s.transaction_id = p_transaction;

  return v_rows;
end $$;

revoke all on function public.finance_void_plan_impact(uuid) from public, anon;
grant execute on function public.finance_void_plan_impact(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00086_planes_uso_y_precio.sql
-- ═══════════════════════════════════════════════════════════

-- 00086 · Cuánta gente tiene cada plan y qué precio tuvo antes
--
-- Qué faltaba en Administración → Planes y modalidades:
--   1. La lista solo decía «Mes · 30 días · Todo el gimnasio · C$560». Para
--      contestar «¿cuánta gente tiene este plan?» había que ir ficha por ficha,
--      y no había forma de ver juntas a las personas de un plan.
--   2. Al cambiar un precio, el anterior se perdía. Un cobro de ayer a C$560
--      no se podía explicar mirando la pantalla, porque nadie guardaba cuándo
--      cambió ni quién lo cambió.
--
-- Qué agrega, y solo esto:
--   * `plan_price_log`: cada alta y cada cambio de precio de un plan, con el
--     valor de antes, el de después, quién y cuándo. Lo llena un disparador en
--     `plans`, así cubre las **dos** puertas que tocan precios (el editor de
--     tarifas rápidas y el catálogo de planes) sin repetir la regla en cada
--     función. Solo escribe cuando un precio cambió de verdad.
--   * `admin_plans_catalog()` suma a cada plan cuántas personas lo tienen
--     vigente, cuántas lo tienen por empezar, cuántos cobros hubo este mes y
--     el último cambio de precio.
--   * `admin_plan_usage(p_plan)` devuelve la lista de esas personas con su
--     vencimiento y el historial de precios del plan.
--
-- Qué NO hace: no cambia precios, no crea ni borra planes, no toca cobros ni
-- vigencias. Es lectura más una bitácora que se llena sola.
--
-- Sin datos inventados: los planes que ya existían **no** reciben un registro
-- histórico con fecha falsa; su primer registro es el primer cambio real que
-- ocurra después de esta migración. La pantalla lo dice así.
--
-- Seguridad: las tres piezas exigen `is_admin()` (administración con segundo
-- factor). La tabla no se entrega a `anon` ni a `authenticated`: se lee solo
-- por las funciones.
--
-- Reversible: `drop trigger ... on public.plans; drop function
-- plan_price_capture, admin_plan_usage; drop table public.plan_price_log;` y
-- volver a aplicar `admin_plans_catalog()` de la 00068.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.plans') is null
     or to_regclass('public.payment_plans') is null
     or to_regclass('public.gym_clients') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.plan_local_today()') is null then
    raise exception 'PLAN_USAGE_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. Bitácora de precios. Mismos criterios que `class_audit` (00077).
create table if not exists public.plan_price_log (
  id             uuid primary key default gen_random_uuid(),
  plan_id        text not null,
  action         text not null check (action in ('alta', 'edicion')),
  before         jsonb,
  after          jsonb not null,
  changed_fields text[] not null default '{}',
  changed_by     uuid references public.profiles (id) on delete set null,
  changed_at     timestamptz not null default now()
);

create index if not exists plan_price_log_plan_idx
  on public.plan_price_log (plan_id, changed_at desc);

alter table public.plan_price_log enable row level security;
revoke all on public.plan_price_log from public, anon, authenticated;

-- 2. Llenado automático. Un solo lugar para las dos pantallas que editan
--    precios; si el valor no cambió, no se escribe nada.
create or replace function public.plan_price_capture()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_fields text[] := '{}';
begin
  v_after := jsonb_build_object(
    'price_nio', new.price_nio,
    'price', new.price,
    'validity_currency', new.validity_currency,
    'validity_amount', new.validity_amount
  );

  if tg_op = 'INSERT' then
    insert into public.plan_price_log(plan_id, action, before, after, changed_fields, changed_by)
    values (
      new.id, 'alta', null, v_after,
      array['price_nio', 'price', 'validity_currency', 'validity_amount'],
      auth.uid()
    );
    return new;
  end if;

  v_before := jsonb_build_object(
    'price_nio', old.price_nio,
    'price', old.price,
    'validity_currency', old.validity_currency,
    'validity_amount', old.validity_amount
  );
  if new.price_nio is distinct from old.price_nio then
    v_fields := v_fields || 'price_nio'::text;
  end if;
  if new.price is distinct from old.price then
    v_fields := v_fields || 'price'::text;
  end if;
  if new.validity_currency is distinct from old.validity_currency then
    v_fields := v_fields || 'validity_currency'::text;
  end if;
  if new.validity_amount is distinct from old.validity_amount then
    v_fields := v_fields || 'validity_amount'::text;
  end if;

  if cardinality(v_fields) = 0 then
    return new;
  end if;

  insert into public.plan_price_log(plan_id, action, before, after, changed_fields, changed_by)
  values (new.id, 'edicion', v_before, v_after, v_fields, auth.uid());
  return new;
end $$;
revoke all on function public.plan_price_capture() from public, anon, authenticated;

drop trigger if exists plan_price_capture on public.plans;
create trigger plan_price_capture
  after insert or update on public.plans
  for each row execute function public.plan_price_capture();

-- 3. Catálogo con el uso de cada plan.
create or replace function public.admin_plans_catalog()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_today date := public.plan_local_today();
  -- Primer instante del mes en curso, en la hora de Managua.
  v_month timestamptz := date_trunc('month', v_today) at time zone 'America/Managua';
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  return jsonb_build_object(
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'slug', p.slug, 'name_es', p.name_es, 'name_en', p.name_en,
        'period', p.period, 'price_nio', p.price_nio, 'price', p.price,
        'access_kind', p.access_kind, 'class_id', p.class_id,
        'class_name', (select name_es from public.classes where id = p.class_id),
        'duration_days', p.duration_days,
        'validity_currency', p.validity_currency,
        'validity_amount', p.validity_amount,
        'is_active', p.is_active, 'sort_order', p.sort_order,
        'updated_at', p.updated_at,
        -- Quiénes lo tienen hoy, quiénes lo tienen por empezar y cuántos se
        -- cobraron este mes. Los segmentos anulados no cuentan (00085).
        'holders_active', (
          select count(*)::int from public.payment_plans s
           where s.plan_id = p.id and s.voided_at is null
             and s.started_on <= v_today and s.expires_on >= v_today
        ),
        'holders_upcoming', (
          select count(*)::int from public.payment_plans s
           where s.plan_id = p.id and s.voided_at is null and s.started_on > v_today
        ),
        'sold_this_month', (
          select count(*)::int from public.payment_plans s
           where s.plan_id = p.id and s.voided_at is null
             and s.created_at >= v_month
        ),
        'last_price_change', (
          select jsonb_build_object(
            'action', l.action, 'before', l.before, 'after', l.after,
            'changedAt', l.changed_at, 'changedBy', l.changed_by,
            'changedByName', (select full_name from public.profiles where id = l.changed_by)
          )
          from public.plan_price_log l
          where l.plan_id = p.id
          order by l.changed_at desc, l.id desc
          limit 1
        )
      ) order by p.sort_order, p.name_es)
      from public.plans p
    ), '[]'::jsonb),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'slug', c.slug, 'name_es', c.name_es, 'is_active', c.is_active)
        order by c.sort_order, c.name_es)
      from public.classes c
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.admin_plans_catalog() from public, anon, authenticated;
grant execute on function public.admin_plans_catalog() to authenticated;

-- 4. Quiénes tienen un plan y qué precios tuvo.
create or replace function public.admin_plan_usage(p_plan text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_today date := public.plan_local_today();
  v_plan public.plans;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_plan is null then raise exception 'NOT_FOUND'; end if;

  select * into v_plan from public.plans where id = p_plan;
  if not found then raise exception 'NOT_FOUND'; end if;

  return jsonb_build_object(
    'plan', jsonb_build_object(
      'id', v_plan.id, 'name_es', v_plan.name_es, 'name_en', v_plan.name_en,
      'access_kind', v_plan.access_kind, 'duration_days', v_plan.duration_days,
      'validity_currency', v_plan.validity_currency,
      'validity_amount', v_plan.validity_amount,
      'price_nio', v_plan.price_nio, 'is_active', v_plan.is_active
    ),
    'today', v_today,
    -- Vigentes y por empezar: es lo que se consulta en el mostrador. Los
    -- vencidos quedan fuera para que la lista no se vuelva un archivo.
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
        'clientId', s.client_id,
        'name', c.full_name,
        'startedOn', s.started_on,
        'expiresOn', s.expires_on,
        'daysLeft', greatest(s.expires_on - v_today + 1, 0),
        'pricePaid', s.price_paid,
        'currency', s.currency,
        'state', case when s.started_on > v_today then 'upcoming' else 'active' end
      ) order by s.started_on, c.full_name)
      from public.payment_plans s
      join public.gym_clients c on c.id = s.client_id
      where s.plan_id = v_plan.id
        and s.voided_at is null
        and s.expires_on >= v_today
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', x.id, 'action', x.action, 'before', x.before, 'after', x.after,
        'changedAt', x.changed_at,
        'changedByName', (select full_name from public.profiles where id = x.changed_by)
      ) order by x.changed_at desc, x.id desc)
      from (
        select l.id, l.action, l.before, l.after, l.changed_at, l.changed_by
          from public.plan_price_log l
         where l.plan_id = v_plan.id
         order by l.changed_at desc, l.id desc
         limit 30
      ) x
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.admin_plan_usage(text) from public, anon, authenticated;
grant execute on function public.admin_plan_usage(text) to authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00087_cierre_y_arqueo_de_caja.sql
-- ═══════════════════════════════════════════════════════════

-- 00087 · FIN-04: abrir la caja, contar y cerrar con arqueo
--
-- Qué faltaba: la tabla `cash_sessions` existía desde la instalación y Caja la
-- mostraba como «sesiones abiertas informadas», pero **nadie podía abrir ni
-- cerrar una caja**: no había función, ni pantalla, ni regla. Peor: la política
-- `Staff can write cash_sessions` era `ALL` para cualquier personal, así que
-- cualquier cajero podía insertar o borrar sesiones sueltas sin arqueo y sin
-- dejar rastro. El saldo de la caja no se podía comprobar contra el efectivo.
--
-- Qué agrega esta migración:
--   · `finance_cash_state()` — lo que la pantalla necesita en una sola lectura:
--     la caja abierta (si hay), sus movimientos de efectivo en curso y las
--     últimas cajas cerradas con su arqueo.
--   · `finance_cash_open(p_request, p_open_nio, p_open_usd, p_notes)` — abre
--     **una** caja (no puede haber dos abiertas) con el efectivo contado al
--     empezar el turno.
--   · `finance_cash_close(p_request, p_session, p_counted_nio, p_counted_usd,
--     p_notes)` — cierra: compara lo contado contra lo esperado, guarda la
--     diferencia y **exige un motivo escrito cuando no cuadra**.
--
-- Cómo se calcula «lo esperado» (la regla que hace que el arqueo signifique
-- algo): apertura + ingresos de efectivo − egresos de efectivo ocurridos
-- **entre la apertura y el cierre**. Lo que es efectivo no se adivina por el
-- nombre del método: manda la cuenta elegida, que es la misma regla que ya usan
-- los cobros desde la 00081 (`account_type = 'caja_fuerte'`). Un movimiento
-- anulado no se resta a mano: la anulación inserta su reversa (00080/00082), y
-- las dos se suman y se anulan solas.
--
-- Reglas de seguridad:
--   · Todo exige `crm_is_staff()` (rol de administración o caja **con** segundo
--     factor). Sin eso: `AUTH`.
--   · Sólo quien abrió puede cerrar; un administrador puede cerrar cualquier
--     caja (`CASH_NOT_YOURS` para el resto). Así el cajero no cierra el turno
--     de otro ni se «arregla» un faltante ajeno.
--   · Los montos se validan en la base: no negativos, dos decimales y tope de
--     99 999 999 (`INVALID_AMOUNT`). El navegador no decide nada.
--   · Cada acción se puede reintentar sin duplicar: `open_request_id` y
--     `close_request_id` son únicos y el mismo pedido devuelve la misma caja.
--   · La tabla deja de aceptar escrituras sueltas: se quita la política `ALL`
--     y los permisos de tabla a `anon` y `authenticated`. Se escribe sólo por
--     estas funciones (`security definer`), que son las que dejan arqueo.
--
-- Qué NO cambia: no se borra ni se migra ningún dato, no se toca el saldo de
-- `bank_accounts`, no cambia `finance_read('summary')` (sigue leyendo la misma
-- columna) ni ninguna pantalla existente.
--
-- Reversible: se pueden borrar las tres funciones y las columnas nuevas; las
-- cajas cerradas quedan como registro histórico y no se pierden.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.cash_sessions') is null
     or to_regclass('public.transactions') is null
     or to_regclass('public.bank_accounts') is null
     or to_regclass('public.profiles') is null
     or to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'CASH_SESSION_PREREQUISITE_MISSING';
  end if;
end $$;

-- Columnas nuevas, todas opcionales: una caja vieja sin estos datos sigue
-- leyéndose igual.
alter table public.cash_sessions
  add column if not exists open_request_id uuid,
  add column if not exists close_request_id uuid,
  add column if not exists close_notes text;

comment on column public.cash_sessions.open_request_id is
  'Pedido que abrió la caja: repetir el mismo pedido no abre otra (FIN-04).';
comment on column public.cash_sessions.close_request_id is
  'Pedido que cerró la caja: repetir el mismo pedido no cobra dos arqueos.';
comment on column public.cash_sessions.close_notes is
  'Motivo escrito del cierre; obligatorio cuando lo contado no coincide (FIN-04).';
comment on column public.cash_sessions.expected_balance_nio is
  'Efectivo NIO esperado al cerrar: apertura + ingresos − egresos de caja.';
comment on column public.cash_sessions.closing_balance_nio is
  'Efectivo NIO contado físicamente al cerrar (el arqueo).';

create unique index if not exists cash_sessions_open_request_key
  on public.cash_sessions (open_request_id)
  where open_request_id is not null;

create unique index if not exists cash_sessions_close_request_key
  on public.cash_sessions (close_request_id)
  where close_request_id is not null;

-- Una sola caja abierta a la vez. Es un índice y no sólo una comprobación
-- dentro de la función: si dos celulares abren al mismo tiempo, la base corta
-- el segundo en vez de dejar dos turnos abiertos.
create unique index if not exists cash_sessions_one_open_key
  on public.cash_sessions ((true))
  where closed_at is null;

-- ---------------------------------------------------------------------------
-- 1. Movimientos de efectivo de una ventana de tiempo
-- ---------------------------------------------------------------------------
-- Devuelve los totales por moneda y el detalle por cuenta, para que la pantalla
-- pueda mostrar de dónde sale cada número. Es interna: la llaman las funciones
-- de abajo, nunca el navegador.
create or replace function public.finance_cash_movements(
  p_from timestamptz,
  p_to timestamptz
) returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with cash as (
    select
      t.amount,
      t.currency::text as currency,
      t.type::text as type,
      t.account_id
    from public.transactions t
    join public.bank_accounts a on a.id = t.account_id
    where a.account_type = 'caja_fuerte'
      and t.status::text = 'completed'
      and t.occurred_at >= p_from
      and t.occurred_at <= p_to
  ), totals as (
    select
      coalesce(sum(amount) filter (where type = 'income' and currency = 'NIO'), 0) as income_nio,
      coalesce(sum(amount) filter (where type = 'income' and currency = 'USD'), 0) as income_usd,
      coalesce(sum(amount) filter (where type = 'expense' and currency = 'NIO'), 0) as expense_nio,
      coalesce(sum(amount) filter (where type = 'expense' and currency = 'USD'), 0) as expense_usd,
      count(*) as movements
    from cash
  )
  select jsonb_build_object(
    'incomeNio', totals.income_nio,
    'incomeUsd', totals.income_usd,
    'expenseNio', totals.expense_nio,
    'expenseUsd', totals.expense_usd,
    'count', totals.movements,
    'accounts', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'accountId', by_account.account_id,
            'currency', by_account.currency,
            'income', by_account.income,
            'expense', by_account.expense
          )
          order by by_account.account_id
        )
        from (
          select
            account_id,
            currency,
            coalesce(sum(amount) filter (where type = 'income'), 0) as income,
            coalesce(sum(amount) filter (where type = 'expense'), 0) as expense
          from cash
          group by account_id, currency
        ) by_account
      ),
      '[]'::jsonb
    )
  )
  from totals;
$$;

revoke all on function public.finance_cash_movements(timestamptz, timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Una caja, tal como la lee la pantalla
-- ---------------------------------------------------------------------------
-- Para una caja abierta, «esperado» se recalcula en el momento (la pantalla se
-- puede mirar antes de cerrar). Para una caja cerrada se devuelve lo guardado:
-- el arqueo es un hecho, no un cálculo que cambia después.
create or replace function public.finance_cash_row_json(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_session public.cash_sessions;
  v_movements jsonb;
  v_expected_nio numeric;
  v_expected_usd numeric;
begin
  select * into v_session from public.cash_sessions where id = p_id;
  if not found then return null; end if;

  v_movements := public.finance_cash_movements(
    v_session.opened_at,
    coalesce(v_session.closed_at, now())
  );
  v_expected_nio := v_session.opening_balance_nio
    + coalesce((v_movements ->> 'incomeNio')::numeric, 0)
    - coalesce((v_movements ->> 'expenseNio')::numeric, 0);
  v_expected_usd := v_session.opening_balance_usd
    + coalesce((v_movements ->> 'incomeUsd')::numeric, 0)
    - coalesce((v_movements ->> 'expenseUsd')::numeric, 0);

  return jsonb_build_object(
    'id', v_session.id,
    'open', v_session.closed_at is null,
    'openedAt', v_session.opened_at,
    'openedById', v_session.opened_by,
    'openedByName', (select full_name from public.profiles where id = v_session.opened_by),
    'openingNio', v_session.opening_balance_nio,
    'openingUsd', v_session.opening_balance_usd,
    'closedAt', v_session.closed_at,
    'closedById', v_session.closed_by,
    'closedByName', (select full_name from public.profiles where id = v_session.closed_by),
    -- `closing_balance_*` es lo contado: el nombre viejo de la tabla se
    -- conserva para no romper `finance_read` ni los datos existentes.
    'countedNio', v_session.closing_balance_nio,
    'countedUsd', v_session.closing_balance_usd,
    'expectedNio', case
      when v_session.closed_at is null then v_expected_nio
      else v_session.expected_balance_nio
    end,
    'expectedUsd', case
      when v_session.closed_at is null then v_expected_usd
      else v_session.expected_balance_usd
    end,
    'differenceNio', v_session.difference_nio,
    'differenceUsd', v_session.difference_usd,
    'notes', v_session.notes,
    'closeNotes', v_session.close_notes,
    'movements', v_movements
  );
end $$;

revoke all on function public.finance_cash_row_json(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lo que la pantalla de Cierre y arqueo pide al abrirse
-- ---------------------------------------------------------------------------
create or replace function public.finance_cash_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_open_id uuid;
  v_history jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;

  select id into v_open_id
  from public.cash_sessions
  where closed_at is null
  order by opened_at desc, id
  limit 1;

  select coalesce(
    jsonb_agg(public.finance_cash_row_json(recent.id) order by recent.closed_at desc),
    '[]'::jsonb
  ) into v_history
  from (
    select id, closed_at
    from public.cash_sessions
    where closed_at is not null
    order by closed_at desc
    limit 20
  ) recent;

  return jsonb_build_object(
    'open', case when v_open_id is null then null
                 else public.finance_cash_row_json(v_open_id) end,
    'history', v_history,
    'cashRule', 'Cuenta de caja (caja_fuerte): apertura + ingresos − egresos.'
  );
end $$;

revoke all on function public.finance_cash_state() from public, anon;
grant execute on function public.finance_cash_state() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Abrir la caja
-- ---------------------------------------------------------------------------
create or replace function public.finance_cash_open(
  p_request uuid,
  p_open_nio numeric default 0,
  p_open_usd numeric default 0,
  p_notes text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_id uuid;
  v_existing uuid;
  v_open uuid;
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  if p_open_nio is null then p_open_nio := 0; end if;
  if p_open_usd is null then p_open_usd := 0; end if;
  if v_notes is not null and char_length(v_notes) > 500 then
    raise exception 'INVALID_NOTES';
  end if;
  if p_open_nio < 0 or p_open_usd < 0
     or p_open_nio > 99999999 or p_open_usd > 99999999
     or p_open_nio <> round(p_open_nio, 2) or p_open_usd <> round(p_open_usd, 2) then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- Mismo pedido, misma caja: un doble toque no abre dos turnos.
  select id into v_existing from public.cash_sessions where open_request_id = p_request;
  if found then return public.finance_cash_row_json(v_existing); end if;

  -- Serie las aperturas: la comprobación de «ya hay una abierta» y el insert
  -- tienen que ver el mismo estado.
  perform pg_advisory_xact_lock(hashtextextended('cash_session_open', 0));

  select id into v_open
  from public.cash_sessions
  where closed_at is null
  order by opened_at desc, id
  limit 1;
  if found then raise exception 'CASH_ALREADY_OPEN'; end if;

  begin
    insert into public.cash_sessions (
      opened_by, opened_at, opening_balance_nio, opening_balance_usd,
      notes, open_request_id
    ) values (
      auth.uid(), now(), p_open_nio, p_open_usd, v_notes, p_request
    ) returning id into v_id;
  exception when unique_violation then
    -- Otra caja ganó la carrera: se informa lo mismo que la comprobación.
    raise exception 'CASH_ALREADY_OPEN';
  end;

  return public.finance_cash_row_json(v_id);
end $$;

revoke all on function public.finance_cash_open(uuid, numeric, numeric, text)
  from public, anon;
grant execute on function public.finance_cash_open(uuid, numeric, numeric, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Cerrar con arqueo
-- ---------------------------------------------------------------------------
create or replace function public.finance_cash_close(
  p_request uuid,
  p_session uuid,
  p_counted_nio numeric,
  p_counted_usd numeric,
  p_notes text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_session public.cash_sessions;
  v_existing uuid;
  v_movements jsonb;
  v_expected_nio numeric;
  v_expected_usd numeric;
  v_difference_nio numeric;
  v_difference_usd numeric;
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null or p_session is null then raise exception 'INVALID_REQUEST'; end if;
  if v_notes is not null and char_length(v_notes) > 500 then
    raise exception 'INVALID_NOTES';
  end if;
  if p_counted_nio is null or p_counted_usd is null
     or p_counted_nio < 0 or p_counted_usd < 0
     or p_counted_nio > 99999999 or p_counted_usd > 99999999
     or p_counted_nio <> round(p_counted_nio, 2)
     or p_counted_usd <> round(p_counted_usd, 2) then
    raise exception 'INVALID_AMOUNT';
  end if;

  select id into v_existing
  from public.cash_sessions
  where close_request_id = p_request;
  if found then return public.finance_cash_row_json(v_existing); end if;

  select * into v_session from public.cash_sessions where id = p_session for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_session.closed_at is not null then raise exception 'CASH_ALREADY_CLOSED'; end if;
  -- Cerrar es firmar el arqueo: sólo quien abrió, o un administrador.
  if v_session.opened_by <> auth.uid() and not public.is_admin() then
    raise exception 'CASH_NOT_YOURS';
  end if;

  v_movements := public.finance_cash_movements(v_session.opened_at, now());
  v_expected_nio := v_session.opening_balance_nio
    + coalesce((v_movements ->> 'incomeNio')::numeric, 0)
    - coalesce((v_movements ->> 'expenseNio')::numeric, 0);
  v_expected_usd := v_session.opening_balance_usd
    + coalesce((v_movements ->> 'incomeUsd')::numeric, 0)
    - coalesce((v_movements ->> 'expenseUsd')::numeric, 0);

  -- La columna es numeric(12,2): se corta acá con un código claro en vez de
  -- dejar que Postgres devuelva un desborde sin explicación.
  if abs(v_expected_nio) > 999999999.99 or abs(v_expected_usd) > 999999999.99 then
    raise exception 'INVALID_AMOUNT';
  end if;

  v_difference_nio := round(p_counted_nio - v_expected_nio, 2);
  v_difference_usd := round(p_counted_usd - v_expected_usd, 2);

  -- Si falta o sobra plata, tiene que quedar escrito por qué. Si cuadra, la
  -- nota es opcional.
  if v_notes is null and (v_difference_nio <> 0 or v_difference_usd <> 0) then
    raise exception 'CASH_DIFFERENCE_REASON_REQUIRED';
  end if;

  update public.cash_sessions set
    closed_by = auth.uid(),
    closed_at = now(),
    closing_balance_nio = p_counted_nio,
    closing_balance_usd = p_counted_usd,
    expected_balance_nio = v_expected_nio,
    expected_balance_usd = v_expected_usd,
    difference_nio = v_difference_nio,
    difference_usd = v_difference_usd,
    close_notes = v_notes,
    close_request_id = p_request
  where id = v_session.id;

  return public.finance_cash_row_json(v_session.id);
end $$;

revoke all on function public.finance_cash_close(uuid, uuid, numeric, numeric, text)
  from public, anon;
grant execute on function public.finance_cash_close(uuid, uuid, numeric, numeric, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. La tabla deja de aceptar escrituras sueltas
-- ---------------------------------------------------------------------------
-- Antes: una sola política `ALL` para cualquier personal. Con ella, el cajero
-- podía insertar una «caja» sin movimientos o borrar la del turno anterior.
-- Ahora se lee por `finance_read` / `finance_cash_state` y se escribe sólo por
-- las funciones de arriba, que dejan apertura, cierre y arqueo.
alter table public.cash_sessions enable row level security;

do $$
declare v_policy record;
begin
  for v_policy in
    select policyname from pg_policies
    where schemaname = 'public' and tablename = 'cash_sessions'
  loop
    execute format('drop policy %I on public.cash_sessions', v_policy.policyname);
  end loop;
end $$;

revoke all on public.cash_sessions from anon, authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00088_anular_caja_cerrada.sql
-- ═══════════════════════════════════════════════════════════

-- 00088 · FIN-04 (segunda parte): un movimiento de una caja ya cerrada no se anula
--
-- Qué faltaba: FIN-04 pedía cierre «con bloqueo o aviso claro para movimientos
-- de un día cerrado». La 00087 agregó abrir, contar y cerrar, pero después de
-- cerrar todavía se podía anular un cobro en efectivo de ese turno: la reversa
-- entra a la cuenta de caja y el arqueo firmado deja de significar algo. Nadie
-- se enteraba, porque la anulación es de hoy y la caja se cerró hace un rato.
--
-- Qué agrega: `finance_void_plan` gana una regla y un dato.
--   · Regla `CASH_SESSION_CLOSED`: si el movimiento es de efectivo (cuenta de
--     caja, `account_type = 'caja_fuerte'`) y ocurrió dentro de una sesión de
--     caja **ya cerrada**, no se anula. Vale para todos los roles, incluido
--     administración: el arqueo es un hecho guardado, no un borrador.
--   · El plan devuelve `closedCashSession` para que la pantalla pueda explicar
--     el motivo sin adivinar por el código.
--
-- Qué NO cambia: las demás reglas de anulación siguen igual y en el mismo
-- orden (transferencia, ya anulada, es una reversa, administración, cajero con
-- interruptor/dueño/día). Un movimiento de banco o billetera, aunque haya una
-- caja cerrada, se sigue anulando como siempre: no forma parte del arqueo.
-- Un movimiento de efectivo **posterior** al cierre también se puede anular:
-- pertenece al turno siguiente o a ninguno, no al arqueo firmado.
--
-- Reversible: volver a aplicar la definición de `finance_void_plan` de la
-- 00080 deja todo como estaba. No se borra ni se migra ningún dato.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.cash_sessions') is null
     or to_regclass('public.transactions') is null
     or to_regclass('public.bank_accounts') is null
     or to_regclass('public.finance_voids') is null
     or to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.is_cashier()') is null
     or to_regprocedure('public.finance_permission_enabled(text)') is null
     or to_regprocedure('public.plan_local_today()') is null then
    raise exception 'VOID_CLOSED_CASH_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.finance_void_plan(p_transaction uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_t public.transactions;
  v_void public.finance_voids;
  v_is_reversal boolean;
  v_admin boolean;
  v_cashier boolean;
  v_today boolean;
  v_own boolean;
  v_closed_cash boolean;
  v_code text;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into v_t from public.transactions where id = p_transaction;
  if not found then raise exception 'NOT_FOUND'; end if;

  select * into v_void from public.finance_voids where original_id = p_transaction;
  v_is_reversal := exists (
    select 1 from public.finance_voids where reversal_id = p_transaction
  );
  v_admin := public.is_admin();
  v_cashier := public.is_cashier();
  v_own := v_t.created_by is not null and v_t.created_by = auth.uid();
  v_today := (v_t.occurred_at at time zone 'America/Managua')::date
    = public.plan_local_today();
  -- FIN-04: ¿este efectivo ya quedó dentro de un arqueo cerrado?
  v_closed_cash := exists (
    select 1
    from public.cash_sessions s
    join public.bank_accounts a on a.id = v_t.account_id
    where s.closed_at is not null
      and a.account_type = 'caja_fuerte'
      and v_t.occurred_at >= s.opened_at
      and v_t.occurred_at <= s.closed_at
  );

  v_code := case
    -- Una transferencia mueve las dos puntas de una misma operación: no se
    -- anula con una sola reversa. Se corrige registrando otra transferencia.
    when v_t.type::text = 'transfer' then 'NOT_VOIDABLE'
    when v_void.id is not null then 'ALREADY_VOIDED'
    when v_is_reversal then 'IS_REVERSAL'
    -- Antes de «administración puede todo»: el arqueo cerrado no se reescribe.
    when v_closed_cash then 'CASH_SESSION_CLOSED'
    when v_admin then 'ALLOWED'
    when v_cashier
      and public.finance_permission_enabled('cashier_can_void')
      and v_own and v_today then 'ALLOWED'
    when not v_cashier then 'NOT_ALLOWED'
    when not public.finance_permission_enabled('cashier_can_void') then 'PERMISSION_OFF'
    when not v_own then 'NOT_YOURS'
    when not v_today then 'NOT_TODAY'
    else 'NOT_ALLOWED'
  end;

  return jsonb_build_object(
    'transactionId', v_t.id,
    'concept', v_t.concept,
    'type', v_t.type::text,
    'amount', v_t.amount,
    'currency', v_t.currency,
    'occurredAt', v_t.occurred_at,
    'accountId', v_t.account_id,
    'isReversal', v_is_reversal,
    'alreadyVoided', v_void.id is not null,
    'voidedAt', v_void.created_at,
    'closedCashSession', v_closed_cash,
    'allowed', v_code = 'ALLOWED',
    'code', v_code
  );
end $$;
revoke all on function public.finance_void_plan(uuid) from public, anon, authenticated;
grant execute on function public.finance_void_plan(uuid) to authenticated;

-- Función chica y probada aparte: qué movimiento cayó dentro de una caja ya
-- cerrada. La usa el plan y la puede usar cualquier informe futuro sin copiar
-- la regla.
create or replace function public.finance_cash_session_closed(p_transaction uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.transactions t
    join public.bank_accounts a on a.id = t.account_id
    join public.cash_sessions s
      on s.closed_at is not null
     and t.occurred_at >= s.opened_at
     and t.occurred_at <= s.closed_at
    where t.id = p_transaction
      and a.account_type = 'caja_fuerte'
  );
$$;
revoke all on function public.finance_cash_session_closed(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00089_biblioteca_de_ejercicios.sql
-- ═══════════════════════════════════════════════════════════

-- 00089 · Biblioteca de ejercicios y rutina del cliente (EX-01)
--
-- Qué faltaba: el cliente tenía su progreso, su asistencia y su rutina asignada
-- por el entrenador, pero **no había ninguna biblioteca de ejercicios**: no se
-- podía consultar cómo se hace un press de banca, qué músculos trabaja ni
-- guardar una lista propia para la sesión.
--
-- Qué agrega esta migración:
--   · `public.exercises` — el catálogo, en **una sola tabla**: instrucciones y
--     tips como arreglos de texto, porque siempre se leen junto al ejercicio y
--     nunca se consultan sueltos. Nada de tablas hijas de pasos.
--   · `admin_import_exercises(jsonb)` — carga idempotente (upsert por `id`) del
--     JSON oficial. Se puede correr dos veces sin duplicar y se puede cortar a
--     la mitad sin dejar basura: cada fila es completa.
--   · `exercise_catalog(...)`, `exercise_facets()`, `exercise_detail(text)` —
--     lectura para cualquier persona con sesión iniciada (cliente, entrenador,
--     caja o administración), con búsqueda sin acentos, filtros por zona del
--     cuerpo, equipo, dificultad y categoría, y paginado.
--   · `client_exercise_routine` — «Mi rutina»: los ejercicios que el cliente
--     guarda con series, repeticiones y descanso. **No toca** `client_routines`
--     (la que asigna el entrenador): son dos cosas distintas y se ven distinto.
--
-- Origen de los datos: dataset público RepDB (repdb.co), uso comercial dentro
-- de la aplicación con atribución visible. El archivo **no** se copia al
-- repositorio: se importa a la base y se muestra con «Exercise data by RepDB
-- (repdb.co)», que la pantalla de la biblioteca exige ver.
--
-- Reglas de seguridad:
--   · El catálogo se lee sólo con sesión (`auth.uid()`); `anon` no tiene nada.
--   · Nadie escribe la tabla directamente: sin `insert/update/delete` para
--     `authenticated`, y la importación pasa por una función que exige
--     administración.
--   · «Mi rutina» es de cada cliente: se resuelve por `gym_clients.profile_id`,
--     no por un id que mande el navegador, y se escribe sólo por funciones.
--
-- Reversible: `drop table public.client_exercise_routine, public.exercises
-- cascade;` y las funciones. No se borra ni se migra ningún dato existente.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.gym_clients') is null
     or to_regclass('public.profiles') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'EXERCISES_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1) El catálogo.
create table if not exists public.exercises (
  id                 text primary key,
  name_es            text not null,
  name_en            text not null,
  description_es     text,
  description_en     text,
  instructions_es    text[] not null default '{}',
  instructions_en    text[] not null default '{}',
  tips_es            text[] not null default '{}',
  tips_en            text[] not null default '{}',
  category           text not null default 'strength',
  force_type         text,
  mechanic           text,
  difficulty         text not null default 'beginner',
  body_part          text not null default 'full_body',
  equipment          text,
  primary_muscles    text[] not null default '{}',
  secondary_muscles  text[] not null default '{}',
  goals              text[] not null default '{}',
  tags               text[] not null default '{}',
  met                numeric(4,1),
  is_unilateral      boolean not null default false,
  is_bodyweight      boolean not null default true,
  image_start        text,
  image_peak         text,
  image_main         text,
  -- Texto listo para buscar: minúsculas y sin acentos, calculado al importar.
  -- Incluye las etiquetas en español que arma la web (`search_extra`), porque
  -- los identificadores del dataset son en inglés y el socio busca «glúteo».
  search_text        text not null default '',
  search_extra       text not null default '',
  source             text not null default 'repdb',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table public.exercises is
  'Catálogo de ejercicios (RepDB, con atribución visible). Una sola tabla: pasos y tips como arreglos.';
comment on column public.exercises.image_start is
  'Ruta relativa del dataset (images/flat/...). Se sirve por /api/exercises/image, nunca se copia al repo.';

create index if not exists exercises_body_part_idx on public.exercises (body_part);
create index if not exists exercises_category_idx on public.exercises (category);
create index if not exists exercises_difficulty_idx on public.exercises (difficulty);
create index if not exists exercises_equipment_idx on public.exercises (equipment);
create index if not exists exercises_primary_muscles_idx on public.exercises using gin (primary_muscles);
create index if not exists exercises_tags_idx on public.exercises using gin (tags);
create index if not exists exercises_search_idx on public.exercises (search_text);

alter table public.exercises enable row level security;
revoke all on public.exercises from anon, authenticated;
grant select on public.exercises to authenticated;

drop policy if exists exercises_read on public.exercises;
create policy exercises_read on public.exercises
  for select to authenticated using (auth.uid() is not null);

-- 2) «Mi rutina» del cliente: lo que guarda para su sesión.
create table if not exists public.client_exercise_routine (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.gym_clients(id) on delete cascade,
  exercise_id  text not null references public.exercises(id) on delete cascade,
  position     integer not null default 0,
  sets         integer check (sets is null or sets between 1 and 20),
  reps         text check (reps is null or length(trim(reps)) between 1 and 20),
  rest_seconds integer check (rest_seconds is null or rest_seconds between 0 and 900),
  note         text check (note is null or length(note) <= 200),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (client_id, exercise_id)
);
create index if not exists client_exercise_routine_client_idx
  on public.client_exercise_routine (client_id, position);

comment on table public.client_exercise_routine is
  'Ejercicios que el cliente guarda para sí. Distinta de client_routines (la que asigna el entrenador).';

alter table public.client_exercise_routine enable row level security;
revoke all on public.client_exercise_routine from anon, authenticated;

-- 3) Normalización para buscar: «prensa», «Prensa» y «PRÉNSA» son lo mismo.
create or replace function public.exercise_search_norm(p_text text)
returns text
language sql
immutable
as $$
  select lower(translate(
    coalesce(p_text, ''),
    'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ',
    'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC'
  ));
$$;

-- 4) Importación idempotente.
create or replace function public.admin_import_exercises(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
  v_count integer;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_payload is null then raise exception 'INVALID_PAYLOAD'; end if;

  v_rows := coalesce(p_payload -> 'exercises', p_payload);
  if jsonb_typeof(v_rows) <> 'array' then raise exception 'INVALID_PAYLOAD'; end if;

  insert into public.exercises (
    id, name_es, name_en, description_es, description_en,
    instructions_es, instructions_en, tips_es, tips_en,
    category, force_type, mechanic, difficulty, body_part, equipment,
    primary_muscles, secondary_muscles, goals, tags, met,
    is_unilateral, is_bodyweight, image_start, image_peak, image_main,
    search_text, search_extra, source, updated_at
  )
  select
    r.id,
    coalesce(nullif(btrim(r.name_es), ''), r.id),
    coalesce(nullif(btrim(r.name_en), ''), r.id),
    r.description_es,
    r.description_en,
    coalesce(r.instructions_es, '{}'),
    coalesce(r.instructions_en, '{}'),
    coalesce(r.tips_es, '{}'),
    coalesce(r.tips_en, '{}'),
    coalesce(nullif(r.category, ''), 'strength'),
    nullif(r.force_type, ''),
    nullif(r.mechanic, ''),
    coalesce(nullif(r.difficulty, ''), 'beginner'),
    coalesce(nullif(r.body_part, ''), 'full_body'),
    nullif(r.equipment, ''),
    coalesce(r.primary_muscles, '{}'),
    coalesce(r.secondary_muscles, '{}'),
    coalesce(r.goals, '{}'),
    coalesce(r.tags, '{}'),
    r.met,
    coalesce(r.is_unilateral, false),
    coalesce(r.is_bodyweight, true),
    nullif(r.image_start, ''),
    nullif(r.image_peak, ''),
    nullif(r.image_main, ''),
    public.exercise_search_norm(
      concat_ws(' ',
        coalesce(nullif(btrim(r.name_es), ''), r.id),
        r.name_en,
        r.body_part,
        r.equipment,
        array_to_string(coalesce(r.primary_muscles, '{}'), ' '),
        array_to_string(coalesce(r.secondary_muscles, '{}'), ' '),
        r.search_extra
      )
    ),
    coalesce(r.search_extra, ''),
    coalesce(nullif(r.source, ''), 'repdb'),
    now()
  from jsonb_to_recordset(v_rows) as r(
    id text, name_es text, name_en text, description_es text, description_en text,
    instructions_es text[], instructions_en text[], tips_es text[], tips_en text[],
    category text, force_type text, mechanic text, difficulty text, body_part text,
    equipment text, primary_muscles text[], secondary_muscles text[], goals text[],
    tags text[], met numeric, is_unilateral boolean, is_bodyweight boolean,
    image_start text, image_peak text, image_main text, search_extra text, source text
  )
  where r.id is not null and btrim(r.id) <> ''
  on conflict (id) do update set
    name_es = excluded.name_es,
    name_en = excluded.name_en,
    description_es = excluded.description_es,
    description_en = excluded.description_en,
    instructions_es = excluded.instructions_es,
    instructions_en = excluded.instructions_en,
    tips_es = excluded.tips_es,
    tips_en = excluded.tips_en,
    category = excluded.category,
    force_type = excluded.force_type,
    mechanic = excluded.mechanic,
    difficulty = excluded.difficulty,
    body_part = excluded.body_part,
    equipment = excluded.equipment,
    primary_muscles = excluded.primary_muscles,
    secondary_muscles = excluded.secondary_muscles,
    goals = excluded.goals,
    tags = excluded.tags,
    met = excluded.met,
    is_unilateral = excluded.is_unilateral,
    is_bodyweight = excluded.is_bodyweight,
    image_start = excluded.image_start,
    image_peak = excluded.image_peak,
    image_main = excluded.image_main,
    search_text = excluded.search_text,
    search_extra = excluded.search_extra,
    source = excluded.source,
    updated_at = now();

  get diagnostics v_count = row_count;
  return jsonb_build_object(
    'imported', v_count,
    'total', (select count(*) from public.exercises)
  );
end $$;

revoke all on function public.admin_import_exercises(jsonb) from public, anon;
grant execute on function public.admin_import_exercises(jsonb) to authenticated;

-- 5) Lectura: catálogo con filtros y paginado.
-- `p_equipment` es una lista porque «máquinas» no es un valor del dataset: la
-- pantalla manda los slugs que agrupa (prensa, hack squat, polea…).
create or replace function public.exercise_catalog(
  p_search text default '',
  p_body_part text default '',
  p_equipment text[] default null,
  p_difficulty text default '',
  p_category text default '',
  p_limit integer default 24,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 24), 1), 60);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := public.exercise_search_norm(btrim(coalesce(p_search, '')));
  v_total integer;
  v_rows jsonb;
begin
  -- Cualquier persona con sesión ve la biblioteca; sin sesión, nada.
  if auth.uid() is null then raise exception 'AUTH'; end if;

  with filtered as (
    select e.*
    from public.exercises e
    where (v_search = '' or e.search_text like '%' || v_search || '%')
      and (coalesce(p_body_part, '') = '' or e.body_part = p_body_part)
      and (p_equipment is null or e.equipment = any (p_equipment))
      and (coalesce(p_difficulty, '') = '' or e.difficulty = p_difficulty)
      and (coalesce(p_category, '') = '' or e.category = p_category)
  ), page as (
    select * from filtered
    order by name_es, id
    limit v_limit offset v_offset
  )
  select
    (select count(*) from filtered)::integer,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', page.id,
        'nameEs', page.name_es,
        'nameEn', page.name_en,
        'category', page.category,
        'difficulty', page.difficulty,
        'bodyPart', page.body_part,
        'equipment', page.equipment,
        'primaryMuscles', page.primary_muscles,
        'isBodyweight', page.is_bodyweight,
        'met', page.met,
        'imageStart', page.image_start,
        'imagePeak', page.image_peak,
        'imageMain', page.image_main
      ) order by page.name_es, page.id)
      from page
    ), '[]'::jsonb)
  into v_total, v_rows;

  return jsonb_build_object(
    'total', v_total, 'limit', v_limit, 'offset', v_offset, 'rows', v_rows
  );
end $$;

revoke all on function public.exercise_catalog(text, text, text[], text, text, integer, integer)
  from public, anon;
grant execute on function public.exercise_catalog(text, text, text[], text, text, integer, integer)
  to authenticated;

-- 6) Facetas con conteos reales: nunca una lista fija en el código.
create or replace function public.exercise_facets()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  return jsonb_build_object(
    'total', (select count(*) from public.exercises),
    'bodyParts', coalesce((
      select jsonb_object_agg(body_part, n)
      from (select body_part, count(*)::integer as n from public.exercises group by body_part) s
    ), '{}'::jsonb),
    'equipment', coalesce((
      select jsonb_object_agg(equipment, n)
      from (
        select equipment, count(*)::integer as n
        from public.exercises where equipment is not null group by equipment
      ) s
    ), '{}'::jsonb),
    'difficulty', coalesce((
      select jsonb_object_agg(difficulty, n)
      from (select difficulty, count(*)::integer as n from public.exercises group by difficulty) s
    ), '{}'::jsonb),
    'category', coalesce((
      select jsonb_object_agg(category, n)
      from (select category, count(*)::integer as n from public.exercises group by category) s
    ), '{}'::jsonb)
  );
end $$;

revoke all on function public.exercise_facets() from public, anon;
grant execute on function public.exercise_facets() to authenticated;

-- 7) Detalle de un ejercicio, con lo que el cliente ya guardó.
create or replace function public.exercise_detail(p_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_e public.exercises;
  v_client uuid;
  v_saved public.client_exercise_routine;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select * into v_e from public.exercises where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  select id into v_client from public.gym_clients where profile_id = auth.uid();
  if v_client is not null then
    select * into v_saved
    from public.client_exercise_routine
    where client_id = v_client and exercise_id = p_id;
  end if;

  return jsonb_build_object(
    'id', v_e.id,
    'nameEs', v_e.name_es,
    'nameEn', v_e.name_en,
    'descriptionEs', v_e.description_es,
    'descriptionEn', v_e.description_en,
    'instructionsEs', v_e.instructions_es,
    'instructionsEn', v_e.instructions_en,
    'tipsEs', v_e.tips_es,
    'tipsEn', v_e.tips_en,
    'category', v_e.category,
    'forceType', v_e.force_type,
    'mechanic', v_e.mechanic,
    'difficulty', v_e.difficulty,
    'bodyPart', v_e.body_part,
    'equipment', v_e.equipment,
    'primaryMuscles', v_e.primary_muscles,
    'secondaryMuscles', v_e.secondary_muscles,
    'goals', v_e.goals,
    'tags', v_e.tags,
    'met', v_e.met,
    'isUnilateral', v_e.is_unilateral,
    'isBodyweight', v_e.is_bodyweight,
    'imageStart', v_e.image_start,
    'imagePeak', v_e.image_peak,
    'imageMain', v_e.image_main,
    'saved', case when v_saved.id is null then null else jsonb_build_object(
      'sets', v_saved.sets,
      'reps', v_saved.reps,
      'restSeconds', v_saved.rest_seconds,
      'note', v_saved.note
    ) end
  );
end $$;

revoke all on function public.exercise_detail(text) from public, anon;
grant execute on function public.exercise_detail(text) to authenticated;

-- 8) «Mi rutina»: guardar, listar y quitar. Siempre sobre el cliente dueño de
-- la sesión; el navegador nunca manda un `client_id`.
create or replace function public.exercise_routine_client()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from public.gym_clients where profile_id = auth.uid();
$$;
revoke all on function public.exercise_routine_client() from public, anon, authenticated;

create or replace function public.client_routine_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_client uuid := public.exercise_routine_client();
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if v_client is null then raise exception 'NO_CLIENT'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'exerciseId', r.exercise_id,
      'position', r.position,
      'sets', r.sets,
      'reps', r.reps,
      'restSeconds', r.rest_seconds,
      'note', r.note,
      'nameEs', e.name_es,
      'bodyPart', e.body_part,
      'equipment', e.equipment,
      'difficulty', e.difficulty,
      'imageStart', e.image_start,
      'imagePeak', e.image_peak,
      'imageMain', e.image_main
    ) order by r.position, r.created_at)
    from public.client_exercise_routine r
    join public.exercises e on e.id = r.exercise_id
    where r.client_id = v_client
  ), '[]'::jsonb);
end $$;

create or replace function public.client_routine_save(
  p_exercise text,
  p_sets integer default null,
  p_reps text default null,
  p_rest integer default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_client uuid := public.exercise_routine_client();
  v_next integer;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if v_client is null then raise exception 'NO_CLIENT'; end if;
  if not exists (select 1 from public.exercises where id = p_exercise) then
    raise exception 'NOT_FOUND';
  end if;

  select coalesce(max(position), 0) + 1 into v_next
  from public.client_exercise_routine where client_id = v_client;

  insert into public.client_exercise_routine (
    client_id, exercise_id, position, sets, reps, rest_seconds, note
  ) values (
    v_client, p_exercise, v_next,
    case when p_sets is null then null else least(greatest(p_sets, 1), 20) end,
    nullif(btrim(coalesce(p_reps, '')), ''),
    case when p_rest is null then null
         else least(greatest(p_rest, 0), 900) end,
    nullif(btrim(coalesce(p_note, '')), '')
  )
  on conflict (client_id, exercise_id) do update set
    sets = coalesce(excluded.sets, public.client_exercise_routine.sets),
    reps = coalesce(excluded.reps, public.client_exercise_routine.reps),
    rest_seconds = coalesce(excluded.rest_seconds, public.client_exercise_routine.rest_seconds),
    note = coalesce(excluded.note, public.client_exercise_routine.note),
    updated_at = now();

  return jsonb_build_object('exerciseId', p_exercise, 'saved', true);
end $$;

create or replace function public.client_routine_remove(p_exercise text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_client uuid := public.exercise_routine_client();
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if v_client is null then raise exception 'NO_CLIENT'; end if;
  delete from public.client_exercise_routine
  where client_id = v_client and exercise_id = p_exercise;
  return jsonb_build_object('exerciseId', p_exercise, 'saved', false);
end $$;

revoke all on function public.client_routine_list() from public, anon;
revoke all on function public.client_routine_save(text, integer, text, integer, text) from public, anon;
revoke all on function public.client_routine_remove(text) from public, anon;
grant execute on function public.client_routine_list() to authenticated;
grant execute on function public.client_routine_save(text, integer, text, integer, text) to authenticated;
grant execute on function public.client_routine_remove(text) to authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00090_catalogo_peso_corporal.sql
-- ═══════════════════════════════════════════════════════════

-- 00090 · «Peso corporal» filtra de verdad (EX-01)
--
-- Qué pasaba: el chip «Peso corporal» de la biblioteca mandaba una lista vacía de
-- equipos y la función la interpretaba como «ningún filtro». El socio tocaba el
-- chip y veía los 701 ejercicios, incluidos los de máquina.
--
-- Qué cambia: un arreglo vacío ahora quiere decir «sin equipo». `null` sigue
-- queriendo decir «no filtrar», así que las demás combinaciones no cambian.
--
-- Reversible: volver a crear la función como estaba en `00089`.
-- Aditiva: no toca datos ni tablas.

begin;
set local lock_timeout = '5s';

create or replace function public.exercise_catalog(
  p_search text default '',
  p_body_part text default '',
  p_equipment text[] default null,
  p_difficulty text default '',
  p_category text default '',
  p_limit integer default 24,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 24), 1), 60);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := public.exercise_search_norm(btrim(coalesce(p_search, '')));
  v_total integer;
  v_rows jsonb;
begin
  -- Cualquier persona con sesión ve la biblioteca; sin sesión, nada.
  if auth.uid() is null then raise exception 'AUTH'; end if;

  with filtered as (
    select e.*
    from public.exercises e
    where (v_search = '' or e.search_text like '%' || v_search || '%')
      and (coalesce(p_body_part, '') = '' or e.body_part = p_body_part)
      -- Un arreglo vacío significa «sin equipo» (peso corporal), no «sin filtro»:
      -- es lo que manda el chip «Peso corporal» de la pantalla.
      and (p_equipment is null
           or (cardinality(p_equipment) = 0 and e.equipment is null)
           or e.equipment = any (p_equipment))
      and (coalesce(p_difficulty, '') = '' or e.difficulty = p_difficulty)
      and (coalesce(p_category, '') = '' or e.category = p_category)
  ), page as (
    select * from filtered
    order by name_es, id
    limit v_limit offset v_offset
  )
  select
    (select count(*) from filtered)::integer,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', page.id,
        'nameEs', page.name_es,
        'nameEn', page.name_en,
        'category', page.category,
        'difficulty', page.difficulty,
        'bodyPart', page.body_part,
        'equipment', page.equipment,
        'primaryMuscles', page.primary_muscles,
        'isBodyweight', page.is_bodyweight,
        'met', page.met,
        'imageStart', page.image_start,
        'imagePeak', page.image_peak,
        'imageMain', page.image_main
      ) order by page.name_es, page.id)
      from page
    ), '[]'::jsonb)
  into v_total, v_rows;

  return jsonb_build_object(
    'total', v_total, 'limit', v_limit, 'offset', v_offset, 'rows', v_rows
  );
end $$;

revoke all on function public.exercise_catalog(text, text, text[], text, text, integer, integer)
  from public, anon;
grant execute on function public.exercise_catalog(text, text, text[], text, text, integer, integer)
  to authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00091_orden_de_gimnasio.sql
-- ═══════════════════════════════════════════════════════════

-- 00091 · La biblioteca abre como un gimnasio (EX-01)
--
-- Qué pasaba: el catálogo se ordenaba por nombre, así que la primera pantalla
-- mezclaba estiramientos y ejercicios de casa con la prensa y el jalón. El
-- dueño lo notó de inmediato: «casi todo se basa en movimientos que se
-- pudieran realizar en casa».
--
-- Qué cambia: el orden por defecto pone primero los ejercicios que usan equipo
-- y deja al final el trabajo sin equipo y los estiramientos. El contenido no se
-- toca: los 701 ejercicios siguen ahí y los filtros funcionan igual.
--
-- Reversible: `create or replace` con el orden de `00090` (name_es, id).
-- Aditiva: no cambia datos ni columnas.

begin;
set local lock_timeout = '5s';

create or replace function public.exercise_catalog(
  p_search text default '',
  p_body_part text default '',
  p_equipment text[] default null,
  p_difficulty text default '',
  p_category text default '',
  p_limit integer default 24,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 24), 1), 60);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := public.exercise_search_norm(btrim(coalesce(p_search, '')));
  v_total integer;
  v_rows jsonb;
begin
  -- Cualquier persona con sesión ve la biblioteca; sin sesión, nada.
  if auth.uid() is null then raise exception 'AUTH'; end if;

  with filtered as (
    select e.*
    from public.exercises e
    where (v_search = '' or e.search_text like '%' || v_search || '%')
      and (coalesce(p_body_part, '') = '' or e.body_part = p_body_part)
      -- Un arreglo vacío significa «sin equipo» (peso corporal), no «sin filtro»:
      -- es lo que manda el chip «Peso corporal» de la pantalla.
      and (p_equipment is null
           or (cardinality(p_equipment) = 0 and e.equipment is null)
           or e.equipment = any (p_equipment))
      and (coalesce(p_difficulty, '') = '' or e.difficulty = p_difficulty)
      and (coalesce(p_category, '') = '' or e.category = p_category)
  ), page as (
    select * from filtered
    -- Orden de gimnasio: primero lo que se hace con equipo (máquina, polea,
    -- barra, mancuerna) y al final el trabajo sin equipo y los estiramientos.
    -- Así la primera pantalla se parece a la sala, no a una rutina de casa.
    order by (equipment is null), (category = 'stretching'), name_es, id
    limit v_limit offset v_offset
  )
  select
    (select count(*) from filtered)::integer,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', page.id,
        'nameEs', page.name_es,
        'nameEn', page.name_en,
        'category', page.category,
        'difficulty', page.difficulty,
        'bodyPart', page.body_part,
        'equipment', page.equipment,
        'primaryMuscles', page.primary_muscles,
        'isBodyweight', page.is_bodyweight,
        'met', page.met,
        'imageStart', page.image_start,
        'imagePeak', page.image_peak,
        'imageMain', page.image_main
      ) order by (page.equipment is null), (page.category = 'stretching'), page.name_es, page.id)
      from page
    ), '[]'::jsonb)
  into v_total, v_rows;

  return jsonb_build_object(
    'total', v_total, 'limit', v_limit, 'offset', v_offset, 'rows', v_rows
  );
end $$;

revoke all on function public.exercise_catalog(text, text, text[], text, text, integer, integer)
  from public, anon;
grant execute on function public.exercise_catalog(text, text, text[], text, text, integer, integer)
  to authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00092_biblioteca_solo_de_gimnasio.sql
-- ═══════════════════════════════════════════════════════════

-- 00092 · La biblioteca muestra lo que es de gimnasio (EX-01)
--
-- Qué pedía el dueño: «quiero la barra y el banco, press de banca, sentadillas
-- con barra, todo lo que tenga que ver con cosas del gym; lo que no quiero son
-- ejercicios de peso libre que se puedan hacer en casa».
--
-- Qué hace esta migración:
--   · Agrega `exercises.visible`. No se borra ni se oculta con filtros de
--     pantalla: el ejercicio sigue en la base y se puede volver a mostrar.
--   · `exercise_is_gym(equipo, categoría)` decide, en un solo lugar, qué cuenta
--     como equipo de sala: máquinas, poleas, barra, mancuerna, pesa rusa, banco,
--     discos, Smith, jalón y las máquinas de cardio. Quedan fuera el peso
--     corporal y los accesorios de casa (bandas, balones, cajón, cuerdas), y
--     todo lo que sea estiramiento, aunque use un accesorio.
--   · `exercise_catalog` y `exercise_facets` cuentan y listan **sólo lo
--     visible**, así los chips y los números dicen la verdad de lo que se ve.
--   · Dos funciones de administración: recalcular todo con el criterio anterior
--     o mostrar/ocultar un ejercicio puntual. Ninguna borra datos.
--
-- Reversible: `alter table public.exercises drop column visible;` y volver a
-- crear `exercise_catalog`/`exercise_facets` como en la 00091. Aditiva.

begin;
set local lock_timeout = '5s';

-- 1) La marca de visibilidad. Todo entra visible; el criterio se aplica abajo.
alter table public.exercises
  add column if not exists visible boolean not null default true;

comment on column public.exercises.visible is
  'Lo que se muestra en la biblioteca del socio. Oculto no es borrado: se puede volver a mostrar.';

create index if not exists exercises_visible_idx
  on public.exercises (visible, body_part);

-- 2) Un solo lugar decide qué es equipo de gimnasio.
create or replace function public.exercise_is_gym(p_equipment text, p_category text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(p_category, '') <> 'stretching'
     and coalesce(p_equipment, '') = any (array[
       -- máquinas de sala
       'machine', 'ab_crunch_machine', 'assisted_pullup_machine',
       'back_extension_machine', 'bicep_curl_machine', 'chest_fly_machine',
       'chest_press_machine', 'dip_machine', 'donkey_calf_raise_machine',
       'glute_ham_developer', 'hack_squat', 'hip_abduction_machine',
       'hip_adduction_machine', 'hip_thrust_machine', 'lat_pulldown_machine',
       'leg_curl', 'leg_extension', 'leg_press', 'pec_deck',
       'plate_loaded_dip_machine', 'plate_loaded_lateral_raise_machine',
       'preacher_curl_machine', 'reverse_fly_machine', 'seated_calf_raise_machine',
       'seated_row_machine', 'shoulder_press_machine', 'shrug_machine',
       'smith_machine', 'standing_calf_raise_machine', 'tricep_extension_machine',
       -- poleas
       'cable',
       -- peso libre de sala
       'barbell', 'dumbbell', 'kettlebell', 'ez_bar', 'trap_bar', 'plates',
       'flat_bench',
       -- aparatos de peso corporal que sólo existen en un gimnasio
       'pull_up_bar', 'dip_station',
       -- cardio de máquina
       'treadmill', 'stationary_bike', 'elliptical', 'rower', 'stair_climber',
       'air_bike', 'ski_erg'
     ]);
$$;

comment on function public.exercise_is_gym(text, text) is
  'Verdadero si el ejercicio usa equipo de sala. Fuera: peso corporal, bandas, balones y estiramientos.';

-- 3) Se aplica a todo el catálogo. Nada se borra: sólo se deja de listar.
update public.exercises
   set visible = public.exercise_is_gym(equipment, category)
 where visible is distinct from public.exercise_is_gym(equipment, category);

-- 4) Catálogo: sólo lo visible.
create or replace function public.exercise_catalog(
  p_search text default '',
  p_body_part text default '',
  p_equipment text[] default null,
  p_difficulty text default '',
  p_category text default '',
  p_limit integer default 24,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 24), 1), 60);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := public.exercise_search_norm(btrim(coalesce(p_search, '')));
  v_total integer;
  v_rows jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;

  with filtered as (
    select e.*
    from public.exercises e
    where e.visible
      and (v_search = '' or e.search_text like '%' || v_search || '%')
      and (coalesce(p_body_part, '') = '' or e.body_part = p_body_part)
      -- Un arreglo vacío significa «sin equipo» (peso corporal), no «sin filtro».
      and (p_equipment is null
           or (cardinality(p_equipment) = 0 and e.equipment is null)
           or e.equipment = any (p_equipment))
      and (coalesce(p_difficulty, '') = '' or e.difficulty = p_difficulty)
      and (coalesce(p_category, '') = '' or e.category = p_category)
  ), page as (
    select * from filtered
    -- Orden de gimnasio: primero lo que usa equipo; el trabajo sin equipo y los
    -- estiramientos, al final.
    order by (equipment is null), (category = 'stretching'), name_es, id
    limit v_limit offset v_offset
  )
  select
    (select count(*) from filtered)::integer,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', page.id,
        'nameEs', page.name_es,
        'nameEn', page.name_en,
        'category', page.category,
        'difficulty', page.difficulty,
        'bodyPart', page.body_part,
        'equipment', page.equipment,
        'primaryMuscles', page.primary_muscles,
        'isBodyweight', page.is_bodyweight,
        'met', page.met,
        'imageStart', page.image_start,
        'imagePeak', page.image_peak,
        'imageMain', page.image_main
      ) order by (page.equipment is null), (page.category = 'stretching'), page.name_es, page.id)
      from page
    ), '[]'::jsonb)
  into v_total, v_rows;

  return jsonb_build_object(
    'total', v_total, 'limit', v_limit, 'offset', v_offset, 'rows', v_rows
  );
end $$;

revoke all on function public.exercise_catalog(text, text, text[], text, text, integer, integer)
  from public, anon;
grant execute on function public.exercise_catalog(text, text, text[], text, text, integer, integer)
  to authenticated;

-- 5) Facetas: cuentan lo visible, para que los chips digan la verdad.
create or replace function public.exercise_facets()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  return jsonb_build_object(
    'total', (select count(*) from public.exercises where visible),
    'bodyParts', coalesce((
      select jsonb_object_agg(body_part, n)
      from (
        select body_part, count(*)::integer as n
        from public.exercises where visible group by body_part
      ) s
    ), '{}'::jsonb),
    'equipment', coalesce((
      select jsonb_object_agg(equipment, n)
      from (
        select equipment, count(*)::integer as n
        from public.exercises where visible and equipment is not null group by equipment
      ) s
    ), '{}'::jsonb),
    'difficulty', coalesce((
      select jsonb_object_agg(difficulty, n)
      from (
        select difficulty, count(*)::integer as n
        from public.exercises where visible group by difficulty
      ) s
    ), '{}'::jsonb),
    'category', coalesce((
      select jsonb_object_agg(category, n)
      from (
        select category, count(*)::integer as n
        from public.exercises where visible group by category
      ) s
    ), '{}'::jsonb)
  );
end $$;

revoke all on function public.exercise_facets() from public, anon;
grant execute on function public.exercise_facets() to authenticated;

-- 6) Administración: recalcular todo o cambiar uno. Nunca borra.
create or replace function public.admin_reset_library_visibility()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_visibles integer;
  v_ocultos integer;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  update public.exercises
     set visible = public.exercise_is_gym(equipment, category),
         updated_at = now()
   where visible is distinct from public.exercise_is_gym(equipment, category);

  select count(*) filter (where visible), count(*) filter (where not visible)
    into v_visibles, v_ocultos
    from public.exercises;

  return jsonb_build_object('visible', v_visibles, 'hidden', v_ocultos, 'total', v_visibles + v_ocultos);
end $$;

create or replace function public.admin_set_exercise_visible(p_id text, p_visible boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_id is null or btrim(p_id) = '' then raise exception 'INVALID_PAYLOAD'; end if;

  update public.exercises
     set visible = coalesce(p_visible, true), updated_at = now()
   where id = btrim(p_id);
  if not found then raise exception 'NOT_FOUND'; end if;

  return jsonb_build_object('id', btrim(p_id), 'visible', coalesce(p_visible, true));
end $$;

revoke all on function public.admin_reset_library_visibility() from public, anon;
revoke all on function public.admin_set_exercise_visible(text, boolean) from public, anon;
grant execute on function public.admin_reset_library_visibility() to authenticated;
grant execute on function public.admin_set_exercise_visible(text, boolean) to authenticated;

-- 7) La importación deja cada fila con el criterio aplicado, así un catálogo
--    nuevo entra ya filtrado sin que nadie toque un interruptor a mano.
create or replace function public.exercise_apply_visibility_defaults()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  update public.exercises
     set visible = public.exercise_is_gym(equipment, category)
   where visible is distinct from public.exercise_is_gym(equipment, category);
  get diagnostics v_count = row_count;
  return v_count;
end $$;

revoke all on function public.exercise_apply_visibility_defaults() from public, anon, authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00093_fotos_reales_del_segundo_catalogo.sql
-- ═══════════════════════════════════════════════════════════

-- 00093 · Las fichas que ya existen muestran fotos reales (EX-04)
--
-- Qué pidió el dueño: las fichas se veían como dibujos planos y no le
-- gustaban. El segundo catálogo (dominio público, Unlicense) trae **dos fotos
-- reales por movimiento**: la posición inicial y la final, que es justo lo que
-- la animación de EX-03 alterna cada 900 ms.
--
-- Su condición fue «solo si están todos». No están todos: de las 701 fichas
-- del catálogo viejo, 185 tienen equivalente exacto en el segundo catálogo.
-- Por eso esto es una **sustitución parcial**, ficha por ficha:
--   · no se crea ninguna ficha nueva ni se duplica nada;
--   · cada ficha conserva su `id`, su nombre, sus pasos y sus consejos;
--   · sólo cambian `image_start` y `image_peak` (la portada `image_main` se
--     deja como estaba: es el respaldo cuando no hay dos fotos).
--
-- Cómo se eligió cada par: nombre normalizado idéntico (sin mayúsculas,
-- acentos, plurales ni palabras de relleno) y equipo compatible, o un puñado
-- de sinónimos revisados a mano uno por uno. Nada de parecido automático: un
-- parecido mal resuelto pone la foto de otro ejercicio, que es peor que el
-- dibujo. Quedan fuera los que no tienen dos fotos y `Air_Bike`, que en el
-- origen es una bicicleta en el piso, no la de sala.
--
-- Qué crea:
--   · `exercise_photo_map` — el mapa curado (id viejo → carpeta de fotos) y,
--     en las mismas filas, las rutas anteriores: la copia para volver atrás.
--   · `exercise_photo_keep()` — un disparador que vuelve a poner las fotos si
--     alguien recarga el catálogo viejo (`admin_import_exercises`). Sin esto,
--     una recarga posterior borraría las fotos en silencio.
--
-- Reversible, sin borrar datos:
--   update public.exercise_photo_map set applied = false;
--   update public.exercises e
--      set image_start = m.old_image_start,
--          image_peak  = m.old_image_peak,
--          image_main  = m.old_image_main,
--          updated_at  = now()
--     from public.exercise_photo_map m
--    where m.exercise_id = e.id;
-- (Con `applied = false` el disparador deja de imponer las fotos.)

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.exercises') is null then
    raise exception 'EXERCISES_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1) El mapa y la copia de las rutas anteriores, en una sola tabla.
create table if not exists public.exercise_photo_map (
  exercise_id     text primary key references public.exercises(id) on delete cascade,
  folder          text not null check (folder ~ '^[A-Za-z0-9][A-Za-z0-9 _().,''&-]{0,90}$'),
  origin_name     text,
  applied         boolean not null default true,
  old_image_start text,
  old_image_peak  text,
  old_image_main  text,
  saved_at        timestamptz not null default now()
);

comment on table public.exercise_photo_map is
  'Ficha del catálogo viejo -> carpeta de fotos del segundo catálogo (EX-04). Guarda las rutas anteriores para revertir. No se lee desde la web.';
comment on column public.exercise_photo_map.applied is
  'En true, el disparador impone las fotos (también después de recargar el catálogo). En false se puede revertir.';

alter table public.exercise_photo_map enable row level security;
revoke all on public.exercise_photo_map from anon, authenticated;

-- 2) El mapa curado: 185 fichas equivalentes, revisadas una por una.
-- La copia de las rutas anteriores se toma aquí, una sola vez: si se vuelve a
-- aplicar la migración, `on conflict do nothing` no la pisa.
insert into public.exercise_photo_map
  (exercise_id, folder, origin_name, old_image_start, old_image_peak, old_image_main)
select p.exercise_id, p.folder, p.origin_name,
       e.image_start, e.image_peak, e.image_main
  from (values
  ('arnold-press', 'Arnold_Dumbbell_Press', 'Arnold Dumbbell Press'),
  ('assisted-dips', 'Dip_Machine', 'Dip Machine'),
  ('band-pull-apart', 'Band_Pull_Apart', 'Band Pull Apart'),
  ('barbell-ab-rollout', 'Barbell_Ab_Rollout', 'Barbell Ab Rollout'),
  ('barbell-calf-raise', 'Standing_Barbell_Calf_Raise', 'Standing Barbell Calf Raise'),
  ('barbell-curl', 'Barbell_Curl', 'Barbell Curl'),
  ('barbell-glute-bridge', 'Barbell_Glute_Bridge', 'Barbell Glute Bridge'),
  ('barbell-lunge', 'Barbell_Lunge', 'Barbell Lunge'),
  ('barbell-overhead-extension', 'Standing_Overhead_Barbell_Triceps_Extension', 'Standing Overhead Barbell Triceps Extension'),
  ('barbell-rear-delt-row', 'Barbell_Rear_Delt_Row', 'Barbell Rear Delt Row'),
  ('barbell-row', 'Bent_Over_Barbell_Row', 'Bent Over Barbell Row'),
  ('barbell-wrist-curl', 'Palms-Up_Barbell_Wrist_Curl_Over_A_Bench', 'Palms-Up Barbell Wrist Curl Over A Bench'),
  ('behind-the-back-barbell-shrug', 'Barbell_Shrug_Behind_The_Back', 'Barbell Shrug Behind The Back'),
  ('bench-dips', 'Bench_Dips', 'Bench Dips'),
  ('bench-press', 'Barbell_Bench_Press_-_Medium_Grip', 'Barbell Bench Press - Medium Grip'),
  ('bent-arm-barbell-pullover', 'Bent-Arm_Barbell_Pullover', 'Bent-Arm Barbell Pullover'),
  ('bent-over-db-row', 'Bent_Over_Two-Dumbbell_Row', 'Bent Over Two-Dumbbell Row'),
  ('bicep-curl', 'Dumbbell_Bicep_Curl', 'Dumbbell Bicep Curl'),
  ('bodyweight-squat', 'Bodyweight_Squat', 'Bodyweight Squat'),
  ('box-squat', 'Box_Squat', 'Box Squat'),
  ('cable-chest-press', 'Cable_Chest_Press', 'Cable Chest Press'),
  ('cable-crunch', 'Cable_Crunch', 'Cable Crunch'),
  ('cable-curl', 'Standing_Biceps_Cable_Curl', 'Standing Biceps Cable Curl'),
  ('cable-external-rotation', 'External_Rotation_with_Cable', 'External Rotation with Cable'),
  ('cable-fly', 'Cable_Crossover', 'Cable Crossover'),
  ('cable-front-raise', 'Front_Cable_Raise', 'Front Cable Raise'),
  ('cable-hammer-curl', 'Cable_Hammer_Curls_-_Rope_Attachment', 'Cable Hammer Curls - Rope Attachment'),
  ('cable-overhead-tricep-extension', 'Cable_Rope_Overhead_Triceps_Extension', 'Cable Rope Overhead Triceps Extension'),
  ('cable-pallof-press', 'Pallof_Press', 'Pallof Press'),
  ('cable-pull-through', 'Pull_Through', 'Pull Through'),
  ('cable-upright-row', 'Upright_Cable_Row', 'Upright Cable Row'),
  ('cable-wrist-curl', 'Cable_Wrist_Curl', 'Cable Wrist Curl'),
  ('cat-stretch', 'Cat_Stretch', 'Cat Stretch'),
  ('childs-pose', 'Childs_Pose', 'Child''s Pose'),
  ('clean', 'Clean', 'Clean'),
  ('clean-and-jerk', 'Clean_and_Jerk', 'Clean and Jerk'),
  ('close-grip-barbell-curl', 'Close-Grip_Standing_Barbell_Curl', 'Close-Grip Standing Barbell Curl'),
  ('close-grip-bench-press', 'Close-Grip_Barbell_Bench_Press', 'Close-Grip Barbell Bench Press'),
  ('close-grip-db-bench-press', 'Close-Grip_Dumbbell_Press', 'Close-Grip Dumbbell Press'),
  ('close-grip-ez-bar-bench-press', 'Close-Grip_EZ-Bar_Press', 'Close-Grip EZ-Bar Press'),
  ('close-grip-ez-bar-curl', 'Close-Grip_EZ_Bar_Curl', 'Close-Grip EZ Bar Curl'),
  ('close-grip-lat-pulldown', 'Close-Grip_Front_Lat_Pulldown', 'Close-Grip Front Lat Pulldown'),
  ('close-stance-leg-press', 'Narrow_Stance_Leg_Press', 'Narrow Stance Leg Press'),
  ('cocoons', 'Cocoons', 'Cocoons'),
  ('concentration-curl', 'Concentration_Curls', 'Concentration Curls'),
  ('cross-body-crunch', 'Cross-Body_Crunch', 'Cross-Body Crunch'),
  ('cross-body-hammer-curl', 'Cross_Body_Hammer_Curl', 'Cross Body Hammer Curl'),
  ('crunches', 'Crunches', 'Crunches'),
  ('db-bench-press', 'Dumbbell_Bench_Press', 'Dumbbell Bench Press'),
  ('db-lunge', 'Dumbbell_Lunges', 'Dumbbell Lunges'),
  ('db-preacher-curl', 'Two-Arm_Dumbbell_Preacher_Curl', 'Two-Arm Dumbbell Preacher Curl'),
  ('db-pullover', 'Straight-Arm_Dumbbell_Pullover', 'Straight-Arm Dumbbell Pullover'),
  ('db-reverse-curl', 'Standing_Dumbbell_Reverse_Curl', 'Standing Dumbbell Reverse Curl'),
  ('db-shrug', 'Dumbbell_Shrug', 'Dumbbell Shrug'),
  ('db-squat', 'Dumbbell_Squat', 'Dumbbell Squat'),
  ('dead-bug', 'Dead_Bug', 'Dead Bug'),
  ('deadlift', 'Barbell_Deadlift', 'Barbell Deadlift'),
  ('decline-bench-press', 'Decline_Dumbbell_Bench_Press', 'Decline Dumbbell Bench Press'),
  ('decline-bench-press-barbell', 'Decline_Barbell_Bench_Press', 'Decline Barbell Bench Press'),
  ('decline-crunch', 'Decline_Crunch', 'Decline Crunch'),
  ('decline-push-up', 'Decline_Push-Up', 'Decline Push-Up'),
  ('deficit-deadlift', 'Deficit_Deadlift', 'Deficit Deadlift'),
  ('donkey-calf-raise', 'Donkey_Calf_Raises', 'Donkey Calf Raises'),
  ('double-kettlebell-jerk', 'Double_Kettlebell_Jerk', 'Double Kettlebell Jerk'),
  ('double-kettlebell-push-press', 'Double_Kettlebell_Push_Press', 'Double Kettlebell Push Press'),
  ('drag-curl', 'Drag_Curl', 'Drag Curl'),
  ('dumbbell-calf-raise', 'Calf_Raise_On_A_Dumbbell', 'Calf Raise On A Dumbbell'),
  ('dumbbell-floor-press', 'Dumbbell_Floor_Press', 'Dumbbell Floor Press'),
  ('dumbbell-front-raise', 'Front_Dumbbell_Raise', 'Front Dumbbell Raise'),
  ('dumbbell-shoulder-press', 'Dumbbell_Shoulder_Press', 'Dumbbell Shoulder Press'),
  ('dumbbell-side-bend', 'Dumbbell_Side_Bend', 'Dumbbell Side Bend'),
  ('dumbbell-split-squat', 'Split_Squat_with_Dumbbells', 'Split Squat with Dumbbells'),
  ('dumbbell-tricep-extension', 'Dumbbell_Tricep_Extension_-Pronated_Grip', 'Dumbbell Tricep Extension -Pronated Grip'),
  ('dumbbell-upright-row', 'Standing_Dumbbell_Upright_Row', 'Standing Dumbbell Upright Row'),
  ('dumbbell-wrist-curl', 'Palms-Up_Dumbbell_Wrist_Curl_Over_A_Bench', 'Palms-Up Dumbbell Wrist Curl Over A Bench'),
  ('elliptical-trainer', 'Elliptical_Trainer', 'Elliptical Trainer'),
  ('ez-bar-curl', 'EZ-Bar_Curl', 'EZ-Bar Curl'),
  ('face-pull', 'Face_Pull', 'Face Pull'),
  ('floor-press', 'Floor_Press', 'Floor Press'),
  ('flutter-kicks', 'Flutter_Kicks', 'Flutter Kicks'),
  ('front-squat', 'Front_Barbell_Squat', 'Front Barbell Squat'),
  ('glute-kickback', 'Glute_Kickback', 'Glute Kickback'),
  ('goblet-squat', 'Goblet_Squat', 'Goblet Squat'),
  ('good-morning', 'Good_Morning', 'Good Morning'),
  ('hack-squat', 'Hack_Squat', 'Hack Squat'),
  ('hammer-curl', 'Hammer_Curls', 'Hammer Curls'),
  ('handstand-push-ups', 'Handstand_Push-Ups', 'Handstand Push-Ups'),
  ('hang-clean', 'Hang_Clean', 'Hang Clean'),
  ('hang-snatch', 'Hang_Snatch', 'Hang Snatch'),
  ('hanging-leg-raise', 'Hanging_Leg_Raise', 'Hanging Leg Raise'),
  ('hanging-pike', 'Hanging_Pike', 'Hanging Pike'),
  ('hip-thrust', 'Barbell_Hip_Thrust', 'Barbell Hip Thrust'),
  ('inchworm', 'Inchworm', 'Inchworm'),
  ('incline-bench-press', 'Barbell_Incline_Bench_Press_-_Medium_Grip', 'Barbell Incline Bench Press - Medium Grip'),
  ('incline-db-curl', 'Incline_Dumbbell_Curl', 'Incline Dumbbell Curl'),
  ('incline-db-press', 'Incline_Dumbbell_Press', 'Incline Dumbbell Press'),
  ('incline-hammer-curl', 'Incline_Hammer_Curls', 'Incline Hammer Curls'),
  ('incline-push-ups', 'Incline_Push-Up', 'Incline Push-Up'),
  ('inverted-row', 'Inverted_Row', 'Inverted Row'),
  ('jackknife-sit-up', 'Jackknife_Sit-Up', 'Jackknife Sit-Up'),
  ('kettlebell-pistol-squat', 'Kettlebell_Pistol_Squat', 'Kettlebell Pistol Squat'),
  ('kettlebell-sumo-high-pull', 'Kettlebell_Sumo_High_Pull', 'Kettlebell Sumo High Pull'),
  ('kettlebell-turkish-get-ups', 'Kettlebell_Turkish_Get-Up_Lunge_style', 'Kettlebell Turkish Get-Up (Lunge style)'),
  ('kettlebell-windmills', 'Kettlebell_Windmill', 'Kettlebell Windmill'),
  ('lat-pulldown', 'Wide-Grip_Lat_Pulldown', 'Wide-Grip Lat Pulldown'),
  ('lateral-raise', 'Side_Lateral_Raise', 'Side Lateral Raise'),
  ('leg-curl', 'Lying_Leg_Curls', 'Lying Leg Curls'),
  ('leg-extension', 'Leg_Extensions', 'Leg Extensions'),
  ('leg-press', 'Leg_Press', 'Leg Press'),
  ('lying-tricep-extension', 'Lying_Dumbbell_Tricep_Extension', 'Lying Dumbbell Tricep Extension'),
  ('machine-bicep-curl', 'Machine_Bicep_Curl', 'Machine Bicep Curl'),
  ('machine-preacher-curl', 'Machine_Preacher_Curls', 'Machine Preacher Curls'),
  ('machine-shoulder-press', 'Machine_Shoulder_Military_Press', 'Machine Shoulder (Military) Press'),
  ('machine-triceps-extension', 'Machine_Triceps_Extension', 'Machine Triceps Extension'),
  ('mountain-climbers', 'Mountain_Climbers', 'Mountain Climbers'),
  ('muscle-snatch', 'Muscle_Snatch', 'Muscle Snatch'),
  ('neck-side-stretch', 'Side_Neck_Stretch', 'Side Neck Stretch'),
  ('one-arm-dumbbell-preacher-curl', 'One_Arm_Dumbbell_Preacher_Curl', 'One Arm Dumbbell Preacher Curl'),
  ('one-arm-dumbbell-shoulder-press', 'Dumbbell_One-Arm_Shoulder_Press', 'Dumbbell One-Arm Shoulder Press'),
  ('one-arm-kettlebell-floor-press', 'One-Arm_Kettlebell_Floor_Press', 'One-Arm Kettlebell Floor Press'),
  ('one-arm-kettlebell-push-press', 'One-Arm_Kettlebell_Push_Press', 'One-Arm Kettlebell Push Press'),
  ('one-arm-kettlebell-row', 'One-Arm_Kettlebell_Row', 'One-Arm Kettlebell Row'),
  ('one-arm-kettlebell-swing', 'One-Arm_Kettlebell_Swings', 'One-Arm Kettlebell Swings'),
  ('one-arm-lat-pulldown', 'One_Arm_Lat_Pulldown', 'One Arm Lat Pulldown'),
  ('one-arm-seated-cable-row', 'Seated_One-arm_Cable_Pulley_Rows', 'Seated One-arm Cable Pulley Rows'),
  ('overhead-squat', 'Overhead_Squat', 'Overhead Squat'),
  ('plank', 'Plank', 'Plank'),
  ('plate-pinch', 'Plate_Pinch', 'Plate Pinch'),
  ('plyo-push-up', 'Plyo_Push-up', 'Plyo Push-up'),
  ('preacher-curl', 'Preacher_Curl', 'Preacher Curl'),
  ('preacher-hammer-curl', 'Preacher_Hammer_Dumbbell_Curl', 'Preacher Hammer Dumbbell Curl'),
  ('push-press', 'Push_Press', 'Push Press'),
  ('rack-pull', 'Rack_Pulls', 'Rack Pulls'),
  ('rear-delt-fly', 'Reverse_Flyes', 'Reverse Flyes'),
  ('renegade-row', 'Alternating_Renegade_Row', 'Alternating Renegade Row'),
  ('reverse-curl', 'Reverse_Barbell_Curl', 'Reverse Barbell Curl'),
  ('reverse-grip-bent-over-row', 'Reverse_Grip_Bent-Over_Rows', 'Reverse Grip Bent-Over Rows'),
  ('ring-dips', 'Ring_Dips', 'Ring Dips'),
  ('romanian-deadlift', 'Romanian_Deadlift', 'Romanian Deadlift'),
  ('rope-climb', 'Rope_Climb', 'Rope Climb'),
  ('russian-twist', 'Russian_Twist', 'Russian Twist'),
  ('scissor-kicks', 'Scissor_Kick', 'Scissor Kick'),
  ('seated-barbell-overhead-press', 'Seated_Barbell_Military_Press', 'Seated Barbell Military Press'),
  ('seated-cable-row', 'Seated_Cable_Rows', 'Seated Cable Rows'),
  ('seated-calf-raise', 'Seated_Calf_Raise', 'Seated Calf Raise'),
  ('seated-db-press', 'Seated_Dumbbell_Press', 'Seated Dumbbell Press'),
  ('seated-dumbbell-curl', 'Seated_Dumbbell_Curl', 'Seated Dumbbell Curl'),
  ('seated-dumbbell-lateral-raise', 'Seated_Side_Lateral_Raise', 'Seated Side Lateral Raise'),
  ('seated-leg-curl', 'Seated_Leg_Curl', 'Seated Leg Curl'),
  ('shrug', 'Barbell_Shrug', 'Barbell Shrug'),
  ('single-arm-db-row', 'One-Arm_Dumbbell_Row', 'One-Arm Dumbbell Row'),
  ('single-arm-dumbbell-bench-press', 'One_Arm_Dumbbell_Bench_Press', 'One Arm Dumbbell Bench Press'),
  ('single-leg-extension', 'Single-Leg_Leg_Extension', 'Single-Leg Leg Extension'),
  ('single-leg-glute-bridge', 'Single_Leg_Glute_Bridge', 'Single Leg Glute Bridge'),
  ('skull-crusher', 'EZ-Bar_Skullcrusher', 'EZ-Bar Skullcrusher'),
  ('sled-push', 'Sled_Push', 'Sled Push'),
  ('sled-row', 'Sled_Row', 'Sled Row'),
  ('smith-machine-bench-press', 'Smith_Machine_Bench_Press', 'Smith Machine Bench Press'),
  ('smith-machine-bent-over-row', 'Smith_Machine_Bent_Over_Row', 'Smith Machine Bent Over Row'),
  ('smith-machine-calf-raise', 'Smith_Machine_Calf_Raise', 'Smith Machine Calf Raise'),
  ('smith-machine-decline-bench-press', 'Smith_Machine_Decline_Press', 'Smith Machine Decline Press'),
  ('smith-machine-incline-bench-press', 'Smith_Machine_Incline_Bench_Press', 'Smith Machine Incline Bench Press'),
  ('smith-machine-shoulder-press', 'Smith_Machine_Overhead_Shoulder_Press', 'Smith Machine Overhead Shoulder Press'),
  ('smith-machine-squat', 'Smith_Machine_Squat', 'Smith Machine Squat'),
  ('smith-machine-upright-row', 'Smith_Machine_Upright_Row', 'Smith Machine Upright Row'),
  ('snatch', 'Snatch', 'Snatch'),
  ('split-jerk', 'Split_Jerk', 'Split Jerk'),
  ('split-squat', 'Split_Squats', 'Split Squats'),
  ('squat', 'Barbell_Squat', 'Barbell Squat'),
  ('standing-calf-raise', 'Standing_Calf_Raises', 'Standing Calf Raises'),
  ('straight-arm-pulldown', 'Straight-Arm_Pulldown', 'Straight-Arm Pulldown'),
  ('sumo-deadlift', 'Sumo_Deadlift', 'Sumo Deadlift'),
  ('superman', 'Superman', 'Superman'),
  ('svend-press', 'Svend_Press', 'Svend Press'),
  ('t-bar-row', 'T-Bar_Row_with_Handle', 'T-Bar Row with Handle'),
  ('treadmill-running', 'Running_Treadmill', 'Running, Treadmill'),
  ('tricep-kickback', 'Tricep_Dumbbell_Kickback', 'Tricep Dumbbell Kickback'),
  ('tricep-pushdown', 'Triceps_Pushdown', 'Triceps Pushdown'),
  ('upright-row', 'Upright_Barbell_Row', 'Upright Barbell Row'),
  ('v-bar-tricep-pushdown', 'Triceps_Pushdown_-_V-Bar_Attachment', 'Triceps Pushdown - V-Bar Attachment'),
  ('wide-grip-bench-press', 'Wide-Grip_Barbell_Bench_Press', 'Wide-Grip Barbell Bench Press'),
  ('worlds-greatest-stretch', 'Worlds_Greatest_Stretch', 'World''s Greatest Stretch'),
  ('wrist-roller', 'Wrist_Roller', 'Wrist Roller'),
  ('zercher-squat', 'Zercher_Squats', 'Zercher Squats'),
  ('zottman-curl', 'Zottman_Curl', 'Zottman Curl')
  ) as p(exercise_id, folder, origin_name)
  join public.exercises e on e.id = p.exercise_id
on conflict (exercise_id) do nothing;

-- 3) Las fichas mapeadas pasan a mostrar las dos fotos del movimiento.
update public.exercises e
   set image_start = m.folder || '/0.jpg',
       image_peak  = m.folder || '/1.jpg',
       updated_at  = now()
  from public.exercise_photo_map m
 where m.exercise_id = e.id
   and m.applied
   and (e.image_start is distinct from m.folder || '/0.jpg'
     or e.image_peak  is distinct from m.folder || '/1.jpg');

-- 4) Recargar el catálogo viejo no puede borrar lo que ya se decidió.
create or replace function public.exercise_photo_keep()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_folder text;
begin
  select m.folder into v_folder
    from public.exercise_photo_map m
   where m.exercise_id = new.id
     and m.applied;

  if v_folder is not null then
    new.image_start := v_folder || '/0.jpg';
    new.image_peak  := v_folder || '/1.jpg';
  end if;

  return new;
end;
$$;

comment on function public.exercise_photo_keep() is
  'Mantiene las fotos de EX-04 cuando se recarga el catálogo viejo. Revertir: applied = false en exercise_photo_map.';

drop trigger if exists exercises_keep_photo on public.exercises;
create trigger exercises_keep_photo
  before insert or update on public.exercises
  for each row execute function public.exercise_photo_keep();

commit;

-- ═══════════════════════════════════════════════════════════
--  00094_fotos_que_faltaban.sql
-- ═══════════════════════════════════════════════════════════

-- 00094 · Las tres fichas que sí tenían fotos y se quedaron sin movimiento (EX-04b)
--
-- Qué pasó: al abrir la biblioteca en el teléfono el dueño vio que algunas
-- fichas se movían y otras no. De las 467 visibles, **32 no se mueven** porque
-- el catálogo de dibujos (RepDB) publicó **una sola imagen** para ellas: son
-- posiciones que se mantienen (planchas, sostenes, L-sit, levers), paseos con
-- peso y máquinas de cardio.
--
-- De esas 32, sólo **tres** tienen equivalente con dos fotos en el segundo
-- catálogo y equivalen al mismo movimiento:
--   · Caminata en cinta inclinada → `Walking_Treadmill` (cinta caminando).
--   · Escaladora de escaleras    → `Stairmaster` (escaladora de sala).
--   · Caminata del granjero con mancuernas → `Farmers_Walk` (mancuernas).
--
-- Las otras 29 se quedan como están, a propósito: o son posiciones que no se
-- mueven (no hay movimiento que mostrar), o el segundo catálogo sólo tiene un
-- aparato parecido pero **distinto** (una bicicleta reclinada no es la
-- bicicleta fija de la sala, y su «Air Bike» es un abdominal en el piso, no la
-- de aire). Poner la foto de otro aparato sería peor que el dibujo quieto.
--
-- Usa la misma tabla y el mismo disparador de la 00093: no crea nada nuevo y
-- guarda las rutas anteriores para poder revertir con
--   update public.exercise_photo_map set applied = false;  (+ restaurar old_*)

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.exercise_photo_map') is null then
    raise exception 'EXERCISES_PREREQUISITE_MISSING';
  end if;
end $$;

insert into public.exercise_photo_map
  (exercise_id, folder, origin_name, old_image_start, old_image_peak, old_image_main)
select p.exercise_id, p.folder, p.origin_name,
       e.image_start, e.image_peak, e.image_main
  from (values
    ('dumbbell-farmers-walk',   'Farmers_Walk',      'Farmer''s Walk'),
    ('incline-treadmill-walk',  'Walking_Treadmill', 'Walking, Treadmill'),
    ('stair-climber',           'Stairmaster',       'Stairmaster')
  ) as p(exercise_id, folder, origin_name)
  join public.exercises e on e.id = p.exercise_id
on conflict (exercise_id) do nothing;

-- Las tres pasan a mostrar sus dos fotos (el disparador de la 00093 las
-- mantiene aunque se recargue el catálogo viejo).
update public.exercises e
   set image_start = m.folder || '/0.jpg',
       image_peak  = m.folder || '/1.jpg',
       updated_at  = now()
  from public.exercise_photo_map m
 where m.exercise_id = e.id
   and m.applied
   and m.folder in ('Farmers_Walk', 'Walking_Treadmill', 'Stairmaster')
   and (e.image_start is distinct from m.folder || '/0.jpg'
     or e.image_peak  is distinct from m.folder || '/1.jpg');

commit;

-- ═══════════════════════════════════════════════════════════
--  00095_cuentas_catalogos.sql
-- ═══════════════════════════════════════════════════════════

-- ============================================================
--  00095 — Cuentas de caja/banco, métodos y categorías (FIN-03, parte 1)
-- ============================================================
--  Poder administrar desde la app las cuentas donde entra la plata, los
--  métodos de pago y las categorías de gasto. Antes sólo existían en la base.
--
--  Reglas:
--    · Escribir exige administrador con segundo factor (`is_admin()`).
--      Leer exige personal con segundo factor (`crm_is_staff()`).
--    · Los saldos sólo se ven con el interruptor de saldos o siendo admin.
--    · Nada se borra: se apaga (`is_active`). No se apaga una caja con turno
--      abierto ni se le cambia la moneda a una cuenta con movimientos.
--    · Todo queda en `finance_settings_audit`: quién, cuándo, antes y después.
--
--  Aditiva: una tabla nueva, una columna con valor por omisión y funciones
--  nuevas. No toca datos existentes ni crea movimientos.
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0. Comprobaciones de lo que ya tiene que existir
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.bank_accounts') is null
     or to_regclass('public.payment_methods') is null
     or to_regclass('public.expense_categories') is null
     or to_regclass('public.profiles') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('public.finance_permission_enabled(text)') is null
     or to_regprocedure('public.crm_options()') is null
     or to_regprocedure('public.finance_writes_ready()') is null then
    raise exception 'CUENTAS_PREREQUISITE_MISSING';
  end if;
end $$;

-- 1. Bitácora de los cambios de configuración del dinero
-- ---------------------------------------------------------------------------
create table if not exists public.finance_settings_audit (
  id        uuid primary key default gen_random_uuid(),
  at        timestamptz not null default now(),
  actor_id  uuid references public.profiles (id) on delete set null,
  action    text not null check (action in (
              'account_save', 'method_save', 'category_save',
              'transfer_create', 'transfer_void'
            )),
  target    text,
  details   jsonb not null default '{}'::jsonb
);

create index if not exists finance_settings_audit_at_idx
  on public.finance_settings_audit (at desc);

alter table public.finance_settings_audit enable row level security;
-- Nadie escribe ni lee esta tabla directamente: la escriben las funciones de
-- abajo (security definer) y la lee `finance_accounts_state` para el panel.
revoke all on public.finance_settings_audit from public, anon, authenticated;

-- Una categoría de gasto también se apaga en vez de borrarse. Los gastos
-- viejos siguen apuntando a su categoría.
alter table public.expense_categories
  add column if not exists is_active boolean not null default true;

-- ---------------------------------------------------------------------------
-- 2. Una sola lectura para la pantalla de cuentas
-- ---------------------------------------------------------------------------
create or replace function public.finance_accounts_state(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_can_manage boolean := public.is_admin();
  v_balances boolean := public.is_admin()
    or public.finance_permission_enabled('cashier_can_view_account_balances');
  v_accounts jsonb;
  v_methods jsonb;
  v_categories jsonb;
  v_transfers jsonb;
  v_audit jsonb;
begin
  if not public.crm_is_staff() then
    raise exception 'AUTH';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id,
      'name', a.name,
      'accountType', a.account_type,
      'currency', a.currency,
      'bankName', a.bank_name,
      'accountNumber', a.account_number,
      'isActive', a.is_active,
      'displayOrder', a.display_order,
      'balance', case when v_balances then a.balance else null end,
      'movements', (
        select count(*)
        from public.transactions t
        where t.account_id = a.id or t.destination_account_id = a.id
      ),
      'cashOpen', case
        when a.account_type = 'caja_fuerte'
          then exists(select 1 from public.cash_sessions c where c.closed_at is null)
        else false
      end
    ) order by a.display_order, a.name, a.id), '[]'::jsonb)
  into v_accounts
  from public.bank_accounts a;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id,
      'name', m.name,
      'currency', m.currency,
      'feePct', m.fee_pct,
      'isActive', m.is_active,
      'displayOrder', m.display_order,
      'movements', (select count(*) from public.transactions t where t.method_id = m.id)
    ) order by m.display_order, m.name, m.id), '[]'::jsonb)
  into v_methods
  from public.payment_methods m;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id,
      'name', c.name,
      'color', c.color,
      'budgetMonthly', c.budget_monthly,
      'isActive', c.is_active,
      'displayOrder', c.display_order,
      'movements', (select count(*) from public.transactions t where t.category_id = c.id)
    ) order by c.display_order, c.name, c.id), '[]'::jsonb)
  into v_categories
  from public.expense_categories c;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id,
      'occurredAt', t.occurred_at,
      'status', t.status,
      'fromId', t.account_id,
      'fromName', f.name,
      'toId', t.destination_account_id,
      'toName', d.name,
      'amountOut', t.amount,
      'currencyOut', t.currency,
      'amountIn', case
        when coalesce(d.currency, t.currency) = 'NIO' then round(t.amount_nio, 2)
        else round(t.amount_usd, 2)
      end,
      'currencyIn', coalesce(d.currency, t.currency),
      'fx', t.fx_used,
      'amountNio', t.amount_nio,
      'concept', t.concept,
      'createdByName', (select p.full_name from public.profiles p where p.id = t.created_by),
      'voided', exists(select 1 from public.finance_voids v where v.original_id = t.id),
      'voidReason', (select v.reason from public.finance_voids v where v.original_id = t.id)
    ) order by t.occurred_at desc, t.id desc), '[]'::jsonb)
  into v_transfers
  from (
    select *
    from public.transactions
    where type = 'transfer'
    order by occurred_at desc, id desc
    limit v_limit
  ) t
  join public.bank_accounts f on f.id = t.account_id
  left join public.bank_accounts d on d.id = t.destination_account_id;

  -- La bitácora sólo la ve quien puede cambiar la configuración.
  if v_can_manage then
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id,
        'at', x.at,
        'action', x.action,
        'target', x.target,
        'actorName', (select p.full_name from public.profiles p where p.id = x.actor_id),
        'details', x.details
      ) order by x.at desc), '[]'::jsonb)
    into v_audit
    from (
      select * from public.finance_settings_audit order by at desc limit 20
    ) x;
  end if;

  return jsonb_build_object(
    'accounts', v_accounts,
    'methods', v_methods,
    'categories', v_categories,
    'transfers', v_transfers,
    'audit', coalesce(v_audit, '[]'::jsonb),
    'canManage', v_can_manage,
    'balancesVisible', v_balances,
    'rules', jsonb_build_object(
      'accountTypes', jsonb_build_array('caja_fuerte', 'banco', 'billetera'),
      'currencies', jsonb_build_array('NIO', 'USD'),
      'transferRule', 'Una transferencia mueve plata entre dos cuentas: no es ingreso ni gasto. Se guarda la tasa NIO/USD usada.'
    )
  );
end $$;

revoke all on function public.finance_accounts_state(integer) from public, anon;
grant execute on function public.finance_accounts_state(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Alta y edición de cuentas
-- ---------------------------------------------------------------------------
create or replace function public.finance_account_save(
  p_id text default null,
  p_name text default '',
  p_account_type text default 'caja_fuerte',
  p_currency text default 'NIO',
  p_bank_name text default null,
  p_account_number text default null,
  p_display_order integer default 100,
  p_is_active boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_id text := nullif(btrim(coalesce(p_id, '')), '');
  v_name text := btrim(coalesce(p_name, ''));
  v_type text := btrim(coalesce(p_account_type, ''));
  v_currency text := btrim(coalesce(p_currency, ''));
  v_bank text := nullif(btrim(coalesce(p_bank_name, '')), '');
  v_number text := nullif(btrim(coalesce(p_account_number, '')), '');
  v_row public.bank_accounts;
  v_before jsonb;
  v_deactivating boolean;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  if char_length(v_name) not between 2 and 60 then raise exception 'INVALID_NAME'; end if;
  if v_type not in ('caja_fuerte', 'banco', 'billetera') then raise exception 'INVALID_ACCOUNT_TYPE'; end if;
  if v_currency not in ('NIO', 'USD') then raise exception 'INVALID_CURRENCY'; end if;
  if v_bank is not null and char_length(v_bank) > 60 then raise exception 'INVALID_BANK'; end if;
  if v_number is not null and char_length(v_number) > 40 then raise exception 'INVALID_ACCOUNT_NUMBER'; end if;
  if p_display_order is null or p_display_order not between 0 and 9999 then
    raise exception 'INVALID_ORDER';
  end if;

  if v_id is null then
    if exists (select 1 from public.bank_accounts where lower(name) = lower(v_name)) then
      raise exception 'ACCOUNT_NAME_TAKEN';
    end if;
    v_id := 'cta_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    insert into public.bank_accounts (
      id, name, account_type, currency, bank_name, account_number,
      balance, is_active, display_order
    ) values (
      v_id, v_name, v_type, v_currency, v_bank, v_number,
      0, coalesce(p_is_active, true), p_display_order
    ) returning * into v_row;
    v_before := null;
  else
    select * into v_row from public.bank_accounts where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if exists (
      select 1 from public.bank_accounts
      where lower(name) = lower(v_name) and id <> v_id
    ) then
      raise exception 'ACCOUNT_NAME_TAKEN';
    end if;

    -- Cambiar la moneda cambiaría el significado de todos sus movimientos.
    if v_currency <> v_row.currency
       and exists (
         select 1 from public.transactions
         where account_id = v_id or destination_account_id = v_id
       ) then
      raise exception 'ACCOUNT_CURRENCY_LOCKED';
    end if;

    v_deactivating := v_row.is_active and not coalesce(p_is_active, true);
    if v_deactivating
       and v_row.account_type = 'caja_fuerte'
       and exists (select 1 from public.cash_sessions where closed_at is null) then
      raise exception 'ACCOUNT_IN_OPEN_CASH';
    end if;

    v_before := to_jsonb(v_row);
    update public.bank_accounts set
      name = v_name,
      account_type = v_type,
      currency = v_currency,
      bank_name = v_bank,
      account_number = v_number,
      is_active = coalesce(p_is_active, true),
      display_order = p_display_order
    where id = v_id
    returning * into v_row;
  end if;

  insert into public.finance_settings_audit (actor_id, action, target, details)
  values (
    auth.uid(), 'account_save', v_id,
    jsonb_build_object('before', v_before, 'after', to_jsonb(v_row))
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'accountType', v_row.account_type,
    'currency', v_row.currency,
    'bankName', v_row.bank_name,
    'accountNumber', v_row.account_number,
    'isActive', v_row.is_active,
    'displayOrder', v_row.display_order,
    'balance', v_row.balance
  );
end $$;

revoke all on function public.finance_account_save(text, text, text, text, text, text, integer, boolean)
  from public, anon, authenticated;
grant execute on function public.finance_account_save(text, text, text, text, text, text, integer, boolean)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Alta y edición de métodos de pago
-- ---------------------------------------------------------------------------
create or replace function public.finance_method_save(
  p_id text default null,
  p_name text default '',
  p_currency text default 'NIO',
  p_fee_pct numeric default 0,
  p_display_order integer default 100,
  p_is_active boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_id text := nullif(btrim(coalesce(p_id, '')), '');
  v_name text := btrim(coalesce(p_name, ''));
  v_currency text := btrim(coalesce(p_currency, ''));
  v_fee numeric := coalesce(p_fee_pct, 0);
  v_row public.payment_methods;
  v_before jsonb;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  if char_length(v_name) not between 2 and 40 then raise exception 'INVALID_NAME'; end if;
  if v_currency not in ('NIO', 'USD', 'BOTH') then raise exception 'INVALID_CURRENCY'; end if;
  if v_fee < 0 or v_fee > 100 or v_fee <> round(v_fee, 2) then raise exception 'INVALID_FEE'; end if;
  if p_display_order is null or p_display_order not between 0 and 9999 then
    raise exception 'INVALID_ORDER';
  end if;

  if v_id is null then
    if exists (select 1 from public.payment_methods where lower(name) = lower(v_name)) then
      raise exception 'METHOD_NAME_TAKEN';
    end if;
    v_id := 'met_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    insert into public.payment_methods (id, name, currency, fee_pct, is_active, display_order)
    values (v_id, v_name, v_currency, v_fee, coalesce(p_is_active, true), p_display_order)
    returning * into v_row;
    v_before := null;
  else
    select * into v_row from public.payment_methods where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if exists (
      select 1 from public.payment_methods
      where lower(name) = lower(v_name) and id <> v_id
    ) then
      raise exception 'METHOD_NAME_TAKEN';
    end if;
    v_before := to_jsonb(v_row);
    update public.payment_methods set
      name = v_name,
      currency = v_currency,
      fee_pct = v_fee,
      is_active = coalesce(p_is_active, true),
      display_order = p_display_order
    where id = v_id
    returning * into v_row;
  end if;

  insert into public.finance_settings_audit (actor_id, action, target, details)
  values (
    auth.uid(), 'method_save', v_id,
    jsonb_build_object('before', v_before, 'after', to_jsonb(v_row))
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'currency', v_row.currency,
    'feePct', v_row.fee_pct,
    'isActive', v_row.is_active,
    'displayOrder', v_row.display_order
  );
end $$;

revoke all on function public.finance_method_save(text, text, text, numeric, integer, boolean)
  from public, anon, authenticated;
grant execute on function public.finance_method_save(text, text, text, numeric, integer, boolean)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Alta y edición de categorías de gasto
-- ---------------------------------------------------------------------------
create or replace function public.finance_category_save(
  p_id text default null,
  p_name text default '',
  p_color text default '#888888',
  p_budget_monthly numeric default null,
  p_display_order integer default 100,
  p_is_active boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_id text := nullif(btrim(coalesce(p_id, '')), '');
  v_name text := btrim(coalesce(p_name, ''));
  v_color text := btrim(coalesce(p_color, '#888888'));
  v_budget numeric := p_budget_monthly;
  v_row public.expense_categories;
  v_before jsonb;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;

  if char_length(v_name) not between 2 and 40 then raise exception 'INVALID_NAME'; end if;
  if v_color !~ '^#[0-9a-fA-F]{6}$' then raise exception 'INVALID_COLOR'; end if;
  if v_budget is not null
     and (v_budget < 0 or v_budget > 99999999 or v_budget <> round(v_budget, 2)) then
    raise exception 'INVALID_BUDGET';
  end if;
  if p_display_order is null or p_display_order not between 0 and 9999 then
    raise exception 'INVALID_ORDER';
  end if;

  if v_id is null then
    if exists (select 1 from public.expense_categories where lower(name) = lower(v_name)) then
      raise exception 'CATEGORY_NAME_TAKEN';
    end if;
    v_id := 'cat_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    insert into public.expense_categories (
      id, name, color, budget_monthly, display_order, is_active
    ) values (
      v_id, v_name, lower(v_color), v_budget, p_display_order, coalesce(p_is_active, true)
    ) returning * into v_row;
    v_before := null;
  else
    select * into v_row from public.expense_categories where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if exists (
      select 1 from public.expense_categories
      where lower(name) = lower(v_name) and id <> v_id
    ) then
      raise exception 'CATEGORY_NAME_TAKEN';
    end if;
    v_before := to_jsonb(v_row);
    update public.expense_categories set
      name = v_name,
      color = lower(v_color),
      budget_monthly = v_budget,
      display_order = p_display_order,
      is_active = coalesce(p_is_active, true)
    where id = v_id
    returning * into v_row;
  end if;

  insert into public.finance_settings_audit (actor_id, action, target, details)
  values (
    auth.uid(), 'category_save', v_id,
    jsonb_build_object('before', v_before, 'after', to_jsonb(v_row))
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'color', v_row.color,
    'budgetMonthly', v_row.budget_monthly,
    'isActive', v_row.is_active,
    'displayOrder', v_row.display_order
  );
end $$;

revoke all on function public.finance_category_save(text, text, text, numeric, integer, boolean)
  from public, anon, authenticated;
grant execute on function public.finance_category_save(text, text, text, numeric, integer, boolean)
  to authenticated;

notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00096_transferencias_y_arqueo.sql
-- ═══════════════════════════════════════════════════════════

-- ============================================================
--  00096 — Transferencias entre cuentas y arqueo que las cuenta
--  (FIN-03, parte 2)
-- ============================================================
--  Pasar plata de una cuenta a otra sin que cuente como ingreso ni gasto, y
--  anularla con contra-asiento. Una transferencia es UNA fila de `transactions`
--  con `type='transfer'`, origen en `account_id` y destino en
--  `destination_account_id` (el modelo ya existía sin usar).
--
--  Además corrige el arqueo: si sale efectivo de la caja fuerte, «debería
--  haber» baja; si entra, sube. Sin esto, cerrar la caja después de una
--  transferencia inventaría un faltante.
--
--  Requiere 00095 (bitácora) y las funciones de caja de 00087.
-- ============================================================

begin;

set local lock_timeout = '5s';

do $$
begin
  if to_regclass('public.finance_settings_audit') is null
     or to_regclass('public.finance_voids') is null
     or to_regclass('public.cash_sessions') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.finance_cash_row_json(uuid)') is null
     or to_regprocedure('public.finance_cash_close(uuid,uuid,numeric,numeric,text)') is null
     or to_regprocedure('public.finance_cash_movements(timestamptz,timestamptz)') is null then
    raise exception 'TRANSFER_PREREQUISITE_MISSING';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Transferencia entre cuentas (no es ingreso ni gasto)
-- ---------------------------------------------------------------------------
create or replace function public.finance_transfer_create(
  p_request uuid,
  p_from text,
  p_to text,
  p_amount numeric,
  p_fx numeric,
  p_concept text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_from public.bank_accounts;
  v_to public.bank_accounts;
  v_existing public.finance_entries;
  v_payload jsonb;
  v_concept text := btrim(coalesce(p_concept, ''));
  v_amount_in numeric;
  v_amount_nio numeric;
  v_amount_usd numeric;
  v_from_after numeric;
  v_to_after numeric;
  v_id uuid;
  v_at timestamptz := clock_timestamp();
  v_actor_name text;
  v_receipt jsonb;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 99999999
     or p_amount <> round(p_amount, 2) then
    raise exception 'INVALID_AMOUNT';
  end if;
  if p_fx is null or p_fx < 0.0001 or p_fx > 10000 or p_fx <> round(p_fx, 4) then
    raise exception 'INVALID_FX';
  end if;
  if char_length(v_concept) not between 2 and 200 then raise exception 'INVALID_CONCEPT'; end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'INVALID_ACCOUNTS'; end if;

  v_payload := jsonb_build_object(
    'kind', 'transfer',
    'from', p_from,
    'to', p_to,
    'amount', p_amount,
    'fx', p_fx,
    'concept', v_concept
  );

  perform pg_advisory_xact_lock(hashtextextended(p_request::text, 0));
  select * into v_existing from public.finance_entries where request_id = p_request;
  if found then
    if v_existing.payload is distinct from v_payload then
      raise exception 'REQUEST_CONFLICT';
    end if;
    return v_existing.receipt;
  end if;

  -- Siempre en el mismo orden para que dos transferencias cruzadas no se
  -- queden esperando la una a la otra.
  perform 1 from public.bank_accounts where id in (p_from, p_to) order by id for update;

  select * into v_from from public.bank_accounts where id = p_from;
  if not found or not v_from.is_active then raise exception 'INVALID_ACCOUNT'; end if;
  select * into v_to from public.bank_accounts where id = p_to;
  if not found or not v_to.is_active then raise exception 'INVALID_ACCOUNT'; end if;

  -- Igual que un gasto en efectivo, una transferencia puede dejar la cuenta
  -- en negativo: la app muestra el saldo antes y después, y el dueño decide.
  -- No se bloquea acá para no inventar una regla que el resto del dinero no
  -- tiene (un gasto sí puede dejar saldo negativo).
  if v_from.currency = v_to.currency then
    v_amount_in := p_amount;
    v_amount_nio := case when v_from.currency = 'NIO' then p_amount else round(p_amount * p_fx, 2) end;
    v_amount_usd := case when v_from.currency = 'USD' then p_amount else round(p_amount / p_fx, 4) end;
  elsif v_from.currency = 'NIO' then
    -- Córdobas → dólares: se entrega lo que compra la tasa.
    v_amount_in := round(p_amount / p_fx, 2);
    v_amount_nio := p_amount;
    v_amount_usd := round(p_amount / p_fx, 4);
  else
    -- Dólares → córdobas: se entrega lo que vale la tasa.
    v_amount_in := round(p_amount * p_fx, 2);
    v_amount_nio := v_amount_in;
    v_amount_usd := p_amount;
  end if;

  if v_amount_in <= 0 then raise exception 'INVALID_AMOUNT'; end if;

  v_from_after := v_from.balance - p_amount;
  v_to_after := v_to.balance + v_amount_in;
  if abs(v_from_after) > 9999999999.99 or abs(v_to_after) > 9999999999.99 then
    raise exception 'INVALID_AMOUNT';
  end if;

  select full_name into v_actor_name from public.profiles where id = auth.uid();

  insert into public.transactions (
    type, status, occurred_at, account_id, destination_account_id,
    amount, currency, amount_nio, amount_usd, fx_used,
    concept, notes, crm_request_id, created_by, created_at, updated_at
  ) values (
    'transfer', 'completed', v_at, p_from, p_to,
    p_amount, v_from.currency, v_amount_nio, v_amount_usd, p_fx,
    'Transferencia · ' || v_concept,
    v_from.name || ' → ' || v_to.name,
    p_request, auth.uid(), v_at, v_at
  ) returning id into v_id;

  update public.bank_accounts set balance = v_from_after where id = p_from;
  update public.bank_accounts set balance = v_to_after where id = p_to;

  insert into public.finance_entries (transaction_id, request_id, payload, receipt)
  values (
    v_id,
    p_request,
    v_payload,
    jsonb_build_object(
      'id', v_id,
      'reference', 'SG-' || v_id::text,
      'requestId', p_request,
      'kind', 'transfer',
      'occurredAt', v_at,
      'fromId', p_from,
      'fromName', v_from.name,
      'toId', p_to,
      'toName', v_to.name,
      'amount', p_amount,
      'currency', v_from.currency,
      'amountIn', v_amount_in,
      'currencyIn', v_to.currency,
      'fx', p_fx,
      'amountNio', v_amount_nio,
      'amountUsd', v_amount_usd,
      'concept', v_concept,
      'actorId', auth.uid(),
      'actorName', v_actor_name,
      'fromBefore', v_from.balance,
      'fromAfter', v_from_after,
      'toBefore', v_to.balance,
      'toAfter', v_to_after
    )
  );

  insert into public.finance_settings_audit (actor_id, action, target, details)
  values (
    auth.uid(), 'transfer_create', v_id::text,
    jsonb_build_object(
      'from', p_from, 'to', p_to,
      'amount', p_amount, 'currency', v_from.currency,
      'amountIn', v_amount_in, 'currencyIn', v_to.currency,
      'fx', p_fx, 'concept', v_concept,
      'fromBefore', v_from.balance, 'fromAfter', v_from_after,
      'toBefore', v_to.balance, 'toAfter', v_to_after
    )
  );

  select receipt into v_receipt from public.finance_entries where transaction_id = v_id;
  return v_receipt;
end $$;

revoke all on function public.finance_transfer_create(uuid, text, text, numeric, numeric, text)
  from public, anon, authenticated;
grant execute on function public.finance_transfer_create(uuid, text, text, numeric, numeric, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Anular una transferencia: contra-asiento, nunca borrar
-- ---------------------------------------------------------------------------
create or replace function public.finance_transfer_void(
  p_request uuid,
  p_transfer uuid,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_t public.transactions;
  v_from public.bank_accounts;
  v_to public.bank_accounts;
  v_existing public.finance_voids;
  v_payload jsonb;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_amount_in numeric;
  v_reversal uuid;
  v_at timestamptz := clock_timestamp();
  v_from_after numeric;
  v_to_after numeric;
  v_receipt jsonb;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  if p_transfer is null then raise exception 'NOT_FOUND'; end if;
  if char_length(v_reason) not between 5 and 300 then raise exception 'INVALID_REASON'; end if;

  v_payload := jsonb_build_object('transfer', p_transfer, 'reason', v_reason);

  perform pg_advisory_xact_lock(hashtextextended(p_request::text, 0));
  select * into v_existing from public.finance_voids where request_id = p_request;
  if found then
    if v_existing.payload is distinct from v_payload then
      raise exception 'REQUEST_CONFLICT';
    end if;
    return v_existing.receipt;
  end if;

  select * into v_t from public.transactions where id = p_transfer for update;
  if not found or v_t.type <> 'transfer' then raise exception 'NOT_FOUND'; end if;
  if v_t.status <> 'completed' then raise exception 'NOT_ALLOWED'; end if;
  if exists (select 1 from public.finance_voids where original_id = p_transfer) then
    raise exception 'NOT_ALLOWED';
  end if;
  if v_t.destination_account_id is null then raise exception 'NOT_FOUND'; end if;

  perform 1 from public.bank_accounts
    where id in (v_t.account_id, v_t.destination_account_id)
    order by id for update;

  select * into v_from from public.bank_accounts where id = v_t.account_id;
  if not found then raise exception 'INVALID_ACCOUNT'; end if;
  select * into v_to from public.bank_accounts where id = v_t.destination_account_id;
  if not found then raise exception 'INVALID_ACCOUNT'; end if;

  v_amount_in := case
    when v_to.currency = 'NIO' then round(v_t.amount_nio, 2)
    else round(v_t.amount_usd, 2)
  end;

  v_from_after := v_from.balance + v_t.amount;
  v_to_after := v_to.balance - v_amount_in;
  if abs(v_from_after) > 9999999999.99 or abs(v_to_after) > 9999999999.99 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- El contra-asiento es la transferencia al revés.
  insert into public.transactions (
    type, status, occurred_at, account_id, destination_account_id,
    amount, currency, amount_nio, amount_usd, fx_used,
    concept, notes, crm_request_id, created_by, created_at, updated_at
  ) values (
    'transfer', 'completed', v_at, v_to.id, v_from.id,
    v_amount_in, v_to.currency, v_t.amount_nio, v_t.amount_usd, v_t.fx_used,
    left('Anulación: ' || v_t.concept, 200),
    v_to.name || ' → ' || v_from.name,
    p_request, auth.uid(), v_at, v_at
  ) returning id into v_reversal;

  update public.bank_accounts set balance = v_from_after where id = v_from.id;
  update public.bank_accounts set balance = v_to_after where id = v_to.id;

  v_receipt := jsonb_build_object(
    'id', v_reversal,
    'reference', 'SG-' || v_reversal::text,
    'requestId', p_request,
    'kind', 'transfer_void',
    'originalId', v_t.id,
    'reversalId', v_reversal,
    'reason', v_reason,
    'occurredAt', v_at,
    'fromId', v_to.id,
    'toId', v_from.id,
    'amount', v_amount_in,
    'currency', v_to.currency
  );

  insert into public.finance_voids (
    original_id, reversal_id, reason, request_id, payload, receipt, actor_id, created_at
  ) values (
    v_t.id, v_reversal, v_reason, p_request, v_payload, v_receipt, auth.uid(), v_at
  );

  insert into public.finance_settings_audit (actor_id, action, target, details)
  values (
    auth.uid(), 'transfer_void', v_t.id::text,
    jsonb_build_object(
      'reason', v_reason,
      'reversalId', v_reversal,
      'amount', v_t.amount, 'amountIn', v_amount_in
    )
  );

  return v_receipt;
end $$;

revoke all on function public.finance_transfer_void(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.finance_transfer_void(uuid, uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Los desplegables de cobro y gasto sólo ofrecen lo que está encendido
-- ---------------------------------------------------------------------------
create or replace function public.finance_options()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  v := public.crm_options();
  return (v - 'payments_enabled' - 'payment_block_reason') || jsonb_build_object(
    'protocol', 'service-v1',
    'writes_enabled', public.finance_writes_ready(),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by display_order, name)
      from public.expense_categories
      where is_active
    ), '[]'::jsonb)
  );
end $$;

revoke all on function public.finance_options() from public, anon, authenticated;
grant execute on function public.finance_options() to authenticated;

-- ---------------------------------------------------------------------------
-- 9. El arqueo de caja tiene que ver las transferencias
-- ---------------------------------------------------------------------------
-- Si alguien pasa efectivo de la caja fuerte al banco, la caja tiene menos
-- plata. Sin esta corrección, cerrar la caja inventaría un faltante.
create or replace function public.finance_cash_movements(
  p_from timestamptz,
  p_to timestamptz
) returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with cash_accounts as (
    select id, currency from public.bank_accounts where account_type = 'caja_fuerte'
  ), cash as (
    select
      t.amount,
      t.currency::text as currency,
      t.type::text as type,
      t.account_id
    from public.transactions t
    join cash_accounts a on a.id = t.account_id
    where t.status::text = 'completed'
      and t.type::text in ('income', 'expense')
      and t.occurred_at >= p_from
      and t.occurred_at <= p_to
  ), transfers_out as (
    select
      t.amount,
      t.currency::text as currency,
      t.occurred_at
    from public.transactions t
    join cash_accounts a on a.id = t.account_id
    where t.type::text = 'transfer'
      and t.status::text = 'completed'
      and t.occurred_at >= p_from
      and t.occurred_at <= p_to
  ), transfers_in as (
    select
      case when a.currency = 'NIO' then t.amount_nio else round(t.amount_usd, 2) end as amount,
      a.currency::text as currency
    from public.transactions t
    join cash_accounts a on a.id = t.destination_account_id
    where t.type::text = 'transfer'
      and t.status::text = 'completed'
      and t.occurred_at >= p_from
      and t.occurred_at <= p_to
  ), totals as (
    select
      coalesce((select sum(amount) from cash where type = 'income' and currency = 'NIO'), 0) as income_nio,
      coalesce((select sum(amount) from cash where type = 'income' and currency = 'USD'), 0) as income_usd,
      coalesce((select sum(amount) from cash where type = 'expense' and currency = 'NIO'), 0) as expense_nio,
      coalesce((select sum(amount) from cash where type = 'expense' and currency = 'USD'), 0) as expense_usd,
      coalesce((select sum(amount) from transfers_in where currency = 'NIO'), 0) as transfer_in_nio,
      coalesce((select sum(amount) from transfers_in where currency = 'USD'), 0) as transfer_in_usd,
      coalesce((select sum(amount) from transfers_out where currency = 'NIO'), 0) as transfer_out_nio,
      coalesce((select sum(amount) from transfers_out where currency = 'USD'), 0) as transfer_out_usd,
      (select count(*) from cash)
        + (select count(*) from transfers_out)
        + (select count(*) from transfers_in) as movements
  )
  select jsonb_build_object(
    'incomeNio', totals.income_nio,
    'incomeUsd', totals.income_usd,
    'expenseNio', totals.expense_nio,
    'expenseUsd', totals.expense_usd,
    'transferInNio', totals.transfer_in_nio,
    'transferInUsd', totals.transfer_in_usd,
    'transferOutNio', totals.transfer_out_nio,
    'transferOutUsd', totals.transfer_out_usd,
    'count', totals.movements,
    'accounts', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'accountId', by_account.account_id,
            'currency', by_account.currency,
            'income', by_account.income,
            'expense', by_account.expense,
            'transferIn', by_account.transfer_in,
            'transferOut', by_account.transfer_out
          )
          order by by_account.account_id
        )
        from (
          select
            base.account_id,
            base.currency,
            coalesce(sum(base.income), 0) as income,
            coalesce(sum(base.expense), 0) as expense,
            coalesce(sum(base.transfer_in), 0) as transfer_in,
            coalesce(sum(base.transfer_out), 0) as transfer_out
          from (
            select account_id, currency, amount as income, 0::numeric as expense,
                   0::numeric as transfer_in, 0::numeric as transfer_out
            from cash where type = 'income'
            union all
            select account_id, currency, 0::numeric, amount, 0::numeric, 0::numeric
            from cash where type = 'expense'
            union all
            select t.account_id, t.currency::text, 0::numeric, 0::numeric, 0::numeric, t.amount
            from public.transactions t
            join cash_accounts a on a.id = t.account_id
            where t.type::text = 'transfer' and t.status::text = 'completed'
              and t.occurred_at >= p_from and t.occurred_at <= p_to
            union all
            select t.destination_account_id, a.currency::text, 0::numeric, 0::numeric,
                   case when a.currency = 'NIO' then t.amount_nio else round(t.amount_usd, 2) end,
                   0::numeric
            from public.transactions t
            join cash_accounts a on a.id = t.destination_account_id
            where t.type::text = 'transfer' and t.status::text = 'completed'
              and t.occurred_at >= p_from and t.occurred_at <= p_to
          ) base
          group by base.account_id, base.currency
        ) by_account
      ),
      '[]'::jsonb
    )
  )
  from totals;
$$;

revoke all on function public.finance_cash_movements(timestamptz, timestamptz)
  from public, anon, authenticated;

-- `finance_cash_row_json`: el «debería haber» suma lo que entró por
-- transferencia y resta lo que salió.
create or replace function public.finance_cash_row_json(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_session public.cash_sessions;
  v_movements jsonb;
  v_expected_nio numeric;
  v_expected_usd numeric;
begin
  select * into v_session from public.cash_sessions where id = p_id;
  if not found then return null; end if;

  v_movements := public.finance_cash_movements(
    v_session.opened_at,
    coalesce(v_session.closed_at, now())
  );
  v_expected_nio := v_session.opening_balance_nio
    + coalesce((v_movements ->> 'incomeNio')::numeric, 0)
    - coalesce((v_movements ->> 'expenseNio')::numeric, 0)
    + coalesce((v_movements ->> 'transferInNio')::numeric, 0)
    - coalesce((v_movements ->> 'transferOutNio')::numeric, 0);
  v_expected_usd := v_session.opening_balance_usd
    + coalesce((v_movements ->> 'incomeUsd')::numeric, 0)
    - coalesce((v_movements ->> 'expenseUsd')::numeric, 0)
    + coalesce((v_movements ->> 'transferInUsd')::numeric, 0)
    - coalesce((v_movements ->> 'transferOutUsd')::numeric, 0);

  return jsonb_build_object(
    'id', v_session.id,
    'open', v_session.closed_at is null,
    'openedAt', v_session.opened_at,
    'openedById', v_session.opened_by,
    'openedByName', (select full_name from public.profiles where id = v_session.opened_by),
    'openingNio', v_session.opening_balance_nio,
    'openingUsd', v_session.opening_balance_usd,
    'closedAt', v_session.closed_at,
    'closedById', v_session.closed_by,
    'closedByName', (select full_name from public.profiles where id = v_session.closed_by),
    'countedNio', v_session.closing_balance_nio,
    'countedUsd', v_session.closing_balance_usd,
    'expectedNio', case
      when v_session.closed_at is null then v_expected_nio
      else v_session.expected_balance_nio
    end,
    'expectedUsd', case
      when v_session.closed_at is null then v_expected_usd
      else v_session.expected_balance_usd
    end,
    'differenceNio', v_session.difference_nio,
    'differenceUsd', v_session.difference_usd,
    'notes', v_session.notes,
    'closeNotes', v_session.close_notes,
    'movements', v_movements
  );
end $$;

revoke all on function public.finance_cash_row_json(uuid)
  from public, anon, authenticated;

-- `finance_cash_close` guarda el mismo «debería haber» que muestra la pantalla.
create or replace function public.finance_cash_close(
  p_request uuid,
  p_session uuid,
  p_counted_nio numeric,
  p_counted_usd numeric,
  p_notes text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '5s'
as $$
declare
  v_session public.cash_sessions;
  v_existing uuid;
  v_movements jsonb;
  v_expected_nio numeric;
  v_expected_usd numeric;
  v_difference_nio numeric;
  v_difference_usd numeric;
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null or p_session is null then raise exception 'INVALID_REQUEST'; end if;
  if v_notes is not null and char_length(v_notes) > 500 then
    raise exception 'INVALID_NOTES';
  end if;
  if p_counted_nio is null or p_counted_usd is null
     or p_counted_nio < 0 or p_counted_usd < 0
     or p_counted_nio > 99999999 or p_counted_usd > 99999999
     or p_counted_nio <> round(p_counted_nio, 2)
     or p_counted_usd <> round(p_counted_usd, 2) then
    raise exception 'INVALID_AMOUNT';
  end if;

  select id into v_existing
  from public.cash_sessions
  where close_request_id = p_request;
  if found then return public.finance_cash_row_json(v_existing); end if;

  select * into v_session from public.cash_sessions where id = p_session for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_session.closed_at is not null then raise exception 'CASH_ALREADY_CLOSED'; end if;
  if v_session.opened_by <> auth.uid() and not public.is_admin() then
    raise exception 'CASH_NOT_YOURS';
  end if;

  v_movements := public.finance_cash_movements(v_session.opened_at, now());
  v_expected_nio := v_session.opening_balance_nio
    + coalesce((v_movements ->> 'incomeNio')::numeric, 0)
    - coalesce((v_movements ->> 'expenseNio')::numeric, 0)
    + coalesce((v_movements ->> 'transferInNio')::numeric, 0)
    - coalesce((v_movements ->> 'transferOutNio')::numeric, 0);
  v_expected_usd := v_session.opening_balance_usd
    + coalesce((v_movements ->> 'incomeUsd')::numeric, 0)
    - coalesce((v_movements ->> 'expenseUsd')::numeric, 0)
    + coalesce((v_movements ->> 'transferInUsd')::numeric, 0)
    - coalesce((v_movements ->> 'transferOutUsd')::numeric, 0);

  if abs(v_expected_nio) > 999999999.99 or abs(v_expected_usd) > 999999999.99 then
    raise exception 'INVALID_AMOUNT';
  end if;

  v_difference_nio := round(p_counted_nio - v_expected_nio, 2);
  v_difference_usd := round(p_counted_usd - v_expected_usd, 2);

  if v_notes is null and (v_difference_nio <> 0 or v_difference_usd <> 0) then
    raise exception 'CASH_DIFFERENCE_REASON_REQUIRED';
  end if;

  update public.cash_sessions set
    closed_by = auth.uid(),
    closed_at = now(),
    closing_balance_nio = p_counted_nio,
    closing_balance_usd = p_counted_usd,
    expected_balance_nio = v_expected_nio,
    expected_balance_usd = v_expected_usd,
    difference_nio = v_difference_nio,
    difference_usd = v_difference_usd,
    close_notes = v_notes,
    close_request_id = p_request
  where id = v_session.id;

  return public.finance_cash_row_json(v_session.id);
end $$;

revoke all on function public.finance_cash_close(uuid, uuid, numeric, numeric, text)
  from public, anon;
grant execute on function public.finance_cash_close(uuid, uuid, numeric, numeric, text)
  to authenticated;

-- La regla escrita que la pantalla de arqueo muestra al usuario.
create or replace function public.finance_cash_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_open_id uuid;
  v_history jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;

  select id into v_open_id
  from public.cash_sessions
  where closed_at is null
  order by opened_at desc, id
  limit 1;

  select coalesce(
    jsonb_agg(public.finance_cash_row_json(recent.id) order by recent.closed_at desc),
    '[]'::jsonb
  ) into v_history
  from (
    select id, closed_at
    from public.cash_sessions
    where closed_at is not null
    order by closed_at desc
    limit 20
  ) recent;

  return jsonb_build_object(
    'open', case when v_open_id is null then null
                 else public.finance_cash_row_json(v_open_id) end,
    'history', v_history,
    'cashRule', 'Cuenta de caja (caja_fuerte): apertura + ingresos − egresos ± transferencias con otras cuentas.'
  );
end $$;

revoke all on function public.finance_cash_state() from public, anon;
grant execute on function public.finance_cash_state() to authenticated;


notify pgrst, 'reload schema';

commit;

-- ═══════════════════════════════════════════════════════════
--  00097_venta_particular.sql
-- ═══════════════════════════════════════════════════════════

-- 00097 — Venta particular: vender un producto a quien no está registrado.
--
-- El problema real: `product_sell` exigía un cliente de `gym_clients` y la tabla
-- tenía `stock_sale_client check (kind <> 'venta' or client_id is not null)`.
-- Quien entra sólo a comprar una camiseta o un suplemento porque le dijeron que
-- ahí sale más barato no tiene ficha, y caja no podía cobrarle sin inventarle
-- una cuenta de cliente —o sin negarle la venta—.
--
-- Qué cambia (sólo agrega; no borra movimientos):
--   · `stock_movements.customer_name`: nombre de quien compra sin registro, si
--     caja lo escribe. Es opcional para no frenar la venta en el mostrador.
--   · Se retira la restricción `stock_sale_client`: una venta puede no tener
--     cliente registrado.
--   · `finance_record_movement_before_debts` deja de exigir ficha de cliente
--     para un ingreso (`service_income`): sin eso, la venta particular no podía
--     entrar a la caja ni al arqueo. Un ingreso sin cliente sigue siendo un
--     ingreso normal: mueve la cuenta, se ve en Caja y cuenta en el arqueo; lo
--     único que no hace es anotarse en la ficha de nadie (`client_events`) ni
--     contar para la categoría de un cliente.
--   · `product_sell` acepta `p_customer_name` y devuelve `particular`.
--     El ingreso es el mismo de siempre (`service_income`), en la misma cuenta y
--     con el mismo método: sólo deja de tener ficha de cliente. No se crea un
--     cliente de mentira, no se toca `gym_clients` y la categoría del cliente
--     (`client_category`) no cuenta estas ventas para nadie.
--
-- Reversión: recrear el `product_sell` de la 00042 y volver a agregar
-- `stock_sale_client`. Ojo: esa restricción falla si ya hay ventas particulares
-- guardadas; primero habría que asignarles una ficha. La columna nueva puede
-- quedarse sin uso, así que no hace falta borrarla.

begin;

-- 1. Nombre de quien compra sin ficha (opcional).
alter table public.stock_movements
  add column if not exists customer_name text
  check (customer_name is null or length(btrim(customer_name)) between 2 and 80);

comment on column public.stock_movements.customer_name is
  'Nombre de quien compró sin estar registrado (venta particular). NULL si la venta tiene ficha o si no se preguntó el nombre.';

-- 2. Una venta ya no necesita cliente registrado.
alter table public.stock_movements drop constraint if exists stock_sale_client;

-- 3. Un ingreso ya no exige ficha de cliente.
--
-- Se reemplaza la misma función, con la misma firma y el mismo trabajo: sólo
-- deja de rechazar `service_income` sin cliente y no escribe en `client_events`
-- cuando no hay ficha. Todo lo demás (candado del pedido, validaciones, cuenta,
-- método, comprobante y saldo) queda igual, para no abrir un segundo camino de
-- dinero.
create or replace function public.finance_record_movement_before_debts(
  p_request uuid, p_kind text, p_client uuid, p_amount numeric, p_currency text,
  p_method text, p_account text, p_concept text, p_fx numeric, p_category text default null
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
  -- Cambio de la 00097: un ingreso puede no tener ficha (venta particular).
  if p_kind is null or p_kind not in ('service_income','expense')
    or p_amount is null or p_amount<=0 or p_amount>99999999 or p_amount<>round(p_amount,2)
    or p_currency is null or p_currency not in ('NIO','USD')
    or p_fx is null or p_fx<0.0001 or p_fx>10000 or p_fx<>round(p_fx,4)
    or p_concept is null or length(trim(p_concept)) not between 2 and 200
    or (p_kind='service_income' and p_category is not null)
    or (p_kind='expense' and (p_client is not null or p_category is null)) then raise exception 'INVALID_PAYMENT'; end if;
  if p_kind='service_income' and p_client is not null then
    select full_name,profile_id into v_name,v_profile from public.gym_clients where id=p_client for share;
    if not found then raise exception 'NOT_FOUND'; end if;
  elsif p_kind='expense' then
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
  -- Sólo hay evento del cliente cuando hay ficha.
  if p_kind='service_income' and p_client is not null then
    insert into public.client_events(client_id,action,details,actor_id)
      values(p_client,'payment',jsonb_build_object('transaction_id',v_id,'kind',p_kind),v_actor);
  end if;
  return v_id;
end $$;
revoke all on function public.finance_record_movement_before_debts(uuid,text,uuid,numeric,text,text,text,text,numeric,text)
  from public,anon,authenticated;

-- 4. La función de venta: mismo trabajo, con la venta particular permitida.
drop function if exists public.product_sell(uuid, uuid, integer, uuid, text, text);

create or replace function public.product_sell(
  p_request uuid,
  p_product uuid,
  p_qty integer,
  p_client uuid default null,
  p_method text default null,
  p_account text default null,
  p_customer_name text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare
  v_name text; v_status text; v_price numeric; v_stock integer; v_total numeric; v_tx uuid;
  v_existing public.stock_movements;
  v_customer text;
  v_concept text;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  select * into v_existing from public.stock_movements where request_id = p_request;
  if found then
    return jsonb_build_object(
      'transaction_id', v_existing.transaction_id, 'already', true,
      'stock', public.product_stock_of(p_product),
      'particular', v_existing.client_id is null,
      'customer_name', v_existing.customer_name);
  end if;

  if p_method is null or btrim(p_method) = '' then raise exception 'INVALID_METHOD'; end if;
  if p_account is null or btrim(p_account) = '' then raise exception 'INVALID_ACCOUNT'; end if;
  if p_qty is null or p_qty <= 0 or p_qty > 1000 then raise exception 'INVALID_QTY'; end if;

  -- Con ficha manda la ficha; sin ficha, el nombre escrito (o ninguno).
  v_customer := nullif(btrim(coalesce(p_customer_name, '')), '');
  if v_customer is not null and char_length(v_customer) > 80 then
    raise exception 'INVALID_CUSTOMER';
  end if;
  if p_client is not null then
    v_customer := null;
    if not exists (select 1 from public.gym_clients where id = p_client) then
      raise exception 'INVALID_CLIENT';
    end if;
  end if;

  select name, status, price into v_name, v_status, v_price
    from public.products where id = p_product for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_status <> 'activo' then raise exception 'PRODUCT_INACTIVE'; end if;

  v_stock := public.product_stock_of(p_product);
  if v_stock < p_qty then raise exception 'SIN_STOCK'; end if;
  v_total := round(p_qty * v_price, 2);

  v_concept := case
    when p_client is null and v_customer is not null
      then 'Venta particular (' || v_customer || '): ' || v_name || ' x' || p_qty
    when p_client is null
      then 'Venta particular: ' || v_name || ' x' || p_qty
    else 'Venta: ' || v_name || ' x' || p_qty
  end;
  -- El concepto de una transacción no lleva más de 200 letras (00022).
  v_concept := left(v_concept, 200);

  v_tx := public.finance_record_movement(
    p_request, 'service_income', p_client, v_total, 'NIO', p_method, p_account, v_concept, 1, null);

  insert into public.stock_movements(
    product_id, kind, qty, unit_price, client_id, customer_name, transaction_id, request_id, note, created_by)
  values (
    p_product, 'venta', -p_qty, v_price, p_client, v_customer, v_tx, p_request,
    case when p_client is null then 'Venta particular' else null end, auth.uid());

  return jsonb_build_object(
    'transaction_id', v_tx, 'already', false, 'stock', v_stock - p_qty,
    'total', v_total, 'particular', p_client is null, 'customer_name', v_customer);
end $$;

-- 5. Permisos: sólo sesión iniciada con rol de caja o administración.
revoke all on function public.product_sell(uuid, uuid, integer, uuid, text, text, text)
  from public, anon;
grant execute on function public.product_sell(uuid, uuid, integer, uuid, text, text, text)
  to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00098_limites_de_abuso.sql
-- ═══════════════════════════════════════════════════════════

-- 00098 — Límites de abuso compartidos (SEG-07).
--
-- El problema real: el antispam de los formularios públicos llevaba el conteo
-- **en la memoria de cada instancia** del servidor. Con dos o más instancias
-- (o después de cada despliegue, que arranca procesos nuevos) el contador
-- volvía a cero: bastaba repartir el ataque entre instancias para que el
-- límite nunca se alcanzara. Además, cualquier ruta que escribe quedaba
-- expuesta a que la martillaran, porque el único freno era por IP y en memoria.
--
-- Qué agrega (sólo suma; no toca datos del gimnasio):
--   · `public.rate_limits`: un contador por `(scope, key)`. `key` **no** es una
--     IP ni un correo: es un hash SHA-256 calculado en el servidor, así que la
--     tabla no guarda datos personales.
--   · `public.rate_limit_hit(scope, key, limit, ventana)`: una sola sentencia
--     atómica que cuenta y responde si el pedido pasa. Con dos pedidos al mismo
--     tiempo, uno gana y el otro ve el conteo real (nada de carreras).
--   · RLS activo y **sin políticas**: nadie lee ni escribe la tabla directo;
--     sólo se llega por la función.
--
-- Reversión: `drop function public.rate_limit_hit(text,text,integer,integer);`
-- y `drop table public.rate_limits;`. La app vuelve sola al contador en memoria
-- cuando la función no existe, así que retirarla no tumba nada (los límites
-- pasan a ser por instancia, como antes).

begin;

create table if not exists public.rate_limits (
  scope text not null,
  key text not null,
  window_start timestamptz not null default now(),
  count integer not null default 0,
  primary key (scope, key)
);

comment on table public.rate_limits is
  'Contadores de límite de abuso por (scope, key). La key es un hash: no guarda IPs ni correos.';

comment on column public.rate_limits.window_start is
  'Inicio de la ventana vigente. Al vencer, el conteo vuelve a 1.';

-- Nadie entra directo: sólo por la función.
alter table public.rate_limits enable row level security;
revoke all on table public.rate_limits from anon, authenticated;

create index if not exists rate_limits_window_start_idx
  on public.rate_limits (window_start);

/**
 * Cuenta un pedido y dice si pasa.
 *
 * `p_key` tiene que venir ya hasheada desde el servidor: la función no sabe
 * (ni quiere saber) de quién se trata.
 *
 * Devuelve:
 *   allowed            → si el pedido puede seguir
 *   count              → cuántos van en esta ventana (incluido éste)
 *   limit              → el tope aplicado
 *   remaining          → cuántos quedan
 *   retry_after_seconds→ cuánto falta para que la ventana vuelva a cero
 */
create or replace function public.rate_limit_hit(
  p_scope text,
  p_key text,
  p_limit integer,
  p_window_seconds integer
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set lock_timeout = '3s'
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_window interval;
  v_row public.rate_limits;
begin
  -- Validaciones baratas: nada de ventanas absurdas ni claves gigantes.
  if p_scope is null or btrim(p_scope) = '' or length(p_scope) > 60 then
    raise exception 'rate_limit_hit: scope inválido' using errcode = '22023';
  end if;
  if p_key is null or btrim(p_key) = '' or length(p_key) > 120 then
    raise exception 'rate_limit_hit: key inválida' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100000 then
    raise exception 'rate_limit_hit: límite fuera de rango' using errcode = '22023';
  end if;
  if p_window_seconds is null or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception 'rate_limit_hit: ventana fuera de rango' using errcode = '22023';
  end if;

  v_window := make_interval(secs => p_window_seconds);

  -- Una sola sentencia: cuenta e informa sin ventana de carrera.
  insert into public.rate_limits as rl (scope, key, window_start, count)
  values (p_scope, p_key, v_now, 1)
  on conflict (scope, key) do update
    set count = case when rl.window_start <= v_now - v_window then 1 else rl.count + 1 end,
        window_start = case when rl.window_start <= v_now - v_window then v_now else rl.window_start end
  returning * into v_row;

  -- Limpieza oportunista: 1 de cada 100 llamadas barre lo que ya venció hace
  -- más de un día, para que la tabla no crezca sin fin. No bloquea el pedido.
  if random() < 0.01 then
    delete from public.rate_limits where window_start < v_now - interval '1 day';
  end if;

  return jsonb_build_object(
    'allowed', v_row.count <= p_limit,
    'count', v_row.count,
    'limit', p_limit,
    'remaining', greatest(p_limit - v_row.count, 0),
    'retry_after_seconds',
      greatest(ceil(extract(epoch from (v_row.window_start + v_window - v_now)))::integer, 1)
  );
end;
$$;

comment on function public.rate_limit_hit(text, text, integer, integer) is
  'Cuenta un pedido por (scope, hash) y responde si pasa. Atómica: sirve con varias instancias del servidor.';

-- La app llama con la llave pública del proyecto y la sesión del usuario, así
-- que la función tiene que ser ejecutable por `anon` y `authenticated`. Lo que
-- no puede nadie es leer ni escribir la tabla: sólo esta función escribe.
revoke all on function public.rate_limit_hit(text, text, integer, integer) from public;
grant execute on function public.rate_limit_hit(text, text, integer, integer) to anon, authenticated;

commit;

-- ═══════════════════════════════════════════════════════════
--  00099_embudo_de_ventas.sql
-- ═══════════════════════════════════════════════════════════

-- 00099 · Embudo de ventas online: órdenes, leads y configuración
--
-- Qué resuelve: que la landing VENDA. Hoy un visitante no puede comprar:
-- el cobro es presencial (caja) y el visitante curioso se pierde.
--
-- Flujo (fase A):
--   1. El visitante arma su orden en la web (plan + productos opcionales).
--   2. embudo_crear_orden() calcula el TOTAL EN SERVIDOR con los precios
--      canónicos (nunca confía en el precio que manda el navegador) y
--      devuelve un código público corto.
--   3. El cliente paga por SINPE/transferencia y informa el número de
--      referencia (embudo_informar_pago) → la orden queda «por_verificar».
--   4. El personal confirma con un toque (embudo_confirmar_orden): crea o
--      enlaza el cliente, registra el cobro y la membresía con las MISMAS
--      funciones de la cadena (crm_record_payment_plan → plan_register_segment)
--      y baja el stock de los productos. Nada se inventa acá.
--   5. Si el visitante no compra, queda como LEAD (embudo_guardar_lead,
--      deduplicado por teléfono) con su etapa de seguimiento en el CRM y
--      mensaje de WhatsApp prellenado por etapa.
--
-- Fase B (pasarela de tarjetas): el webhook del procesador llamará a
-- embudo_confirmar_orden desde service_role; por eso la RPC valida y es
-- idempotente, sin depender de quién la llame.
--
-- Reversión: drop de las 4 tablas y sus funciones. No toca tablas previas.

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.plans') is null
     or to_regclass('public.gym_clients') is null
     or to_regclass('public.products') is null
     or to_regclass('public.payment_methods') is null
     -- 00081 le agregó p_cash_received (11 args) con default: cualquiera
     -- de las dos sobrecargas sirve para la llamada de 10 que hacemos acá.
     or (to_regprocedure('public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text)') is null
         and to_regprocedure('public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text,numeric)') is null)
     or to_regprocedure('public.plan_register_segment(uuid,text,numeric,text,uuid,uuid,text)') is null
     or to_regprocedure('public.crm_is_staff()') is null then
    raise exception 'EMBUDO_PREREQUISITE_MISSING';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. Órdenes
-- ------------------------------------------------------------
create table if not exists public.embudo_orders (
  id             uuid primary key default gen_random_uuid(),
  public_id      text not null unique,
  status         text not null default 'pendiente'
                 check (status in ('pendiente','por_verificar','pagada','cancelada')),
  full_name      text not null check (length(trim(full_name)) between 2 and 120),
  phone          text not null check (length(trim(phone)) between 6 and 40),
  email          text check (length(trim(email)) <= 120),
  member_id      uuid references public.profiles(id) on delete set null,
  client_id      uuid references public.gym_clients(id) on delete set null,
  plan_id        text references public.plans(id) on delete set null,
  plan_name      text,
  plan_amount    numeric(12,2) check (plan_amount is null or plan_amount >= 0),
  plan_currency  text,
  items          jsonb not null default '[]'::jsonb,
  total          numeric(12,2) not null check (total >= 0),
  currency       text not null default 'NIO',
  pay_method     text not null default 'pm_sinpe'
                 references public.payment_methods(id) on delete restrict,
  pay_reference  text check (length(pay_reference) <= 120),
  pay_notified_at timestamptz,
  staff_note     text check (length(staff_note) <= 500),
  source         text not null default 'web' check (source in ('web','manual')),
  confirmed_by   uuid references public.profiles(id) on delete set null,
  confirmed_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint embudo_orders_contact_chk
    check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

create index if not exists embudo_orders_pendientes_idx
  on public.embudo_orders (status, created_at desc);
create index if not exists embudo_orders_phone_idx
  on public.embudo_orders (phone);

-- ------------------------------------------------------------
-- 2. Leads (los que todavía no compran)
-- ------------------------------------------------------------
create table if not exists public.embudo_leads (
  id          uuid primary key default gen_random_uuid(),
  full_name   text not null check (length(trim(full_name)) between 2 and 120),
  phone       text not null check (length(trim(phone)) between 6 and 40),
  email       text check (length(trim(email)) <= 120),
  source      text not null default 'landing'
              check (source in ('landing','checkout','manual','whatsapp')),
  interest    text check (length(interest) <= 120),
  stage       text not null default 'nuevo'
              check (stage in ('nuevo','contactado','visito','comprador','perdido')),
  note        text check (length(note) <= 500),
  order_id    uuid references public.embudo_orders(id) on delete set null,
  client_id   uuid references public.gym_clients(id) on delete set null,
  last_touch  timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint embudo_leads_phone_key unique (phone)
);

create index if not exists embudo_leads_stage_idx
  on public.embudo_leads (stage, last_touch desc);

-- ------------------------------------------------------------
-- 3. Configuración del checkout (cuentas para pagar, instrucciones)
-- ------------------------------------------------------------
create table if not exists public.embudo_config (
  key        text primary key,
  value      text not null check (length(value) <= 1000),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.embudo_config (key, value) values
  ('instrucciones',
   'Pagá por SINPE Móvil o transferencia. Enviar al número que te confirma ' ||
   'recepción por WhatsApp. Después de pagar, cargá el número de referencia ' ||
   'acá mismo y te activamos la membresía.')
on conflict (key) do nothing;

-- RLS: nadie lee ni escribe estas tablas por RLS; todo va por RPCs
-- (el patrón del hardening de 00030). El cliente ve SU orden por la RPC
-- de estado, que sólo devuelve columnas inocuas.
alter table public.embudo_orders  enable row level security;
alter table public.embudo_leads   enable row level security;
alter table public.embudo_config  enable row level security;

revoke all on public.embudo_orders from anon, authenticated;
revoke all on public.embudo_leads from anon, authenticated;
revoke all on public.embudo_config from anon, authenticated;

-- El personal consulta directo (panel); escritura sólo por RPCs auditadas.
grant select on public.embudo_orders to authenticated;
grant select on public.embudo_leads to authenticated;
grant select on public.embudo_config to authenticated;

create policy embudo_orders_staff_read on public.embudo_orders
  for select to authenticated using (public.crm_is_staff());
create policy embudo_leads_staff_read on public.embudo_leads
  for select to authenticated using (public.crm_is_staff());
create policy embudo_config_staff_read on public.embudo_config
  for select to authenticated using (public.crm_is_staff());

-- ------------------------------------------------------------
-- 4. RPC públicas (anon): crear orden, informar pago, estado, lead
-- ------------------------------------------------------------
create or replace function public.embudo_crear_orden(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_full_name text;
  v_phone     text;
  v_email     text;
  v_plan_id   text;
  v_pay       text;
  v_plan      public.plans;
  v_terms     jsonb;
  v_items     jsonb;
  v_item      jsonb;
  v_prod      public.products;
  v_qty       integer;
  v_total     numeric(12,2) := 0;
  v_pid       text;
  v_member    uuid;
  v_out       public.embudo_orders;
begin
  if p_payload is null then raise exception 'PAYLOAD_INVALID'; end if;
  v_full_name := nullif(trim(coalesce(p_payload->>'full_name','')),'');
  v_phone     := nullif(regexp_replace(coalesce(p_payload->>'phone',''), '\D', '', 'g'),'');
  v_email     := nullif(trim(coalesce(p_payload->>'email','')),'');
  v_plan_id   := nullif(trim(coalesce(p_payload->>'plan_id','')),'');
  v_pay       := nullif(trim(coalesce(p_payload->>'pay_method','')),'');

  if v_full_name is null or length(v_full_name) < 2 then
    raise exception 'NOMBRE_INVALIDO';
  end if;
  if v_phone is null or length(v_phone) < 6 then
    raise exception 'TELEFONO_INVALIDO';
  end if;

  -- Plan: precio y nombre SIEMPRE desde la base. Sólo planes con precio
  -- NIO publicado (el pase y las membresías de pesas). Boxeo se cobra en
  -- USD por recepción; no entra al checkout online en esta fase.
  if v_plan_id is not null then
    select * into v_plan from public.plans where id = v_plan_id and is_active;
    if not found then raise exception 'PLAN_NO_DISPONIBLE'; end if;
    v_terms := public.plan_validity_terms(v_plan.id);
    if v_terms is null or (v_terms->>'currency') is distinct from 'NIO'
       or (v_terms->>'amount') is null or (v_terms->>'amount')::numeric <= 0 then
      raise exception 'PLAN_NO_DISPONIBLE';
    end if;
    v_total := v_total + (v_terms->>'amount')::numeric;
  end if;

  -- Productos: cantidades y precios desde la base (qty 1..10 por ítem).
  v_items := '[]'::jsonb;
  if jsonb_typeof(coalesce(p_payload->'items','[]'::jsonb)) = 'array' then
    for v_item, v_qty in select it, coalesce((it->>'qty')::integer, 0)
                          from jsonb_array_elements(p_payload->'items') it loop
      if v_qty between 1 and 10 then
        select * into v_prod from public.products
         where id = (v_item->>'product_id')::uuid and status = 'activo';
        if found then
          v_items := v_items || jsonb_build_object(
            'product_id', v_prod.id, 'name', v_prod.name,
            'qty', v_qty, 'unit_price', v_prod.price,
            'total', round(v_prod.price * v_qty, 2));
          v_total := v_total + round(v_prod.price * v_qty, 2);
        end if;
      end if;
    end loop;
  end if;

  if v_plan_id is null and v_items = '[]'::jsonb then
    raise exception 'ORDEN_VACIA';
  end if;

  -- Método de pago: debe existir y estar activo (SINPE/transferencias).
  if v_pay is null or not exists (
    select 1 from public.payment_methods where id = v_pay and is_active) then
    v_pay := 'pm_sinpe';
  end if;

  -- Si el visitante ya tiene cuenta en la app, enlazamos la orden.
  if v_email is not null then
    select p.id into v_member
      from public.profiles p
     where lower(p.email) = lower(v_email)
     limit 1;
  end if;

  insert into public.embudo_orders (
    public_id, full_name, phone, email, member_id,
    plan_id, plan_name, plan_amount, plan_currency,
    items, total, currency, pay_method
  ) values (
    'PB' || upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 8)),
    v_full_name, v_phone, v_email, v_member,
    v_plan_id, v_plan.name_es, coalesce((v_terms->>'amount')::numeric, null),
    coalesce(v_terms->>'currency', null),
    v_items, round(v_total, 2), 'NIO', v_pay
  ) returning * into v_out;

  -- El lead nace con la orden: comprador en potencia, nunca se pierde.
  insert into public.embudo_leads (full_name, phone, email, source, interest, stage, order_id)
  values (v_full_name, v_phone, v_email, 'checkout', v_plan.name_es, 'nuevo', v_out.id)
  on conflict (phone) do update set
    full_name = excluded.full_name,
    email     = coalesce(excluded.email, embudo_leads.email),
    order_id  = excluded.order_id,
    stage     = case when embudo_leads.stage = 'nuevo' then 'nuevo' else embudo_leads.stage end,
    last_touch = now(),
    updated_at = now();

  return jsonb_build_object(
    'public_id', v_out.public_id, 'total', v_out.total,
    'currency', v_out.currency, 'plan_name', v_out.plan_name,
    'items', v_out.items,
    'instrucciones', (select value from public.embudo_config where key = 'instrucciones'));
end $$;

create or replace function public.embudo_informar_pago(
  p_public_id text, p_reference text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_status text;
begin
  p_reference := nullif(trim(coalesce(p_reference,'')),'');
  if p_reference is null or length(p_reference) < 4 then
    raise exception 'REFERENCIA_INVALIDA';
  end if;
  select id, status into v_id, v_status
    from public.embudo_orders where public_id = p_public_id;
  if not found then raise exception 'ORDEN_NO_ENCONTRADA'; end if;
  if v_status not in ('pendiente','por_verificar') then
    raise exception 'ORDEN_NO_PENDIENTE';
  end if;
  update public.embudo_orders
     set status = 'por_verificar', pay_reference = left(p_reference,120),
         pay_notified_at = now(), updated_at = now()
   where id = v_id;
  return jsonb_build_object('public_id', p_public_id, 'status', 'por_verificar');
end $$;

create or replace function public.embudo_estado_orden(p_public_id text)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o public.embudo_orders;
begin
  select * into o from public.embudo_orders where public_id = p_public_id;
  if not found then raise exception 'ORDEN_NO_ENCONTRADA'; end if;
  return jsonb_build_object(
    'public_id', o.public_id, 'status', o.status,
    'plan_name', o.plan_name, 'total', o.total, 'currency', o.currency,
    'items', o.items, 'pay_method', o.pay_method,
    'informada', o.pay_notified_at is not null,
    'created_at', o.created_at);
end $$;

create or replace function public.embudo_guardar_lead(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_full_name text; v_phone text; v_email text; v_interest text;
begin
  v_full_name := nullif(trim(coalesce(p_payload->>'full_name','')),'');
  v_phone := nullif(regexp_replace(coalesce(p_payload->>'phone',''), '\D', '', 'g'),'');
  v_email := nullif(trim(coalesce(p_payload->>'email','')),'');
  v_interest := nullif(trim(coalesce(p_payload->>'interest','')),'');
  if v_full_name is null or v_phone is null then
    raise exception 'LEAD_INVALIDO';
  end if;
  insert into public.embudo_leads (full_name, phone, email, source, interest)
  values (v_full_name, v_phone, v_email, coalesce(p_payload->>'source','landing'), v_interest)
  on conflict (phone) do update set
    full_name  = excluded.full_name,
    email      = coalesce(excluded.email, embudo_leads.email),
    interest   = coalesce(excluded.interest, embudo_leads.interest),
    stage      = case when embudo_leads.stage = 'perdido' then 'nuevo' else embudo_leads.stage end,
    last_touch = now(), updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- ------------------------------------------------------------
-- 5. RPC del personal (authenticated staff): confirmar y avanzar
-- ------------------------------------------------------------
create or replace function public.embudo_confirmar_orden(p_order_id uuid, p_cuenta text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  o public.embudo_orders;
  v_uid uuid := auth.uid();
  v_client uuid;
  v_tx uuid;
  v_producto jsonb;
  v_idx integer;
  v_cuenta text;
  v_request uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into o from public.embudo_orders
   where id = p_order_id for update;
  if not found then raise exception 'ORDEN_NO_ENCONTRADA'; end if;
  if o.status = 'pagada' then
    -- Idempotente: devolver el estado actual sin duplicar nada.
    return jsonb_build_object('id', o.id, 'status', 'pagada', 'client_id', o.client_id);
  end if;
  if o.status <> 'por_verificar' and o.status <> 'pendiente' then
    raise exception 'ORDEN_NO_CONFIRMABLE';
  end if;

  -- Cliente: enlazar por teléfono; si no existe, crearlo.
  select c.id into v_client from public.gym_clients c
   where c.phone = o.phone or (o.email is not null and lower(c.email) = lower(o.email))
   order by c.client_number limit 1;
  if v_client is null then
    insert into public.gym_clients (full_name, phone, email, profile_id)
    values (o.full_name, o.phone, o.email, o.member_id)
    returning id into v_client;
  elsif o.member_id is not null then
    update public.gym_clients set profile_id = coalesce(profile_id, o.member_id)
     where id = v_client and profile_id is null;
  end if;

  v_cuenta := coalesce(nullif(trim(p_cuenta),''), 'cta_caja_nio');

  -- 1) La membresía por el cauce canónico del modelo split: el cobro con
  --    finance_record_movement (el mismo escritor de la caja) y la
  --    membresía con plan_register_segment, tal como hace
  --    crm_record_payment_plan. El request de la orden hace de idempotencia.
  if o.plan_id is not null then
    v_tx := public.finance_record_movement(
      o.id, 'service_income', v_client, o.plan_amount, o.plan_currency,
      o.pay_method, v_cuenta, 'Venta online ' || o.public_id, 1);
    perform public.plan_register_segment(
      v_client, o.plan_id, o.plan_amount, o.plan_currency, o.id, v_tx, 'crm');
  end if;

  -- 2) Los productos: cobro con request DERIVADO por línea (md5 del id de
  --    orden + posición) para que la idempotencia sea por ítem, y salida
  --    de stock como en la ficha CRM.
  for v_idx, v_producto in
    select t.ord, t.val from jsonb_array_elements(o.items) with ordinality as t(val, ord)
  loop
    v_request := substr(md5(o.id::text || ':item:' || v_idx::text), 1, 32)::uuid;
    perform public.finance_record_movement(
      v_request, 'service_income', v_client, (v_producto->>'total')::numeric, 'NIO',
      o.pay_method, v_cuenta,
      'Venta online ' || o.public_id || ' · ' || (v_producto->>'name'), 1);
    insert into public.stock_movements (product_id, kind, qty, unit_price, client_id)
    values ((v_producto->>'product_id')::uuid, 'venta', -((v_producto->>'qty')::integer),
            (v_producto->>'unit_price')::numeric, v_client);
  end loop;

  update public.embudo_orders
     set status = 'pagada', client_id = v_client,
         confirmed_by = v_uid, confirmed_at = now(), updated_at = now()
   where id = o.id;

  -- El lead que compró se cierra solo.
  update public.embudo_leads
     set stage = 'comprador', client_id = v_client, order_id = o.id,
         last_touch = now(), updated_at = now()
   where phone = o.phone and stage <> 'comprador';

  return jsonb_build_object('id', o.id, 'status', 'pagada', 'client_id', v_client);
end $$;

create or replace function public.embudo_avanzar_lead(p_lead_id uuid, p_stage text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_stage not in ('nuevo','contactado','visito','comprador','perdido') then
    raise exception 'ETAPA_INVALIDA';
  end if;
  update public.embudo_leads
     set stage = p_stage,
         note  = coalesce(nullif(trim(coalesce(p_note,'')),''), note),
         last_touch = now(), updated_at = now()
   where id = p_lead_id;
  if not found then raise exception 'LEAD_NO_ENCONTRADO'; end if;
  return jsonb_build_object('id', p_lead_id, 'stage', p_stage);
end $$;

create or replace function public.embudo_config_set(p_key text, p_value text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_key is null or length(p_key) > 60 or p_value is null or length(p_value) > 1000 then
    raise exception 'CONFIG_INVALIDA';
  end if;
  insert into public.embudo_config (key, value, updated_by, updated_at)
  values (p_key, p_value, auth.uid(), now())
  on conflict (key) do update set value = excluded.value,
    updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('key', p_key);
end $$;

revoke all on function public.embudo_crear_orden(jsonb) from public, authenticated;
revoke all on function public.embudo_informar_pago(text,text,text) from public, authenticated;
revoke all on function public.embudo_estado_orden(text) from public, authenticated;
revoke all on function public.embudo_guardar_lead(jsonb) from public, authenticated;
revoke all on function public.embudo_confirmar_orden(uuid,text) from public, anon;
revoke all on function public.embudo_avanzar_lead(uuid,text,text) from public, anon;
revoke all on function public.embudo_config_set(text,text) from public, anon;

grant execute on function public.embudo_crear_orden(jsonb) to anon, authenticated;
grant execute on function public.embudo_informar_pago(text,text,text) to anon, authenticated;
grant execute on function public.embudo_estado_orden(text) to anon, authenticated;
grant execute on function public.embudo_guardar_lead(jsonb) to anon, authenticated;
grant execute on function public.embudo_confirmar_orden(uuid,text) to authenticated;
grant execute on function public.embudo_avanzar_lead(uuid,text,text) to authenticated;
grant execute on function public.embudo_config_set(text,text) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00100_superadministrador.sql
-- ═══════════════════════════════════════════════════════════

-- 00100 · Súper administrador: la cuenta del dueño del aplicativo
--
-- Qué resuelve: el desarrollador (dueño del aplicativo) necesita una cuenta
-- que siga siendo dueño AUNQUE el gimnasio tenga su propio administrador.
-- Hoy el admin puede (vía admin_set_role) subir/bajar a cualquier otro
-- administrador: nada protegía al dueño del sistema.
--
-- Reglas que quedan (aditivas, no cambian nada para admin/caja/entrenador):
--   1. El rol 'superadmin' ES administrador en todos los helpers de la
--      cadena (is_admin, crm_is_staff) y además no se otorga ni se quita
--      desde la app: sólo la consola de la base lo asigna o lo retira.
--   2. La cuenta superadmin no se degrada, no se da de baja, no se borra
--      y no se le cambia el rol desde el aplicativo (ni por otro admin,
--      ni por otro superadmin).
--   3. Superadmin puede todo lo que hace un administrador (mismo panel,
--      mismas funciones). La diferencia es que SU cuenta es intocable.
--
-- Asignación del primer superadmin (consola, sin sesión de usuario):
--   update public.profiles set role = 'superadmin' where id = <uuid>;
--
-- Reversión: los superadmin deben volver a 'admin' por consola y luego
--   drop de triggers/funciones nuevas; las funciones re-definidas acá
--   quedan con su versión anterior re-aplicando 00033/00034/00036/00049/00067.

begin;
set local lock_timeout = '5s';

-- ------------------------------------------------------------
-- 1. El nuevo valor del enum.
-- PG 12+ lo permite dentro de una transacción mientras el valor no se
-- USE en esa misma transacción: acá sólo se compara como TEXTO.
-- ------------------------------------------------------------
alter type public.user_role add value if not exists 'superadmin';

-- ------------------------------------------------------------
-- 2. Helpers de la cadena: superadmin es admin y es staff.
-- (idénticos a 00033/00034, con el rol sumado)
-- ------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(select 1 from public.profiles where id = auth.uid() and role::text in ('admin', 'superadmin'));
$$;

create or replace function public.crm_is_staff()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(select 1 from public.profiles where id = auth.uid() and role::text in ('admin', 'cashier', 'superadmin'));
$$;

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ------------------------------------------------------------
-- 3. admin_set_role: el superadmin no se otorga ni se quita desde la app.
-- (idéntico a 00036, con las dos guardias nuevas)
-- ------------------------------------------------------------
create or replace function public.admin_set_role(p_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public, pg_temp set lock_timeout = '5s' as $$
declare v_old text; v_admins integer;
begin
  if not public.is_admin() then raise exception 'AUTH'; end if;
  -- El rol del dueño del aplicativo no se otorga desde el panel.
  if p_role = 'superadmin' then raise exception 'SUPERADMIN_PROTECTED'; end if;
  if p_role not in ('member', 'cashier', 'trainer', 'admin') then raise exception 'INVALID_ROLE'; end if;
  if p_id is null or p_id = auth.uid() then raise exception 'SELF_ROLE_CHANGE'; end if;
  select role::text into v_old from public.profiles where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old = p_role then return; end if;
  -- ...ni se le cambia el rol a quien ya lo tiene.
  if v_old = 'superadmin' then raise exception 'SUPERADMIN_PROTECTED'; end if;
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

-- ------------------------------------------------------------
-- 4. staff_set_status: la cuenta del superadmin no se da de baja.
-- (idéntico a 00049, con la guardia nueva)
-- ------------------------------------------------------------
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
  -- La cuenta del dueño del aplicativo no se da de baja desde el panel.
  if v_role = 'superadmin' then raise exception 'SUPERADMIN_PROTECTED'; end if;

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

revoke all on function public.staff_set_status(uuid, boolean, text) from public, anon;
grant execute on function public.staff_set_status(uuid, boolean, text) to authenticated;

-- ------------------------------------------------------------
-- 5. crm_update_client: el superadmin también puede cambiar categoría.
-- (idéntico a 00067; sólo cambia cómo se lee el rol del llamador)
-- ------------------------------------------------------------
create or replace function public.crm_update_client(p_id uuid, p_name text, p_phone text, p_email text, p_category text, p_status text, p_plan text, p_notes text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  old_row public.gym_clients;
  v_admin boolean;
  v_today date := public.plan_local_today();
  v_shift integer := 0;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into old_row from public.gym_clients where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select role::text in ('admin', 'superadmin') into v_admin from public.profiles where id = auth.uid();
  if p_category <> old_row.category and not coalesce(v_admin, false) then raise exception 'ADMIN_ONLY'; end if;
  if p_email is not null and trim(p_email) <> '' and p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'INVALID_EMAIL'; end if;

  if p_status = 'frozen' and old_row.status <> 'frozen' then
    update public.gym_clients set full_name = trim(p_name), phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), ''),
      category = p_category, status = p_status, plan_id = nullif(p_plan, ''), notes = coalesce(p_notes, ''),
      frozen_since = v_today, updated_at = now() where id = p_id;
  elsif old_row.status = 'frozen' and p_status = 'active' then
    if old_row.frozen_since is not null then
      v_shift := v_today - old_row.frozen_since;
    end if;
    if v_shift > 0 then
      update public.payment_plans
         set started_on = started_on + v_shift, expires_on = expires_on + v_shift
       where client_id = p_id and expires_on >= old_row.frozen_since;
    end if;
    update public.gym_clients set full_name = trim(p_name), phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), ''),
      category = p_category, status = p_status, plan_id = nullif(p_plan, ''), notes = coalesce(p_notes, ''),
      frozen_since = null, updated_at = now() where id = p_id;
  else
    update public.gym_clients set full_name = trim(p_name), phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), ''),
      category = p_category, status = p_status, plan_id = nullif(p_plan, ''), notes = coalesce(p_notes, ''),
      updated_at = now() where id = p_id;
  end if;

  insert into public.client_events(client_id, action, details, actor_id) values(p_id, 'updated',
    jsonb_build_object('category_before', old_row.category, 'category_after', p_category,
      'status_before', old_row.status, 'status_after', p_status,
      'frozen_days_shifted', v_shift), auth.uid());
end $$;

revoke all on function public.crm_update_client(uuid,text,text,text,text,text,text,text) from public, anon;
grant execute on function public.crm_update_client(uuid,text,text,text,text,text,text,text) to authenticated;

-- ------------------------------------------------------------
-- 6. El guardián del perfil: cambiar un rol hacia/desde superadmin exige
--    consola (sin sesión); el resto exige admin o superadmin.
-- (extiende 00020 sin cambiar la regla para los demás roles)
-- ------------------------------------------------------------
create or replace function public.crm_protect_profile_role()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null then
    -- El rol del dueño del aplicativo es intocable desde la app.
    if old.role::text = 'superadmin' or new.role::text = 'superadmin' then
      raise exception 'SUPERADMIN_PROTECTED';
    end if;
    if not exists(select 1 from public.profiles where id=auth.uid() and role::text in ('admin','superadmin')) then
      raise exception 'ADMIN_ONLY';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.crm_protect_profile_role() from public;
drop trigger if exists crm_protect_profile_role on public.profiles;
create trigger crm_protect_profile_role before update of role on public.profiles for each row execute function public.crm_protect_profile_role();

-- ------------------------------------------------------------
-- 7. Nadie crea ni borra un superadmin desde la app. La baja de la cuenta
--    también queda cubierta (auth.users → profiles en cascada pasa por acá
--    sólo si se hace con sesión; por consola sigue siendo posible).
-- ------------------------------------------------------------
create or replace function public.superadmin_guard_insert()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.role::text = 'superadmin' and auth.uid() is not null then
    raise exception 'SUPERADMIN_PROTECTED';
  end if;
  return new;
end $$;

create or replace function public.superadmin_guard_delete()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.role::text = 'superadmin' and auth.uid() is not null then
    raise exception 'SUPERADMIN_PROTECTED';
  end if;
  return old;
end $$;

revoke all on function public.superadmin_guard_insert(), public.superadmin_guard_delete() from public, anon, authenticated;

drop trigger if exists crm_superadmin_ins on public.profiles;
create trigger crm_superadmin_ins before insert on public.profiles for each row execute function public.superadmin_guard_insert();
drop trigger if exists crm_superadmin_del on public.profiles;
create trigger crm_superadmin_del before delete on public.profiles for each row execute function public.superadmin_guard_delete();

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00101_tienda_publica.sql
-- ═══════════════════════════════════════════════════════════

-- 00101 · Tienda pública: catálogo visible para visitantes (sin sesión)
--
-- Qué resuelve: la tienda de la landing debe mostrar productos con precio
-- a CUALQUIER visitante (sin cuenta), pero la tabla products guarda datos
-- internos (costo, ganancia, stock mínimo) que no se publican. El
-- hardening anterior revocó la lectura directa a anon — bien para la
-- tabla completa, mal para vender. Esta RPC es la puerta estrecha:
-- sólo columnas públicas de productos ACTIVOS.
--
-- El carrito/orden sigue validando TODO en el servidor
-- (embudo_crear_orden re-lee precio y estado de cada producto), así que
-- esta lectura no agrega superficie de riesgo.
--
-- Reversión: drop function public.tienda_productos();

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.products') is null then
    raise exception 'TIENDA_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.tienda_productos()
returns table (id uuid, name text, category text, price numeric, image_data text)
language sql
stable
security definer
set search_path = public, pg_temp as $$
  select p.id, p.name, p.category, p.price, p.image_data
    from public.products p
   where p.status = 'activo'
   order by p.category, p.name;
$$;

revoke all on function public.tienda_productos() from public, authenticated;
grant execute on function public.tienda_productos() to anon, authenticated;

notify pgrst, 'reload schema';
commit;

-- ============================================================
--  FIN DE LA INSTALACIÓN
-- ============================================================
--  Si el editor marca un error, no te asustes: cada bloque trae su
--  propio begin/commit y se puede volver a correr. Los errores
--  típicos son «ya existe», y son inofensivos.
