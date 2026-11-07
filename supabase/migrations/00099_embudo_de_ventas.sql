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
    'items', v_out.items);
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
