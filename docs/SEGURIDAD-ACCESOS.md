# Seguridad 1A — perfiles, vistas financieras y RPC de mantenimiento

Fecha: 18 de octubre de 2026. Base: merge de PR10 (`6ed6616`).
Rama de esta continuación: `arena/90aa43e3-strong-gym`.

## Estado

**Aplicado en Supabase real con autorización explícita del usuario.**
Verificados después los privilegios efectivos/opciones de vistas y políticas.
La comprobación funcional de pantallas conectadas desde el celular sigue pendiente.
El diagnóstico remoto fue exclusivamente de estructura/permisos. No se consultaron
filas de clientes ni se ejecutaron pagos, cambios de plan, borrados o nuevas altas.
Esta entrega no cierra toda la seguridad ni certifica HTTPS/TLS.

## Qué se confirmó en el proyecto conectado

Se consultaron pg_class, pg_policies, pg_views, pg_proc, pg_trigger, pg_attribute,
roles y privilegios efectivos, sin leer registros comerciales ni secretos.

- Esquema real `bank_accounts_split`, PostgreSQL 17. RLS está habilitado en las 23
  tablas públicas inventariadas. Tener RLS no protege por sí solo toda la API.
- Cinco vistas financieras (`v_account_balances`, `v_expenses_by_category`,
  `v_members_with_debt`, `v_monthly_summary`, `v_top_members`) permiten SELECT a anon
  y authenticated, sin security_invoker. Su propietario postgres tiene BYPASSRLS
  y sus definiciones no filtran por identidad. **Exposición de configuración
  confirmada**, no sólo un riesgo del instalador antiguo. No se descargaron sus datos
  ni se simuló un acceso HTTP adverso contra producción.
- profiles concede UPDATE de tabla a authenticated y autoedición por id=auth.uid().
  El trigger protege cambios de role, no plan_id/email/otras columnas. Esto confirma
  el permiso excesivo; no demuestra que alguien haya abusado ni justifica modificar
  planes históricos. Los registros de prueba del diagnóstico anterior eran locales.
- bank_accounts tiene SELECT permisivo para cualquier usuario autenticado, incluidos
  saldos. No basta con proteger la vista si se deja abierta la tabla.
- Algunas RPC CRM heredan ejecución de anon. Sus comprobaciones internas siguen siendo
  importantes: tener EXECUTE no significa que todas permitan operaciones sin rol.
- generate_week_sessions/close_past_sessions conservan ejecución pública. Las rutas
  de la web no las usan; deben reservarse a mantenimiento SQL/servicio autorizado.
- session_occupancy sólo devuelve session_id/booked_count. Es una excepción pública
  agregada necesaria para anunciar cupos reales sin exponer identidades de reservas.

## Corrección 00030

Archivo único generado: [supabase/SEGURIDAD-ACCESOS.sql](../supabase/SEGURIDAD-ACCESOS.sql).
Origen: `supabase/migrations/00030_access_hardening.sql`.

1. Eliminar CREATE de esquema para roles de API.
2. Revocar permisos de tabla Y por columna sobre profiles. Conservar SELECT por RLS
   y UPDATE sólo de full_name/phone. Registro Auth y RPCs autorizadas siguen funcionando.
   Nadie cambia roles/planes mediante un UPDATE directo del navegador, tampoco admin:
   las operaciones comerciales usan RPC autorizada; futuras altas de administradores
   requieren un flujo admin específico, no reabrir UPDATE general.
3. Permitir lectura de perfiles al personal mediante crm_is_staff (SECURITY DEFINER),
   sin recursión. Datos de clientes permanecen ocultos a otros clientes.
4. Restringir lectura de bank_accounts a staff con política RESTRICTIVE, sin borrar
   políticas previas ni tocar saldos. Nuevas políticas RESTRICTIVE de finanzas limitan
   filas a su dueño/staff incluso si hay una política permisiva adicional.
5. Vistas financieras de ambos esquemas: security_invoker + security_barrier, sin
   acceso público/escritura. Conceder SELECT de tablas subyacentes sólo con RLS
   habilitado; abortar si falta. Personal ve reportes globales; un cliente como mucho
   sus propias filas, NUNCA las de otro cliente. No se cambian definiciones financieras.
6. Preservar ocupación pública en contexto propietario deliberadamente: invoker
   contaría sólo reservas propias y anunciaría cupos falsos. Validar sus dos columnas,
   sin añadir datos personales ni permisos de escritura.
7. Retirar EXECUTE público de CRM/book/cancel/trigger de Auth, preservando los grants
   authenticated existentes y sin abrir helpers privados. Mantenimiento de generación
   y cierre horario ya no es invocable por roles de API, incluido personal: no hay
   acción web que dependa de esas funciones; mantenimiento SQL autorizado sigue posible.
8. Recargar caché PostgREST tras el commit. Transacción y lock_timeout de 5 segundos:
   un error revierte el incremental, no deja permisos parcialmente aplicados.

**No se escriben filas comerciales.** No se cambian roles, contraseñas, planes,
saldos, recibos ni los cuerpos de escritores/RPC. No se borra historial ni se repiten
abonos. Las restricciones no corrigen supuestas modificaciones históricas: requieren
evidencia y conciliación, nunca un reset de planes.

El instalador SETUP y los generados ACTUALIZAR/FASE2 incorporan 00030 para nuevas
instalaciones. **NO ejecutarlos sobre la base actual**: podrían reinstalar otros
wrappers. En la base existente aplicar exclusivamente SEGURIDAD-ACCESOS.sql.
El merge del PR NO ejecuta esa migración en Supabase.

## Pruebas

Nueva suite en `npm run test:sql`: `scripts/test-access-hardening-sql.mjs`.

- 147 comprobaciones entre repository y bank_accounts_split.
- Reproduce permiso excesivo antes de corregir, con registros ficticios locales.
- Instalación repetida conserva registros y cuerpos de funciones.
- Anónimo sin lectura de las10 vistas financieras sumando ambos esquemas; clientes
  A/B aislados y authenticated sin identidad sin datos. Admin/staff conservan datos
  financieros no vacíos y totales completos, no sólo una consulta que no arroja error.
- No actualizar plan_id/role/email/ids/fechas, ni insertar/borrar perfiles directamente.
- Autoedición nombre/teléfono, registro de Auth y edición de plan vía RPC autorizada.
- Cupos públicos correctos entre dos clientes y cancelación propia que libera lugar.
- Cuentas bancarias privadas, rol retirado pierde acceso y mantenimiento no accesible.
- Cobro idempotente, comprobante, reporte y abono20/recibido100/vuelto80 permanecen
  operativos en datos locales; no hubo movimientos nuevos en Supabase.
- Ajustada prueba CRM: promoción de role ahora falla antes del trigger por permisos
  de columna, y se comprueba que role continúa siendo member.
- Suite PostgreSQL concurrente incorpora00030 para verificar escritores con los nuevos
  permisos en CI. No se presenta PGlite como prueba multiconexión.

Resultados locales reales:

```
npm run typecheck: exit 0 (tsc --noEmit)
npm run lint: exit 0; 0 errors, 10 warnings
npm run build: exit 0; Compiled successfully; static pages 40/40
npm run test:auth: exit 0;438 pass, 0 fail
npm run test:sql: exit 0; base + CRM49 + compatibilidad69 + escritura86 + plan22
  + reservas42 + ficha54 + deudas95 + seguridad147
```

Los 5 avisos high de dependencias de desarrollo detectados al instalar siguen abiertos.
No se aplicó audit fix --force. Estas pruebas NO equivalen a Supabase/PostgREST
remoto ni sustituyen pruebas de navegador conectado después de aplicar el incremental.

## Aplicación autorizada y comprobación remota

SHA-256 del SQL aplicado: `17868004723b00819a06f1021b812dc0e50b90eff7ccf78c8e31577c36e6498d`.

El usuario eligió «Sí, aplicá ese ajuste de permisos» para este único incremental.
Se ejecutó exactamente el contenido de00030 en una transacción: éxito, sin filas
comerciales modificadas por el SQL. Se notificó a PostgREST para recargar esquema.
El código usa exclusivamente DDL/grants; no se calculó un hash de registros reales
ni se atribuye a esta ejecución una auditoría histórica de alteraciones anteriores.

Evidencia de consultas de sólo lectura posteriores:

- Las5 vistas financieras existentes: invoker=true, barrier=true; anon SELECT=false;
  authenticated SELECT=true y UPDATE por columna=false.
- profiles: UPDATE full_name/phone=true; role/plan_id/email/id/fechas=false;
  INSERT/DELETE=false para authenticated y SELECT=false para anon.
- Políticas RESTRICTIVE activas en bank_accounts, transactions y member_balances.
- Cupos: anon SELECT=true, authenticated UPDATE=false, columnas agregadas intactas.
- CRM/directorio/book/cancel: anon EXECUTE=false, authenticated EXECUTE=true.
  Helper privado crm_finance_layout permanece sin EXECUTE de authenticated.
- Generar/cerrar horarios: EXECUTE=false para anon/authenticated. Finanzas y abonos
  mantienen EXECUTE de authenticated; el rol se sigue validando dentro de cada RPC.
- CREATE de esquema para authenticated=false.

Identificadores de auditoría del conector (no secretos): aplicación
92ebe3d3-a1f3-4b6a-8704-61f8e62b57ab; verificación
00227b3c-12e4-4d8c-9b22-0ba9ca6578b8. Ejecución vía execute_query, no gestor de
migraciones CLI; el incremental queda versionado en el repositorio.

**No volver a pegar este SQL por rutina.** Su aplicación no depende de hacer merge.
Falta prueba de humo de lectura desde celular: panel/clientes/Caja/reportes/cupos,
sin crear pagos ni repetir liquidación de Cliente EJEMPLO. Si algo falla, detener y
revisar; no reinstalar SETUP ni relajar RLS para hacerlo pasar.

## Lo siguiente, sin mezclar alcances

1. Completar prueba visual conectada de lectura; permisos00030 ya aplicados/verificados.
2. Aislar demo/producción y revisar secretos/configuración publicada.
3. Auth/recuperación/MFA, abuso/CSRF y revisión restante de políticas/RPC/Storage.
4. Navegación, módulos y aceptación integral según la lista única. TLS/dominio,
   backups/restauración y pruebas finales siguen siendo condiciones de entrega.
