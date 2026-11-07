# Plan de la ficha y Mi cuenta — reparación

## Evidencia remota del 17 de octubre de 2026

El usuario asignó «Gimnasio mensual» a Cliente EJEMPLO (ficha/cuenta de prueba) desde
Clientes, guardó y recargó: plan y nota «Plan Común» permanecieron. En Mi cuenta,
tras recargar con esa identidad, seguía apareciendo «Sin plan asignado».

También quedó comprobada la entrada manual del 17 de octubre a las 17:58 Managua,
su persistencia tras recargar y el rechazo de una segunda entrada del mismo día,
sin nueva fila ni cambio de hora. Esto no demuestra asistencia a una clase reservada.

## Causa y solución

- El editor escribe `gym_clients.plan_id`; Mi cuenta resolvía el plan usando
  `profiles.plan_id` del contexto de autenticación. Son campos distintos.
- No se copia indiscriminadamente entre tablas ni se altera el perfil de acceso.
  La fuente del plan asignado es la ficha CRM vinculada a `auth.uid()`.
- `crm_my_assigned_plan()` es una lectura sin argumentos: no permite elegir otra
  persona y únicamente retorna si hay ficha vinculada y el id/nombres/actividad
  del plan. No expone notas, correo, teléfono, saldos ni datos de otras fichas.
- No se modifica RLS para permitir al cliente consultar directamente su fila CRM
  completa, que contiene notas internas.
- Mi cuenta recibe la lectura desde servidor, ligada al id de sesión. Si falla,
  muestra «Plan no confirmado» y un reintento, nunca «Sin plan asignado» por error.
- Sin ficha y ficha sin plan son estados distintos. Un plan inactivo conserva su
  nombre con aviso de que ya no está disponible para nuevas asignaciones.
- En conectado no hay fallback a profiles ni a planes demo. Demo sin Supabase
  conserva su comportamiento anterior.
- La interfaz dice «Plan asignado» y aclara que no confirma pago ni vigencia.
  No crea cobros, renovaciones, fechas, descuentos ni privilegios.

## Instalación en la base existente

1. Conservar el respaldo habitual de la base.
2. Ejecutar **sólo** `supabase/PLAN-CUENTA.sql` en SQL Editor de Supabase.
   Es una función de lectura y sus permisos; no actualiza ni borra datos.
3. Resultado esperado: `Success. No rows returned`.
4. Usar el preview actualizado de PR10. Como Cliente EJEMPLO, recargar Mi cuenta:
   debe verse «Gimnasio mensual». No reasignar ni guardar la ficha otra vez.
5. Si aparece un error, informar el texto/código. No repetir SETUP, FASE2,
   COBROS-GASTOS ni crear otra ficha.

El archivo corresponde exactamente a la migración `00025_account_assigned_plan.sql`.
El generador también lo incluye en SETUP/ACTUALIZAR/FASE2 para futuras instalaciones;
**eso no significa que deban ejecutarse esos archivos en esta base existente**.
Si el frontend se publica antes del SQL, el error de función ausente permanece
explícito en la tarjeta del plan y no se presenta como ausencia de plan.

## Pruebas de esta entrega

- 22 controles SQL en PGlite, esquemas repository y bank_accounts_split:
  reinstalación sin cambios de datos; edición mediante RPC de admin; lectura como
  cliente con profile divergente; sin plan sin fallback legado; privacidad;
  aislamiento entre identidades; RLS directo intacto; RPC sin id seleccionable;
  plan inactivo; sin ficha; anon sin EXECUTE; authenticated sin uid rechazado.
- Pruebas React/JSDOM de los estados anteriores y cambio de identidad.
- Consulta del servidor: protocolo validado, fallo de conexión/SQL/respuesta
  incompleta explícitos; no se filtran detalles privados.
- Página SSR pasa al panel la lectura canónica y su identidad; un fallo del plan
  no bloquea por sí mismo el resto del panel.

Salidas reales (código 0):

```text
npm run typecheck
> tsc --noEmit

npm run lint
✖ 10 problems (0 errors, 10 warnings)

npm run build
✓ Compiled successfully in 17.8s
✓ Generating static pages using 1 worker (40/40) in 646ms

npm run test:auth
# tests 321
# pass 321
# fail 0

npm run test:sql
🎉 Todo pasó
🎉 CRM: 49 comprobaciones pasaron
🎉 Compatibilidad CRM: 69 comprobaciones pasaron
🎉 Escritura financiera: 86 comprobaciones pasaron (PGlite; sin concurrencia multiconexión ni SQL remoto)
🎉 Plan propio: 22 comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).
```

No se ejecutó SQL remoto por el agente. La instalación y la comparación final de
ambas vistas en Supabase quedan pendientes del usuario. El aviso de saldo vinculado
no disponible es un pendiente separado; esta reparación no lo sustituye por cero.
PR10 continúa sin merge. No se retiraron accesos ni borraron datos de prueba.
