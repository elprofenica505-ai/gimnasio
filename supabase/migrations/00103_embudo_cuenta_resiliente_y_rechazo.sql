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
