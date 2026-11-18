# Migraciones de producción — operación segura

Esta guía define cómo proteger la base actual del gimnasio. Es una guía de
operación, no una lista de tareas: el seguimiento sigue en
[`PENDIENTES-ACTUALES.md`](PENDIENTES-ACTUALES.md), especialmente **CAL-06**.

## Estado especial 00099–00104

Las migraciones locales 00099 a 00104 ya tienen su estado funcional final en
producción, aunque no hay seis filas individuales equivalentes en el historial
remoto de Supabase. La investigación y las huellas verificadas están en
[`CONCILIACION-MIGRACIONES-00099-00104.md`](CONCILIACION-MIGRACIONES-00099-00104.md).

Por tanto, estos archivos son un **baseline histórico congelado**:

- siguen en Git y en `INSTALAR-BASE.sql` para poder instalar un proyecto nuevo;
- sus funcionalidades siguen activas en la aplicación actual;
- no se borran, renombran, editan ni se vuelven a ejecutar en producción;
- una mejora o corrección se hace en una migración nueva, nunca modificando uno
  de esos seis archivos;
- el chequeo `npm run check:migration-baseline`, ejecutado también en CI,
  verifica sus hashes SHA-256 y que continúen dentro del instalador completo.

“Congelado” sólo se refiere a **no repetir su instalación SQL**. No desactiva
Embudo, Superadmin, Tienda ni ARM.

## Prohibiciones en la base de producción actual

No ejecutar contra este proyecto:

```bash
supabase db push
supabase migration repair --status applied 00099 00100 00101 00102 00103 00104
```

Tampoco pegar los seis archivos, `INSTALAR-BASE.sql` o sus partes en SQL Editor
sobre una base existente. El instalador completo es exclusivamente para un
proyecto nuevo, aislado y vacío; no es un mecanismo de actualización de
producción.

No insertar ni borrar filas directamente en `supabase_migrations.schema_migrations`.
Una entrada histórica inventada es peor que una brecha conocida.

## Regla para una migración nueva

Antes de aplicar cualquier cambio SQL futuro:

1. Crear un archivo SQL nuevo, inmutable y revisable en `supabase/migrations/`.
   No reutilizar ni editar números anteriores.
2. Añadir pruebas proporcionales de reglas, permisos, RLS y concurrencia cuando
   corresponda; ejecutar las suites locales y los chequeos de generación.
3. Aplicar el cambio primero en un proyecto de **staging separado**, con su
   propio `project_ref`, URL y sin datos personales de producción.
4. Comparar en staging el esquema, las políticas, los grants y la operación de
   la pantalla afectada. Tener respaldo y un plan de reversión antes de tocar
   producción.
5. Aplicar una única vez el SQL aprobado a producción usando el mismo método
   que se haya ensayado. Registrar en el PR, en CAL-06 si corresponde, el
   nombre remoto/timestamp devuelto por Supabase y el hash del archivo local.
6. Volver a leer el catálogo remoto y ejecutar las pruebas de aceptación antes
   de declarar el cambio terminado.

Si no existe un staging con conexión identificable de forma independiente, el
paso 5 no se realiza. No se sustituye staging por una preview de Vercel ni por
una rama de Supabase que no exponga una URL o `project_ref` propio para SQL.

## Recuperación ante una duda

Si alguien cree que una migración ya fue aplicada pero no aparece en el
historial:

1. Detener el despliegue SQL; no reintentar ni “forzar” la migración.
2. Comparar, en sólo lectura, tablas, constraints, índices, RLS/policies,
   firmas, cuerpos de función y grants con el archivo local.
3. Guardar la evidencia en un documento técnico enlazado desde la lista viva.
4. Decidir si se trata de un baseline histórico o si hace falta una migración
   nueva correctiva. Nunca asumir que una fila ausente significa que el esquema
   falta.

Este procedimiento busca proteger datos, roles, ventas, caja y conversaciones
existentes, sin impedir que las funcionalidades ya instaladas sigan operando.
