-- ============================================================
--  SEMILLA FINANCIERA GENÉRICA PARA EL ESQUEMA SPLIT
-- ============================================================
--  ARTEFACTO DE INSTALACIÓN (no es una migración numerada).
--  `scripts/build-install-sql.mjs` lo intercala en INSTALAR-BASE.sql
--  EN LUGAR de `00011_finance_seed.sql`, cuya siembra está escrita
--  para las columnas del modelo «repository» (slug/kind/name_es/
--  accepts_nio/icon…) y no encaja en las tablas split que crea
--  00010-esquema-financiero-split.sql.
--
--  Contenido: el MISMO catálogo genérico que conserva el 00011
--  sanitizado (10 métodos de pago y 11 categorías de gasto), con
--  tres adaptaciones al modelo split [CÓDIGO]:
--    · payment_methods: (id, name, currency, fee_pct, is_active,
--      display_order). `currency` sale de mapear accepts_nio/
--      accepts_usd del seed repository (ambas → BOTH). No existen
--      las columnas details/icon/slug: finance_read (00023) deriva
--      slug e icono desde el id para la web. fee_pct arranca en 0 y
--      se edita en el panel.
--    · expense_categories: (id, name, color, budget_monthly,
--      display_order). `name` es el name_es del seed repository;
--      color y presupuesto quedan en sus defaults (se editan en el
--      panel; 00095 trae el RPC del catálogo).
--    · Sin §0 de tipo de cambio: el 00011 repository hacía
--      set_config('app.fx_nio_per_usd') con alcance de SESIÓN y no
--      existe ningún consumidor de ese GUC en la cadena ni en la
--      web. En el modelo split el cambio viaja por movimiento
--      (transactions.fx_used) y por parámetro (00029, 00096).
--
--  Lo que NO hay acá (y en el 00011 repository está ANULADO):
--  cuentas del gimnasio, entrenadores, transacciones de ejemplo y
--  apertura de caja. Las cuentas se crean en PERSONALIZAR-GIMNASIO.sql
--  (las dos cajas) y en el panel (bancos y billeteras, vía 00095).
--
--  Idempotente: se puede volver a correr sin duplicar.
-- ============================================================


-- ------------------------------------------------------------
--  1. Métodos de pago genéricos
-- ------------------------------------------------------------
insert into public.payment_methods
  (id, name, currency, fee_pct, is_active, display_order)
values
  ('pm_cash_nio',   'Efectivo (C$)',          'NIO',  0, true,  1),
  ('pm_cash_usd',   'Efectivo (US$)',         'USD',  0, true,  2),
  ('pm_bac_nio',    'Transferencia BAC NIO',  'NIO',  0, true,  3),
  ('pm_bac_usd',    'Transferencia BAC USD',  'USD',  0, true,  4),
  ('pm_lafi_nio',   'Transferencia LAFISE',   'NIO',  0, true,  5),
  ('pm_card_local', 'Tarjeta POS',            'BOTH', 0, true,  6),
  ('pm_sinpe',      'SINPE Móvil',            'NIO',  0, true,  7),
  ('pm_tigo_money', 'Tigo Money',             'NIO',  0, true,  8),
  ('pm_claro_pay',  'Claro Pay',              'NIO',  0, true,  9),
  ('pm_crypto',     'Cripto (USDT)',          'USD',  0, true, 10)
on conflict (id) do update set
  name          = excluded.name,
  currency      = excluded.currency,
  display_order = excluded.display_order,
  is_active     = true;


-- ------------------------------------------------------------
--  2. Categorías de gasto genéricas
-- ------------------------------------------------------------
insert into public.expense_categories
  (id, name, display_order)
values
  ('exp_rent',        'Alquiler del local',       1),
  ('exp_electricity', 'Servicio eléctrico',       2),
  ('exp_water',       'Agua potable',             3),
  ('exp_internet',    'Internet y cable',         4),
  ('exp_coaches',     'Sueldos de coaches',       5),
  ('exp_cleaning',    'Artículos de limpieza',    6),
  ('exp_equipment',   'Mantenimiento equipos',    7),
  ('exp_supplements', 'Compra de suplementos',    8),
  ('exp_marketing',   'Marketing y redes',        9),
  ('exp_tax',         'Impuestos y tasas',       10),
  ('exp_misc',        'Otros gastos',            99)
on conflict (id) do update set
  name          = excluded.name,
  display_order = excluded.display_order;
