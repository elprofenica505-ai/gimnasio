-- OPCIONAL — SEMILLA VACIADA.
-- Acá se insertaban seis fichas ficticias («Ejemplo · …», is_demo = true)
-- con visitas simuladas para probar FASE 2. Un gimnasio nuevo arranca sin
-- clientes, ni siquiera ficticios: las fichas reales se crean desde el
-- panel (Recepción → Clientes) y las pruebas SQL fabrican sus propios
-- datos de ejemplo dentro de cada suite.
-- Correr este archivo no produce ningún efecto; es idempotente.
begin;
-- Nada que sembrar: la instalación queda vacía a propósito.
commit;
