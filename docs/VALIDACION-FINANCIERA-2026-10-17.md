# Validación financiera — 17 de octubre de 2026

## Alcance y evidencia remota

Pruebas realizadas por el usuario en el preview de la rama, contra Supabase real.
El agente no ejecutó operaciones financieras remotas. Cliente EJEMPLO es una cuenta/ficha
de prueba del usuario; no es una cliente real del dueño. La tasa 40 es ficticia.

- Cobro NIO10, cuenta EJEMPLO - Caja NIO, saldo 0 → 10.
  Comprobante SG-e0e448a0-9ca3-42c5-960d-9647294beb2d.
- Gasto NIO4, misma cuenta, Misceláneos, saldo 10 → 6.
  Comprobante SG-9ca113fb-fa2e-4e8f-babe-0de25395a1d9.
- Cobro USD1, cuenta EJEMPLO - Caja USD, saldo USD0 → 1.
  Comprobante SG-13b26579-109e-4482-a997-df12bb5e8fb6.
  La cuenta NIO permanece en 6; el equivalente NIO40 no es un abono a esa cuenta.
- El usuario confirmó que Caja y Gastos, por enlace directo como Cliente EJEMPLO,
  redirigen a Mi cuenta sin mostrar panel ni datos administrativos.
- Capturas de consultas como Cliente EJEMPLO a `/api/admin/finance` y a
  `?receipt=9ca113fb-fa2e-4e8f-babe-0de25395a1d9` muestran
  `{"error":"No tenés acceso a movimientos financieros."}`.
  Las capturas prueban el cuerpo de rechazo, no documentan el código HTTP.
- El usuario confirmó actualización del historial «Últimos 50 comprobantes del
  nuevo registro», apertura del gasto original y saldos guardados 10 → 6.
  Esto prueba lectura posterior, no un reintento de escritura tras fallo de red.

## Refuerzo automatizado local de esta continuación

Se añadieron siete casos API/formulario y cuatro comprobaciones SQL:

- Consultas de recibos e historiales y escritura de gastos rechazadas antes del RPC
  para anónimo, member y roles no admitidos, incluso con UUID conocido y campos
  de rol/autor manipulados. Respuestas de lectura privadas y sin caché.
- Rol retirado entre envío y reintento: la API no vuelve a invocar el writer.
- Formulario con intento pendiente y respuesta 403: conserva el payload original,
  no ofrece comprobante ni anuncia confirmación, y no habilita un intento nuevo.
- SQL real en PGlite con rol retirado: reintento y recibo rechazados, sin cambios
  en saldo/transacción/evento. Al restaurar el rol, el mismo UUID recupera el
  comprobante original sin duplicar.
- Se volvieron a ejecutar los casos existentes de doble envío, pérdida de
  respuesta, recarga, igualdad del payload, conflicto y rollback.

No se modificó la lógica productiva, el SQL de instalación ni la base remota.

## Salidas reales de esta ejecución

Todos los comandos siguientes terminaron con código 0:

```text
npm run typecheck
> tsc --noEmit

npm run lint
✖ 10 problems (0 errors, 10 warnings)

npm run build
✓ Compiled successfully in 13.8s
✓ Generating static pages using 1 worker (40/40) in 233ms

npm run test:auth
# tests 301
# pass 301
# fail 0

npm run test:sql
🎉 Todo pasó
🎉 CRM: 49 comprobaciones pasaron
🎉 Compatibilidad CRM: 69 comprobaciones pasaron
🎉 Escritura financiera: 86 comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)
```

Prueba dirigida de API/formulario: 49 tests, 49 pass, 0 fail.
Logs de esta ejecución: `/home/user/finance-followup-{targeted,auth,sql,typecheck,lint,build}.log`.
Las diez advertencias de lint no se silenciaron. No se ejecutó un audit nuevo.

## Pendientes y límites

- Escritura rechazada directamente por API/SQL bajo identidad de cliente en
  Supabase remoto: aún no acreditada; las pruebas remotas de lectura no la sustituyen.
- Reintento remoto tras respuesta perdida: pendiente. La contención entre
  conexiones ya se probó en PostgreSQL local (véase abajo), no en Supabase remoto.
- Falta el resto de aceptación integral del producto. No declarar módulo completo
  ni producto listo sólo por las pruebas locales y estos recorridos remotos.
- No repetir COBROS-GASTOS.sql: el usuario ya lo instaló correctamente.
- Sin merge, sin borrado de ficticios, sin cambios de roles ni movimientos remotos.

## Concurrencia PostgreSQL local (continuación)

Se añadió `npm run test:finance:concurrency`. Usa `pg` sólo como dependencia de
pruebas y tres conexiones independientes a PostgreSQL. No sustituye el fixture
por un writer simulado: instala las migraciones y llama al RPC real bajo el rol
`authenticated`. La identidad se configura por sesión/transacción.

La prueba espera observar `pg_blocking_pids` antes de liberar el COMMIT/ROLLBACK;
no asume que `Promise.all` por sí solo demuestra concurrencia. Comprueba:

1. UUID idéntico simultáneo: el segundo espera y obtiene el mismo comprobante.
2. Sólo un abono, una transacción, un snapshot y un evento de cliente.
3. UUID idéntico con monto diferente: conflicto sin segundo abono.
4. UUID distintos sobre la misma cuenta: snapshots encadenados y ningún saldo perdido.
5. ROLLBACK del primero: el segundo completa la operación, sin residuos del anterior.
6. Cambio de rol concurrente: espera el bloqueo del perfil del writer; tras retirar
   el rol, el reintento se rechaza.

Ejecutado en PostgreSQL **18.4** local: primera ejecución y tres repeticiones
adicionales, todas con las seis comprobaciones aprobadas en bases nuevas.

```text
PostgreSQL 18.4, tres conexiones independientes, base local desechable.
🎉 Concurrencia PostgreSQL: 6 comprobaciones pasaron. No se accedió a Supabase.
```

El runner rechaza hosts fuera de loopback, parámetros URL que puedan sobrescribir
el host, nombres de base fuera de `strong_gym_test*` y bases que ya contengan tablas
públicas. Se verificaron los cuatro rechazos. No borra ni reinstala una base existente.
Requiere una instancia local de pruebas y una base nueva por ejecución; por ejemplo:

```sh
createdb strong_gym_test_concurrency
TEST_POSTGRES_URL=postgresql://postgres@127.0.0.1:5432/strong_gym_test_concurrency npm run test:finance:concurrency
```

CI incorpora un job independiente con un servicio desechable PostgreSQL **17**;
ese resultado no se da por aprobado antes de que termine GitHub Actions.
No se incluyen los binarios ni los archivos de la base local en el repositorio.

Se repitieron también typecheck (exit 0), lint (0 errores/10 advertencias), build
(40/40 páginas, compilación 2.2s), auth (301/301) y SQL (49/69/86 más base), todos
con código 0. Los nuevos logs están en `/home/user/finance-concurrency-*.log`.


## Recuperación integrada después del COMMIT (continuación posterior)

El runner de concurrencia ahora ejecuta también siete comprobaciones de
recuperación usando `tests/helpers/finance-recovery.mjs`:

- Renderiza `MovementForm` real con React/JSDOM y carga GET/POST reales de la API.
- Sólo sustituye las fronteras de Next/Supabase: consulta el rol real en profiles
  y transporta cada RPC a las funciones SQL reales, bajo `authenticated`, en una
  conexión PostgreSQL separada con transacción e identidad local.
- Envía un gasto NIO4 (cuenta local inicial10) y un cobro USD1 (cuenta local inicial0),
  ambos FX40 ficticia. Cada primer envío hace COMMIT y **después** se pierde la
  respuesta antes de llegar al formulario. No es sólo un mock que lanza error sin guardar.
- Comprueba saldo, transacción, snapshot y evento persistidos; no aparece éxito
  falso y la referencia completa permanece en sessionStorage.
- Desmonta/remonta el formulario conservando la pestaña: el historial recupera
  el comprobante, y el reintento envía el mismo UUID/payload. Se obtiene el mismo
  recibo y no cambian por segunda vez saldo, conteos ni eventos.
- Consulta el recibo por API y contrasta snapshots 10→6 y 0→1, equivalentes
  NIO4/USD0.1000 y NIO40/USD1, respectivamente.
- Retira el rol en profiles local y comprueba POST403 antes del RPC y sin cambios.

**Límites:** no se ejecuta Next por HTTP, PostgREST, cookies de Supabase ni un
navegador Chromium. El remontaje conserva sessionStorage: no demuestra recuperar
un pendiente tras cerrar la pestaña/borrar su almacenamiento. No hubo operaciones
ni SQL ejecutados en Supabase remoto. El caso remoto sigue pendiente.

### Corrección productiva descubierta

Tras un movimiento exitoso, un segundo envío con resultado incierto podía dejar
visible el enlace «Abrir comprobante interno» del movimiento anterior. No alteraba
el saldo, pero podía confundir el resultado del segundo intento. Ahora se limpia
ese enlace al comenzar cada envío. El historial sigue disponible para consultar
los comprobantes previos.

Se añadió una regresión que falla sin la corrección y pasa con ella: primer envío
exitoso → segundo envío con respuesta perdida → no aparece el recibo anterior ni
un mensaje de confirmación, y se conserva el nuevo intento pendiente. El cambio
no modifica el SQL instalado ni exige migración.

### Salidas reales de esta continuación

```text
npm run typecheck
> tsc --noEmit
(exit 0)

npm run lint
✖ 10 problems (0 errors, 10 warnings)
(exit 0)

npm run build
✓ Compiled successfully in 26.8s
✓ Generating static pages using 1 worker (40/40) in 189ms
(exit 0)

npm run test:auth
# tests 302
# pass 302
# fail 0
(exit 0)

npm run test:sql
🎉 Todo pasó
🎉 CRM: 49 comprobaciones pasaron
🎉 Compatibilidad CRM: 69 comprobaciones pasaron
🎉 Escritura financiera: 86 comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)
(exit 0)

npm run test:finance:concurrency
PostgreSQL 18.4, tres conexiones independientes, base local desechable.
🎉 Concurrencia PostgreSQL: 6 comprobaciones pasaron. No se accedió a Supabase.
🎉 Recuperación UI/API/SQL: 7 comprobaciones pasaron (JSDOM + PostgreSQL local, sin Supabase remoto).
(exit 0)
```

Logs: `/home/user/recovery-{integration,form,auth,sql,typecheck,lint,build}.log`.
La prueba integrada no produjo advertencias de React act en su ejecución final.
El job CI conserva PostgreSQL17 y ejecuta también la recuperación; consultar el
resultado del commit correspondiente, no extrapolar el CI del commit anterior.
