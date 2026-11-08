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
