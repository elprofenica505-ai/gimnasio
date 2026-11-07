# Finanzas de la ficha: saldo registrado y cobros no son lo mismo

## Alcance de esta entrega

C.2 (lectura y conciliación): reemplaza sólo `crm_detail(uuid)` con su control
staff/admin y búsqueda de ficha preexistentes. No toca writers, tablas, triggers,
RLS, asociaciones de perfiles, datos de negocio ni reglas de deuda/vigencia.
Conserva el mecanismo preexistente de carnet `crm_get_card` (puede crear un carnet
si faltaba; no es una escritura financiera). No carga ejemplos remotos.

No implementa todavía cargos, abonos, anticipos, devoluciones ni saldos iniciales.
No convierte cobros por servicio en pagos de deuda o renovaciones. Esa parte del
producto continúa pendiente; falta conciliación y reglas explícitas del negocio.

## Problemas corregidos

- Antes se distinguía genéricamente saldo `null`, pero se usaba `Number` sin
  validar las cuatro cifras de crédito/deuda: `null` podía dibujarse como cero,
  texto inválido como NaN. Ahora se valida sin coerción, junto a identidad,
  estructura, versión, estado y consistencia de valores/totales.
- Una cuenta web vinculada sin fila en `member_balances` es `missing`; no se crea
  fila ni se reconstruye a partir de cobros. Una ficha sin cuenta es `unlinked`.
  Una fila real con ceros es `ready` y se muestra como tal. Una estructura no
  reconocida es `unsupported`, con totales desconocidos, no ceros.
- En `bank_accounts_split` se leen los cuatro valores originales por separado,
  sin compensación o conversión. En `repository` se indica explícitamente que
  es un saldo neto legado NIO; no se inventa una separación o cifra USD.
- El historial antes no filtraba direction/type y podía llamar «cobro» a un egreso.
  Ahora sólo incluye ingresos. El vínculo `client_id` explícito prevalece: un
  movimiento con otra ficha no se atribuye además al perfil de esta ficha.
  El fallback por `member_id` sólo se usa cuando no hay `client_id`.
- Nuevos totales en moneda original de ingresos **completed**, sobre todos los
  registros vinculados, no sólo las últimas40 filas. Excluyen egresos y estados
  pending/cancelled/reversed. No se suman NIO y USD ni sus equivalentes FX.
- Lista con límite40 y orden fecha/ID; estados traducidos y fechas Managua.
  Importes/monedas/fechas inválidos se señalan, no se convierten en cifras ficticias.
- Lectura obsoleta/carga/error se muestran como no confirmados, ocultando cifras
  financieras antiguas. No se bloquea recepción por un saldo financiero ilegible.
  Reintentar saldo usa sólo GET de la misma ficha, sin crear otra o cobrar.

## Instalación manual

Ejecutar **sólo `supabase/SALDO-CLIENTE.sql`**, equivalente a00027, en Supabase SQL
Editor. Requiere FASE2/compatibilidad ya instaladas en este proyecto. Transacción
idempotente, conserva permisos autenticados con guard de staff dentro del RPC y
notifica recarga a PostgREST. No ejecutar SETUP/ACTUALIZAR/FASE2 otra vez.

El agente no ha ejecutado este SQL remoto. Si aún está instalada la función vieja,
la sección financiera muestra `CRM_FINANCE_READ_UNCONFIRMED`; no simula ceros.
El resto de la ficha sigue disponible. El despliegue web no instala SQL remoto.

## Validación remota pendiente

1. Instalar el SQL incremental y esperar Success sin filas.
2. En preview, administrador → Clientes → buscar Cliente EJEMPLO → abrir su ficha.
3. Revisar el bloque nuevo «Saldo y cobros del cliente». Si informa `missing`,
   significa que no hay fila de saldo para el perfil vinculado; no que esté al día.
   No cambiar perfil, crear saldo cero ni hacer otro cobro para ocultarlo.
4. Verificar historial de ingresos frente a movimientos/comprobantes ya existentes,
   con sus monedas originales y estados. No se predice un importe sin comprobar
   cuáles están asociados a esta ficha.
5. Compartir captura de ese bloque. No repetir reservas, planes, entradas ni cobros.

Cliente EJEMPLO es la cuenta/ficha de prueba del usuario, no cliente real del dueño.
PR10 sigue sin merge; no limpieza, cambios de administrador ni importación real.

## Evidencia local

`scripts/test-client-finance-sql.mjs`:54 comprobaciones PGlite en repository y
bank_accounts_split. Dos instalaciones sin alterar datos/writers; distinción
unlinked/missing/ready/unsupported; valores/cero reales;45 cobros NIO más ingreso
legado superan el límite40; USD original; pendientes/revertidos/cancelados,
egresos y vínculos ajenos no inflan totales; lectura sin alterar cuentas/saldos;
permisos staff/admin, miembro/otro/anónimo/sin identidad/rol retirado. Incluye
cobro por servicio y reintento idempotente después del cambio: cuenta aumenta una
vez, total aumenta una vez, saldo faltante no se crea. Sólo bases desechables.

Pruebas React/contrato validan separación de cuatro valores, metadatos de identidad,
ceros explícitos, ausencia, estructura legada/desconocida, null/texto/NaN/infinito,
no mostrar cifras mientras carga o al fallar, reintento GET, recepción disponible,
estados y fecha Managua. No sustituyen Supabase/PostgREST real.

El runner de diseño incluye el bloque real de saldo/historial como séptima
pantalla con tres fixtures y ocho anchos (320–1280px). Es SSR con CSS de producción,
no certifica hidratación ni operaciones remotas.

### Salidas reales locales

```text
npm run typecheck
> tsc --noEmit
(exit 0)
npm run lint
✖ 10 problems (0 errors, 10 warnings)
(exit 0)
npm run build
✓ Compiled successfully in 710ms
✓ Generating static pages using 1 worker (40/40) in 199ms
(exit 0)
npm run test:auth
# tests 390
# pass 390
# fail 0
(exit 0)
npm run test:sql
🎉 Todo pasó
🎉 CRM: 49 comprobaciones pasaron
🎉 Compatibilidad CRM: 69 comprobaciones pasaron
🎉 Escritura financiera: 86 comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)
🎉 Plan propio: 22 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
🎉 Lectura de reservas: 42 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
🎉 Finanzas de ficha: 54 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
(exit 0)
```

Logs `/home/user/client-finance-{auth,typecheck,lint,build,sql}.log`; pruebas
focalizadas en `client-finance-targeted-{sql,browser}.log`. No HTTP/Supabase real.
Diseño responsive nuevo queda sujeto al runner Chromium de CI; no se ejecutó
Chromium local por no estar instalado en este workspace.
