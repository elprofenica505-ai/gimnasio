-- ============================================================
--  00003 · Datos del gimnasio — SEMILLA VACIADA
-- ============================================================
--  Esta migración reemplazaba los datos de ejemplo por los datos
--  reales del gimnasio anterior (tarifas, disciplinas, grilla de
--  boxeo y limpiezas). En este repositorio queda VACIADA: sólo se
--  conservan las partes ESTRUCTURALES, que sirven para cualquier
--  gimnasio:
--
--    1. El precio de un plan puede quedar sin publicar (nullable).
--    2. El color por defecto de disciplinas y entrenadores.
--    3. generate_week_sessions() con la GRILLA VACÍA: no crea nada
--       hasta que el gimnasio cargue sus horarios en el panel.
--
--  Los pasos de datos (limpiar la grilla vieja, borrar entrenadores
--  de ejemplo, reemplazar disciplinas y planes, borrar mensajes y
--  generar 4 semanas) están ANULADOS: un gimnasio nuevo carga lo
--  suyo desde el panel y nada de eso se hereda por SQL.
--
--  SE PUEDE CORRER VARIAS VECES
--  ----------------------------
--  Es idempotente y ya no inserta ni borra datos de nadie.
--
--  OJO — MARCAS INTACTAS
--  ---------------------
--  Los bloques entre las marcas «PLANTILLA SEMANAL» y «SALAS» los
--  reescribe scripts/build-sql.mjs desde src/lib/data/demo-sessions.ts.
--  No borrar las marcas: el generador falla si faltan.
--
--  CÓMO CORRERLA
--  -------------
--  Supabase → SQL Editor → New query → pegar todo → Run.
-- ============================================================

begin;


-- ------------------------------------------------------------
--  1. El precio puede quedar sin publicar
-- ------------------------------------------------------------
--  Hay planes cuyo precio todavía no se anuncia en la web. En vez
--  de inventar un número, guardamos NULL y la web muestra
--  "Consultar por WhatsApp".

alter table public.plans alter column price drop not null;
alter table public.plans alter column price drop default;


-- ------------------------------------------------------------
--  2. Color de marca
-- ------------------------------------------------------------
--  El verde lima del diseño anterior se reemplaza por el rojo real.

alter table public.classes alter column color set default '#d81a22';
alter table public.coaches alter column color set default '#d81a22';

update public.classes set color = '#d81a22' where color = '#cbf73f';
update public.coaches set color = '#d81a22' where color = '#cbf73f';


-- ------------------------------------------------------------
--  3. Generador de semana con la grilla vacía
-- ------------------------------------------------------------
--  La función se vuelve a crear leyendo una plantilla que está
--  VACÍA. El bloque marcado lo genera scripts/build-sql.mjs a
--  partir de src/lib/data/demo-sessions.ts; mientras el gimnasio
--  no cargue sus horarios, la función no crea ninguna clase.

create or replace function public.generate_week_sessions(p_monday date)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted integer := 0;
  v_slot record;
  v_class  public.classes;
  v_coach  text;
  v_start  timestamptz;
  v_created integer;
begin
  -- Sólo admin o staff
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'staff')
  ) and auth.uid() is not null then
    raise exception 'AUTH: sólo el staff puede generar horarios';
  end if;

  for v_slot in
    select * from (values
-- >>> PLANTILLA SEMANAL (generada por scripts/build-sql.mjs — no editar a mano) >>>
      -- Misma grilla que src/lib/data/demo-sessions.ts (la web).
      -- día (0 = lunes), hora local del gimnasio, disciplina
      -- Lunes: sin clases
      -- Martes: sin clases
      -- Miércoles: sin clases
      -- Jueves: sin clases
      -- Viernes: sin clases
      -- Sábado: sin clases
      -- Domingo: sin clases
      -- Grilla vacía a propósito: el gimnasio carga sus horarios en el panel.
      (null::integer, null::time, null::text)
-- <<< PLANTILLA SEMANAL <<<
    ) as t(day_offset, start_time, slug)
  loop
    select * into v_class from public.classes where slug = v_slot.slug and is_active;
    if not found then continue; end if;

    -- `fecha + hora` da un timestamp "sin zona"; AT TIME ZONE lo interpreta
    -- como hora local del gimnasio y devuelve el instante UTC correcto.
    -- (Managua es UTC-6 todo el año, no tiene horario de verano.)
    v_start := ((p_monday + v_slot.day_offset) + v_slot.start_time)
               at time zone 'America/Managua';

    -- Evitamos duplicar si ya existe esa clase a esa hora
    select count(*) into v_created
    from public.sessions
    where class_id = v_class.id and starts_at = v_start;

    if v_created > 0 then continue; end if;

    -- Elegimos un profe al azar entre los que dictan la disciplina
    select id into v_coach
    from public.coaches
    where is_active and v_class.slug = any (specialties)
    order by random()
    limit 1;

    insert into public.sessions (class_id, coach_id, starts_at, ends_at, capacity, room)
    values (
      v_class.id,
      v_coach,
      v_start,
      v_start + (v_class.duration_min || ' minutes')::interval,
      v_class.capacity,
      case v_class.slug
-- >>> SALAS >>>
        when null then null  -- sin salas por disciplina: todo en «Salón principal»
-- <<< SALAS <<<
        else 'Salón principal'
      end
    );

    v_inserted := v_inserted + 1;
  end loop;

  return v_inserted;
end;
$$;

revoke all on function public.generate_week_sessions(date) from public;
grant execute on function public.generate_week_sessions(date) to authenticated;


-- ------------------------------------------------------------
--  4. ANULADO — Limpiar las clases futuras de la grilla vieja
-- ------------------------------------------------------------
--  Cancelaba/borraba las clases futuras de la grilla anterior.
--  En un gimnasio nuevo no hay grilla vieja que limpiar, y correr
--  esto sobre horarios legítimos creados desde el panel los
--  borraría. Se anula a propósito.


-- ------------------------------------------------------------
--  5. ANULADO — Entrenadores de ejemplo
-- ------------------------------------------------------------
--  Borraba seis entrenadores inventados por ids del gimnasio
--  anterior. Acá no existe ninguno: los entrenadores reales se
--  cargan desde el panel.


-- ------------------------------------------------------------
--  6. ANULADO — Disciplinas reales
-- ------------------------------------------------------------
--  Insertaba el catálogo real del gimnasio anterior (pesas y
--  máquinas, boxeo, zumba) y desactivaba/borraba las demás.
--  Las disciplinas del gimnasio nuevo se crean en el panel.


-- ------------------------------------------------------------
--  7. ANULADO — Planes reales
-- ------------------------------------------------------------
--  Insertaba los planes con las tarifas del gimnasio anterior y
--  borraba los planes viejos. Los planes base sin precio los crea
--  supabase/PERSONALIZAR-GIMNASIO.sql; los precios se cargan en
--  Administración → Planes.


-- ------------------------------------------------------------
--  8. ANULADO — Mensajes de ejemplo
-- ------------------------------------------------------------
--  Borraba dos consultas de prueba del buzón. En una instalación
--  nueva el buzón ya nace vacío.


-- ------------------------------------------------------------
--  9. ANULADO — Clases de las próximas 4 semanas
-- ------------------------------------------------------------
--  Llamaba a generate_week_sessions() cuatro veces para materializar
--  la grilla del gimnasio anterior. Con la grilla vacía no tiene
--  sentido: las semanas se generan desde el panel cuando el
--  gimnasio carga sus horarios.


commit;


-- ============================================================
--  COMPROBAR QUE SALIÓ BIEN
-- ============================================================
--  Esta migración ya no cambia datos. Para comprobar:
--
--    select count(*)::text as generador
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and p.proname = 'generate_week_sessions';
--
--  Tiene que devolver 1. Y con la grilla vacía:
--
--    select public.generate_week_sessions(current_date);
--
--  Tiene que devolver 0 sin crear clases.
-- ============================================================
