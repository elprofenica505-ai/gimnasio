# Efectivo recibido y vuelto en abonos

## Aclaración del usuario

El rechazo de excedentes corresponde al **importe aplicado a la deuda**, no al
billete que entrega el cliente. Si debe60 puede abonar20 entregando100 y recibir
80 de vuelto (deuda40), o abonar60 entregando100 y recibir40 (deuda0). No se aplica
la deuda completa si sólo quiere abonar una parte. No se genera crédito.

## Implementación

- En Deudas y abonos, al elegir abono se puede marcar **Calcular vuelto por
  entrega de efectivo**. Importe aplicado y efectivo recibido separados; cálculo
  en centavos, preview de vuelto/deuda restante/neto y confirmación explícita.
- Sólo cuentas activas `caja_fuerte`, misma moneda. El esquema no clasifica los
  métodos como efectivo/tarjeta: NO se adivina por su nombre. El personal declara
  recepción física con esa casilla y selecciona el método correspondiente.
  Bancos/billeteras quedan fuera del selector en este modo y SQL rechaza usarlos.
- Sin modo efectivo se conserva la operación anterior (pago exacto/no efectivo).
  No se fabrican efectivo recibido ni vuelto para comprobantes históricos.
- `finance_debt_record_with_cash` toma el bloqueo de UUID antes del saldo. Reusa
  el escritor00028 y guarda recibido/vuelto en payload, ledger, comprobante de
  Caja y evento dentro de la misma transacción. Caja/deuda cambian sólo por el
  abono: no se registra ingreso bruto100 seguido de gasto80.
- La cuenta se verifica como caja DESPUÉS de que el escritor base la bloquea;
  no se adquiere un bloqueo de cuenta antes del saldo. Si falla validación o
  enriquecimiento, revierte TODO. No entrega físicamente billetes ni controla
  denominaciones: personal entrega el vuelto mostrado.
- Replay exige mismo UUID/payload/efectivo. Cambiar efectivo recibido no reutiliza
  el intento; rol se verifica otra vez, aun al recuperar un recibo confirmado.
- SessionStorage conserva el recibido; reintento/remontaje tras respuesta perdida
  recupera el mismo recibo, sin repetir dinero ni reducción de deuda. No supone
  recuperación automática en otro dispositivo ni confirma entrega física de vuelto.
- Comprobante/PDF/ledger muestran efectivo, vuelto y abono neto guardados.
  Se corrigió el pie contradictorio de abonos: sí reducen deuda, sin netear crédito
  o monedas ni renovar planes. Históricos sin efectivo no inventan esos datos.

## Instalación pendiente

Ejecutar sólo `supabase/VUELTO-ABONOS.sql` completo, después de00028 ya instalado.
No repetir00028/COBROS-GASTOS/FASE2/SETUP: podrían reemplazar lectores nuevos.
La migración no agrega operaciones, saldos ni ejemplos. Es reaplicable sin cambios
sobre los registros. Se anuncia capacidad `cash-v1` en el lector; antes de instalar
la casilla está deshabilitada con aviso, sin éxito simulado ni fallback de escritura.
No hay migración automática ni modificación de cobros/abonos existentes.

## Evidencia remota aportada por el usuario antes de este cambio

FICHA FICTICIA Cliente EJEMPLO, no cliente real del dueño:
- Apertura0/0/0/0, referencia SD-196dc579-4bcb-469b-b54f-b651c03fc212.
- Cargo100 NIO, referencia SD-57b3f4ec-f42b-4627-a923-e239b2c90b3c.
- Abono40 NIO, SG-344483e5-9b86-42f3-9548-87a7bd7edaee,
  request6b553ad5-f4eb-4104-8a94-d6a1fd923323. Caja EJEMPLO NIO6→46, deuda100→60;
  ingresos hoy50→90, egresos4. Comprobante capturado con snapshots correctos.
- Intento80 frente a deuda60 rechazado en FORMULARIO (no prueba SQL remota).
- Usuario informó ejecución exitosa de00028; esos controles/capturas acreditan
  lectura/apertura/cargo/abono real en Supabase, no todas las ramas del sistema.

Próximo paso: instalar este incremental, verificar lectura y hacer con el usuario
una prueba ficticia de abonar20 entregando100: vuelto80, deuda60→40, cuenta46→66,
siempre que no haya habido otros movimientos. NO asumir prueba ya ejecutada.
No ejecutar pagos, limpieza, saldos reales, transferencias de administrador ni merge.

## Pruebas añadidas

PGlite incluye instalación repetida intacta, ambos ejemplos, pago exacto, USD,
ficha sin login, exceso de abono rechazado aunque recibido lo cubra, insuficiencia,
precisión/límites, cuenta bancaria, método, permisos, rol retirado al replay,
conflicto por cambiar efectivo, y fallo del último evento que revierte todo.
React/API y SSR: preview, confirmación/cancelación, payload explícito, referencia
persistida, recibo incoherente rechazado y pie de comprobante corregido.
PostgreSQL real: contención UUID/exceso/rollback y pérdida de respuesta después del
COMMIT, remontaje y recibo inmutable. Es local, no HTTP Next ni Supabase remoto.
Chromium CI agrega comprobante con vuelto como novena pantalla (3 fixtures/8 anchos);
no acredita por sí solo el formulario interactivo nuevo en celular real.

### Resultado local de esta entrega

`typecheck` exit0; `lint`0 errores/10 advertencias base; `build`40/40;
`test:auth`438/438; `test:sql` conserva suites previas y95 controles de deudas
(28 añadidos). PostgreSQL18.4:13 contención +13 recuperación UI/API/SQL
(3 nuevos en cada grupo). SQL generado/diff check correctos. Servidor PG local
apagado, datos de pruebas retirados. Ninguna operación remota del agente.
