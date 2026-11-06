-- ============================================================
--  Catálogo base para PRUEBAS (FIXTURE — no es una migración)
-- ============================================================
--  Reemplaza a 00002_seed.sql dentro de las suites PGlite: los
--  mismos ids estables que las pruebas referencian, con textos
--  neutros y SIN clases programadas.
--
--    · classes: cls_musculacion, cls_boxeo, cls_zumba
--    · plans:   pln_boxeo, pln_gimnasio, pln_dia
--
--  Este archivo no entra en SETUP.sql, ACTUALIZAR.sql ni
--  INSTALAR-BASE.sql: es sólo material de prueba. El catálogo real
--  del gimnasio se carga desde el panel de administración.
--
--  Las sesiones NO se siembran acá: cada suite crea las que
--  necesita, así las cuentas de clases generadas no se contaminan.
--
--  Idempotente: se puede aplicar varias veces sin duplicar.
-- ============================================================

insert into public.classes
  (id, slug, name_es, name_en, description_es, description_en,
   intensity, duration_min, capacity, color, sort_order)
values
  ('cls_musculacion', 'musculacion', 'Pesas y máquinas', 'Weights & Machines',
   'Disciplina de prueba (fixture).',
   'Test discipline (fixture).',
   'medium', 60, 40, '#404040', 1),

  ('cls_boxeo', 'boxeo', 'Boxeo', 'Boxing',
   'Disciplina de prueba (fixture).',
   'Test discipline (fixture).',
   'high', 60, 20, '#505050', 2),

  ('cls_zumba', 'zumba', 'Zumba', 'Zumba',
   'Disciplina de prueba (fixture).',
   'Test discipline (fixture).',
   'medium', 60, 30, '#606060', 3)
on conflict (id) do update set
  slug = excluded.slug,
  name_es = excluded.name_es,
  name_en = excluded.name_en,
  description_es = excluded.description_es,
  description_en = excluded.description_en,
  intensity = excluded.intensity,
  duration_min = excluded.duration_min,
  capacity = excluded.capacity,
  color = excluded.color,
  sort_order = excluded.sort_order,
  is_active = true;

-- price = NULL = «a consultar». Las tarifas NIO de prueba las
-- completan las migraciones 00057/00058 cuando la suite las aplica
-- (40 / 150 / 280 / 560), igual que en la cadena real.
insert into public.plans
  (id, slug, name_es, name_en, tagline_es, tagline_en, price, period,
   features_es, features_en, is_popular, sort_order)
values
  ('pln_boxeo', 'boxeo', 'Boxeo', 'Boxing',
   'Plan de prueba (fixture)', 'Test plan (fixture)',
   20, 'month',
   array['Plan de prueba'],
   array['Test plan'],
   true, 1),

  ('pln_gimnasio', 'gimnasio-mensual', 'Gimnasio mensual', 'Monthly Gym',
   'Plan de prueba (fixture)', 'Test plan (fixture)',
   null, 'month',
   array['Plan de prueba'],
   array['Test plan'],
   false, 2),

  ('pln_dia', 'pase-del-dia', 'Pase del día', 'Day Pass',
   'Plan de prueba (fixture)', 'Test plan (fixture)',
   null, 'session',
   array['Plan de prueba'],
   array['Test plan'],
   false, 3)
on conflict (id) do update set
  slug = excluded.slug,
  name_es = excluded.name_es,
  name_en = excluded.name_en,
  tagline_es = excluded.tagline_es,
  tagline_en = excluded.tagline_en,
  price = excluded.price,
  period = excluded.period,
  features_es = excluded.features_es,
  features_en = excluded.features_en,
  is_popular = excluded.is_popular,
  sort_order = excluded.sort_order,
  is_active = true;
