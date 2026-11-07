# Seguridad 1C — Acceso y recuperación de contraseña

18 de octubre de2026. Base: PR12 mergeado (`538101e`). Rama:
`arena/1e67d1fd-strong-gym`. Código/documentación, pruebas aisladas y revisión Auth
en sólo lectura; no SQL,
correos reales enviados, usuarios modificados, factores MFA ni ajustes remotos.

## 1. Qué construye este bloque

1. En ingreso ES/EN aparece **¿Olvidaste tu contraseña?**.
2. `/es/recuperar` y `/en/recuperar`: solicitud mediante Supabase Auth SDK.
   Respuesta neutral si el SDK acepta la solicitud: «Si existe una cuenta…».
   No confirma que una dirección exista ni que el correo haya sido entregado.
   Un error/rate limit no se transforma en envío exitoso. Bloqueo de doble submit
   en cliente, no rate limiter servidor ni sustituto de CAPTCHA/protección del proveedor.
3. `/api/auth/callback`: intercambia un código PKCE con el SDK/SSR, persiste cookies
   y verifica identidad con getUser antes del destino fijo. No usa service_role,
   token_hash, roles de metadata ni getSession como prueba de autorización.
   GET no escribe datos de negocio; intercambia la credencial de un uso del email.
4. Código ausente/vencido/reutilizado, verificador ausente, proveedor caído o usuario
   distinto: error explícito y nuevo enlace, sin eco de códigos/mensajes sensibles.
   El código depende del navegador donde se inició el pedido: abrir el correo en otro
   navegador/dispositivo puede fallar. Usar el último enlace si se pidieron varios.
5. `/es/recuperar/actualizar` (también EN) requiere una identidad verificada en servidor.
   No alcanza con querystring. Antes del cambio se vuelve a verificar el ID: si la
   cuenta cambió en otra pestaña no modificar la nueva identidad accidentalmente.
   Un usuario ya autenticado también puede cambiar SU contraseña desde esta página;
   `flow=recovery` NO es un privilegio ni una prueba independiente del tipo de correo.
6. Registro NUEVO y recuperación usan12–128 caracteres, coincidencia y sin trim de
   contraseña. Login no exige12: contraseñas existentes siguen funcionando. Es
   validación de la aplicación, NO se afirma haber cambiado/enforzado la política
   de todo Supabase Auth; un cliente externo sigue sujeto a la política del proveedor.
7. Se exige confirmación del SDK antes de mostrar «Contraseña actualizada». Error o
   respuesta perdida: resultado no confirmado, sin reintento automático. Si el SDK
   confirma el cambio, se intenta logout global; si falla, se informa que la contraseña
   SÍ cambió, sin invitar a repetir la escritura. Access tokens previos pueden valer
   hasta su vencimiento incluso tras logout/revocación de refresh tokens.
8. Logout normal ahora verifica error del SDK antes de limpiar estado; no anuncia
   cierre confirmado ante error. Quitado aviso optimista del menú.
9. Retorno de registro usa el mismo callback PKCE, respetando idioma. Redirect de
   ingreso/registro sólo admite rutas internas del idioma, sin URLs externas,
   backslashes, porcentajes, dot segments, queries, fragmentos ni bucles de auth.
   Destinos administrativos mantienen sus propios guards, no conceden rol por redirección.
10. Demo no muestra formularios ni crea identidades. Producción sin configuración
    sigue503. Callback/recuperación usan no-store/no-referrer/noindex; encabezados
    adicionales para que códigos/credenciales no se propaguen como Referer.

## 2. Preparación del correo — sin modificaciones remotas

No hace falta SQL. No cambiar contraseñas, desactivar confirmación ni retirar roles.

**Actualización de revisión real:** [informe previo a publicación](REVISION-CORREO-AUTH.md).
Dominio, patrón de destinos y templates son compatibles. SMTP propio NO configurado;
el correo general a clientes sigue bloqueado para aceptación productiva. No se enviaron
mensajes ni se modificó configuración. La lista siguiente es una referencia de destinos,
no una instrucción para añadirlos repetidos al patrón existente.

Antes de dar por operativo el correo real, revisar en Authentication → URL Configuration:

- Site URL del dominio confirmado: `https://strong-gym-gamma.vercel.app`.
- Conservar destinos anteriores durante transición. Agregar, si faltan, estos destinos
  concretos a Redirect URLs (no autoriza al agente a cambiarlos remotamente):

```text
https://strong-gym-gamma.vercel.app/api/auth/callback?locale=es&flow=signup
https://strong-gym-gamma.vercel.app/api/auth/callback?locale=en&flow=signup
https://strong-gym-gamma.vercel.app/api/auth/callback?locale=es&flow=recovery
https://strong-gym-gamma.vercel.app/api/auth/callback?locale=en&flow=recovery
```

El SDK actual usa PKCE legacy compatible por defecto; no se habilitó el flag
experimental de agregar flow IDs dinámicos. No sustituir una allowlist por dominios
Vercel globales. Para probar una preview/local, autorizar SU origen concreto y
conservar las mismas rutas/parámetros; la cookie de PKCE no viaja entre orígenes.
No quitar rutas previas sin revisar correos vigentes. Esta entrega no cambia templates:
la ruta soporta retorno de `ConfirmationURL` con `code`, no hash fragments/token_hash.
Si una plantilla personalizada usa otro formato, revisar antes de publicar.

Revisar SMTP/entregabilidad/límites, confirmación, expiración/reautenticación,
contraseñas filtradas y CAPTCHA en el proveedor. No habilitar CAPTCHA sin implementar
su interacción en la app. La revisión posterior consultó la configuración Auth existente
en sólo lectura: los campos SMTP no están configurados. No se solicitaron claves API
ni variables de Vercel y no se guardó la respuesta completa. Ver informe enlazado.
No se promete una auditoría completa de Auth.

## 3. MFA — límites y siguiente bloque

- No enroll/unenroll, obligatorio global, QR MFA, llaves ni cambios a administradores.
- El recorrido de cambio consulta identidad/AAL y se detiene en cliente si hay factor
  verificado que requiere aal2 o no se puede leer el nivel. No desactiva el factor.
- Esa comprobación de UI NO sustituye enforcement MFA en Auth/servidor/RLS ni evita
  por sí sola que un cliente externo use el API Auth. Protección integral MFA de las
  rutas/API/datos y una UI de challenge todavía NO están implementadas.
- Antes de habilitar MFA admin: challenge/step-up, políticas del servidor/base,
  sesión/refresco y recuperación de factores, método de respaldo y prueba del dueño
  para no bloquearle acceso. No pedir contraseñas, QR/semillas ni códigos por chat.

## 4. Evidencia aislada y revisión posterior

- Política de redirección y casos de recuperación/cambio/error/MFA/logout.
- Callback ejecutado con SDK/SSR reales y transporte simulado: /recover genera PKCE,
  se verifica el challenge SHA256 al canjear código, se guardan cookies, se llama
  /user con token nuevo y se rechaza replay sin verificador. NO envío real ni
  verificación criptográfica del token ficticio del test.
- React/JSDOM ejecuta formularios reales: demo/sin identidad sin inputs, envío doble
  una sola llamada, fallo no muestra éxito, validación sin SDK y guardado confirmado
  con distinción de logout fallido. Logout normal falla sin borrar identidad.
- Test HTTP producción sin configuración incluye nuevas rutas y callback503.
- Diseño SSR/CSS amplía a264 casos (11 pantallas ×3 fixtures ×8 anchos320–1280).
  No equivale a probar hidratación/entregabilidad en dispositivos reales.
- SQL y regresiones financieras se mantienen aisladas. No repetir Cliente EJEMPLO,
  movimientos ni00030. Ningún merge nuevo queda autorizado por esta documentación.

Después de publicar con autorización y verificar redirects/SMTP, guiar una prueba
con correo controlado por el usuario: pedir enlace en ese navegador, abrirlo allí,
error de enlace reutilizado, cambio voluntario y nuevo login. No enviar correos ni
cambiar claves reales automáticamente. Esa aceptación todavía está pendiente.

### Resultados locales de esta entrega

```text
typecheck: tsc --noEmit, exit0
lint:0 errores,9 advertencias
build: Compiled successfully;44/44 (flag demo=true, producción sin Supabase)
test:auth:532/532,0 fallos (63 casos nuevos desde PR12)
test:sql: todas las suites aprobadas, seguridad147/deudas95 incluidas
test:finance:rsc: Cuentas/Reportes/Gastos/Comprobante aprobados
test:metadata: páginas ES/EN y API503, no-referrer en rutas nuevas, OG PNG válidos
test:layout:264 casos,11 pantallas/formularios,320–1280px
```

Chromium efímero instalado fuera del producto para la prueba local; no se agregaron
paquetes al proyecto. npm ci informa5 vulnerabilidades high en dependencias; no se
aplicó fix --force ni se afirma auditoría de dependencias resuelta en este bloque.
Concurrencia PostgreSQL y el resto de CI se vuelven a ejecutar en el PR; el resultado
remoto no se presupone por los resultados locales.
