/**
 * El mínimo de Supabase que PGlite no trae: schema `auth`, roles
 * anon/authenticated, auth.users y las funciones auth.uid()/auth.jwt()
 * que las políticas RLS de la cadena usan.
 *
 * Lo comparten scripts/test-instalar-base-sql.mjs y
 * scripts/diagnostic-esquema-local.mjs para que las dos ejecuciones
 * locales de INSTALAR-BASE.sql partan exactamente de la misma base.
 *
 * @param {import("@electric-sql/pglite").PGlite} db
 */
export async function authMinimo(db) {
  await db.exec(`
create schema if not exists auth;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
create table if not exists auth.current_user (id uuid, aal text);
create or replace function auth.uid() returns uuid
  language sql stable as $$ select id from auth.current_user limit 1 $$;
create or replace function auth.jwt() returns jsonb
  language sql stable as $$ select jsonb_build_object('aal', aal) from auth.current_user limit 1 $$;
grant usage on schema auth to authenticated, anon;
grant select on auth.current_user to authenticated, anon;
`);
}
