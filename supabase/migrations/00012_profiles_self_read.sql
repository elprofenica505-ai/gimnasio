-- ============================================================
-- Permitir la lectura del perfil propio con RLS.
-- ============================================================
-- Ejecutar en el SQL Editor del proyecto que usa el sitio.
-- Caso observado: profiles.role = admin como dueño, pero el usuario
-- authenticated no ve su propia fila aunque is_staff() = true.
--
-- Sólo agrega SELECT de la fila propia para authenticated. No cambia
-- roles, datos, grants, funciones ni políticas ajenas, y no desactiva RLS.
-- No permite leer perfiles ajenos ni escribir en profiles.
-- Es idempotente y puede aplicarse sin merge ni redeploy del frontend.
-- Si hay políticas AS RESTRICTIVE que bloquean SELECT, éstas siguen
-- vigentes: revisar pg_policies, no borrarlas ni desactivar RLS a ciegas.

begin;

drop policy if exists profiles_select_own_authenticated on public.profiles;
create policy profiles_select_own_authenticated
  on public.profiles
  as permissive
  for select
  to authenticated
  using (id = (select auth.uid()));

commit;
