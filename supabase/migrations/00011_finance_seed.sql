-- ============================================================
--  FASE 1: Catálogo base (sin datos de ejemplo)
-- ============================================================
--  De la migración original se conservan SÓLO dos bloques genéricos:
--    · los métodos de pago (efectivo, transferencia, tarjeta, billetera)
--    · las categorías de gasto (alquiler, luz, agua, salarios…)
--
--  ANULADO (antes venía acá y eran datos del gimnasio anterior):
--    · las cuentas bancarias y billeteras con sus números reales
--    · los entrenadores con nombre y biografía
--    · las transacciones de ejemplo del mes
--    · la apertura de caja inicial
--
--  Las cuentas reales se agregan en Administración → Dinero; las
--  dos cajas de efectivo las crea supabase/PERSONALIZAR-GIMNASIO.sql.
--
--  Es SEGURO correrlo varias veces: usa ON CONFLICT e ids estables.
--
--  TIPO DE CAMBIO (configurable): 1 USD = 36.5 NIO (Banco Central de
--  Nicaragua, precio de venta aprox. a 2026). Si cambia, actualizá el
--  valor abajo y se recalcula todo.
-- ============================================================


-- ------------------------------------------------------------
--  0. TIPO DE CAMBIO
-- ------------------------------------------------------------
--  Si tu contador te pasa un valor distinto, cambialo acá y se
--  recalculan las conversiones en las transacciones existentes.
do $$
declare
  v_fx numeric(12,4) := 36.50;  -- 1 USD = 36.50 NIO
begin
  perform set_config('app.fx_nio_per_usd', v_fx::text, false);
end $$;


-- ------------------------------------------------------------
--  1. MÉTODOS DE PAGO
-- ------------------------------------------------------------
--  Catálogo genérico de lo que un gimnasio en Nicaragua puede
--  aceptar. Los números de cuenta NO vienen acá: cada gimnasio
--  configura los suyos en Administración → Dinero.

insert into public.payment_methods
  (id, slug, kind, name_es, name_en, details_es, details_en,
   accepts_nio, accepts_usd, icon, sort_order)
values
  ('pm_cash_nio',  'efectivo-cordobas', 'cash',          'Efectivo (C$)',       'Cash (NIO)',
   'Pago en efectivo en la recepción, en córdobas.',
   'Cash payment at the front desk, in córdobas.',
   true,  false, 'Banknote', 1),

  ('pm_cash_usd',  'efectivo-dolares', 'cash',          'Efectivo (US$)',      'Cash (USD)',
   'Pago en efectivo en la recepción, en dólares.',
   'Cash payment at the front desk, in US dollars.',
   false, true,  'DollarSign', 2),

  ('pm_bac_nio',   'transferencia-bac', 'bank_transfer', 'Transferencia BAC NIO','Bank transfer (BAC, NIO)',
   'Transferencia bancaria en córdobas · configurá tu cuenta en Administración → Dinero',
   'Bank transfer in córdobas · set your account in Admin → Money',
   true,  false, 'Building2', 3),

  ('pm_bac_usd',   'transferencia-bac-usd', 'bank_transfer', 'Transferencia BAC USD','Bank transfer (BAC, USD)',
   'Transferencia bancaria en dólares · configurá tu cuenta en Administración → Dinero',
   'Bank transfer in US dollars · set your account in Admin → Money',
   false, true,  'Building2', 4),

  ('pm_lafi_nio',  'transferencia-lafise', 'bank_transfer', 'Transferencia LAFISE', 'Bank transfer (LAFISE)',
   'Transferencia bancaria · configurá el número de cuenta en Administración → Dinero',
   'Bank transfer · set the account number in Admin → Money',
   true,  false, 'Building2', 5),

  ('pm_card_local','tarjeta-pos', 'debit_card',   'Tarjeta POS',          'Card (POS)',
   'Débito y crédito Visa / MasterCard en la terminal del local.',
   'Debit and credit Visa / MasterCard at the in-store terminal.',
   true,  true,  'CreditCard', 6),

  ('pm_sinpe',     'sinpe-movil',  'sinpe_movil',   'SINPE Móvil',          'SINPE Móvil',
   'Transferencia inmediata · configurá el número en Administración → Dinero',
   'Instant bank transfer · set the number in Admin → Money',
   true,  false, 'Smartphone', 7),

  ('pm_tigo_money','tigo-money',   'mobile_wallet', 'Tigo Money',           'Tigo Money',
   'Billetera móvil · configurá el número en Administración → Dinero',
   'Mobile wallet · set the number in Admin → Money',
   true,  false, 'Wallet', 8),

  ('pm_claro_pay', 'claro-pay',    'mobile_wallet', 'Claro Pay',            'Claro Pay',
   'Billetera móvil · configurá el número en Administración → Dinero',
   'Mobile wallet · set the number in Admin → Money',
   true,  false, 'Wallet', 9),

  ('pm_crypto',    'cripto-usdt',  'crypto',        'Cripto (USDT)',        'Crypto (USDT)',
   'USDT en red TRC-20 · consultá la wallet en Administración → Dinero',
   'USDT on TRC-20 network · ask for the wallet address in Admin → Money',
   false, true,  'Bitcoin', 10)
on conflict (id) do update set
  name_es = excluded.name_es,
  name_en = excluded.name_en,
  details_es = excluded.details_es,
  details_en = excluded.details_en,
  icon = excluded.icon,
  sort_order = excluded.sort_order;


-- ------------------------------------------------------------
--  2. CATEGORÍAS DE GASTOS
-- ------------------------------------------------------------

insert into public.expense_categories (id, slug, name_es, name_en, icon, sort_order) values
  ('exp_rent',       'alquiler',     'Alquiler del local',  'Rent',              'Home',          1),
  ('exp_electricity','luz',          'Servicio eléctrico',  'Electricity',       'Zap',           2),
  ('exp_water',      'agua',         'Agua potable',        'Water',             'Droplet',       3),
  ('exp_internet',   'internet',     'Internet y cable',    'Internet & cable',  'Wifi',          4),
  ('exp_coaches',    'sueldos-coaches', 'Sueldos de coaches','Coaches payroll',  'Users',         5),
  ('exp_cleaning',   'limpieza',     'Artículos de limpieza','Cleaning supplies','Sparkles',      6),
  ('exp_equipment',  'mantenimiento','Mantenimiento equipos','Equipment maintenance','Wrench',    7),
  ('exp_supplements','compra-suplementos','Compra de suplementos','Supplements restock','Package',8),
  ('exp_marketing',  'marketing',    'Marketing y redes',   'Marketing & social','Megaphone',     9),
  ('exp_tax',        'impuestos',    'Impuestos y tasas',   'Taxes & fees',      'FileText',     10),
  ('exp_misc',       'varios',       'Otros gastos',        'Other expenses',    'Receipt',      99)
on conflict (id) do update set
  name_es = excluded.name_es,
  name_en = excluded.name_en,
  icon = excluded.icon,
  sort_order = excluded.sort_order;


-- ------------------------------------------------------------
--  3. CUENTAS DEL GIMNASIO
-- ------------------------------------------------------------
--  ANULADO. Acá se insertaban las cuentas del gimnasio anterior:
--  cajas fuertes, cuentas bancarias con su número y titular, y
--  billetera móvil. Una instalación nueva NO hereda cuentas de
--  nadie: las dos cajas de efectivo las crea
--  supabase/PERSONALIZAR-GIMNASIO.sql y los bancos reales se
--  agregan en Administración → Dinero.


-- ------------------------------------------------------------
--  4. COACHES
-- ------------------------------------------------------------
--  ANULADO. Acá se insertaban entrenadores con nombre, biografía
--  y especialidades del gimnasio anterior. Los entrenadores reales
--  se cargan desde el panel (Administración → Entrenadores).


-- ============================================================
--  5. SOCIOS DE EJEMPLO
-- ============================================================
--  ANULADO (la migración original ya no los insertaba; sólo
--  documentaba que vivían en el modo demo). Un gimnasio nuevo
--  arranca sin socios: se registran ellos mismos desde la web.


-- ============================================================
--  6. TRANSACCIONES DE EJEMPLO
-- ============================================================
--  ANULADO. Acá se insertaban los gastos fijos del mes del
--  gimnasio anterior (alquiler, luz, sueldos…). La caja de una
--  instalación nueva arranca en cero y los movimientos reales se
--  registran desde el panel.


-- ------------------------------------------------------------
--  8. APERTURA DE CAJA INICIAL
-- ------------------------------------------------------------
--  ANULADO. La caja se abre el primer día de operación real,
--  desde el panel, con el efectivo que haya en el local.


-- ============================================================
--  FIN DEL ARCHIVO
-- ============================================================
--  Resumen de lo que SÍ carga (todo genérico, sirve para cualquier
--  gimnasio):
--    · 10 métodos de pago (efectivo C$ y US$, transferencias BAC y
--      LAFISE, tarjeta POS, SINPE Móvil, Tigo Money, Claro Pay y
--      cripto USDT) SIN números de cuenta: se configuran en el panel.
--    · 11 categorías de gastos.
--
--  Lo que NO carga (anulado a propósito):
--    · Cuentas bancarias ni billeteras con números reales.
--    · Entrenadores con nombre y biografía.
--    · Transacciones de ejemplo ni apertura de caja.
-- ============================================================
