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
  fee_pct       numeric not null default 0,
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
    monthly_salary numeric default 0,
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
