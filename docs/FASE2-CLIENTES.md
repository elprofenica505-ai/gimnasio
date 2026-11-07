# FASE 2 — Clientes, etiquetas y recepción manual/QR

## Decisiones del negocio

- En Nicaragua se usa **clientes**, no “socios”. La interfaz en español, plantilla
  CSV y textos administrativos usan ese término. Se conservan rutas históricas,
  nombres internos `member` y claves SQL para no romper integraciones.
- Etiquetas: **Clientes**, **Clientes amigos**, **Clientes familia Strong**.
  Sólo el administrador cambia la etiqueta; staff atiende, registra y cobra.
  Son segmentación comercial. No son roles, planes, descuentos ni promociones.
- Frecuencia separada: días de visita en los últimos 30 días (hoy y los 29
  anteriores), aproximación semanal y última visita. Sin clasificación moral de
  “buen cliente”, ascensos automáticos ni umbrales comerciales inventados.
- Una visita por cliente/día, en America/Managua. Reingresar ese día no duplica
  la estadística. No es asistencia a una clase: no modifica bookings.
- QR y búsqueda manual abren la misma ficha. Escanear NO cobra ni registra
  asistencia automáticamente. Confirmar cada acción por separado.
- Cliente sin teléfono/correo/cuenta: alta rápida sólo con nombre, carnet impreso
  o búsqueda manual por nombre/número. Revisar coincidencias antes de dar de alta.
- Se bloquea asistencia si la ficha está congelada/cancelada. No hay bloqueo
  automático por deuda. Un saldo desconocido se muestra como desconocido, no cero.

## Arquitectura y límites

`profiles` sigue siendo la tabla de identidades del sitio, enlazada a Supabase
Auth. `gym_clients` NO es una tabla de usuarios: es la ficha comercial que puede
existir sin cuenta web. `profile_id` es opcional y único. No se crean cuentas
falsas, correos artificiales ni contraseñas para clientes de recepción.

La migración crea fichas vinculadas para los perfiles `member` existentes y un
trigger para registros web nuevos. No vincula fichas por email automáticamente.
Una persona dada de alta en recepción que posteriormente se registre en la web
puede quedar con dos fichas: esta primera entrega NO incluye fusión/vinculación
administrativa de historiales. Antes de habilitar esa transición masivamente,
implementar un proceso verificado; no unir por coincidencia de correo ni editar
IDs a ciegas. Puede usar el carnet de recepción sin cuenta mientras tanto.

El directorio busca nombre/teléfono/número y filtra etiqueta, 30 resultados por
página. La ficha muestra últimas 60 visitas, 40 transacciones y 40 eventos.
Los cambios de etiqueta y estado guardan valor anterior/nuevo y actor en auditoría.
Los datos opcionales del CSV (emergencia, nacimiento, dirección, notas médicas)
se conservan en campos separados de la ficha; esta versión no incluye su editor
visual. No usar notas comerciales para almacenar información médica.

Los cobros guardan `transactions.client_id` y son visibles en Caja. Si existe un
perfil vinculado, también usan `member_id` y los triggers financieros existentes.
Una ficha sin cuenta web tiene historial de cobros, pero NO se inventa saldo,
no se emite factura, no se genera deuda ni se renueva un plan automáticamente.
Asignar plan aquí es un dato comercial, no un contrato con vencimiento calculado.

## Seguridad y confiabilidad

- Guards de servidor, API y SQL: admin/staff. El cliente sólo obtiene su propio
  carnet con `crm_my_pass`; no tiene directorio ni permiso para registrar visitas.
- RLS activo; tablas CRM sin escritura directa por navegador. Operaciones vía
  funciones con validación y auditoría, EXECUTE revocado a PUBLIC.
- Se impide cambiar `profiles.role` desde la antigua edición de perfil propio.
  Sólo un admin puede cambiar roles; el SQL Editor sin identidad conserva su
  administración. La migración no promueve a nadie.
- QR: token aleatorio, sin nombre, teléfono, deuda, UUID de login ni URL pública.
  Se envía por POST, no por querystring. Es identificador, no contraseña ni
  prueba antifraude de presencia. Recepción debe confirmar el nombre.
- Reemplazar el QR invalida el anterior. El carnet se entrega personalmente o en
  papel/PDF; no publicarlo. Cámara con permiso explícito, HTTPS y botón detener.
  Permiso denegado o dispositivo sin cámara: búsqueda manual siempre disponible.
- Cobros con confirmación, cuenta/moneda/método activos y tasa explícita para USD.
  Referencia idempotente por intento: repetir el mismo no duplica transacciones;
  cambiar el contenido con la misma referencia genera conflicto.
- Intento pendiente se conserva en sessionStorage de esa pestaña y sobrevive a
  recarga. No abrir otra pestaña para “reintentar”: revisar historial y misma
  referencia. Descartar sólo tras comprobar el resultado, pues un intento nuevo
  puede duplicar un pago ya guardado. Si el almacenamiento está bloqueado, el
  formulario no envía el cobro. No hay escritura offline ni éxito simulado.
- Los endpoints de CRM/carnet responden private/no-store. Sin migración se muestra
  error explícito; no hay fallback a datos ficticios en producción.

## Instalar desde el celular (sin merge obligatorio)

1. Tener Fase 1 y el fix de lectura propia 00012 ya instalados. Hacer backup.
2. Preferir una base de pruebas antes de producción: FASE2.sql modifica el esquema
   compartido y agrega fichas para perfiles member, aunque el frontend sea Preview.
3. Abrir `supabase/FASE2.sql`, copiar TODO en SQL Editor y ejecutarlo una vez.
   Es transaccional e idempotente. No usar SETUP/ACTUALIZAR completos para este paso.
4. Opcional: ejecutar `supabase/migrations/00021_clients_seed.sql`. Son 6 fichas
   FICTICIAS, marcadas como Ejemplo/is_demo, con distintas etiquetas/frecuencias.
   No crea cuentas, teléfonos falsos ni transacciones. No se carga automáticamente.
5. Abrir Preview del PR con Supabase configurado, iniciar sesión como admin.
6. Panel → Clientes y recepción (también desde Caja y menú). Si aparece modo demo,
   las acciones están deshabilitadas: eso no valida el flujo real.
7. No mergear hasta autorizarlo y revisar los checks y el siguiente recorrido.

### Recorrido de aceptación

1. Buscar un cliente por nombre/número. Crear otro de prueba sólo con nombre.
2. Repetir alta: comprobar aviso de coincidencia; sólo confirmar duplicado si es
   otra persona. Homónimos reales están permitidos con revisión explícita.
3. Como admin cambiar etiqueta; como staff comprobar que no puede cambiarla.
4. Confirmar entrada manual. Repetir: debe avisar sin duplicar.
5. Imprimir/guardar carnet y escanear desde otro dispositivo. La ficha debe abrir
   sin registrar entrada ni cobro. Confirmar nombre y luego entrada.
6. Denegar cámara: probar la búsqueda manual. Retirar permiso o salir de pantalla:
   la cámara debe apagarse. Probar en el teléfono real de caja, no sólo escritorio.
7. Reemplazar carnet: el QR antiguo debe fallar y el nuevo funcionar.
8. Con cuenta de pruebas y autorización, registrar un cobro controlado. Verlo en
   historial y Caja. No hacer cobros ficticios en producción para “probar”.
9. Importar CSV de pruebas sin email y repetirlo: no debe crear login ni duplicar.
10. Con una cuenta cliente: directorio/API rechazados, carnet propio disponible.
11. Confirmar que precios y etiqueta siguen iguales al registrar visitas.

Para quitar sólo el seed CRM, sin tocar clientes reales:

```sql
-- Antes: revisar exactamente qué se va a borrar.
select id, full_name from public.gym_clients where is_demo;
-- Sólo tras confirmar; borra carnet/visitas/eventos por cascada.
-- Si tiene transacciones, la FK impide borrarlo para conservar contabilidad.
delete from public.gym_clients where is_demo;
```

El reset anterior de Herramientas es de Fase 1; NO elimina estos ejemplos CRM.
No borrar pagos reales ni usar el reset para revertir cobros.

## Pruebas

```sh
npm ci
npm run typecheck
npm run lint
npm run build
npm run test:auth
npm run test:sql
node scripts/build-sql.mjs --check
```

La suite SQL usa PostgreSQL/PGlite, roles y RLS reales. La suite de auth incluye
API con fronteras simuladas, validación y generación/decodificación real del QR
con ZXing. Se hizo además una prueba de componente en Chromium a 390×844 con APIs
simuladas: alta sin contacto, entrada duplicada, identificación QR, reintento de
cobro tras recarga y permiso de cámara denegado. No equivale a probar Supabase
real ni una cámara física: esas comprobaciones siguen en el recorrido de aceptación.

Marketing/envío de promociones, fusión de cuentas posteriores, membresías con
vencimiento, lector de torniquete, autoservicio y sincronización offline NO están
incluidos en esta entrega. Las etiquetas y métricas preparan esa evolución.

## Corrección de apertura de fichas y atención sin QR

- La búsqueda por nombre es la primera sección del panel. QR/cámara/lector USB
  son alternativas opcionales; escanear sigue sin cobrar ni registrar entrada.
- Listado, ficha y planes/métodos tienen estados de error independientes. Una
  lectura exitosa del listado no borra el error de la ficha. Los botones de
  reintento sólo repiten lecturas: **no vuelven a crear clientes ni cobros**.
- Lecturas con espera máxima de 15 segundos; operaciones de escritura, 30.
  Una respuesta perdida de escritura **no significa que no se guardó**. Buscar
  al cliente o revisar historial antes de repetir. Los cobros conservan la misma
  referencia en sessionStorage; no abrir otra pestaña para repetirlos.
- Durante una actualización se conserva el formulario de cobro y su referencia,
  pero se deshabilitan las acciones y se oculta el carnet hasta confirmar la
  ficha actual. Una respuesta tardía de otro cliente se descarta.
- Respuestas vacías o JSON inválido producen error, nunca una ficha inventada
  ni una carga perpetua.

### Diagnóstico de una base ya instalada

No reinstalar SETUP/ACTUALIZAR ni cambiar RLS a ciegas. La pantalla puede mostrar
por ejemplo `CRM_DETAIL_42703`: `DETAIL` identifica la lectura de ficha; `42703`
es una columna no encontrada. `42501` identifica permisos rechazados;
`PGRST202`/`42883`, una función que no se pudo encontrar. El código orienta la
revisión, pero no identifica por sí solo la columna o el cambio SQL necesario.
Los logs de esta API sólo registran operación y código validado, no mensajes SQL
crudos, nombres de clientes, tokens QR ni cuerpos de solicitudes.

1. Copiar el código visible y decir si falló ficha, listado o planes/métodos.
2. Si el listado funciona, no concluir que toda Supabase está desconectada.
3. Comparar la función/columnas reales con las migraciones antes de proponer SQL.
   Si se diagnostica `crm_detail` desde el SQL Editor con identidad de staff,
   usar una transacción y **ROLLBACK**: esa función puede crear un carnet cuando
   falta, por lo que no es una consulta estrictamente de sólo lectura. Si falla,
   ejecutar ROLLBACK antes de continuar. No compartir credenciales ni tokens.
4. Volver a buscar al cliente existente; no duplicarlo por un error al abrirlo.

El diagnóstico completo posterior a PR #10 confirmó una estructura financiera
diferente (ver sección de compatibilidad abajo). Las pruebas locales no
certifican por sí solas esa instalación remota.

### Demostración comercial conectada vs. modo sin base

- **Sin configuración Supabase:** panel sin escritura; no sirve para demostrar
  alta/cobros reales.
- **Demo comercial conectada:** usar preferentemente un proyecto Supabase y un
  despliegue separados, con migraciones revisadas y clientes de ejemplo
  identificados (`is_demo`, indicador EJEMPLO). El seed 00021 es opt-in: no se
  ejecutó automáticamente con este arreglo. No crea pagos ni cuentas Auth falsas.
- **Entrega al negocio:** preparar su propia base/despliegue y sus credenciales,
  sin seed ficticio. Configurar sus planes, métodos, cuentas y administrador con
  información confirmada. No reemplazar variables de un despliegue compartido
  ni limpiar la base actual sin backup y autorización.
- El código no selecciona automáticamente “demo comercial” por el nombre del
  despliegue: una base configurada escribe realmente en ella. `is_demo` marca
  datos de ejemplo, no crea aislamiento ni convierte cobros en simulaciones.

Verificación antes de una venta: alta sólo nombre, búsqueda, ficha, una visita
por día, cobro con referencia visible en Caja, reintento sin duplicación,
reemplazo de QR, permisos staff/member y pruebas físicas de cámara/impresión.
No marcar estas verificaciones como hechas sólo por pasar CI o abrir páginas.

### Evidencia de la instalación remota y exportación de estructura

Las capturas posteriores a PR #10 confirman que esa base no usa la estructura
financiera de `00010_finance.sql`: el diagnóstico devuelve nueve columnas no
encontradas. La estructura visible incluye `bank_accounts`,
`payment_methods.name/currency`, `member_balances.credit_nio/credit_usd/debt_nio`
y `transactions.type`. El CSV completo recibido posteriormente permitió reproducir columnas,
restricciones, enums y la vista en una fixture local, sin registros del negocio.
No asumir que `type` equivale a `direction`, ni calcular un saldo neto mezclando
monedas. No crear tablas paralelas `accounts` ni columnas vacías para silenciar
el fallo. La compatibilidad de cobros y Caja requiere revisar también enums,
restricciones y triggers reales antes de cambiar funciones o escritura.

`supabase/DIAGNOSTICO-FINANZAS.sql` es una consulta manual de metadatos (no una
migración). Devuelve una fila JSON con columnas/tipos/defaults, restricciones,
valores enum, definiciones de triggers y vistas de esas relaciones financieras.
No consulta registros comerciales. Exportar el resultado completo como CSV evita
celdas cortadas y el límite de filas de la interfaz. Revisar el archivo antes de
compartirlo: las definiciones SQL personalizadas podrían contener literales
privados añadidos fuera del repositorio; no compartir claves ni secretos.
El diagnóstico no cambia el esquema ni certifica que el CRM remoto funcione.


## Compatibilidad incremental confirmada por CSV (00022)

**Para la base existente del diagnóstico, con CRM ya instalado:** hacer backup y
aplicar únicamente `supabase/COMPATIBILIDAD-CRM.sql` (idéntico a migración 00022).
No SETUP, ACTUALIZAR, seed ni reinstalación completa de FASE2. El cambio de
funciones SQL afecta a todas las versiones que compartan esa base, incluso si
el PR aún no está mergeado. Coordinar la prueba en una base de ensayo si es
posible. Si la ejecución falla dentro de la transacción, ejecutar ROLLBACK antes
de cualquier otra consulta y compartir el error sin repetir escrituras.

Qué cambia exactamente:
- Agrega `crm_options`, RPC para authenticated con comprobación interna de
  admin/staff. No concede acceso directo nuevo a ninguna tabla ni desactiva RLS.
- Normaliza `bank_accounts` y `payment_methods.name/currency/display_order`
  según las columnas recibidas. `BOTH` permite ambas monedas; no incluye métodos
  ni cuentas inactivos. No inventa cuentas ni métodos ni copia registros.
- Sustituye `crm_detail`: conserva ficha/carnet/historial y devuelve los cuatro
  campos crédito/deuda NIO/USD por separado. No convierte ni compensa monedas;
  una fila de saldo ausente no se muestra como cero.
- Conserva la implementación de cobro original como función privada sin EXECUTE
  para PUBLIC/anon/authenticated. El punto de entrada público sigue validando
  staff y sólo la invoca para el modelo original del repositorio.
- **En el modelo bank_accounts/saldos separados bloquea cobros CRM tanto en UI
  como SQL (`FINANCE_REVIEW_REQUIRED`).** No inserta una transacción ni cambia
  cuentas, créditos o deuda en ese modelo. Las referencias pendientes se
  conservan; no repetir un cobro en otra pantalla sin revisar primero historial.
- No modifica visitas ni etiquetas y no borra/recrea clientes o carnets.
- Es idempotente. Los paquetes generados para instalaciones nuevas incorporan
  00022; el archivo incremental evita reinstalar etapas anteriores en esta base.

El CSV recibido trae una lista de triggers no internos vacía y
`v_account_balances` simplemente lee `bank_accounts.balance`. **No alcanza con
insertar un income y asumir que Caja se actualiza.** Todavía falta revisar las
funciones de escritura/actualización financieras que esa instalación utiliza
(si existen) y acordar el significado del cobro respecto a crédito/deuda. Por
eso esta entrega habilita lectura/recepción compatible, NO certifica ni habilita
cobros en esa base. Tampoco adapta aún el resto de consultas/reportes de FASE1;
que abra una pantalla de Caja no valida sus totales con ese esquema.

Pruebas: la fixture `tests/fixtures/finance-bank-accounts.sql` reproduce metadatos
recibidos, no contiene datos reales ni pretende representar permisos RLS o
funciones no exportadas. Los datos insertados en las pruebas son ficticios y
sólo viven en PGlite local. Se reproduce el 42703 antes del parche; después se
prueban lectura, monedas, permisos, bloqueo de cobro, conservación de datos y
reaplicación. La estructura original del repositorio mantiene sus pruebas de
pago idempotente mediante el wrapper. Pendiente ejecutar/validar el incremental
en la base remota con autorización del usuario.

### Aviso de entrada repetida junto al botón

El usuario confirmó que repetir la entrada no agregaba otra visita, pero no veía
el aviso. El código enviaba la confirmación al banner del principio del panel,
lejos del botón de la ficha en celular. Ahora el resultado se muestra debajo de
«Confirmar entrada», con región accesible: confirmación, «ya tiene una visita
registrada hoy; no se duplicó», o error. Permanece durante el refresh de la misma
ficha y se limpia al seleccionar otro cliente. Una respuesta sin booleano
`already` no se presenta como éxito ni dispara un reintento automático.
Este ajuste no modifica SQL ni habilita cobros. La no duplicación conserva las
pruebas SQL originales; la posición del mensaje se prueba con componentes reales
y respuestas simuladas. Falta la comprobación visual del Preview actualizado en
el teléfono del usuario.

## Continuación autorizada: auditoría de Caja y cobros

El usuario autorizó continuar sin merge. La entrada repetida con aviso al lado
del botón ya quedó confirmada por captura en la ficha de prueba. Eso no valida
finanzas ni habilita cobros.

La revisión de FASE1 encontró lecturas que ignoraban `error` de Supabase y
convertían fallos en ceros/listas vacías o «No hay cuentas pendientes». Ahora las
lecturas de Caja, Cuentas, Reportes y Gastos exigen columnas de su contrato nativo,
propagan un error seguro y esas páginas muestran «Información financiera no
disponible», sin KPI cero ni afirmación de ausencia de deuda cuando falla una
consulta. Una lectura confirmada sin filas sigue siendo distinta de un error.
No se reemplazaron las tablas de la base bank_accounts ni se inventó un mapeo de
escritura. En esa estructura el aviso puede seguir apareciendo hasta implementar
compatibilidad real de reportes, no por desconexión total de la aplicación.

También se quitó la afirmación fija «1 USD = 36.5 NIO» y «10 métodos», porque
no estaba basada en configuración consultada. No se convierte dinero con una
tasa supuesta. La pantalla Gastos aclara que su formulario aún no existe; conectar
Supabase por sí solo no lo habilita. Fechas/cortes de reportes, cuenta corriente,
comisiones y actualización atómica de cuentas siguen pendientes de la revisión de
las funciones/vistas efectivas. Este avance no certifica ningún total remoto.

### Diagnóstico del escritor financiero (sólo lectura)

`supabase/DIAGNOSTICO-ESCRITURA-FINANCIERA.sql` obtiene en una fila JSON:
- Funciones/procedimientos públicos no CRM que referencian las tablas financieras
  o usan nombres financieros; sólo sus definiciones, no las ejecuta.
- Vistas/reportes, precisión de columnas, estado RLS, políticas y permisos de
  tablas relacionadas. No modifica ni elimina políticas.

Ejecutar en SQL Editor, Export → CSV y compartir el archivo revisado, sin claves.
No necesita reinstalar la compatibilidad ni crear clientes o movimientos. La
consulta se prueba en transacción READ ONLY local y no devuelve datos comerciales.
Si no aparecen escritores, no concluir que no existen en otro esquema o con
SQL dinámico: revisar ese límite antes de decidir una migración.

El CSV anterior sólo incluía funciones de triggers de esas tablas (lista vacía);
no permitía identificar RPC que actualicen saldos explícitamente. No decidir cómo
repartir un cobro entre crédito y deuda ni aplicar comisiones sin revisar ese
contrato. La autorización para seguir no significa autorización de merge ni
certificación de cobros. Hasta completar esa revisión, permanece el bloqueo SQL
FINANCE_REVIEW_REQUIRED y la referencia idempotente de cualquier intento pendiente.

## Lecturas compatibles con el segundo diagnóstico (00023)

Decisiones expresas del usuario: **mantener cobros bloqueados** y preparar, sin
aplicarlo, un SQL opcional con cuentas y cliente nuevos identificados EJEMPLO.
El segundo CSV ya fue revisado: no se necesita repetir aquella exportación.

### Alcance e instalación incremental

1. Sobre la base con CRM y `COMPATIBILIDAD-CRM.sql` (00022) ya aplicados,
   revisar y ejecutar **sólo `supabase/LECTURA-CAJA.sql`** (copia generada de
   `00023_finance_read_bank_accounts.sql`). No reinstalar SETUP/ACTUALIZAR en
   la base remota con esquema diferente. Nada se ejecuta automáticamente desde
   el frontend ni por publicar/mergear el código.
2. El script crea `finance_read(text,integer)`, SECURITY DEFINER, con permiso de
   ejecución para authenticated y verificación interna `crm_is_staff()` antes
   de leer. Nueve secciones cubren métodos, cuentas activas, categorías,
   movimientos, días, meses, métodos agregados, deuda y resumen. No crea tablas,
   vistas paralelas, movimientos ni reglas financieras; no cambia RLS existente.
3. **También reemplaza/bloquea la firma antigua comprobada**
   `record_payment(uuid,numeric,text,text,text,text,text,text)` sólo en el modelo
   bank_accounts_split. Esto afectará llamadas externas a ese RPC, no sólo al
   botón CRM. Staff/admin reciben FINANCE_REVIEW_REQUIRED; member AUTH;
   anon no tiene EXECUTE. No se cambia la firma/escritor nativo diferente.
   Revisar/guardar la definición anterior antes de aplicar si se requiere
   reversión; nunca reactivarla sin corregir y acordar reglas.
4. Código de aplicación y SQL deben acompañarse. Sin la nueva RPC, un error
   de contrato sigue mostrándose como información no disponible, no como cero.
   El lector alternativo se activa sólo ante columnas/tablas/relaciones ausentes;
   errores de permisos, sesión, cancelación, timeout o red no habilitan fallback.
   Se valida wrapper, modelo, sección, estructura, valores monetarios y estados.
5. Opcional y **separado**: revisar/ejecutar
   `supabase/EJEMPLOS-CAJA-OPCIONAL.sql`. Crea dos cuentas NIO/USD EJEMPLO,
   saldo inicial cero y un `gym_clients.is_demo=true`, sin perfil/login, plan,
   teléfono, correo, visita, transacción, deuda ni crédito. Identificadores
   estables, sin UPDATE; repetir no reinicia saldos. Conflictos abortan la
   transacción. No está incluido en SETUP, ACTUALIZAR ni FASE2. No es una
   demo aislada ni una implementación de cobros.

### Interpretación de las lecturas

- Agregados en **equivalentes NIO guardados** (`amount_nio`), sin consultar FX
  actual, calcular nuevas conversiones o intentar reparar movimientos históricos.
  Resumen diario/mensual: cortes America/Managua. Dinero sólo de completed;
  transferencias no se tratan como ingresos/egresos. Contador de movimientos
  completados sí puede incluir transferencias. Desglose por método: todo el
  historial, no fingir que es sólo el mes; gráficos: días/meses con registros.
- Historial: importe/moneda originales y estados pending/completed/cancelled;
  transferencias neutrales, con estado visible, excluidas del dinero agregado.
- Deuda: debt_nio y debt_usd **separadas**. No compensar credit_nio/credit_usd.
  Sin fuente de facturas/vencimientos: null, «no informado», no cero facturas ni
  días de mora inventados. Falta de filas no certifica una cuenta corriente completa.
- Cuentas: balance **informado** en moneda propia, sin recalcular ni certificar
  arqueo. Varias cash_sessions abiertas se cuentan y la última se identifica como
  informada, no se afirma una única caja correctamente arqueada.
- Gastos: categorías legibles; no se habilitó formulario de egresos. El esquema
  exportado no tiene is_active para categorías: queda desconocido, no inventado.
- El escritor antiguo observado no valida rol internamente y no ofrece
  idempotencia; reduce deuda en ambas monedas y suma equivalentes NIO incluso a
  cuentas USD. No se reutiliza. Permisos EXECUTE previos y cuerpo de
  get_fx_nio_per_usd no estaban en el CSV: no se afirma exposición anónima probada.
- No se reparan automáticamente saldos, deudas ni conversiones previas. La ruta
  nativa conserva sus vistas/cortes y escritor; este cambio no certifica su
  contabilidad ni corrige todas las limitaciones históricas de FASE1.

### Prueba local y revisión remota pendiente

Pruebas con fixtures sin registros reales: migración repetible y snapshots
financieros intactos; nueve secciones en transacciones READ ONLY; separación de
monedas; cortes UTC/Managua en borde de día/mes; estados/cuentas; conservación de
RLS y acceso limitado; bloqueo CRM/escritor antiguo por rol; escritor nativo
intacto; seed opcional idempotente, sin reset de saldo ni creación de usuarios,
y aborto por conflictos sin convertir personas reales en ejemplos. Tests de
aplicación: fallback sólo de contrato, errores seguros, respuesta inválida,
monedas, estados y SSR de Caja/Cuentas. No equivalen a E2E en Supabase remoto.

Tras revisar/aplicar el incremental, con el Preview del PR actualizado: abrir
Caja/Cuentas/Reportes/Gastos como staff/admin, comprobar valores contra la base,
verificar botón de cobro bloqueado y que un member no acceda al panel. Si se
elige el seed opcional, comprobar sus identificadores y conservar separado de
los registros reales. **PR #10 sigue sin merge. No declarar demo financiera
completa hasta esas pruebas y el acuerdo de reglas con el dueño.**

Salida de validación local de este avance (secuencial, 2026-10-15):
- `npm run typecheck`: `tsc --noEmit`, exit 0.
- `npm run lint`: `10 problems (0 errors, 10 warnings)`; advertencias previas.
- `npm run test:auth`: `tests 106`, `pass 106`, `fail 0`.
- `npm run build`: `Compiled successfully`, `Generating static pages (41/41)`.
  Sigue el aviso previo metadataBase, no fallo de compilación.
- `npm run test:sql`: suite histórica «Todo pasó»; CRM 48 y compatibilidad 67.
- `node scripts/build-sql.mjs --check`: «Todo al día — 9 clases por semana».
- `git diff --check`: sin errores. No se aplicó SQL a Supabase remoto.

## Capturas remotas de Caja y corrección de gráficos (2026-10-16)

El usuario compartió seis capturas del Preview: se ve la lectura compatible,
0 sesiones abiertas informadas, ingresos/egresos del día en cero, resultado del
mes -NIO 86,600, deudas NIO/USD en cero y ambas cuentas EJEMPLO con saldo cero.
También aparecen conceptos `[SEED-GASTO]` y un agregado sin nombre de método.
Esto prueba el caso de carga mostrado, NO la exactitud contable, el bloqueo de
RPC por rol en remoto, la existencia del cliente EJEMPLO ni las otras pantallas.
No interpretar el resultado negativo como pérdida real del negocio sin revisar
los movimientos y su procedencia. No se borran/excluyen automáticamente seeds.

Las barras tenían alturas porcentuales dentro de columnas sin altura definida;
el resultado negativo además generaba alturas negativas. Se corrige sólo su
representación: alturas explícitas en px, escala compartida por valor absoluto,
eje cero central y negativos debajo, importes disponibles como texto/tabla
expandible sin depender del hover. Cero con registros se distingue de ausencia
de registros. En celular se conserva el formato de las fechas mediante scroll
horizontal del gráfico, no de toda la página. No hay cambios a consultas,
agregados, importes, permisos, migraciones ni datos.

Accesos rápidos: «Ver categorías de gastos» y aclaración de consulta, sin
prometer registrar egresos; deuda informada por moneda en vez de cuotas
inferidas; reporte enlazado sin prometer desglose no incluido en esa página.
Tipos de cuenta traducidos y método sin nombre: «Sin método informado», sin
asignar un método a transacciones existentes.

Pruebas nuevas: negativos, mixtos, cero, sin filas, valores desconocidos,
anchura/fechas del gráfico móvil y enlaces sin promesas de escritura. La salida
SSR prueba el markup/estilos generados; no sustituye revisión visual del Preview
en el teléfono. PR #10 permanece sin merge. Este ajuste **no necesita SQL nuevo**.

Salida real local posterior al ajuste: typecheck `tsc --noEmit` exit 0; lint
`10 problems (0 errors, 10 warnings)` previos; test:auth `tests 112`, `pass 112`,
`fail 0`; build `Compiled successfully` y `41/41` (aviso previo metadataBase);
test:sql «Todo pasó», CRM 48 y compatibilidad 67; build-sql --check al día;
git diff --check sin errores. Sin ejecución remota ni certificación visual nueva.

## Confirmación de gráficos y contención móvil (2026-10-16)

Las capturas nuevas de 07:29 en el Preview `3e5minnn6` muestran barras negativas
(-166.5K/-86.6K) y tabla expandida de ingresos en cero. Se valida ese caso visual,
no sus importes contables. Las capturas de 07:15 adjuntas otra vez corresponden
al Preview anterior (`f78mjvkhv`), no prueban regresión del texto de accesos.
La captura de Cliente EJEMPLO ya validada tampoco se interpreta como nueva prueba de Caja.

Se detectó que la grilla móvil, sin columnas explícitas ni min-width:0 en sus
hijos, heredaba el ancho mínimo del gráfico. Corrección acotada: columna
minmax(0,1fr) en móvil, tarjetas/section min-w-0 y contenedor scroll w-full,
min-w-0/max-w-full. Sólo la tira interna mantiene ancho mínimo para las fechas.
El área desplazable tiene nombre accesible y foco de teclado. Sin ocultar el
overflow del body, sin modificar importes, consultas, cobros ni SQL.

Comprobación real con Chromium local, markup SSR de CashPanel con 14 días
sintéticos, CSS compilado por Next y marco flex/main equivalente (sin cabecera,
sin sesión/Supabase remoto ni navegación completa):

| Viewport px | Documento antes px | Documento después px |
| --- | --- | --- |
| 320 | 527 | 320 |
| 360 | 527 | 360 |
| 393 | 527 | 393 |
| 414 | 527 | 414 |
| 768 | 768 | 768 |
| 1280 | 1280 | 1280 |

Cada tamaño se midió con tablas cerradas y abiertas. Después, el contenedor
interior permite contenido más ancho (477px frente a 318px de área en viewport
360), sin ensanchar la página. El test habitual agrega regresión DOM de la
cadena grid/tarjeta/section/scroll; JSDOM no calcula dimensiones. La medición
Chromium es una comprobación local separada, no E2E del Preview ni de datos
reales. No se agregaron dependencias de navegador al proyecto. Falta confirmar
la contención en teléfono y revisar Cuentas/Reportes/Gastos. PR sin merge.

Salida real local del ajuste de contención: typecheck `tsc --noEmit`, exit 0;
lint `10 problems (0 errors, 10 warnings)` previos; test:auth `tests 113`,
`pass 113`, `fail 0`; build `Compiled successfully` y `41/41`, con aviso previo
metadataBase; test:sql «Todo pasó», CRM 48 y compatibilidad 67; build-sql --check
al día y diff --check sin errores.

## Error de servidor al abrir otra pantalla financiera (2026-10-16)

Capturas del Preview `2797tstu0`: Caja muestra el scroll interno del gráfico,
tablas abiertas/cerradas, tipos de cuenta traducidos y enlace «Ver categorías de
gastos». También aparecen Administración y Clientes; no se dan por validados
sus KPI/datos por abrir. La última captura muestra error de servidor con digest
`3219287748`, sin ruta visible. Por el flujo solicitado se revisa Cuentas, sin
atribuir ese digest a una causa sólo por su número ni certificar todos los enlaces.

Se encontró un defecto concreto en Cuentas **y** Reportes: ambas páginas servidor
importaban y ejecutaban `formatMoney` desde `cash-panel.tsx`, marcado `use client`.
La lectura podía completarse y después fallar el render, fuera de readFinance.
Reproducción antes del arreglo con Next 16 en producción (fixture aislada):
«Attempted to call formatMoney() from the server but formatMoney is on the client».
El digest local es distinto del remoto: no se usa como identificación del origen.

Corrección: mover la implementación sin cambios de comportamiento a
`src/lib/finance/format-money.ts`, sin directiva cliente, React, datos, sesión ni
conversión FX. Caja, Cuentas y Reportes importan esa misma función pura. No se
cambian saldos, deuda, consultas, permisos, cobros ni SQL. No se convierte la
página entera en cliente ni se oculta el fallo como lectura vacía.

### Por qué no bastaban las pruebas anteriores

El build habitual sin Supabase renderiza el placeholder y no ejercita el camino
con lecturas exitosas. El loader SSR de tests compila módulos como JS y no aplica
la frontera RSC de Next a `use client`; por eso podía ejecutar el formateador y
pasar aunque producción fallara. Se reconoce ese hueco de cobertura.

- Pruebas unitarias: mismo formato NIO/USD, signo, decimales, compacto y valores
  desconocidos; páginas con filas y vacías bajo un módulo cliente trampa que
  falla si se llama desde servidor.
- **`npm run test:finance:rsc`**, agregado a CI: genera una aplicación Next
  temporal dentro de .next, reutiliza las páginas originales y sus componentes,
  y sustituye únicamente lecturas/sesión/configuración por fixtures explícitas.
  Construye/prerenderiza con Next en producción y webpack, con filas y vacío,
  y verifica HTML financiero esperado en Cuentas/Reportes, sin aviso de fallo.
  Limpia los archivos temporales; no agrega rutas, bypass de permisos ni datos
  de ejemplo al producto, no usa credenciales y no accede a Supabase.
- El prerender real falló antes del cambio y pasa después en los cuatro casos
  (dos páginas por dos estados). Es prueba de render/frontera RSC, no E2E de la
  instalación remota, RLS o contenido comercial. Build principal sigue Turbopack.

Pendiente abrir Cuentas y Reportes en el nuevo Preview, confirmar cuál enlace
mostró el error si no fue Cuentas y luego revisar Gastos. No pedir ejecutar otra
vez SQL por un fallo de render. Cobros sin habilitar; PR #10 sin merge.

Salida real local posterior: typecheck `tsc --noEmit`, exit 0; lint `10 problems
(0 errors, 10 warnings)` previos; test:auth `tests 121`, `pass 121`, `fail 0`;
test:finance:rsc «Cuentas y Reportes prerenderizados con filas y vacíos»;
build principal `Compiled successfully` y `41/41`, con aviso previo metadataBase;
test:sql «Todo pasó», CRM 48 y compatibilidad 67; build-sql --check al día y
diff --check sin errores. Ningún SQL remoto ejecutado. Validación remota pendiente.

## Capturas posteriores: Cuentas vacía y Reportes con filas (2026-10-16)

El usuario compartió Cuentas por cobrar (22:28) sin error de servidor: cero filas,
NIO cero, mora no informada y mensaje de consulta sin deudas informadas. Se
confirma el caso de render/lectura vacía, no que todos los clientes estén al día.
Reportes (22:40) muestra octubre con egresos 86,600 y septiembre 166,500,
ingresos cero y resultados negativos; total del desglose 253,100. Son valores
mostrados en las capturas, no una auditoría ni una pérdida real certificada;
Caja ya había mostrado movimientos con conceptos `[SEED-GASTO]`.

Se detectó una presentación engañosa: «Qué método se usa más para cobrar» y
«Otros» presentaban el volumen de egresos como si fueran cobros. Ahora Reportes
muestra ingresos, egresos y volumen de los campos ya leídos, todos NIO, y explica
que volumen = ingresos + egresos, no resultado ni saldo de cuenta. Sin nombre:
«Sin método informado», sin asignar un método a transacciones. El desglose aclara
que abarca todo el historial de movimientos completados, no sólo el mes de la
tabla. No hay nuevas conversiones, compensaciones, consultas ni exclusión de seeds.

Tabla mensual: mes y cantidades/signo sin salto de línea, ancho mínimo sólo en
la tabla y scroll horizontal interno con foco/nombre accesible. No se oculta el
overflow de la página. Mensaje vacío acotado a los resultados de esta consulta,
no afirmación de ausencia de movimientos durante doce meses completos.

Pruebas añadidas: egresos sin método, mezcla ingreso/egreso sin netear campos,
mes/signo juntos, contención DOM y estado vacío. Next/RSC mantiene verificación
con filas/vacío y ahora comprueba etiquetas de los tres importes por método.
Chromium local real con markup de la página, lecturas/sesión simuladas y CSS de
producción: en 320/360/393/414/768/1280px, ancho del documento igual al viewport,
antes y después de desplazar la tabla; cada celda de datos permanece en una
línea. En móvil la tabla mide 512px y sólo su contenedor se desplaza. Sin cabecera,
sin navegación o sesión real de Supabase: no es E2E remoto ni valida importes.

Este ajuste es sólo presentación, sin SQL nuevo, permisos ni habilitación de
cobros. Pendiente revisar Gastos; PR #10 permanece sin merge.

Salida real local del ajuste de Reportes: typecheck `tsc --noEmit`, exit 0;
lint `10 problems (0 errors, 10 warnings)` previos; test:auth `tests 125`,
`pass 125`, `fail 0`; Next/RSC Cuentas y Reportes con filas/vacíos PASS;
build `Compiled successfully` y `41/41` (aviso previo metadataBase);
test:sql «Todo pasó», CRM 48 y compatibilidad 67; build-sql --check y
diff --check PASS. No se ejecutó SQL remoto. Ajuste visual nuevo pendiente
comprobar en Preview; carga anterior con filas confirmada por captura.
