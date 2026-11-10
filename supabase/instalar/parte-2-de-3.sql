-- ============================================================
--  PARTE 2 DE 3 — NO CORRER FUERA DE ORDEN
-- ============================================================
--  Es el mismo contenido de supabase/INSTALAR-BASE.sql, cortado
--  en 3 para que el SQL Editor del celular no se trabe.
--  Correr la 1, esperar el «Success», después la 2 y después la 3.
--  Guía paso a paso: docs/INSTALAR-DESDE-EL-CELULAR.md
--  Generado por scripts/build-install-sql.mjs — no editar a mano.
-- ============================================================

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

-- ============================================================
--  FIN DE LA PARTE 2
-- ============================================================
