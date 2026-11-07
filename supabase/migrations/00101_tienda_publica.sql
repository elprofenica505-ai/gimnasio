-- 00101 · Tienda pública: catálogo visible para visitantes (sin sesión)
--
-- Qué resuelve: la tienda de la landing debe mostrar productos con precio
-- a CUALQUIER visitante (sin cuenta), pero la tabla products guarda datos
-- internos (costo, ganancia, stock mínimo) que no se publican. El
-- hardening anterior revocó la lectura directa a anon — bien para la
-- tabla completa, mal para vender. Esta RPC es la puerta estrecha:
-- sólo columnas públicas de productos ACTIVOS.
--
-- El carrito/orden sigue validando TODO en el servidor
-- (embudo_crear_orden re-lee precio y estado de cada producto), así que
-- esta lectura no agrega superficie de riesgo.
--
-- Reversión: drop function public.tienda_productos();

begin;
set local lock_timeout = '5s';

do $$ begin
  if to_regclass('public.products') is null then
    raise exception 'TIENDA_PREREQUISITE_MISSING';
  end if;
end $$;

create or replace function public.tienda_productos()
returns table (id uuid, name text, category text, price numeric, image_data text)
language sql
stable
security definer
set search_path = public, pg_temp as $$
  select p.id, p.name, p.category, p.price, p.image_data
    from public.products p
   where p.status = 'activo'
   order by p.category, p.name;
$$;

revoke all on function public.tienda_productos() from public, authenticated;
grant execute on function public.tienda_productos() to anon, authenticated;

notify pgrst, 'reload schema';
commit;
