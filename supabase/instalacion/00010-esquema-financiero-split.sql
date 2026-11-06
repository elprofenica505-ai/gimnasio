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
--    · Sin centinela record_payment: en una base nueva esa función
--      no existe; 00023 sólo la bloquea si ya existía y ningún
--      módulo de la cadena la llama.
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
  color          text not null default '#999999',
  budget_monthly numeric(12,2),
  display_order  integer not null default 0
);


-- ------------------------------------------------------------
--  3. Sesiones de caja [DIAGNÓSTICO]
-- ------------------------------------------------------------
--  La usan 00033/00037/00038/00087/00088 (apertura, cierre y arqueo).
create table if not exists public.cash_sessions (
  id                    uuid primary key default gen_random_uuid(),
  opened_by             uuid not null references public.profiles(id),
  opened_at             timestamptz not null default now(),
  closed_by             uuid references public.profiles(id),
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

drop policy if exists "Staff can write cash_sessions" on public.cash_sessions;
create policy "Staff can write cash_sessions" on public.cash_sessions
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

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
-- 10. Columnas de coaches nacidas por fuera del repo [CÓDIGO+PRUEBAS]
-- ------------------------------------------------------------
--  00050 y 00051 crean vistas sobre coaches.full_name y
--  coaches.specialty, pero ninguna migración numerada crea esas dos
--  columnas: en la base real nacieron por fuera del repo. El shim
--  `coachShim` de scripts/helpers/sql-test-db.mjs tapa el mismo hueco
--  en las suites. En una instalación nueva la tabla está vacía, así
--  que el update no toca nada; queda por si este bloque se reaplica.
alter table public.coaches add column if not exists full_name text;
alter table public.coaches add column if not exists specialty text;
update public.coaches
   set full_name = coalesce(full_name, name),
       specialty = coalesce(specialty, role_es);
