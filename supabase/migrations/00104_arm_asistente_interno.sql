-- 00104 · ARM: asistente relacional multicanal — canal interno (fase 2)
--
-- El «empleado virtual 24/7» del paso 2. Un cerebro que responde leyendo la
-- base (planes, clases, tienda) y captura interesados como leads, con canales
-- enchufables que se encienden y apagan con un interruptor:
--
--   · 'interno'  → ACTIVO desde acá. Burbuja de chat en la web pública
--                  (visitantes anónimos) y «Mensajes» en Mi cuenta (socios).
--                  Cuesta $0 y no depende de Meta.
--   · 'whatsapp' → APAGADO. Se activa tras la firma, cuando el gimnasio tenga
--                  su Meta Business verificada (candado natural).
--   · 'correo'   → APAGADO. Reservado para una fase futura.
--
-- Nada de este módulo envía mensajes hacia afuera: sólo conversa con quien
-- escribe primero y deja el recado en la bandeja del panel (Asistente).
--
-- Escritura SÓLO por RPC security definer (nadie inserta en las tablas
-- directo, ni el personal: responde por arm_responder_staff). Lectura por
-- RLS: el personal ve todo; un socio ve únicamente su hilo; el visitante
-- anónimo sólo por RPC con su token (uuid inadivinable).
--
-- Reversión:
--   drop function public.arm_hilo_visitante(uuid,text);
--   drop function public.arm_enviar_visitante(uuid,text);
--   drop function public.arm_responder_asistente(uuid,text);
--   drop function public.arm_historial(uuid,integer);
--   drop function public.arm_marcar_leida_visitante(uuid);
--   drop function public.arm_vincular_contacto(uuid,text,text,text);
--   drop function public.arm_responder_staff(uuid,text);
--   drop function public.arm_anotar_contacto(uuid,text,text);
--   drop table public.arm_messages; drop table public.arm_threads;
--   drop table public.arm_channels;
--   alter table public.embudo_leads drop constraint embudo_leads_source_check;
--   alter table public.embudo_leads add constraint embudo_leads_source_check
--     check (source in ('landing','checkout','manual','whatsapp'));

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.embudo_leads') is null
     or to_regclass('public.gym_clients') is null
     or to_regprocedure('public.embudo_guardar_lead(jsonb)') is null
     or to_regprocedure('public.crm_is_staff()') is null then
    raise exception 'ARM_00104_PREREQUISITE_MISSING';
  end if;
end $$;

-- El asistente es una fuente nueva de leads del embudo: ensanchamos el CHECK
-- (idempotente; si ya trae 'asistente' no se toca).
do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'embudo_leads_source_check'
       and pg_get_constraintdef(oid) like '%asistente%'
  ) then
    alter table public.embudo_leads drop constraint if exists embudo_leads_source_check;
    alter table public.embudo_leads add constraint embudo_leads_source_check
      check (source in ('landing','checkout','manual','whatsapp','asistente'));
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. Interruptores de canal
-- ------------------------------------------------------------
create table if not exists public.arm_channels (
  channel    text primary key check (channel in ('interno','whatsapp','correo')),
  enabled    boolean not null default false,
  note       text not null default '',
  updated_at timestamptz not null default now()
);

insert into public.arm_channels (channel, enabled, note) values
  ('interno',  true,  'Burbuja de chat en la web y mensajes de socios. $0, sin Meta.'),
  ('whatsapp', false, 'Se activa tras la firma, con la Meta Business del gimnasio.'),
  ('correo',   false, 'Canal reservado para una fase futura.')
on conflict (channel) do nothing;

-- ------------------------------------------------------------
-- 2. Hilos de conversación
-- ------------------------------------------------------------
create table if not exists public.arm_threads (
  id              uuid primary key default gen_random_uuid(),
  channel         text not null default 'interno' references public.arm_channels(channel),
  locale          text not null default 'es' check (locale in ('es','en')),
  status          text not null default 'abierta' check (status in ('abierta','cerrada')),
  -- Un hilo es de UN participante: visitante anónimo (token) o socio (user).
  visitor_token   uuid,
  user_id         uuid,
  full_name       text,
  phone           text,
  email           text,
  lead_id         uuid references public.embudo_leads(id) on delete set null,
  client_id       uuid references public.gym_clients(id) on delete set null,
  staff_unread    integer not null default 0,
  visitor_unread  integer not null default 0,
  last_message    text,
  last_message_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint arm_threads_participante
    check (visitor_token is not null or user_id is not null)
);

create index if not exists arm_threads_bandeja_idx
  on public.arm_threads (status, last_message_at desc nulls last);
create index if not exists arm_threads_token_idx
  on public.arm_threads (visitor_token) where visitor_token is not null;
create index if not exists arm_threads_user_idx
  on public.arm_threads (user_id) where user_id is not null;

-- ------------------------------------------------------------
-- 3. Mensajes
-- ------------------------------------------------------------
create table if not exists public.arm_messages (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references public.arm_threads(id) on delete cascade,
  role       text not null check (role in ('visitante','asistente','staff')),
  text       text not null,
  created_at timestamptz not null default now()
);

create index if not exists arm_messages_hilo_idx
  on public.arm_messages (thread_id, created_at);

-- ------------------------------------------------------------
-- 4. RLS: lectura controlada; la escritura vive en los RPC
-- ------------------------------------------------------------
alter table public.arm_channels enable row level security;
alter table public.arm_threads  enable row level security;
alter table public.arm_messages enable row level security;

drop policy if exists arm_channels_leer on public.arm_channels;
create policy arm_channels_leer on public.arm_channels
  for select using (true);

drop policy if exists arm_channels_personal on public.arm_channels;
create policy arm_channels_personal on public.arm_channels
  for update to authenticated
  using (public.crm_is_staff()) with check (public.crm_is_staff());

drop policy if exists arm_threads_personal_leer on public.arm_threads;
create policy arm_threads_personal_leer on public.arm_threads
  for select to authenticated
  using (public.crm_is_staff() or user_id = auth.uid());

drop policy if exists arm_threads_personal_editar on public.arm_threads;
create policy arm_threads_personal_editar on public.arm_threads
  for update to authenticated
  using (public.crm_is_staff()) with check (public.crm_is_staff());

drop policy if exists arm_messages_personal_leer on public.arm_messages;
create policy arm_messages_personal_leer on public.arm_messages
  for select to authenticated
  using (
    public.crm_is_staff()
    or exists (
      select 1 from public.arm_threads t
       where t.id = arm_messages.thread_id and t.user_id = auth.uid()
    )
  );

-- Grants explícitos: en PGlite no hay defaults de Supabase, en producción
-- son los mismos que ya aplican. La RLS es la puerta de verdad.
grant select on public.arm_channels to anon, authenticated;
grant update on public.arm_channels to authenticated;
grant select, update on public.arm_threads to authenticated;
grant select on public.arm_messages to authenticated;

-- ------------------------------------------------------------
-- 5. RPC del visitante (anon + socio). El único camino de escritura.
-- ------------------------------------------------------------
-- Abre (o reutiliza) el hilo de un visitante/socio. Si hay sesión activa,
-- el hilo queda amarrado al socio y además adopta el hilo anónimo que
-- hubiera abierto antes de entrar a su cuenta.
create or replace function public.arm_hilo_visitante(p_token uuid, p_locale text default 'es')
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid   uuid := auth.uid();
  v_id    uuid;
  v_locale text := case when p_locale in ('es','en') then p_locale else 'es' end;
begin
  if p_token is null then raise exception 'TOKEN_INVALIDO'; end if;
  if not exists (select 1 from public.arm_channels where channel = 'interno' and enabled) then
    raise exception 'CANAL_APAGADO';
  end if;

  if v_uid is not null then
    update public.arm_threads
       set user_id = v_uid, updated_at = now()
     where visitor_token = p_token
       and user_id is null
       and not exists (select 1 from public.arm_threads t2 where t2.user_id = v_uid);

    select id into v_id
      from public.arm_threads
     where user_id = v_uid
     order by created_at
     limit 1;
    if v_id is null then
      insert into public.arm_threads (channel, locale, visitor_token, user_id)
      values ('interno', v_locale, p_token, v_uid)
      returning id into v_id;
    end if;
    return v_id;
  end if;

  select id into v_id
    from public.arm_threads
   where visitor_token = p_token and user_id is null
   order by created_at
   limit 1;
  if v_id is null then
    insert into public.arm_threads (channel, locale, visitor_token)
    values ('interno', v_locale, p_token)
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- El visitante/socio escribe. Devuelve el id del mensaje insertado.
create or replace function public.arm_enviar_visitante(p_token uuid, p_text text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_thread uuid;
  v_msg    uuid;
  v_texto  text := trim(coalesce(p_text, ''));
begin
  if v_texto = '' or char_length(v_texto) > 1000 then
    raise exception 'MENSAJE_INVALIDO';
  end if;
  select public.arm_hilo_visitante(p_token) into v_thread;

  -- Si el personal cerró el hilo, un mensaje nuevo lo reabre: es más amable
  -- que dejar a la persona sin poder contestar.
  insert into public.arm_messages (thread_id, role, text)
  values (v_thread, 'visitante', v_texto)
  returning id into v_msg;

  update public.arm_threads
     set last_message = left(v_texto, 160),
         last_message_at = now(),
         staff_unread = staff_unread + 1,
         status = 'abierta',
         updated_at = now()
   where id = v_thread;

  return v_msg;
end $$;

-- El cerebro deja su respuesta en el hilo (sólo hilos de visitante anónimo:
-- al socio el que le contesta es el personal, no el bot).
create or replace function public.arm_responder_asistente(p_token uuid, p_text text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_thread public.arm_threads;
  v_texto  text := trim(coalesce(p_text, ''));
begin
  if v_texto = '' or char_length(v_texto) > 1000 then
    raise exception 'MENSAJE_INVALIDO';
  end if;
  if not exists (select 1 from public.arm_channels where channel = 'interno' and enabled) then
    raise exception 'CANAL_APAGADO';
  end if;
  select * into v_thread
    from public.arm_threads
   where visitor_token = p_token
   order by created_at
   limit 1;
  if not found then raise exception 'HILO_NO_ENCONTRADO'; end if;
  if v_thread.user_id is not null then return; end if; -- socio: sin bot

  insert into public.arm_messages (thread_id, role, text)
  values (v_thread.id, 'asistente', left(v_texto, 1000));

  update public.arm_threads
     set last_message = left(v_texto, 160),
         last_message_at = now(),
         visitor_unread = visitor_unread + 1,
         updated_at = now()
   where id = v_thread.id;
end $$;

-- Historial del hilo del visitante (sólo con su token): contacto conocido
-- (para que el cerebro retome una captura a medias) + últimos mensajes.
-- Sin hilo → null.
create or replace function public.arm_historial(p_token uuid, p_limite integer default 200)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'contacto', jsonb_build_object(
      'full_name', t.full_name,
      'phone',     t.phone,
      'email',     t.email,
      'socio',     t.user_id is not null,
      'status',    t.status
    ),
    'mensajes', coalesce((
      select jsonb_agg(row_to_json(x) order by x.created_at)
      from (
        select m.role, m.text, m.created_at
          from public.arm_messages m
         where m.thread_id = t.id
         order by m.created_at desc
         limit greatest(least(coalesce(p_limite, 200), 500), 1)
      ) x
    ), '[]'::jsonb)
  )
  from public.arm_threads t
  where t.visitor_token = p_token
  order by t.created_at
  limit 1;
$$;

-- Captura a medias: el cerebro consiguió el nombre pero falta el teléfono,
-- o al revés. Guarda lo que hay SIN crear lead todavía; el lead nace cuando
-- estén los dos (arm_vincular_contacto).
create or replace function public.arm_anotar_contacto(
  p_token uuid, p_full_name text, p_phone text
)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_nombre text := nullif(trim(coalesce(p_full_name, '')), '');
  v_phone  text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
begin
  if v_nombre is null and v_phone is null then return; end if;
  if v_phone is not null and char_length(v_phone) < 6 then v_phone := null; end if;
  if v_nombre is null and v_phone is null then return; end if;
  update public.arm_threads
     set full_name = coalesce(v_nombre, full_name),
         phone = coalesce(v_phone, phone),
         updated_at = now()
   where visitor_token = p_token and user_id is null;
end $$;

-- El visitante abrió el chat: limpiar su contador de «sin leer».
create or replace function public.arm_marcar_leida_visitante(p_token uuid)
returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.arm_threads
     set visitor_unread = 0, updated_at = now()
   where visitor_token = p_token
      or (auth.uid() is not null and user_id = auth.uid());
$$;

-- Captura de interesado: el cerebro pidió nombre y teléfono, el visitante
-- los dio. Visitante anónimo → lead (mismo cauce del embudo, source
-- 'asistente'). Socio → se enlaza su ficha de cliente si el teléfono
-- coincide con alguna.
create or replace function public.arm_vincular_contacto(
  p_token uuid, p_full_name text, p_phone text, p_email text default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_thread public.arm_threads;
  v_phone  text;
  v_nombre text;
  v_email  text;
  v_lead   uuid;
  v_client uuid;
begin
  select * into v_thread
    from public.arm_threads
   where visitor_token = p_token or user_id = auth.uid()
   order by created_at
   limit 1;
  if not found then raise exception 'HILO_NO_ENCONTRADO'; end if;

  v_nombre := nullif(trim(coalesce(p_full_name, '')), '');
  v_phone  := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_email  := nullif(trim(coalesce(p_email, '')), '');
  if v_nombre is null or char_length(v_phone) < 6 then
    raise exception 'CONTACTO_INVALIDO';
  end if;

  update public.arm_threads
     set full_name = v_nombre, phone = v_phone, email = v_email, updated_at = now()
   where id = v_thread.id;

  if v_thread.user_id is null then
    perform public.embudo_guardar_lead(jsonb_build_object(
      'full_name', v_nombre,
      'phone',     v_phone,
      'email',     v_email,
      'source',    'asistente',
      'interest',  'Asistente web'
    ));
    select id into v_lead
      from public.embudo_leads
     where phone = v_phone
     order by created_at
     limit 1;
    update public.arm_threads
       set lead_id = coalesce(v_lead, lead_id)
     where id = v_thread.id;
  else
    select id into v_client
      from public.gym_clients
     where phone = v_phone
     order by client_number
     limit 1;
    update public.arm_threads
       set client_id = coalesce(v_client, client_id)
     where id = v_thread.id;
  end if;

  return jsonb_build_object('ok', true, 'lead_id', v_lead, 'client_id', v_client);
end $$;

-- ------------------------------------------------------------
-- 6. RPC del personal: responder desde la bandeja del panel
-- ------------------------------------------------------------
create or replace function public.arm_responder_staff(p_thread_id uuid, p_text text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_texto text := trim(coalesce(p_text, ''));
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if v_texto = '' or char_length(v_texto) > 1000 then
    raise exception 'MENSAJE_INVALIDO';
  end if;
  if not exists (select 1 from public.arm_threads where id = p_thread_id) then
    raise exception 'HILO_NO_ENCONTRADO';
  end if;

  insert into public.arm_messages (thread_id, role, text)
  values (p_thread_id, 'staff', v_texto);

  update public.arm_threads
     set last_message = left(v_texto, 160),
         last_message_at = now(),
         visitor_unread = visitor_unread + 1,
         staff_unread = 0,
         updated_at = now()
   where id = p_thread_id;
end $$;

-- ------------------------------------------------------------
-- 7. Grants de funciones (patrón del embudo: nada público por defecto)
-- ------------------------------------------------------------
revoke all on function public.arm_hilo_visitante(uuid,text) from public, authenticated;
revoke all on function public.arm_enviar_visitante(uuid,text) from public, authenticated;
revoke all on function public.arm_responder_asistente(uuid,text) from public, authenticated;
revoke all on function public.arm_historial(uuid,integer) from public, authenticated;
revoke all on function public.arm_marcar_leida_visitante(uuid) from public, authenticated;
revoke all on function public.arm_vincular_contacto(uuid,text,text,text) from public, authenticated;
revoke all on function public.arm_responder_staff(uuid,text) from public, anon;
revoke all on function public.arm_anotar_contacto(uuid,text,text) from public, authenticated;

grant execute on function public.arm_hilo_visitante(uuid,text) to anon, authenticated;
grant execute on function public.arm_enviar_visitante(uuid,text) to anon, authenticated;
grant execute on function public.arm_responder_asistente(uuid,text) to anon, authenticated;
grant execute on function public.arm_historial(uuid,integer) to anon, authenticated;
grant execute on function public.arm_marcar_leida_visitante(uuid) to anon, authenticated;
grant execute on function public.arm_vincular_contacto(uuid,text,text,text) to anon, authenticated;
grant execute on function public.arm_anotar_contacto(uuid,text,text) to anon, authenticated;
grant execute on function public.arm_responder_staff(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;
