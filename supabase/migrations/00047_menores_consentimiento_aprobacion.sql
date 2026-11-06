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
