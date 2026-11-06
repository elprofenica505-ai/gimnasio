-- ============================================================
--  DIAGNÓSTICO DE SOLO LECTURA — ESQUEMA FINANCIERO Y VECINOS
-- ============================================================
--  Para cerrar el hueco #5 (docs/INVENTARIO-DATOS-STRONG.md §8.7).
--  La instalación nueva reproduce el esquema «bank_accounts_split»
--  a partir de diagnósticos viejos; este archivo es la comprobación
--  final contra la realidad.
--
--  CÓMO SE USA
--    1. Supabase de Strong (proyecto viejo) → SQL Editor → pegar
--       este archivo TAL CUAL → Run → copiar TODA la salida.
--    2. Supabase del gimnasio nuevo (después de INSTALAR-BASE.sql)
--       → lo mismo.
--    3. Comparar las dos salidas fila por fila (diff). El PR #4 no
--       se fusiona hasta que la diferencia sea cero, o hasta que
--       cada diferencia quede explicada y aceptada a propósito.
--
--  NO MODIFICA NADA: sólo lee catálogos del sistema. La salida es
--  una única tabla ordenada (seccion | objeto | detalle), pensada
--  para copiarse completa y diffearse sin ambigüedad.
--
--  Diferencias ESPERADAS (no son error, están documentadas):
--    · Filas de datos: este diagnóstico NO cuenta filas; la base de
--      Strong tiene la operación del gimnasio, la nueva nace vacía.
--    · Cuerpos de funciones: sólo se lista nombre+firma. Las
--      funciones de la instalación nueva vienen de la cadena del
--      repo, que es MÁS NUEVA que la base de Strong.
--    · record_payment: en Strong existe (la creó el sistema viejo);
--      en la instalación nueva NO debe existir (00023 sólo la
--      bloquea si ya existía y ningún módulo la llama).
-- ============================================================

with tablas(t) as (
  values
    -- tablas del modelo split que la instalación nueva crea
    ('bank_accounts'), ('payment_methods'), ('transactions'),
    ('member_balances'), ('expense_categories'), ('cash_sessions'),
    -- tablas financieras que crea la cadena después
    ('finance_entries'), ('finance_settings_audit'),
    -- tabla vecina que el artefacto completa (full_name, specialty)
    ('coaches'),
    -- tablas del modelo histórico repository: en la instalación
    -- nueva NO deben existir; lo que haya en Strong, que se vea
    ('accounts'), ('invoices'), ('invoice_items'), ('cash_registers')
)
select seccion, objeto, detalle
  from (
        -- 00. Resumen: qué modelo ve el clasificador de 00022
        select '00.layout' as seccion,
               'crm_finance_layout()' as objeto,
               coalesce(public.crm_finance_layout(), 'NULL') as detalle

        union all
        -- 01. Existencia de cada tabla
        select '01.tabla', t,
               case when to_regclass('public.' || t) is null
                    then 'NO EXISTE' else 'existe' end
          from tablas

        union all
        -- 02. Columnas: posición | tipo | largo | nullable | default
        select '02.columna',
               c.table_name || '.' || c.column_name,
               c.ordinal_position::text || '|' || c.data_type || '|' ||
               coalesce(c.character_maximum_length::text, '') || '|' ||
               c.is_nullable || '|' || coalesce(c.column_default, '')
          from information_schema.columns c
          join tablas on c.table_name = tablas.t
         where c.table_schema = 'public'

        union all
        -- 03. Constraints: PK, FK, CHECK, UNIQUE (y triggers con
        --     constraint). En orden alfabético de tabla.nombre.
        select '03.constraint',
               con.conrelid::regclass::text || '.' || con.conname,
               pg_get_constraintdef(con.oid)
          from pg_constraint con
          join tablas on con.conrelid = to_regclass('public.' || tablas.t)

        union all
        -- 04. Índices (definición completa)
        select '04.indice',
               ix.tablename || '.' || ix.indexname,
               ix.indexdef
          from pg_indexes ix
          join tablas on ix.tablename = tablas.t
         where ix.schemaname = 'public'

        union all
        -- 05. Políticas RLS: comando | roles | using | with check
        select '05.politica',
               pol.polrelid::regclass::text || '.' || pol.polname,
               case pol.polcmd
                 when 'r' then 'SELECT' when 'a' then 'INSERT'
                 when 'w' then 'UPDATE' when 'd' then 'DELETE'
                 else 'ALL' end ||
               '|roles=' || coalesce((
                 select string_agg(r.rolname, ',' order by r.rolname)
                   from unnest(pol.polroles) as g(roleid)
                   join pg_roles r on r.oid = g.roleid), '') ||
               '|using=' || coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') ||
               '|check=' || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')
          from pg_policy pol
          join tablas on pol.polrelid = to_regclass('public.' || tablas.t)

        union all
        -- 06. RLS activada + permisos de tabla (ACL)
        select '07.permiso',
               c.relname,
               'rls=' || c.relrowsecurity ||
               '|acl=' || coalesce(c.relacl::text, 'default')
          from pg_class c
          join tablas on c.oid = to_regclass('public.' || tablas.t)
         where c.relnamespace = 'public'::regnamespace

        union all
        -- 08. Enums del dominio financiero: etiquetas en orden
        select '08.enum',
               ty.typname,
               string_agg(en.enumlabel, ',' order by en.enumsortorder)
          from pg_type ty
          join pg_enum en on en.enumtypid = ty.oid
         where ty.typname in ('transaction_status', 'transaction_type')
         group by ty.typname

        union all
        -- 09. Vista de saldos: columnas en orden
        select '09.vista',
               'v_account_balances',
               case when to_regclass('public.v_account_balances') is null
                    then 'NO EXISTE'
                    else coalesce((
                           select string_agg(v.column_name, ','
                                              order by v.ordinal_position)
                             from information_schema.columns v
                            where v.table_schema = 'public'
                              and v.table_name = 'v_account_balances'), '')
               end

        union all
        -- 10. Funciones del dominio financiero: nombre/firma.
        --     INFORMATIVO: los cuerpos difieren a propósito (la
        --     cadena del repo es más nueva que la base de Strong).
        select '10.funcion',
               p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
               'existe'
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and (p.proname ~ '^(finance_|cashier_|record_payment$|crm_finance_)')
       ) x
 order by seccion, objeto;
