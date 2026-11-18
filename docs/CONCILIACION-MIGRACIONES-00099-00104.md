# Conciliación de migraciones 00099–00104

**Estado:** baseline histórico verificado y protegido en el repositorio; no se
ha escrito SQL ni metadatos de migración en producción.

**Fecha de evidencia:** 17 de noviembre de 2026  
**Proyecto:** `hcnuepdxmbsmlzdmvwhx`  
**Alcance:** historial de migración y definiciones de esquema, RLS, grants y
funciones relacionados con 00099–00104. No se consultaron filas de clientes,
pagos, pedidos, mensajes ni perfiles.

## Conclusión ejecutiva

El historial de Supabase termina en la migración remota con nombre
`limites_de_abuso` y versión `20261102174311`, que corresponde al cambio local
00098. No hay registros para 00099–00104.

Aun así, el estado funcional final de esas seis migraciones **ya está en la
base**. Se verificaron sus seis tablas, columnas, constraints, índices, RLS,
las ocho políticas esperadas, el enum `superadmin`, los permisos de ejecución
y las veinte funciones que resultan al aplicar la secuencia completa. Los cuatro
cuerpos de función que no coincidieron byte a byte con el archivo actual sólo
difieren por comentarios explicativos; la versión ejecutable, los parámetros,
el retorno, `security definer`, `search_path`, el `lock_timeout` cuando aplica
y los grants de ejecución son equivalentes.

Por tanto, **no se deben reejecutar 00099–00104**. Reaplicar los archivos puede
intentar recrear políticas sin guardia, volver a hacer DDL sobre objetos que ya
existen o alterar funciones ya verificadas. El problema restante es de
**trazabilidad de historial**, no de ausencia de esquema. La protección local y
la operación de futuras migraciones se definen en
[`MIGRACIONES-PRODUCCION.md`](MIGRACIONES-PRODUCCION.md).

No fue posible demostrar con una lectura de catálogos cuál fue el mecanismo
original de aplicación. El instalador completo del repositorio contiene las seis
migraciones byte a byte y es una explicación plausible, pero no es prueba de
que se haya ejecutado en este proyecto.

## Evidencia por migración

| Local | Registro remoto | Evidencia remota de estado final |
|---|---|---|
| `00099_embudo_de_ventas` | Ausente | Tablas `embudo_orders`, `embudo_leads` y `embudo_config`; RLS y políticas de lectura de personal; funciones de crear orden, informar pago, consultar estado, guardar lead y confirmar orden. |
| `00100_superadministrador` | Ausente | Enum `user_role` incluye `superadmin`; `is_admin()`, `crm_is_staff()`, `admin_set_role()`, `staff_set_status()` y `crm_update_client()` conservan las guardas de superadministrador. |
| `00101_tienda_publica` | Ausente | `tienda_productos()` devuelve únicamente catálogo público y tiene ejecución para `anon` y `authenticated`. |
| `00102_embudo_metodo_pago_resiliente` | Ausente | La versión activa de `embudo_crear_orden(jsonb)` contiene el comportamiento final de selección de método y la guarda `SIN_METODO_PAGO`. |
| `00103_embudo_cuenta_resiliente_y_rechazo` | Ausente | La versión activa de `embudo_confirmar_orden(uuid,text)` contiene el fallback de cuenta NIO; existe `embudo_cancelar_orden(uuid,text)`, idempotente, y la guarda `SIN_CUENTA_NIO`. |
| `00104_arm_asistente_interno` | Ausente | Tablas `arm_channels`, `arm_threads` y `arm_messages`; canal `interno` activo y `whatsapp`/`correo` inactivos; RLS, políticas y ocho RPC de ARM presentes. |

### Catálogo y seguridad comprobados

- Las seis tablas tienen RLS activado.
- Las ocho políticas presentes son exactamente las previstas por la cadena:
  tres lecturas de personal para Embudo y cinco políticas de ARM.
- Los constraints, índices y relaciones de las seis tablas corresponden al
  diseño local: contacto y estado de órdenes, fuente `asistente` de leads,
  tokens/hilos/mensajes de ARM y sus claves foráneas.
- Se comprobaron los canales sin leer mensajes: `interno=true`,
  `whatsapp=false` y `correo=false`.
- Las veinte funciones finales esperadas están presentes. Dieciséis coinciden
  en hash de cuerpo con el SQL local final. Las cuatro restantes (`admin_set_role`,
  `staff_set_status`, `arm_enviar_visitante` y `arm_responder_asistente`) difieren
  sólo en comentarios dentro del cuerpo; tras retirar comentarios y espacios,
  los hashes coinciden con las definiciones locales.
- Los RPC públicos/privados observados conservan el reparto esperado: funciones
  de visitante de Embudo/ARM se ejecutan desde `anon`; funciones de personal y
  protección de roles no. La RLS sigue siendo la barrera para las tablas ARM.

La revisión de grants amplios generales de la base continúa bajo **SEG-06**; no
se cambió ningún grant en esta investigación.

## Validación local reproducida

Con `npm ci` (incluido el parche aprobado de `braces`) se ejecutaron contra una
base PGlite desechable:

```text
npm run test:embudo       42 comprobaciones
npm run test:superadmin   21 comprobaciones
npm run test:tienda        5 comprobaciones
npm run test:arm                    42 comprobaciones SQL + 20 pruebas del asistente
npm run build:install:check
npm run check:migration-baseline     hashes y presencia en el instalador
```

Todo terminó correctamente. Esto verifica que la secuencia local se aplica y
que el instalador generado incluye las migraciones 00099–00104; no sustituye la
trazabilidad histórica del proyecto remoto.

## Ensayo autorizado: resultado y límite de la herramienta

Con la autorización recibida el 17 de noviembre se creó la rama temporal de
Supabase `migration-repair-validation-20261117`, asociada a esta rama Git. El
proveedor la reportó como no persistente, sin datos y con el preview saludable.
No se ejecutó SQL contra ella ni contra producción.

El ensayo no pudo continuar sin arriesgar producción por dos límites técnicos
comprobados:

- La respuesta de branching expone el mismo `project_ref` que producción y la
  herramienta de consultas sólo acepta ese `project_ref`; no ofrece un selector
  de rama. Una consulta de prueba por ese camino podría terminar en la base
  principal, por lo que no se usó.
- La CLI oficial actual sí tiene `supabase migration repair`: valida un número
  de versión, lee el archivo local correspondiente y hace un `UPSERT` de sus
  metadatos en una transacción. No ejecuta el DDL del archivo. Pero el historial
  remoto existente usa timestamps de 14 dígitos, mientras que estos archivos
  locales usan `00099`–`00104`. Marcarlos directamente dejaría dos convenciones
  de versión en el mismo historial, no una reconciliación verificable. Además,
  la conexión de la CLI al host remoto fue rechazada en este entorno por IPv6 y
  no se recuperó ni solicitó ninguna contraseña o secreto.

Por eso no se usó `migration repair` en producción ni se creó una migración
vacía de "baseline": cualquiera de las dos alternativas aparentaría resolver
la historia sin definir el mapeo correcto entre los timestamps remotos y los
números lógicos del repositorio.

## Plan seguro pendiente de un entorno de ensayo direccionable

1. **Congelar la situación actual.** No correr `db push`, no ejecutar los seis
   archivos por SQL Editor, no crear una migración que los replique y no insertar
   directamente en `supabase_migrations.schema_migrations`.
2. **Respaldar y capturar de nuevo las huellas de catálogo** inmediatamente antes
   de cualquier reparación: tablas, constraints, índices, políticas, grants,
   firmas y cuerpos de función. También registrar el estado de Realtime por
   separado; no forma parte de estas migraciones.
3. **Ensayar el método oficial de reparación de historial en una rama o proyecto
   desechable de Supabase**, con una copia del historial y sin DDL de negocio.
   Debe confirmar cómo representa Supabase las versiones: este proyecto usa
   identificadores de 14 dígitos en la tabla remota, mientras que el repositorio
   conserva números lógicos de cinco dígitos.
4. Tras un ensayo auditable en una base realmente aislada —la autorización del
   usuario ya fue recibida— aplicar el procedimiento oficial soportado para
   marcar el baseline verificado. Debe registrar el origen, fecha, operador, las
   seis huellas revisadas y no ejecutar ningún `CREATE`, `ALTER`, `DROP`,
   `INSERT` de negocio ni cambio de datos.
5. Verificar después que el historial quede coherente y que las huellas antes y
   después sean idénticas. Si no se puede obtener ese procedimiento soportado,
   conservar el historial como está, bloquear el replay de 00099–00104 en la
   operación y documentar el hueco: una entrada inventada es peor que una brecha
   conocida.

La autorización para investigar ya fue recibida, pero no se escribe ningún
metadato remoto mientras no exista un ensayo aislado y un mapeo histórico
verificable. El guard de CI evita mientras tanto que estos seis archivos se
editen, desaparezcan o queden fuera del instalador de un proyecto nuevo.
