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
