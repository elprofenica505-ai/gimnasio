-- PENDIENTE DE AUTORIZACIÓN. NO APLICAR sin orden expresa del dueño/usuario.
-- Objetivo: que el personal (admin/staff) sólo lea datos protegidos con MFA verificado (AAL2).
-- Cambia sólo crm_is_staff(): las políticas RLS y RPC existentes ya la usan.
-- No crea tablas, no borra datos, no cambia roles ni planes ni saldos.
-- Efecto esperado: personal sin MFA ve sólo lo permitido a clientes (su propia información).
-- Rollback: ver bloque al final.
begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regprocedure('public.crm_is_staff()') is null
     or to_regprocedure('auth.jwt()') is null then
    raise exception 'MFA_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.crm_is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists(
       select 1 from public.profiles
       where id = auth.uid() and role in ('admin', 'staff')
     );
$$;

revoke all on function public.crm_is_staff() from public, anon;
grant execute on function public.crm_is_staff() to authenticated;

notify pgrst, 'reload schema';
commit;

-- ROLLBACK (sólo si hay que volver atrás; pegar en lugar del bloque anterior):
-- begin;
-- create or replace function public.crm_is_staff()
-- returns boolean language sql stable security definer set search_path = public, pg_temp
-- as $$ select exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff')); $$;
-- revoke all on function public.crm_is_staff() from public;
-- grant execute on function public.crm_is_staff() to authenticated;
-- notify pgrst, 'reload schema';
-- commit;
