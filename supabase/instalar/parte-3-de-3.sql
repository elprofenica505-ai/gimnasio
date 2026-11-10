-- ============================================================
--  PARTE 3 DE 3 — NO CORRER FUERA DE ORDEN
-- ============================================================
--  Es el mismo contenido de supabase/INSTALAR-BASE.sql, cortado
--  en 3 para que el SQL Editor del celular no se trabe.
--  Correr la 1, esperar el «Success», después la 2 y después la 3.
--  Guía paso a paso: docs/INSTALAR-DESDE-EL-CELULAR.md
--  Generado por scripts/build-install-sql.mjs — no editar a mano.
-- ============================================================

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

-- ═══════════════════════════════════════════════════════════
--  00102_embudo_metodo_pago_resiliente.sql
-- ═══════════════════════════════════════════════════════════

-- 00102 · Embudo: método de pago por defecto resiliente
--
-- Incidente real (producción, demo 8-nov): la base tenía el catálogo de
-- métodos de pago con ids propios (sinpe_movil, transfer_bac_nio, …) y SIN
-- la fila 'pm_sinpe' que la semilla del instalador crea. El default duro
-- 'pm_sinpe' de 00099 disparaba la FK embudo_orders_pay_method_fkey y TODA
-- orden web fallaba con un ERROR genérico en pantalla.
--
-- Qué cambia acá: si el método enviado no existe (o no llega), la RPC
-- elige el mejor método ACTIVO disponible (prefiere cualquier variante
-- SINPE, luego display_order) y sólo falla con SIN_METODO_PAGO cuando el
-- gimnasio no tiene ninguno. El resto de la función queda idéntico a 00099.
--
-- Reversión: recrear public.embudo_crear_orden(jsonb) con el bloque del
-- método de pago tal como está en 00099 (v_pay := 'pm_sinpe';).

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.payment_methods') is null
     or to_regprocedure('public.embudo_crear_orden(jsonb)') is null then
    raise exception 'EMBUDO_00102_PREREQUISITE_MISSING';
  end if;
end $$;

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
  -- 00102: sin id válido NO se asume 'pm_sinpe' a ciegas (una base puede
  -- tener el catálogo con otros ids y entonces TODA orden web moría con la
  -- FK embudo_orders_pay_method_fkey). Ahora se elige el mejor método
  -- activo disponible — prefiere cualquier variante SINPE y luego el orden
  -- de despliegue — y sólo falla (SIN_METODO_PAGO) si no hay ninguno.
  if v_pay is null or not exists (
    select 1 from public.payment_methods where id = v_pay and is_active) then
    select id into v_pay
      from public.payment_methods
     where is_active
     order by (id like '%sinpe%') desc,
              coalesce(display_order, 999),
              id
     limit 1;
  end if;
  if v_pay is null then
    raise exception 'SIN_METODO_PAGO';
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

revoke all on function public.embudo_crear_orden(jsonb) from public, authenticated;
grant execute on function public.embudo_crear_orden(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00103_embudo_cuenta_resiliente_y_rechazo.sql
-- ═══════════════════════════════════════════════════════════

-- 00103 · Embudo: cuenta de cobro resiliente + rechazo de órdenes
--
-- Incidente real (producción, demo 9-nov): la base tenía las cuentas con
-- ids propios (caja_fuerte_nio, banco_bac_nio, …) y SIN la fila
-- 'cta_caja_nio' que siembra el instalador. El default duro del confirm
-- disparaba INVALID_ACCOUNT y el personal NO podía confirmar ningún pago
-- web (mismo patrón del incidente de pm_sinpe que arregló 00102).
--
-- Qué cambia acá:
--   1. embudo_confirmar_orden: sin cuenta explícita, elige la mejor caja
--      NIO activa (caja fuerte primero, luego display_order) y sólo falla
--      con SIN_CUENTA_NIO si no hay ninguna. Con cuenta explícita se
--      mantiene la validación estricta de siempre.
--   2. embudo_cancelar_orden (NUEVA): el personal rechaza una orden
--      pendiente o por_verificar; queda 'cancelada' con nota, idempotente,
--      sin tocar finanzas ni stock (en esos estados no se movió nada).
--
-- Reversión: recrear ambas funciones tal como están en 00099 y drop de
-- embudo_cancelar_orden(uuid,text).

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.bank_accounts') is null
     or to_regclass('public.embudo_orders') is null
     or to_regprocedure('public.embudo_confirmar_orden(uuid,text)') is null then
    raise exception 'EMBUDO_00103_PREREQUISITE_MISSING';
  end if;
end $$;

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

  -- 00103: sin cuenta explícita NO se asume 'cta_caja_nio' a ciegas (una
  -- base puede tener el catálogo con otros ids y TODO cobro online moría
  -- con INVALID_ACCOUNT). Se elige la mejor caja NIO activa — prefiere
  -- caja fuerte, luego display_order — y sólo falla (SIN_CUENTA_NIO) si
  -- el gimnasio no tiene ninguna cuenta activa en córdobas.
  v_cuenta := nullif(trim(coalesce(p_cuenta, '')), '');
  if v_cuenta is null then
    select id into v_cuenta
      from public.bank_accounts
     where is_active and currency = 'NIO'
     order by (account_type = 'caja_fuerte') desc, coalesce(display_order, 999), id
     limit 1;
    if v_cuenta is null then raise exception 'SIN_CUENTA_NIO'; end if;
  end if;

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


-- ------------------------------------------------------------
-- 00103 · Rechazo de órdenes (nuevo): el personal puede cerrar una
-- orden pendiente o por_verificar sin cobrar ni activar nada. No toca
-- stock ni finanzas: en esos estados todavía no se movió nada.
-- ------------------------------------------------------------
create or replace function public.embudo_cancelar_orden(p_order_id uuid, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  o public.embudo_orders;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_nota is not null and length(trim(p_nota)) = 0 then p_nota := null; end if;
  select * into o from public.embudo_orders
   where id = p_order_id for update;
  if not found then raise exception 'ORDEN_NO_ENCONTRADA'; end if;
  if o.status = 'cancelada' then
    -- Idempotente: rechazar dos veces no es error.
    return jsonb_build_object('id', o.id, 'status', 'cancelada', 'ya_estaba', true);
  end if;
  if o.status = 'pagada' then raise exception 'ORDEN_YA_PAGADA'; end if;
  update public.embudo_orders
     set status = 'cancelada',
         staff_note = left(coalesce(p_nota, o.staff_note), 500),
         updated_at = now()
   where id = o.id;
  return jsonb_build_object('id', o.id, 'status', 'cancelada', 'ya_estaba', false);
end $$;

revoke all on function public.embudo_confirmar_orden(uuid,text) from public, anon;
revoke all on function public.embudo_cancelar_orden(uuid,text) from public, anon;
grant execute on function public.embudo_confirmar_orden(uuid,text) to authenticated;
grant execute on function public.embudo_cancelar_orden(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ═══════════════════════════════════════════════════════════
--  00104_arm_asistente_interno.sql
-- ═══════════════════════════════════════════════════════════

-- 00104 · ARM: asistente relacional multicanal — canal interno (fase 2)
--
-- El «empleado virtual 24/7» del paso 2. Un cerebro que responde leyendo la
-- base (planes, clases, tienda) y captura interesados como leads, con canales
-- enchufables que se encienden y apagan con un interruptor:
--
--   · 'interno'  → ACTIVO desde acá. Burbuja de chat en la web pública
--                  (visitantes anónimos) y «Mensajes» en Mi cuenta (socios).
--                  Cuesta $0 y no depende de Meta.
--   · 'whatsapp' → APAGADO. Se activa tras la firma, cuando el gimnasio tenga
--                  su Meta Business verificada (candado natural).
--   · 'correo'   → APAGADO. Reservado para una fase futura.
--
-- Nada de este módulo envía mensajes hacia afuera: sólo conversa con quien
-- escribe primero y deja el recado en la bandeja del panel (Asistente).
--
-- Escritura SÓLO por RPC security definer (nadie inserta en las tablas
-- directo, ni el personal: responde por arm_responder_staff). Lectura por
-- RLS: el personal ve todo; un socio ve únicamente su hilo; el visitante
-- anónimo sólo por RPC con su token (uuid inadivinable).
--
-- Reversión:
--   drop function public.arm_hilo_visitante(uuid,text);
--   drop function public.arm_enviar_visitante(uuid,text);
--   drop function public.arm_responder_asistente(uuid,text);
--   drop function public.arm_historial(uuid,integer);
--   drop function public.arm_marcar_leida_visitante(uuid);
--   drop function public.arm_vincular_contacto(uuid,text,text,text);
--   drop function public.arm_responder_staff(uuid,text);
--   drop function public.arm_anotar_contacto(uuid,text,text);
--   drop table public.arm_messages; drop table public.arm_threads;
--   drop table public.arm_channels;
--   alter table public.embudo_leads drop constraint embudo_leads_source_check;
--   alter table public.embudo_leads add constraint embudo_leads_source_check
--     check (source in ('landing','checkout','manual','whatsapp'));

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.embudo_leads') is null
     or to_regclass('public.gym_clients') is null
     or to_regprocedure('public.embudo_guardar_lead(jsonb)') is null
     or to_regprocedure('public.crm_is_staff()') is null then
    raise exception 'ARM_00104_PREREQUISITE_MISSING';
  end if;
end $$;

-- El asistente es una fuente nueva de leads del embudo: ensanchamos el CHECK
-- (idempotente; si ya trae 'asistente' no se toca).
do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'embudo_leads_source_check'
       and pg_get_constraintdef(oid) like '%asistente%'
  ) then
    alter table public.embudo_leads drop constraint if exists embudo_leads_source_check;
    alter table public.embudo_leads add constraint embudo_leads_source_check
      check (source in ('landing','checkout','manual','whatsapp','asistente'));
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. Interruptores de canal
-- ------------------------------------------------------------
create table if not exists public.arm_channels (
  channel    text primary key check (channel in ('interno','whatsapp','correo')),
  enabled    boolean not null default false,
  note       text not null default '',
  updated_at timestamptz not null default now()
);

insert into public.arm_channels (channel, enabled, note) values
  ('interno',  true,  'Burbuja de chat en la web y mensajes de socios. $0, sin Meta.'),
  ('whatsapp', false, 'Se activa tras la firma, con la Meta Business del gimnasio.'),
  ('correo',   false, 'Canal reservado para una fase futura.')
on conflict (channel) do nothing;

-- ------------------------------------------------------------
-- 2. Hilos de conversación
-- ------------------------------------------------------------
create table if not exists public.arm_threads (
  id              uuid primary key default gen_random_uuid(),
  channel         text not null default 'interno' references public.arm_channels(channel),
  locale          text not null default 'es' check (locale in ('es','en')),
  status          text not null default 'abierta' check (status in ('abierta','cerrada')),
  -- Un hilo es de UN participante: visitante anónimo (token) o socio (user).
  visitor_token   uuid,
  user_id         uuid,
  full_name       text,
  phone           text,
  email           text,
  lead_id         uuid references public.embudo_leads(id) on delete set null,
  client_id       uuid references public.gym_clients(id) on delete set null,
  staff_unread    integer not null default 0,
  visitor_unread  integer not null default 0,
  last_message    text,
  last_message_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint arm_threads_participante
    check (visitor_token is not null or user_id is not null)
);

create index if not exists arm_threads_bandeja_idx
  on public.arm_threads (status, last_message_at desc nulls last);
create index if not exists arm_threads_token_idx
  on public.arm_threads (visitor_token) where visitor_token is not null;
create index if not exists arm_threads_user_idx
  on public.arm_threads (user_id) where user_id is not null;

-- ------------------------------------------------------------
-- 3. Mensajes
-- ------------------------------------------------------------
create table if not exists public.arm_messages (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references public.arm_threads(id) on delete cascade,
  role       text not null check (role in ('visitante','asistente','staff')),
  text       text not null,
  created_at timestamptz not null default now()
);

create index if not exists arm_messages_hilo_idx
  on public.arm_messages (thread_id, created_at);

-- ------------------------------------------------------------
-- 4. RLS: lectura controlada; la escritura vive en los RPC
-- ------------------------------------------------------------
alter table public.arm_channels enable row level security;
alter table public.arm_threads  enable row level security;
alter table public.arm_messages enable row level security;

drop policy if exists arm_channels_leer on public.arm_channels;
create policy arm_channels_leer on public.arm_channels
  for select using (true);

drop policy if exists arm_channels_personal on public.arm_channels;
create policy arm_channels_personal on public.arm_channels
  for update to authenticated
  using (public.crm_is_staff()) with check (public.crm_is_staff());

drop policy if exists arm_threads_personal_leer on public.arm_threads;
create policy arm_threads_personal_leer on public.arm_threads
  for select to authenticated
  using (public.crm_is_staff() or user_id = auth.uid());

drop policy if exists arm_threads_personal_editar on public.arm_threads;
create policy arm_threads_personal_editar on public.arm_threads
  for update to authenticated
  using (public.crm_is_staff()) with check (public.crm_is_staff());

drop policy if exists arm_messages_personal_leer on public.arm_messages;
create policy arm_messages_personal_leer on public.arm_messages
  for select to authenticated
  using (
    public.crm_is_staff()
    or exists (
      select 1 from public.arm_threads t
       where t.id = arm_messages.thread_id and t.user_id = auth.uid()
    )
  );

-- Grants explícitos: en PGlite no hay defaults de Supabase, en producción
-- son los mismos que ya aplican. La RLS es la puerta de verdad.
grant select on public.arm_channels to anon, authenticated;
grant update on public.arm_channels to authenticated;
grant select, update on public.arm_threads to authenticated;
grant select on public.arm_messages to authenticated;

-- ------------------------------------------------------------
-- 5. RPC del visitante (anon + socio). El único camino de escritura.
-- ------------------------------------------------------------
-- Abre (o reutiliza) el hilo de un visitante/socio. Si hay sesión activa,
-- el hilo queda amarrado al socio y además adopta el hilo anónimo que
-- hubiera abierto antes de entrar a su cuenta.
create or replace function public.arm_hilo_visitante(p_token uuid, p_locale text default 'es')
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid   uuid := auth.uid();
  v_id    uuid;
  v_locale text := case when p_locale in ('es','en') then p_locale else 'es' end;
begin
  if p_token is null then raise exception 'TOKEN_INVALIDO'; end if;
  if not exists (select 1 from public.arm_channels where channel = 'interno' and enabled) then
    raise exception 'CANAL_APAGADO';
  end if;

  if v_uid is not null then
    update public.arm_threads
       set user_id = v_uid, updated_at = now()
     where visitor_token = p_token
       and user_id is null
       and not exists (select 1 from public.arm_threads t2 where t2.user_id = v_uid);

    select id into v_id
      from public.arm_threads
     where user_id = v_uid
     order by created_at
     limit 1;
    if v_id is null then
      insert into public.arm_threads (channel, locale, visitor_token, user_id)
      values ('interno', v_locale, p_token, v_uid)
      returning id into v_id;
    end if;
    return v_id;
  end if;

  select id into v_id
    from public.arm_threads
   where visitor_token = p_token and user_id is null
   order by created_at
   limit 1;
  if v_id is null then
    insert into public.arm_threads (channel, locale, visitor_token)
    values ('interno', v_locale, p_token)
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- El visitante/socio escribe. Devuelve el id del mensaje insertado.
create or replace function public.arm_enviar_visitante(p_token uuid, p_text text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_thread uuid;
  v_msg    uuid;
  v_texto  text := trim(coalesce(p_text, ''));
begin
  if v_texto = '' or char_length(v_texto) > 1000 then
    raise exception 'MENSAJE_INVALIDO';
  end if;
  select public.arm_hilo_visitante(p_token) into v_thread;

  -- Si el personal cerró el hilo, un mensaje nuevo lo reabre: es más amable
  -- que dejar a la persona sin poder contestar.
  insert into public.arm_messages (thread_id, role, text)
  values (v_thread, 'visitante', v_texto)
  returning id into v_msg;

  update public.arm_threads
     set last_message = left(v_texto, 160),
         last_message_at = now(),
         staff_unread = staff_unread + 1,
         status = 'abierta',
         updated_at = now()
   where id = v_thread;

  return v_msg;
end $$;

-- El cerebro deja su respuesta en el hilo (sólo hilos de visitante anónimo:
-- al socio el que le contesta es el personal, no el bot).
create or replace function public.arm_responder_asistente(p_token uuid, p_text text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_thread public.arm_threads;
  v_texto  text := trim(coalesce(p_text, ''));
begin
  if v_texto = '' or char_length(v_texto) > 1000 then
    raise exception 'MENSAJE_INVALIDO';
  end if;
  if not exists (select 1 from public.arm_channels where channel = 'interno' and enabled) then
    raise exception 'CANAL_APAGADO';
  end if;
  select * into v_thread
    from public.arm_threads
   where visitor_token = p_token
   order by created_at
   limit 1;
  if not found then raise exception 'HILO_NO_ENCONTRADO'; end if;
  if v_thread.user_id is not null then return; end if; -- socio: sin bot

  insert into public.arm_messages (thread_id, role, text)
  values (v_thread.id, 'asistente', left(v_texto, 1000));

  update public.arm_threads
     set last_message = left(v_texto, 160),
         last_message_at = now(),
         visitor_unread = visitor_unread + 1,
         updated_at = now()
   where id = v_thread.id;
end $$;

-- Historial del hilo del visitante (sólo con su token): contacto conocido
-- (para que el cerebro retome una captura a medias) + últimos mensajes.
-- Sin hilo → null.
create or replace function public.arm_historial(p_token uuid, p_limite integer default 200)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'contacto', jsonb_build_object(
      'full_name', t.full_name,
      'phone',     t.phone,
      'email',     t.email,
      'socio',     t.user_id is not null,
      'status',    t.status
    ),
    'mensajes', coalesce((
      select jsonb_agg(row_to_json(x) order by x.created_at)
      from (
        select m.role, m.text, m.created_at
          from public.arm_messages m
         where m.thread_id = t.id
         order by m.created_at desc
         limit greatest(least(coalesce(p_limite, 200), 500), 1)
      ) x
    ), '[]'::jsonb)
  )
  from public.arm_threads t
  where t.visitor_token = p_token
  order by t.created_at
  limit 1;
$$;

-- Captura a medias: el cerebro consiguió el nombre pero falta el teléfono,
-- o al revés. Guarda lo que hay SIN crear lead todavía; el lead nace cuando
-- estén los dos (arm_vincular_contacto).
create or replace function public.arm_anotar_contacto(
  p_token uuid, p_full_name text, p_phone text
)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_nombre text := nullif(trim(coalesce(p_full_name, '')), '');
  v_phone  text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
begin
  if v_nombre is null and v_phone is null then return; end if;
  if v_phone is not null and char_length(v_phone) < 6 then v_phone := null; end if;
  if v_nombre is null and v_phone is null then return; end if;
  update public.arm_threads
     set full_name = coalesce(v_nombre, full_name),
         phone = coalesce(v_phone, phone),
         updated_at = now()
   where visitor_token = p_token and user_id is null;
end $$;

-- El visitante abrió el chat: limpiar su contador de «sin leer».
create or replace function public.arm_marcar_leida_visitante(p_token uuid)
returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.arm_threads
     set visitor_unread = 0, updated_at = now()
   where visitor_token = p_token
      or (auth.uid() is not null and user_id = auth.uid());
$$;

-- Captura de interesado: el cerebro pidió nombre y teléfono, el visitante
-- los dio. Visitante anónimo → lead (mismo cauce del embudo, source
-- 'asistente'). Socio → se enlaza su ficha de cliente si el teléfono
-- coincide con alguna.
create or replace function public.arm_vincular_contacto(
  p_token uuid, p_full_name text, p_phone text, p_email text default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_thread public.arm_threads;
  v_phone  text;
  v_nombre text;
  v_email  text;
  v_lead   uuid;
  v_client uuid;
begin
  select * into v_thread
    from public.arm_threads
   where visitor_token = p_token or user_id = auth.uid()
   order by created_at
   limit 1;
  if not found then raise exception 'HILO_NO_ENCONTRADO'; end if;

  v_nombre := nullif(trim(coalesce(p_full_name, '')), '');
  v_phone  := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_email  := nullif(trim(coalesce(p_email, '')), '');
  if v_nombre is null or char_length(v_phone) < 6 then
    raise exception 'CONTACTO_INVALIDO';
  end if;

  update public.arm_threads
     set full_name = v_nombre, phone = v_phone, email = v_email, updated_at = now()
   where id = v_thread.id;

  if v_thread.user_id is null then
    perform public.embudo_guardar_lead(jsonb_build_object(
      'full_name', v_nombre,
      'phone',     v_phone,
      'email',     v_email,
      'source',    'asistente',
      'interest',  'Asistente web'
    ));
    select id into v_lead
      from public.embudo_leads
     where phone = v_phone
     order by created_at
     limit 1;
    update public.arm_threads
       set lead_id = coalesce(v_lead, lead_id)
     where id = v_thread.id;
  else
    select id into v_client
      from public.gym_clients
     where phone = v_phone
     order by client_number
     limit 1;
    update public.arm_threads
       set client_id = coalesce(v_client, client_id)
     where id = v_thread.id;
  end if;

  return jsonb_build_object('ok', true, 'lead_id', v_lead, 'client_id', v_client);
end $$;

-- ------------------------------------------------------------
-- 6. RPC del personal: responder desde la bandeja del panel
-- ------------------------------------------------------------
create or replace function public.arm_responder_staff(p_thread_id uuid, p_text text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_texto text := trim(coalesce(p_text, ''));
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if v_texto = '' or char_length(v_texto) > 1000 then
    raise exception 'MENSAJE_INVALIDO';
  end if;
  if not exists (select 1 from public.arm_threads where id = p_thread_id) then
    raise exception 'HILO_NO_ENCONTRADO';
  end if;

  insert into public.arm_messages (thread_id, role, text)
  values (p_thread_id, 'staff', v_texto);

  update public.arm_threads
     set last_message = left(v_texto, 160),
         last_message_at = now(),
         visitor_unread = visitor_unread + 1,
         staff_unread = 0,
         updated_at = now()
   where id = p_thread_id;
end $$;

-- ------------------------------------------------------------
-- 7. Grants de funciones (patrón del embudo: nada público por defecto)
-- ------------------------------------------------------------
revoke all on function public.arm_hilo_visitante(uuid,text) from public, authenticated;
revoke all on function public.arm_enviar_visitante(uuid,text) from public, authenticated;
revoke all on function public.arm_responder_asistente(uuid,text) from public, authenticated;
revoke all on function public.arm_historial(uuid,integer) from public, authenticated;
revoke all on function public.arm_marcar_leida_visitante(uuid) from public, authenticated;
revoke all on function public.arm_vincular_contacto(uuid,text,text,text) from public, authenticated;
revoke all on function public.arm_responder_staff(uuid,text) from public, anon;
revoke all on function public.arm_anotar_contacto(uuid,text,text) from public, authenticated;

grant execute on function public.arm_hilo_visitante(uuid,text) to anon, authenticated;
grant execute on function public.arm_enviar_visitante(uuid,text) to anon, authenticated;
grant execute on function public.arm_responder_asistente(uuid,text) to anon, authenticated;
grant execute on function public.arm_historial(uuid,integer) to anon, authenticated;
grant execute on function public.arm_marcar_leida_visitante(uuid) to anon, authenticated;
grant execute on function public.arm_vincular_contacto(uuid,text,text,text) to anon, authenticated;
grant execute on function public.arm_anotar_contacto(uuid,text,text) to anon, authenticated;
grant execute on function public.arm_responder_staff(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ============================================================
--  FIN DE LA INSTALACIÓN
-- ============================================================
--  Si el editor marca un error, no te asustes: cada bloque trae su
--  propio begin/commit y se puede volver a correr. Los errores
--  típicos son «ya existe», y son inofensivos.

-- ============================================================
--  FIN DE LA PARTE 3
-- ============================================================
