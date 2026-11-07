# Seguridad 1B — Separación demo/producción

Fecha: 18 de octubre de 2026. Base: PR11 mergeado (`545807a`).
Rama: `arena/e27cbf67-strong-gym`. Sin SQL ni cambios en Supabase/Vercel remoto.

## Comportamiento nuevo

| Configuración | Resultado |
|---|---|
| HTTPS + clave pública anon/publishable completa | Supabase real; el flag demo no prevalece. |
| Ambas variables ausentes en producción | Indisponibilidad, nunca demo. |
| Flag demo=true durante build/start de producción | No habilita demo, ni siquiera en previews. |
| next dev + NEXT_PUBLIC_ENABLE_DEMO=true + ambas variables vacías | Demo explícita de sólo lectura. |
| Configuración parcial, URL inválida o clave no pública | No degradar a demo. Next rechaza la configuración presente inválida antes de compilar. |
| Supabase configurado pero red/Auth/RLS falla | Error real; no fallback a datos ficticios ni login local. |

- Política pura compartida en `src/lib/supabase/config-policy.ts`.
- HTTP de Supabase sólo se admite para loopback fuera de producción; producción
  exige HTTPS. No equivale a auditar el certificado TLS externo del dominio final.
- Claves legacy JWT deben declarar role=anon; modernas deben ser sb_publishable_.
  service_role, sb_secret_, JWT de usuario y texto arbitrario son rechazados.
  Es validación estructural, NO verificación criptográfica de la clave: la identidad
  real sigue verificándose con Supabase Auth y perfiles/RLS en el servidor.
- next.config valida ANTES de compilar NEXT_PUBLIC para no publicar una clave privada
  mal colocada. El error nunca imprime URL/clave. Una clave ya expuesta en versiones
  antiguas requeriría investigación/rotación; no se afirma que se haya auditado todo
  el historial o la configuración remota de despliegue.

## Falla cerrada sin credenciales

- Proxy devuelve503 con no-store en ingreso/registro/cuenta/panel/agenda y API.
  JSON de API: CONFIGURATION_UNAVAILABLE, sin eco de entradas ni credenciales.
- Portada ES/EN conserva metadatos/OG y responde200 con aviso de indisponibilidad,
  noindex y no-store. No monta AppProvider ni las pantallas operativas. Imágenes OG
  y assets públicos no necesitan conexión a la base. No presentar HTTP200 de portada
  como prueba de disponibilidad del sistema de gestión.
- Layout agrega defensa antes de leer sesión; SDK server/browser rechazan modo
  unavailable. Lectores sólo devuelven ejemplos cuando DEMO_MODE es explícitamente
  true, no cuando simplemente falta un cliente.
- Páginas administrativas usan DEMO_MODE, no !isSupabaseConfigured; guard de Clientes
  también exige identidad si no está en demo. Sin configuración no se abre el panel.
- Este comportamiento puede comprobarse al construir sin variables: no exige claves
  reales para CI. La compilación correcta no significa conexión verificada.

## Sin contraseñas ni autenticación demo

- Eliminados administrador de ejemplo, contraseña hardcoded, DemoStoredUser y
  escrituras de cuentas/contraseñas en localStorage del proveedor.
- Demo no restaura una identidad desde el navegador. AuthForm no muestra formulario
  de ingreso/registro: no pide correo ni contraseña. Provider rechaza esas acciones,
  reservas/cancelaciones y edición demo sin simular éxitos.
- Botones de cambios locales del panel deshabilitados durante demo; navegación y
  filtros de lectura permanecen disponibles. Su persistencia en modo conectado
  sigue siendo un pendiente separado de producto, no se implementó en esta entrega.
- Al montar el proveedor actualizado se retiran exclusivamente claves antiguas
  `strong-gym:demo-*`. No se borran cookies/sesión Supabase, otras preferencias ni
  referencias de cobros pendientes (importantes para no duplicar movimientos).
- Si no se vuelve a visitar el sitio actualizado o el navegador deniega acceso a
  localStorage, no se afirma haber borrado datos antiguos remotamente.
- Login/registro conectados mantienen SDK Supabase; errores o excepciones no pasan
  a autenticación demo. Sin cambios a contraseñas, roles o usuarios reales.

## Pruebas y límites

- 31 casos nuevos (27 política/build + 4 proveedor/formulario/getters), añadidos a test:auth.
- Matriz producción/desarrollo/test, opt-in, configuración parcial y transporte;
  clave privada/JWT con rol incorrecto rechazados. Build negativo real con valor
  ficticio comprueba rechazo temprano sin mostrarlo.
- React/JSDOM real: no restaurar admin local; limpiar sólo claves demo; no persistir
  nuevas contraseñas; no tocar sesión Supabase ni referencia financiera pendiente;
  SDK conectado invocado y errores/excepciones sin degradación; formulario sin inputs.
- Next producción por HTTP con flag demo=true y sin credenciales:44 solicitudes ES/EN de
  páginas/API GET/POST/PATCH/DELETE bloqueadas503; portada/OG funcionales con aviso,
  sin cuenta de ejemplo. Se integra en test:metadata de CI, no sólo tests de mocks.
- Next dev real local: portada/ingreso/registro/panel200, sin contraseña/admin demo;
  POST reservas503. Servidor efímero apagado al terminar; no base ni claves reales.
- Pruebas previas de roles, SDK refresh, finanzas, deuda/vuelto, SQL y concurrencia
  conservadas. Mocks de entorno ahora distinguen demo explícita de indisponibilidad.

## Entrega

No hay migración nueva ni instrucciones para ejecutar SQL. No repetir00030/00028/
00029. Los datos ficticios PERSISTIDOS en Supabase siguen siendo datos del entorno
conectado: no se confunden con esta demo local. Cliente EJEMPLO/saldos no se tocaron.

Para desplegar, ambas variables públicas reales deben estar configuradas en el
entorno correspondiente de Vercel y reconstruir el despliegue. No pedir al usuario
que comparta valores por chat. Si faltan o son inválidas, corregir configuración;
no activar demo ni relajar guardas para ocultar el error.

La revisión completa de secretos/historial/bundles remotos, Auth/recuperación/MFA,
abuso/CSRF/cabeceras y certificado TLS sigue pendiente. Esta entrega no es una
certificación general ni reorganiza todavía el menú.

### Resultados locales de esta entrega

```text
typecheck: exit0
lint: exit0;0 errores,9 advertencias
build (flag demo=true, sin Supabase): exit0;40/40
test:auth:469/469 (31 casos nuevos)
test:sql: todas las suites aprobadas; seguridad147/deudas95 incluidas
test:finance:rsc: Cuentas/Reportes/Gastos/Comprobante aprobados
test:metadata: HTTP producción y metadatos/PNG aprobados
test:layout:216 casos,320–1280px aprobados
```

Los avisos de desarrollo reportados por npm audit siguen pendientes; no aplicar
fix --force. No se hizo auditoría remota de secretos ni certificado TLS en esta entrega.
