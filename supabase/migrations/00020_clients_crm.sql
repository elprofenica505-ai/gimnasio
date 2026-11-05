-- FASE 2: CRM de clientes + recepción manual/QR. Aplicar después de 00012.
-- profiles sigue siendo la tabla de identidades/login. gym_clients es una
-- ficha comercial independiente: NO exige teléfono, email ni cuenta web.
-- Etiquetas manuales, no precios ni promociones automáticas.
begin;

create or replace function public.crm_is_staff()
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','staff')); $$;
revoke all on function public.crm_is_staff() from public;
grant execute on function public.crm_is_staff() to authenticated;

create table if not exists public.gym_clients (
  id uuid primary key default gen_random_uuid(),
  client_number bigint generated always as identity unique,
  profile_id uuid unique references public.profiles(id) on delete set null,
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  birthdate date,
  address text check (length(address)<=200),
  emergency_contact_name text check (length(emergency_contact_name)<=120),
  emergency_contact_phone text check (length(emergency_contact_phone)<=40),
  medical_notes text check (length(medical_notes)<=500),
  phone text check (length(phone) <= 40),
  email text check (length(email) <= 120),
  category text not null default 'client' check (category in ('client','friend','family')),
  status text not null default 'active' check (status in ('active','frozen','cancelled')),
  plan_id text references public.plans(id) on delete set null,
  notes text not null default '' check (length(notes) <= 2000),
  joined_on date not null default (now() at time zone 'America/Managua')::date,
  is_demo boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists gym_clients_name_idx on public.gym_clients(lower(full_name));
create table if not exists public.client_cards (
  client_id uuid primary key references public.gym_clients(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  updated_at timestamptz not null default now()
);
create table if not exists public.client_visits (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.gym_clients(id) on delete cascade,
  visited_at timestamptz not null default now(),
  local_day date not null default (now() at time zone 'America/Managua')::date,
  source text not null check (source in ('manual','qr')),
  recorded_by uuid references public.profiles(id) on delete set null,
  unique(client_id, local_day)
);
create index if not exists client_visits_day_idx on public.client_visits(local_day desc);
create table if not exists public.client_events (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.gym_clients(id) on delete cascade,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  actor_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.transactions add column if not exists client_id uuid references public.gym_clients(id) on delete restrict;
alter table public.transactions add column if not exists crm_request_id uuid unique;
create index if not exists transactions_client_idx on public.transactions(client_id, occurred_at desc);

-- No escritura directa: las funciones verifican permisos, validan y auditan.
alter table public.gym_clients enable row level security;
alter table public.client_cards enable row level security;
alter table public.client_visits enable row level security;
alter table public.client_events enable row level security;
revoke all on public.gym_clients, public.client_cards, public.client_visits, public.client_events from anon, authenticated;
grant select on public.gym_clients, public.client_visits, public.client_events to authenticated;
drop policy if exists crm_clients_read on public.gym_clients;
create policy crm_clients_read on public.gym_clients for select to authenticated using (public.crm_is_staff());
drop policy if exists crm_visits_read on public.client_visits;
create policy crm_visits_read on public.client_visits for select to authenticated using (public.crm_is_staff());
drop policy if exists crm_events_read on public.client_events;
create policy crm_events_read on public.client_events for select to authenticated using (public.crm_is_staff());

create or replace function public.crm_create_client(p_name text, p_phone text default null, p_email text default null, p_plan text default null, p_duplicate_confirmed boolean default false)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_email is not null and trim(p_email) <> '' and p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'INVALID_EMAIL'; end if;
  perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_name)),0));
  if not coalesce(p_duplicate_confirmed,false) and exists(select 1 from public.gym_clients where
    (lower(full_name)=lower(trim(p_name)) and coalesce(phone,'')=coalesce(nullif(trim(p_phone),''),''))
    or (nullif(trim(p_email),'') is not null and email=lower(trim(p_email)))) then raise exception 'DUPLICATE_CLIENT'; end if;
  insert into public.gym_clients(full_name, phone, email, plan_id, created_by)
    values(trim(p_name), nullif(trim(p_phone),''), nullif(lower(trim(p_email)),''), nullif(p_plan,''), auth.uid()) returning id into v_id;
  insert into public.client_cards(client_id) values(v_id);
  insert into public.client_events(client_id, action, actor_id) values(v_id,'created',auth.uid());
  return v_id;
end $$;

create or replace function public.crm_update_client(p_id uuid, p_name text, p_phone text, p_email text, p_category text, p_status text, p_plan text, p_notes text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare old_row public.gym_clients; v_admin boolean;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into old_row from public.gym_clients where id=p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select role='admin' into v_admin from public.profiles where id=auth.uid();
  if p_category <> old_row.category and not coalesce(v_admin,false) then raise exception 'ADMIN_ONLY'; end if;
  if p_email is not null and trim(p_email) <> '' and p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'INVALID_EMAIL'; end if;
  update public.gym_clients set full_name=trim(p_name),phone=nullif(trim(p_phone),''),email=nullif(lower(trim(p_email)),''),
    category=p_category,status=p_status,plan_id=nullif(p_plan,''),notes=coalesce(p_notes,''),updated_at=now() where id=p_id;
  insert into public.client_events(client_id,action,details,actor_id) values(p_id,'updated',
    jsonb_build_object('category_before',old_row.category,'category_after',p_category,'status_before',old_row.status,'status_after',p_status),auth.uid());
end $$;

create or replace function public.crm_get_card(p_id uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_token uuid;
begin
  if not public.crm_is_staff() and not exists(select 1 from public.gym_clients where id=p_id and profile_id=auth.uid()) then raise exception 'AUTH'; end if;
  if not exists(select 1 from public.gym_clients where id=p_id) then raise exception 'NOT_FOUND'; end if;
  insert into public.client_cards(client_id) values(p_id) on conflict(client_id) do nothing;
  select token into v_token from public.client_cards where client_id=p_id;
  return v_token;
end $$;
create or replace function public.crm_rotate_card(p_id uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_token uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if not exists(select 1 from public.gym_clients where id=p_id) then raise exception 'NOT_FOUND'; end if;
  insert into public.client_cards(client_id) values(p_id) on conflict(client_id) do update set token=gen_random_uuid(),updated_at=now() returning token into v_token;
  insert into public.client_events(client_id,action,actor_id) values(p_id,'card_reset',auth.uid());
  return v_token;
end $$;
create or replace function public.crm_find_card(p_token uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select client_id into v_id from public.client_cards where token=p_token;
  if v_id is null then raise exception 'INVALID_CARD'; end if;
  return v_id;
end $$;

create or replace function public.crm_check_in(p_id uuid, p_source text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_visit uuid; v_existing uuid; v_status text;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select status into v_status from public.gym_clients where id=p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_status <> 'active' then raise exception 'INACTIVE'; end if;
  if p_source not in ('manual','qr') or p_source is null then raise exception 'INVALID_SOURCE'; end if;
  if p_source='qr' and not exists(select 1 from public.client_cards where client_id=p_id and token=p_token) then raise exception 'INVALID_CARD'; end if;
  insert into public.client_visits(client_id,source,recorded_by) values(p_id,p_source,auth.uid())
    on conflict(client_id,local_day) do nothing returning id into v_visit;
  if v_visit is null then
    select id into v_existing from public.client_visits where client_id=p_id and local_day=(now() at time zone 'America/Managua')::date;
    return jsonb_build_object('id',v_existing,'already',true);
  end if;
  return jsonb_build_object('id',v_visit,'already',false);
end $$;

-- Cobro confirmado, separado del escaneo y de la asistencia. Sin factura ni
-- descuento automático. Idempotencia: reintentar el MISMO request no duplica caja.
create or replace function public.crm_record_payment(p_id uuid, p_request uuid, p_amount numeric, p_currency text, p_method text, p_account text, p_concept text, p_fx numeric default 1)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_profile uuid; v_existing public.transactions;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if p_request is null then raise exception 'INVALID_REQUEST'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into v_existing from public.transactions where crm_request_id=p_request;
  if found then
    if v_existing.client_id is distinct from p_id or v_existing.amount is distinct from p_amount
      or v_existing.currency::text is distinct from p_currency or v_existing.payment_method_id is distinct from p_method
      or v_existing.account_id is distinct from p_account or v_existing.concept is distinct from trim(p_concept)
      or v_existing.fx_rate is distinct from p_fx then raise exception 'REQUEST_CONFLICT'; end if;
    return v_existing.id;
  end if;
  if p_amount is null or p_amount<=0 or p_amount>99999999 or p_amount<>round(p_amount,2)
    or p_currency is null or p_currency not in ('NIO','USD') or p_fx is null or p_fx<=0 or p_fx>10000
    or p_fx<>round(p_fx,4) or round(p_amount*p_fx,2)>9999999999.99
    or (p_currency='NIO' and p_fx<>1) or p_concept is null or length(trim(p_concept)) not between 2 and 200 then raise exception 'INVALID_PAYMENT'; end if;
  select profile_id into v_profile from public.gym_clients where id=p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not exists(select 1 from public.payment_methods where id=p_method and is_active
    and ((p_currency='NIO' and accepts_nio) or (p_currency='USD' and accepts_usd))) then raise exception 'INVALID_METHOD'; end if;
  if not exists(select 1 from public.accounts where id=p_account and is_active and currency::text=p_currency) then raise exception 'INVALID_ACCOUNT'; end if;
  insert into public.transactions(direction,status,amount,currency,fx_rate,base_amount,payment_method_id,account_id,member_id,client_id,crm_request_id,concept,created_by)
    values('income','completed',p_amount,p_currency::public.currency_code,p_fx,round(p_amount*p_fx,2),p_method,p_account,v_profile,p_id,p_request,trim(p_concept),auth.uid()) returning id into v_id;
  insert into public.client_events(client_id,action,details,actor_id) values(p_id,'payment',jsonb_build_object('transaction_id',v_id),auth.uid());
  return v_id;
end $$;

-- Directorio paginado; filtros en servidor. No devuelve tokens QR.
create or replace function public.crm_directory(p_search text default '', p_category text default '', p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select jsonb_build_object('total',(select count(*) from public.gym_clients c where
    (p_category='' or c.category=p_category) and (p_search='' or c.full_name ilike '%'||p_search||'%' or coalesce(c.phone,'') ilike '%'||p_search||'%' or c.client_number::text=p_search)),
    'rows',coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb)) into result from (
    select c.*,p.name_es as plan_name,
      (select count(*)::int from public.client_visits v where v.client_id=c.id and v.local_day >= (now() at time zone 'America/Managua')::date-29) as visits_30,
      (select max(v.visited_at) from public.client_visits v where v.client_id=c.id) as last_visit
    from public.gym_clients c left join public.plans p on p.id=c.plan_id
    where (p_category='' or c.category=p_category) and (p_search='' or c.full_name ilike '%'||p_search||'%' or coalesce(c.phone,'') ilike '%'||p_search||'%' or c.client_number::text=p_search)
    order by c.full_name,c.id limit 30 offset greatest(0,least(coalesce(p_offset,0),1000000))
  ) r;
  return result;
end $$;
create or replace function public.crm_detail(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client public.gym_clients; v_result jsonb;
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  select * into v_client from public.gym_clients where id=p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  select jsonb_build_object('client',to_jsonb(v_client),'card',public.crm_get_card(p_id),
    'visits',coalesce((select jsonb_agg(to_jsonb(v)) from (select * from public.client_visits where client_id=p_id order by visited_at desc limit 60)v),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(e)) from (select * from public.client_events where client_id=p_id order by created_at desc limit 40)e),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(t)) from (select id,occurred_at,concept,amount,currency,status from public.transactions where client_id=p_id or (v_client.profile_id is not null and member_id=v_client.profile_id) order by occurred_at desc limit 40)t),'[]'::jsonb),
    'balance',case when v_client.profile_id is null then null else (select balance_nio from public.member_balances where member_id=v_client.profile_id) end) into v_result;
  return v_result;
end $$;

-- Perfil web existente/nuevo: crea una ficha vinculada sin exigir login a
-- quienes se registran en recepción. Nunca vincular por simple coincidencia de email.
create or replace function public.crm_profile_created()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.role='member' then
    insert into public.gym_clients(profile_id,full_name,phone,email,plan_id)
      values(new.id,coalesce(nullif(trim(new.full_name),''),'Cliente'),new.phone,new.email,new.plan_id)
      on conflict(profile_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists crm_profile_created on public.profiles;
create trigger crm_profile_created after insert on public.profiles for each row execute function public.crm_profile_created();
insert into public.gym_clients(profile_id,full_name,phone,email,plan_id)
  select id,coalesce(nullif(trim(full_name),''),'Cliente'),phone,email,plan_id from public.profiles where role='member'
  on conflict(profile_id) do nothing;
insert into public.client_cards(client_id) select id from public.gym_clients on conflict(client_id) do nothing;

create or replace function public.crm_my_pass()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.gym_clients;
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  select * into c from public.gym_clients where profile_id=auth.uid();
  if not found then return null; end if;
  return jsonb_build_object('name',c.full_name,'number',c.client_number,'token',public.crm_get_card(c.id));
end $$;

-- Importación sin auth.users ficticios; una fila por RPC, con deduplicación.
create or replace function public.crm_import_client(p_row jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_name text := trim(p_row->>'fullName'); v_email text := nullif(lower(trim(p_row->>'email')),''); v_phone text := nullif(trim(p_row->>'phone'),'');
begin
  if not public.crm_is_staff() then raise exception 'AUTH'; end if;
  if v_name is null or length(v_name) not between 2 and 120 then raise exception 'INVALID_NAME'; end if;
  perform pg_advisory_xact_lock(hashtextextended(coalesce(v_email,lower(v_name)||coalesce(v_phone,'')),0));
  select id into v_id from public.gym_clients where (v_email is not null and email=v_email)
    or (lower(full_name)=lower(v_name) and phone is not distinct from v_phone) order by created_at limit 1;
  if found then return jsonb_build_object('id',v_id,'imported',false); end if;
  v_id := public.crm_create_client(v_name,v_phone,v_email,p_row->>'planId');
  update public.gym_clients set status=coalesce(nullif(p_row->>'status',''),'active'),
    birthdate=nullif(p_row->>'birthdate','')::date,address=nullif(p_row->>'address',''),
    emergency_contact_name=nullif(p_row->>'emergencyContactName',''),emergency_contact_phone=nullif(p_row->>'emergencyContactPhone',''),
    medical_notes=nullif(p_row->>'medicalNotes','') where id=v_id;
  return jsonb_build_object('id',v_id,'imported',true);
end $$;
revoke all on function public.crm_import_client(jsonb) from public;
grant execute on function public.crm_import_client(jsonb) to authenticated;

-- Las funciones CRM dependen de roles reales. Impedir que un cliente cambie
-- su propio role mediante la antigua política de edición del perfil propio.
create or replace function public.crm_protect_profile_role()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null
    and not exists(select 1 from public.profiles where id=auth.uid() and role='admin') then
    raise exception 'ADMIN_ONLY';
  end if;
  return new;
end $$;
revoke all on function public.crm_protect_profile_role() from public;
drop trigger if exists crm_protect_profile_role on public.profiles;
create trigger crm_protect_profile_role before update of role on public.profiles for each row execute function public.crm_protect_profile_role();

-- PostgreSQL concede EXECUTE a PUBLIC por defecto: revocación explícita.
revoke all on function public.crm_create_client(text,text,text,text,boolean), public.crm_update_client(uuid,text,text,text,text,text,text,text), public.crm_get_card(uuid), public.crm_rotate_card(uuid), public.crm_find_card(uuid), public.crm_check_in(uuid,text,uuid), public.crm_record_payment(uuid,uuid,numeric,text,text,text,text,numeric), public.crm_directory(text,text,integer), public.crm_detail(uuid), public.crm_my_pass(), public.crm_profile_created() from public;
grant execute on function public.crm_create_client(text,text,text,text,boolean), public.crm_update_client(uuid,text,text,text,text,text,text,text), public.crm_get_card(uuid), public.crm_rotate_card(uuid), public.crm_find_card(uuid), public.crm_check_in(uuid,text,uuid), public.crm_record_payment(uuid,uuid,numeric,text,text,text,text,numeric), public.crm_directory(text,text,integer), public.crm_detail(uuid), public.crm_my_pass() to authenticated;
commit;
