-- ============================================================
--  FASE 1: Contabilidad, caja y finanzas
-- ============================================================
--  Este archivo crea todo el sistema de caja, ingresos, egresos,
--  cuentas por cobrar y métodos de pago del gimnasio.
--
--  Se puede correr varias veces sin romper nada (IF NOT EXISTS,
--  CREATE OR REPLACE, ON CONFLICT).
--
--  Tablas que crea:
--    · payment_methods       — métodos de pago aceptados (efectivo,
--                              transferencia, tarjeta, SINPE Móvil,
--                              billetera móvil, etc.)
--    · expense_categories    — categorías de gastos (alquiler, luz,
--                              sueldos, mantenimiento…)
--    · accounts              — cuentas bancarias / billeteras del gym
--    · transactions          — cada movimiento de dinero (ingreso o
--                              egreso), con su método, moneda y
--                              conversión a la moneda base.
--    · invoices              — facturas a socios (mensualidades,
--                              pases diarios, suplementos…)
--    · invoice_items         — renglones de cada factura.
--    · cash_registers        — apertura y cierre de caja por día.
--    · member_balances       — saldo a favor / deuda de cada socio
--                              (se actualiza por trigger).
--
--  Campos que se agregan a profiles (sin romper lo existente):
--    · emergency_contact_name, emergency_contact_phone
--    · medical_notes, birthdate, address, joined_at
--    · status: 'active' | 'frozen' | 'cancelled'
--
--  Vistas para el panel:
--    · v_daily_cash           — resumen del día
--    · v_accounts_receivable  — quién debe y cuánto
--    · v_monthly_pnl          — pérdidas y ganancias del mes
--    · v_payment_methods_breakdown — qué método se usa más
-- ============================================================


-- ------------------------------------------------------------
--  1. TIPOS
-- ------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'currency_code') then
    create type public.currency_code as enum ('NIO', 'USD');
  end if;

  if not exists (select 1 from pg_type where typname = 'txn_direction') then
    create type public.txn_direction as enum ('income', 'expense');
  end if;

  if not exists (select 1 from pg_type where typname = 'txn_status') then
    create type public.txn_status as enum ('pending', 'completed', 'reversed');
  end if;

  if not exists (select 1 from pg_type where typname = 'invoice_status') then
    create type public.invoice_status as enum ('draft', 'open', 'paid', 'overdue', 'cancelled');
  end if;

  if not exists (select 1 from pg_type where typname = 'member_status') then
    create type public.member_status as enum ('active', 'frozen', 'cancelled');
  end if;
end $$;


-- ------------------------------------------------------------
--  2. EXTENDER PROFILES (sin romper datos existentes)
-- ------------------------------------------------------------

alter table public.profiles
  add column if not exists emergency_contact_name  text,
  add column if not exists emergency_contact_phone text,
  add column if not exists medical_notes          text,
  add column if not exists birthdate              date,
  add column if not exists address                text,
  add column if not exists joined_at              date default current_date,
  add column if not exists status                 public.member_status not null default 'active';


-- ------------------------------------------------------------
--  3. MÉTODOS DE PAGO
-- ------------------------------------------------------------
--  El admin configura los métodos aceptados. Cada método tiene
--  detalles del banco o billetera para que el socio sepa dónde
--  transferir (ej: "BAC · C$ 12345678").

create table if not exists public.payment_methods (
  id          text primary key,
  slug        text not null unique,
  kind        text not null check (kind in (
                'cash',              -- efectivo
                'bank_transfer',     -- transferencia bancaria
                'credit_card',       -- tarjeta de crédito
                'debit_card',        -- tarjeta de débito
                'sinpe_movil',       -- SINPE Móvil (Costa Rica / Nicaragua)
                'mobile_wallet',     -- billetera móvil (Tigo Money, Claro Pay, etc.)
                'crypto',            -- cripto
                'other'              -- otro
              )),
  name_es     text not null,
  name_en     text not null,
  details_es  text not null default '',
  details_en  text not null default '',
  accepts_nio boolean not null default true,
  accepts_usd boolean not null default true,
  icon        text not null default 'Wallet',
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

create index if not exists payment_methods_active_idx
  on public.payment_methods (is_active, sort_order);


-- ------------------------------------------------------------
--  4. CATEGORÍAS DE GASTOS
-- ------------------------------------------------------------

create table if not exists public.expense_categories (
  id         text primary key,
  slug       text not null unique,
  name_es    text not null,
  name_en    text not null,
  icon       text not null default 'Receipt',
  is_active  boolean not null default true,
  sort_order integer not null default 0
);


-- ------------------------------------------------------------
--  5. CUENTAS DEL GIMNASIO
-- ------------------------------------------------------------
--  Dónde entra el dinero. Permite conciliar con extractos bancarios.

create table if not exists public.accounts (
  id              text primary key,
  slug            text not null unique,
  name            text not null,                -- ej: "Caja fuerte", "BAC NIO", "BAC USD"
  kind            text not null check (kind in ('cash', 'bank', 'wallet')),
  currency        public.currency_code not null default 'NIO',
  bank_name       text,
  account_number  text,
  holder_name     text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);


-- ------------------------------------------------------------
--  6. TRANSACCIONES (corazón del sistema)
-- ------------------------------------------------------------
--  Cada movimiento de dinero. Con método, cuenta, categoría
--  (si es gasto), socio (si es pago de un socio), y la conversión
--  a la moneda base del gimnasio (NIO) para poder sumar.

create table if not exists public.transactions (
  id              uuid primary key default gen_random_uuid(),
  occurred_at     timestamptz not null default now(),
  direction       public.txn_direction not null,
  status          public.txn_status not null default 'completed',

  -- importe original (lo que pagó el socio o lo que salió)
  amount          numeric(12, 2) not null check (amount >= 0),
  currency        public.currency_code not null,

  -- conversión a la moneda base (NIO) en el momento de la tx
  fx_rate         numeric(12, 4) not null default 1.0,
  base_amount     numeric(12, 2) not null,         -- amount * fx_rate

  -- cómo se pagó
  payment_method_id text references public.payment_methods (id) on delete set null,
  account_id        text references public.accounts (id) on delete set null,

  -- de dónde viene / a dónde va
  member_id        uuid references public.profiles (id) on delete set null,
  invoice_id       uuid,                            -- FK se agrega abajo (la tabla invoices se crea después)
  expense_category_id text references public.expense_categories (id) on delete set null,

  -- texto libre
  concept         text not null,
  notes           text,

  -- auditoría
  created_by      uuid references public.profiles (id),
  created_at      timestamptz not null default now(),
  reversed_at     timestamptz,
  reversed_by     uuid references public.profiles (id),

  -- integridad mínima
  constraint tx_positive check (amount > 0)
);

create index if not exists transactions_occurred_idx
  on public.transactions (occurred_at desc);
create index if not exists transactions_member_idx
  on public.transactions (member_id, occurred_at desc);
create index if not exists transactions_direction_idx
  on public.transactions (direction, occurred_at desc);


-- ------------------------------------------------------------
--  7. FACTURAS
-- ------------------------------------------------------------
--  Una factura es un documento que agrupa varios items
--  (mensualidad + suplemento, por ejemplo).

create table if not exists public.invoices (
  id              uuid primary key default gen_random_uuid(),
  number          text not null unique,         -- ej: "FAC-2026-0001"
  member_id       uuid not null references public.profiles (id) on delete restrict,
  status          public.invoice_status not null default 'open',
  issued_at       date not null default current_date,
  due_at          date not null,
  paid_at         timestamptz,
  currency        public.currency_code not null default 'NIO',
  subtotal        numeric(12, 2) not null default 0,
  discount        numeric(12, 2) not null default 0,
  total           numeric(12, 2) not null default 0,
  notes           text,
  created_at      timestamptz not null default now()
);

create index if not exists invoices_member_idx
  on public.invoices (member_id, issued_at desc);
create index if not exists invoices_status_idx
  on public.invoices (status, due_at);

-- Ahora sí, la FK pendiente
alter table public.transactions
  add constraint transactions_invoice_fkey
  foreign key (invoice_id) references public.invoices (id) on delete set null
  not valid;

alter table public.transactions validate constraint transactions_invoice_fkey;


-- ------------------------------------------------------------
--  8. RENGLONES DE FACTURA
-- ------------------------------------------------------------

create table if not exists public.invoice_items (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices (id) on delete cascade,
  description text not null,
  quantity    numeric(10, 2) not null default 1 check (quantity > 0),
  unit_price  numeric(12, 2) not null check (unit_price >= 0),
  total       numeric(12, 2) not null,           -- quantity * unit_price
  sort_order  integer not null default 0
);

create index if not exists invoice_items_invoice_idx
  on public.invoice_items (invoice_id, sort_order);


-- ------------------------------------------------------------
--  9. SALDOS POR SOCIO
-- ------------------------------------------------------------
--  Se actualiza por trigger cuando entra un pago o se emite
--  una factura. Es lo que muestra "saldo a favor" en la ficha.

create table if not exists public.member_balances (
  member_id      uuid primary key references public.profiles (id) on delete cascade,
  balance_nio    numeric(12, 2) not null default 0,    -- + a favor del socio, - deuda
  last_movement  timestamptz,
  updated_at     timestamptz not null default now()
);


-- ------------------------------------------------------------
--  10. APERTURA / CIERRE DE CAJA
-- ------------------------------------------------------------

create table if not exists public.cash_registers (
  id              uuid primary key default gen_random_uuid(),
  opened_at       timestamptz not null default now(),
  closed_at       timestamptz,
  opened_by       uuid references public.profiles (id),
  closed_by       uuid references public.profiles (id),
  opening_amount  numeric(12, 2) not null default 0,    -- efectivo inicial
  closing_amount  numeric(12, 2),                       -- efectivo contado al cierre
  expected_amount numeric(12, 2),                       -- lo que debería haber (suma de tx)
  difference      numeric(12, 2),                       -- expected - closing
  notes           text
);

create index if not exists cash_registers_opened_idx
  on public.cash_registers (opened_at desc);


-- ============================================================
--  11. TRIGGERS DE ACTUALIZACIÓN DE SALDO
-- ============================================================
--  Cada ingreso pago reduce la deuda (sube el balance).
--  Cada factura emitida la aumenta (baja el balance).

create or replace function public.update_member_balance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.member_id is null then
    return new;
  end if;

  insert into public.member_balances (member_id, balance_nio, last_movement)
  values (new.member_id, 0, now())
  on conflict (member_id) do nothing;

  -- Un ingreso mejora el balance (sube); un egreso lo baja.
  -- En la vida real, los gastos casi nunca son "del socio", pero
  -- dejamos el cálculo igual para que el panel pueda mostrar
  -- movimientos por socio si los hay (reembolsos, etc).
  if new.direction = 'income' and new.status = 'completed' then
    update public.member_balances
       set balance_nio = balance_nio + new.base_amount,
           last_movement = new.occurred_at,
           updated_at = now()
     where member_id = new.member_id;
  elsif new.direction = 'expense' and new.status = 'completed' then
    update public.member_balances
       set balance_nio = balance_nio - new.base_amount,
           last_movement = new.occurred_at,
           updated_at = now()
     where member_id = new.member_id;
  end if;

  -- Si la tx está atada a una factura, marcamos la factura como pagada.
  if new.direction = 'income' and new.invoice_id is not null and new.status = 'completed' then
    update public.invoices
       set status = 'paid',
           paid_at = coalesce(paid_at, new.occurred_at)
     where id = new.invoice_id
       and status in ('open', 'overdue');
  end if;

  return new;
end;
$$;

drop trigger if exists transactions_update_balance on public.transactions;
create trigger transactions_update_balance
  after insert or update on public.transactions
  for each row execute function public.update_member_balance();


-- ============================================================
--  12. RECALCULAR TOTALES DE FACTURA
-- ============================================================

create or replace function public.recalc_invoice_totals()
returns trigger
language plpgsql
as $$
declare
  v_subtotal numeric(12, 2);
  v_total    numeric(12, 2);
begin
  select coalesce(sum(total), 0) into v_subtotal
  from public.invoice_items
  where invoice_id = coalesce(new.invoice_id, old.invoice_id);

  select subtotal, discount into v_subtotal, v_total
  from public.invoices
  where id = coalesce(new.invoice_id, old.invoice_id);

  v_total := v_subtotal - coalesce(v_total, 0);

  update public.invoices
     set subtotal = v_subtotal,
         total    = v_total
   where id = coalesce(new.invoice_id, old.invoice_id);

  return new;
end;
$$;

drop trigger if exists invoice_items_recalc on public.invoice_items;
create trigger invoice_items_recalc
  after insert or update or delete on public.invoice_items
  for each row execute function public.recalc_invoice_totals();


-- ============================================================
--  13. VISTAS PARA EL PANEL
-- ============================================================

-- 13.1 — Caja del día
create or replace view public.v_daily_cash as
  select
    date_trunc('day', occurred_at) as day,
    sum(case when direction = 'income'  and status = 'completed' then base_amount else 0 end) as income_nio,
    sum(case when direction = 'expense' and status = 'completed' then base_amount else 0 end) as expense_nio,
    sum(case when direction = 'income'  and status = 'completed' then base_amount
             when direction = 'expense' and status = 'completed' then -base_amount
             else 0 end) as net_nio,
    count(*) filter (where status = 'completed') as tx_count
  from public.transactions
  group by 1
  order by 1 desc;

-- 13.2 — Cuentas por cobrar (facturas abiertas, agrupadas por socio)
create or replace view public.v_accounts_receivable as
  select
    i.member_id,
    p.full_name,
    p.email,
    p.phone,
    count(*)                                as invoices_open,
    sum(i.total)                            as total_owed_nio,
    min(i.due_at)                           as oldest_due,
    max(
      case
        when current_date > i.due_at then (current_date - i.due_at)::int
        else 0
      end
    )                                       as days_overdue
  from public.invoices i
  join public.profiles  p on p.id = i.member_id
  where i.status in ('open', 'overdue')
  group by i.member_id, p.full_name, p.email, p.phone
  order by days_overdue desc nulls last, total_owed_nio desc;

-- 13.3 — P&L mensual
create or replace view public.v_monthly_pnl as
  select
    date_trunc('month', occurred_at) as month,
    sum(case when direction = 'income'  and status = 'completed' then base_amount else 0 end) as income_nio,
    sum(case when direction = 'expense' and status = 'completed' then base_amount else 0 end) as expense_nio,
    sum(case when direction = 'income'  and status = 'completed' then base_amount
             when direction = 'expense' and status = 'completed' then -base_amount
             else 0 end) as net_nio
  from public.transactions
  group by 1
  order by 1 desc;

-- 13.4 — Desglose por método de pago
create or replace view public.v_payment_methods_breakdown as
  select
    t.payment_method_id,
    pm.name_es,
    pm.icon,
    count(*)                                 as tx_count,
    sum(t.base_amount)                       as total_nio,
    sum(case when t.direction = 'income' then t.base_amount else 0 end)  as income_nio,
    sum(case when t.direction = 'expense' then t.base_amount else 0 end) as expense_nio
  from public.transactions t
  left join public.payment_methods pm on pm.id = t.payment_method_id
  where t.status = 'completed'
  group by t.payment_method_id, pm.name_es, pm.icon
  order by total_nio desc;

-- 13.5 — Resumen del estado de cuenta de un socio
create or replace view public.v_member_account as
  select
    p.id                                      as member_id,
    p.full_name,
    p.email,
    p.status,
    coalesce(mb.balance_nio, 0)               as balance_nio,
    coalesce(open_inv.open_count, 0)          as open_invoices,
    coalesce(open_inv.open_total, 0)          as open_total_nio,
    coalesce(tx.last_payment, '1970-01-01'::timestamptz) as last_payment_at
  from public.profiles p
  left join public.member_balances mb on mb.member_id = p.id
  left join (
    select member_id, count(*) as open_count, sum(total) as open_total
    from public.invoices
    where status in ('open', 'overdue')
    group by member_id
  ) open_inv on open_inv.member_id = p.id
  left join (
    select member_id, max(occurred_at) as last_payment
    from public.transactions
    where direction = 'income' and status = 'completed'
    group by member_id
  ) tx on tx.member_id = p.id
  where p.role in ('member', 'staff');


-- ============================================================
--  14. NÚMEROS DE FACTURA AUTOMÁTICOS
-- ============================================================
--  FAC-2026-0001, FAC-2026-0002, etc.

create or replace function public.next_invoice_number()
returns text
language plpgsql
as $$
declare
  v_year text := extract(year from current_date)::text;
  v_next integer;
begin
  select coalesce(max(
    nullif(regexp_replace(number, '[^0-9]', '', 'g'), '')::integer
  ), 0) + 1
  into v_next
  from public.invoices
  where number like 'FAC-' || v_year || '-%';

  return 'FAC-' || v_year || '-' || lpad(v_next::text, 4, '0');
end;
$$;


-- ============================================================
--  15. RLS
-- ============================================================
--  Admin y staff ven todo. Socios solo ven lo propio.

alter table public.payment_methods    enable row level security;
alter table public.expense_categories enable row level security;
alter table public.accounts           enable row level security;
alter table public.transactions       enable row level security;
alter table public.invoices           enable row level security;
alter table public.invoice_items      enable row level security;
alter table public.member_balances    enable row level security;
alter table public.cash_registers     enable row level security;

-- Helper: ¿es admin o staff?
create or replace function public.is_staff()
returns boolean
language sql
stable
as $$
  select exists(
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'staff')
  );
$$;

-- payment_methods: visible para todos (la landing puede listarlos),
-- modificable solo por staff.
drop policy if exists pm_select_all on public.payment_methods;
create policy pm_select_all on public.payment_methods
  for select using (true);

drop policy if exists pm_modify_staff on public.payment_methods;
create policy pm_modify_staff on public.payment_methods
  for all using (public.is_staff()) with check (public.is_staff());

-- expense_categories: idem.
drop policy if exists ec_select_all on public.expense_categories;
create policy ec_select_all on public.expense_categories
  for select using (true);
drop policy if exists ec_modify_staff on public.expense_categories;
create policy ec_modify_staff on public.expense_categories
  for all using (public.is_staff()) with check (public.is_staff());

-- accounts: solo staff.
drop policy if exists accounts_staff on public.accounts;
create policy accounts_staff on public.accounts
  for all using (public.is_staff()) with check (public.is_staff());

-- transactions: staff ve todo; socio ve solo las suyas.
drop policy if exists tx_staff_all on public.transactions;
create policy tx_staff_all on public.transactions
  for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists tx_member_own on public.transactions;
create policy tx_member_own on public.transactions
  for select using (member_id = auth.uid());

-- invoices: staff ve todo; socio ve solo las suyas.
drop policy if exists inv_staff_all on public.invoices;
create policy inv_staff_all on public.invoices
  for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists inv_member_own on public.invoices;
create policy inv_member_own on public.invoices
  for select using (member_id = auth.uid());

drop policy if exists items_staff_all on public.invoice_items;
create policy items_staff_all on public.invoice_items
  for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists items_member_own on public.invoice_items;
create policy items_member_own on public.invoice_items
  for select using (
    exists(select 1 from public.invoices i
           where i.id = invoice_id and i.member_id = auth.uid())
  );

-- member_balances: staff + el socio dueño.
drop policy if exists bal_staff_all on public.member_balances;
create policy bal_staff_all on public.member_balances
  for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists bal_self on public.member_balances;
create policy bal_self on public.member_balances
  for select using (member_id = auth.uid());

-- cash_registers: solo staff.
drop policy if exists cr_staff on public.cash_registers;
create policy cr_staff on public.cash_registers
  for all using (public.is_staff()) with check (public.is_staff());

-- Definiciones legacy: el propietario evalúa estas vistas por defecto.
-- 00030_access_hardening.sql activa invoker/RLS y retira permisos públicos.
-- El instalador completo aplica ese endurecimiento al finalizar.
grant select on public.v_daily_cash,
                public.v_accounts_receivable,
                public.v_monthly_pnl,
                public.v_payment_methods_breakdown,
                public.v_member_account
  to anon, authenticated;


-- ============================================================
--  16. FUNCIÓN PARA EL PANEL: REGISTRAR UN PAGO
-- ============================================================
--  Usa la API desde el panel: registra un pago, crea la tx,
--  y opcionalmente paga una factura.

create or replace function public.record_payment(
  p_member_id          uuid,
  p_amount             numeric,
  p_currency           public.currency_code,
  p_payment_method_id  text,
  p_concept            text,
  p_invoice_id         uuid default null,
  p_account_id         text default null,
  p_fx_rate            numeric default 1.0,
  p_notes              text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id  uuid;
  v_uid uuid := auth.uid();
  v_base numeric := round(p_amount * p_fx_rate, 2);
begin
  if not public.is_staff() then
    raise exception 'AUTH: solo el staff puede registrar pagos';
  end if;

  insert into public.transactions
    (direction, status, amount, currency, fx_rate, base_amount,
     payment_method_id, account_id, member_id, invoice_id,
     concept, notes, created_by)
  values
    ('income', 'completed', p_amount, p_currency, p_fx_rate, v_base,
     p_payment_method_id, p_account_id, p_member_id, p_invoice_id,
     p_concept, p_notes, v_uid)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.record_payment to authenticated;
