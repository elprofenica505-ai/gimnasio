-- ============================================================
--  PERSONALIZAR EL GIMNASIO NUEVO
-- ============================================================
--  Correr DESPUÉS de INSTALAR-BASE.sql, en el mismo SQL Editor.
--  Reemplazar lo que está entre <<  >> y darle Run.
--  Se puede correr varias veces: no duplica nada.
--
--  Orden obligatorio:
--    1) INSTALAR-BASE.sql
--    2) crear el usuario dueño en Authentication → Users
--    3) este archivo
-- ============================================================


-- ------------------------------------------------------------
--  1 · EL DUEÑO TIENE QUE SER ADMINISTRADOR
-- ------------------------------------------------------------
--  El rol vive en la tabla profiles y no se cambia desde el panel.
--  Authentication → Users → Add user → correo y contraseña del dueño.
--  Copiar su UUID (columna UID) y pegarlo abajo.

update public.profiles
   set role = 'admin'
 where id = '<<PEGAR-AQUI-EL-UUID-DEL-DUENO>>';

-- Comprobación: tiene que aparecer una fila con role = admin.
select id, full_name, email, role from public.profiles where role = 'admin';


-- ------------------------------------------------------------
--  2 · CAJA: LAS DOS CUENTAS DE EFECTIVO
-- ------------------------------------------------------------
--  Sin esto la pantalla de Caja no tiene dónde abrir turno.
--  Los bancos se agregan después desde Administración → Dinero,
--  con los números reales del gimnasio.

insert into public.accounts (id, slug, name, kind, currency, holder_name)
values
  ('acc_cash_nio', 'caja-cordobas',  'Caja fuerte (C$)',  'cash', 'NIO', '<<NOMBRE DEL GIMNASIO>>'),
  ('acc_cash_usd', 'caja-dolares',   'Caja fuerte (US$)', 'cash', 'USD', '<<NOMBRE DEL GIMNASIO>>')
on conflict (id) do update set
  name        = excluded.name,
  holder_name = excluded.holder_name,
  is_active   = true;

select id, name, kind, currency, is_active from public.accounts order by id;


-- ------------------------------------------------------------
--  3 · PLANES BASE
-- ------------------------------------------------------------
--  Nombres neutros y precio en NULL = «precio a consultar».
--  La web no inventa cifras: si no hay precio, no muestra número.
--  Los precios reales se cargan en Administración → Planes.

insert into public.plans (
  id, slug, name_es, name_en, tagline_es, tagline_en,
  price, price_nio, period, features_es, features_en,
  is_popular, sort_order, is_active
) values
  ('pln_dia','pase-del-dia','Pase del día','Day pass',
   'Un día de entrenamiento','One training day',
   null, null, 'session',
   array['Acceso por un día','Máquinas y pesas libres'],
   array['One-day access','Machines and free weights'],
   false, 2, true),
  ('pln_semana','gimnasio-semanal','Gimnasio semanal','Weekly gym',
   'Una semana completa','One full week',
   null, null, 'week',
   array['Acceso por 7 días','Máquinas y pesas libres'],
   array['7-day access','Machines and free weights'],
   false, 3, true),
  ('pln_quincena','gimnasio-quincenal','Gimnasio quincenal','15-day gym',
   'Quince días completos','Fifteen full days',
   null, null, 'fortnight',
   array['Acceso por 15 días','Máquinas y pesas libres'],
   array['15-day access','Machines and free weights'],
   false, 4, true),
  ('pln_mes','gimnasio-mensual','Gimnasio mensual','Monthly gym',
   'El mes completo','The whole month',
   null, null, 'month',
   array['Acceso por 30 días','Máquinas y pesas libres'],
   array['30-day access','Machines and free weights'],
   true, 5, true)
on conflict (id) do nothing;

-- Precios del gimnasio nuevo (en córdobas), cuando el dueño los pase.
-- Reemplazar cada <<...>> por el número y quitar los «--»:
-- update public.plans set price_nio = <<DÍA>>     where slug = 'pase-del-dia';
-- update public.plans set price_nio = <<SEMANA>>  where slug = 'gimnasio-semanal';
-- update public.plans set price_nio = <<QUINCENA>> where slug = 'gimnasio-quincenal';
-- update public.plans set price_nio = <<MES>>     where slug = 'gimnasio-mensual';

select slug, name_es, price_nio, period, is_active from public.plans order by sort_order;


-- ------------------------------------------------------------
--  4 · CATEGORÍAS DE CLIENTE (sólo mirar)
-- ------------------------------------------------------------
--  Las reglas vienen de fábrica y se editan desde el panel.
--  El NOMBRE VISIBLE no está en la base: está en el código,
--  en src/components/admin/category-rules.tsx.
--  La clave interna (strong_gym) se deja igual a propósito:
--  renombrarla obliga a tocar 82 migraciones y no aporta nada.

select category, sort_order, is_active, requires_validity, forbids_validity,
       validity_days_min, visits_min, visits_window_days
  from public.category_rules order by sort_order;


-- ------------------------------------------------------------
--  5 · LO QUE NO VA ACÁ
-- ------------------------------------------------------------
--  · Socios, cobros, reservas y mediciones NO se cargan por SQL:
--    se crean desde la app para que la bitácora quede bien.
--  · Disciplinas y horarios: panel → Planes y modalidades,
--    Horarios y clases. Nada se borra, todo queda en bitácora.
--  · La biblioteca de ejercicios: se descarga con el botón de
--    administración (pide 2FA). No vive en la base ni en el repo.
-- ============================================================
