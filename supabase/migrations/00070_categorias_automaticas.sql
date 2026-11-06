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
