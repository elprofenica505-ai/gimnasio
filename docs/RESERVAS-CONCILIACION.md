# Reserva no visible en Mi cuenta — 17 oct 2026

## Evidencia y estado

Usuario, sesión de prueba Cliente EJEMPLO, intentó reservar Boxeo del 20 de octubre
2026 a las 06:00–07:00 Managua. Capturas 18:44–18:45 muestran 1/20 y 19 lugares
libres, pero el botón sigue «Reservar» y Mi cuenta muestra cero reservas y ninguna
próxima. **Recorrido no aceptado entonces; la persistencia se confirmó después mediante CSV (véase abajo).**

Antes del CSV, el cambio a 1/20 podía proceder del incremento local del frontend.
No se dio por confirmada la persistencia ni se asumió una causa sin diagnóstico.

No repetir la reserva, no cancelar ni crear otra ficha/cuenta. El agente no ha
reservado ni cancelado nada en Supabase. PR10 sigue abierto sin merge.

## Defectos de interfaz/confirmación encontrados y corregidos

- Antes: cualquier POST HTTP200 era éxito; se ignoraba su cuerpo. Después de
  releer reservas, incluso un fallo/GET vacío permitía devolver `ok:true`.
- Ahora: el RPC y el POST deben devolver un comprobante de reserva con id,
  session_id exacto y estado confirmed. Un RPC vacío/incoherente devuelve
  UNCONFIRMED503 y respuestas privadas/no-store.
- En el contexto del navegador, también debe aparecer el mismo id/sesión/estado
  en la lectura posterior de la cuenta. Un fallo o discrepancia no devuelve éxito:
  conserva datos anteriores como no confirmados y bloquea nuevas mutaciones hasta
  revisar la lectura. Retirar la sesión impide que respuestas tardías afecten a
  otra identidad.
- Una cancelación sólo se confirma al leer su fila como cancelled. Peticiones
  POST/DELETE tienen límite15s; un fallo de transporte es incierto, no éxito.
- Horarios ya no suma/resta ocupación localmente tras la mutación: vuelve a leer
  la ocupación del servidor. Si falla, muestra el error de lectura.
- Mensaje ES/EN UNCONFIRMED: revisar Mi cuenta y no reservar otra vez todavía.

Esto evita una confirmación y contador inventados; **no sustituye reparar la causa
remota que impide ver la reserva**. Tampoco demuestra concurrencia de reservas,
ni cambia sus reglas de cupos, límite3 o cancelación3horas.

## Diagnóstico remoto recibido

`supabase/DIAGNOSTICO-RESERVA.sql` contiene un solo SELECT con UNION ALL:

1. Identidad/rol del correo de prueba conocido, sin tokens ni contraseñas.
2. Sesiones del instante probado, ocupación efectiva y reservas de esa cuenta.
3. Políticas de bookings (incluidas restrictivas si las hay).
4. RLS/forceRLS y SELECT de authenticated.
5. Definiciones y firmas de book_session/cancel_booking.

No ejecuta esas funciones; consulta sus definiciones. No hay INSERT/UPDATE/DELETE,
ni cambios de esquema/permisos. Probado sintácticamente en PGlite: cinco apartados.
Usuario lo ejecutó en SQL Editor y compartió el resultado como CSV.
No repetir SQL de instalación ni aplicar una política abierta para ocultar el fallo.

## Pruebas

API: rechaza RPC nulo, incompleto, con otra sesión o cancelado; conserva referencia
válida. React: POST exitoso + GET vacío, otra id o estado distinto no confirma;
contrato inválido tampoco; POST/GET coincidentes sí confirma y activa reservado;
cancelación conciliada o divergente; UNCONFIRMED bloquea segundo envío. Horarios
se prueba con ocupación autoritativa7/20 tras reservar (no contador local1/20).

Resultados finales y CI del commit se registran en el comentario de PR10. La
comparación remota de plan ya se observó correcta («Gimnasio mensual»); no repetir
PLAN-CUENTA. El aviso de saldo vinculado y el texto «Hoy:06:00» son otros pendientes.

### Salida real local final

```text
npm run typecheck
> tsc --noEmit
(exit 0)
npm run lint
✖ 10 problems (0 errors, 10 warnings)
(exit 0)
npm run build
✓ Compiled successfully in 2.9s
✓ Generating static pages using 1 worker (40/40) in 379ms
(exit 0)
npm run test:auth
# tests 340
# pass 340
# fail 0
(exit 0)
npm run test:sql
🎉 Todo pasó
🎉 CRM: 49 comprobaciones pasaron
🎉 Compatibilidad CRM: 69 comprobaciones pasaron
🎉 Escritura financiera: 86 comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)
🎉 Plan propio: 22 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
(exit 0)
```

Logs: `/home/user/booking-reconcile-{auth,sql,typecheck,lint,build}.log`.


## Causa remota confirmada y reparación de lectura

Archivo recibido: `Supabase Snippet Untitled query (3).csv` (no se añade al Git).

- Identidad de prueba: `34379751-3dc0-4c97-9a4e-4106e9a36bea`, rol member.
- Sesión: `562f35ba-7249-4d23-96d4-48da64daa113`, scheduled, capacidad20,
  20-oct-2026 06:00–07:00 Managua, ocupación real1.
- Reserva: `0fee38d9-1b12-44c2-a79d-f6e63c3d383d`, confirmed, pertenece a esa
  identidad, creada el17-oct a18:44:12 Managua (18-oct00:44:12 UTC).
- `bookings`: RLStrue, forceRLSfalse, authenticated tiene SELECT, **cero políticas**.
- `book_session(text)` es SECURITY DEFINER y escribe usando auth.uid().

El writer pudo guardar con sus permisos de definidor, pero la lectura habitual
bajo authenticated estaba sometida a denegación por defecto de RLS. No era una
reserva de otra cuenta ni había que crear otra. Las funciones del CSV coinciden
con el contrato esperado; no hace falta reemplazarlas para resolver esta lectura.

Migración00026 y `supabase/LECTURA-RESERVAS.sql`:

- Mantiene RLS habilitado y añade una política SELECT para authenticated:
  `user_id = auth.uid() or public.crm_is_staff()`.
- El cliente lee sólo sus filas; admin/staff según profiles pueden consultar las
  reservas. Sin acceso anónimo ni SELECT público.
- No agrega políticas INSERT/UPDATE/DELETE ni cambia book_session/cancel_booking.
- No borra otras políticas existentes. Sólo reemplaza su propia política versionada
  para hacer la instalación idempotente. No puede eliminar restricciones adicionales
  que pudieran existir en otra base.
- No actualiza, duplica ni cancela registros, ni toca dinero, perfiles o planes.
- Se incluye también en los generados para futuras instalaciones; en esta base
  ejecutar **sólo LECTURA-RESERVAS.sql**, no SETUP/FASE2/ACTUALIZAR.

### Comprobación remota pendiente tras instalar

Recargar como Cliente EJEMPLO. Mi cuenta debe recuperar la reserva **original** del20-oct
06:00, con una próxima reserva; Horarios debe mostrar1/20,19libres y «Cancelar
reserva» para esa clase. No reservar de nuevo ni cancelar aún. No se da la
instalación por ejecutada hasta la respuesta del usuario.

### Nuevas pruebas locales

42 comprobaciones PGlite en esquemas repository y bank_accounts_split: reproducen
exactamente RLS sin políticas, RPC que guarda y SELECT vacío; tras aplicar dos veces
la corrección se recupera la misma referencia, no se alteran datos/funciones, hay
privacidad entre dos clientes, acceso staff/admin, retirada de rol, anonimato,
operaciones directas denegadas en ese escenario, cancelación por RPC y liberación
exacta del cupo. También se verifica conservar una política ajena preexistente.

```text
npm run typecheck
> tsc --noEmit
(exit 0)
npm run lint
✖ 10 problems (0 errors, 10 warnings)
(exit 0)
npm run build
✓ Compiled successfully in 2.5s
✓ Generating static pages using 1 worker (40/40) in 781ms
(exit 0)
npm run test:auth
# tests 340
# pass 340
# fail 0
(exit 0)
npm run test:sql
🎉 Todo pasó
🎉 CRM: 49 comprobaciones pasaron
🎉 Compatibilidad CRM: 69 comprobaciones pasaron
🎉 Escritura financiera: 86 comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)
🎉 Plan propio: 22 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
🎉 Lectura de reservas: 42 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
(exit 0)
```

Logs: `/home/user/booking-read-{targeted,sql,auth,typecheck,lint,build}.log`.
No se ejecutó SQL remoto por el agente. No merge ni limpieza.

## Verificación remota y desincronización de Mi cuenta (17-oct-2026)

El usuario envió `Screenshot_20261017-190835.jpg` y `190843.jpg`: la reserva
original aparece en Mi cuenta, confirmada, martes20-oct06:00, una próxima.
Esto comprueba la recuperación de la lectura después de aplicar el SQL de RLS.
La imagen `190929.jpg` es el catálogo público: «20 lugares» representa capacidad
configurada, no disponibilidad de una sesión (etiquetado ambiguo, pendiente).

Después de la cancelación manual guiada, `Screenshot_20261017-192250.jpg` muestra
la misma sesión con0/20 y20libres; `192311.jpg` muestra reserva CANCELADA en
historial y ninguna próxima. La cancelación remota y liberación del cupo están
comprobadas. El usuario reporta que debió recargar para ver el resultado; no hay
evidencia para atribuirlo a su conexión.

### Causa de la pantalla obsoleta y corrección

`AppProvider` conciliaba DELETE con un nuevo GET y actualizaba sus reservas,
pero `AccountDashboard` y `MemberSummary` seguían dibujando `initialBookings`
recibido por SSR, incluso tras confirmar el nuevo estado. La recarga obtenía
props nuevas y por eso revelaba la cancelación ya guardada.

Ahora ambos componentes derivan estado, historial, próxima clase y estadísticas
de la última lectura autenticada del provider. Éste conserva también el detalle
completo que ya entrega el GET. La instantánea SSR sólo puede completar metadatos
de una fila con la misma identidad, ID de reserva e ID de sesión, nunca restaurar
su estado viejo ni filas que ya no aparecen en la lectura actual. Si no se
puede resolver un detalle, se muestra dato no confirmado, no un cero ficticio.
Se rechazan respuestas GET con filas de otra identidad. La cancelación incierta
en Mi cuenta usa el aviso UNCONFIRMED, no un error genérico ni éxito.

Regresión reproducida antes del arreglo: no aparecía CANCELADA con props SSR
intactas; tampoco se mostraban reservas nuevas presentes en GET. Tras corregir,
43/43 pruebas focalizadas pasan (10 nuevas): actualización sin recarga, lectura
fallida tras DELETE, nuevas filas ausentes de SSR, descarte de SSR obsoleto,
metadatos propios sin recuperar estado antiguo, aislamiento entre identidades,
resumen de Inicio actualizado/error explícito, respuesta lenta sin segundo envío
ni cancelación optimista. La corrección visual todavía necesita comprobación en
el preview publicado; no requiere SQL nuevo. No se ejecutaron movimientos ni SQL
remoto por el agente, no se borraron registros y no se mergeó el PR.

### Validación local de la corrección visual

```text
npm run typecheck
> tsc --noEmit
(exit 0)
npm run lint
✖ 10 problems (0 errors, 10 warnings)
(exit 0)
npm run build
✓ Compiled successfully in 7.0s
✓ Generating static pages using 1 worker (40/40) in 200ms
(exit 0)
npm run test:auth
# tests 350
# pass 350
# fail 0
(exit 0)
npm run test:sql
🎉 Todo pasó
🎉 CRM: 49 comprobaciones pasaron
🎉 Compatibilidad CRM: 69 comprobaciones pasaron
🎉 Escritura financiera: 86 comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)
🎉 Plan propio: 22 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
🎉 Lectura de reservas: 42 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
(exit 0)
```

Logs `/home/user/account-cancel-{targeted,auth,typecheck,lint,build,sql}.log`.

## Confirmación del usuario y aclaración del catálogo (17-oct-2026)

El usuario respondió «Ahora sí funcionó» tras la guía de prueba del arreglo
visual. Se registra como confirmación del usuario del funcionamiento en celular;
una captura por sí sola no demuestra si hubo recarga. Reenvió192311 (historial
cancelado anterior) y añadió194328, que muestra una reserva activa reconocida
para20-oct06:00:1/20,19libres y «Cancelar reserva». No se infiere que el estado
más reciente sea cancelado ni se solicita otra operación para repetir la prueba.

Inicio ahora diferencia capacidad configurada y disponibilidad: para Boxeo,
«Capacidad: {count} personas por sesión», enlace «Ver horarios y reservar» y
aclaración de que los lugares disponibles se consultan al elegir día/hora. La
capacidad sigue viniendo de datos, no de un20 fijo ni del número de reservas.
Acceso libre y consulta mantienen su modalidad, con capacidad general sin
prometer una sesión reservable. Traducciones ES/EN y disposición flexible del
pie de tarjeta para texto largo. Ningún cambio a reservas, SQL o saldos.

6 regresiones SSR nuevas comprueban ES/EN, destino del enlace, capacidad37
configurada, separación de acceso libre/consulta, error explícito y catálogo
realmente vacío. Validación local real:

```text
npm run typecheck
> tsc --noEmit
(exit 0)
npm run lint
✖ 10 problems (0 errors, 10 warnings)
(exit 0)
npm run build
✓ Compiled successfully in 2.7s
✓ Generating static pages using 1 worker (40/40) in 193ms
(exit 0)
npm run test:auth
# tests 356
# pass 356
# fail 0
(exit 0)
npm run test:sql
🎉 Todo pasó
🎉 CRM: 49 comprobaciones pasaron
🎉 Compatibilidad CRM: 69 comprobaciones pasaron
🎉 Escritura financiera: 86 comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)
🎉 Plan propio: 22 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
🎉 Lectura de reservas: 42 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
(exit 0)
```

Logs `/home/user/catalog-capacity-{targeted,auth,typecheck,lint,build,sql}.log`.
