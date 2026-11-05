// Base de datos de prueba en memoria (PGlite) para las migraciones del repo.
// Centraliza el orden real de aplicación y el shim de `auth` que usa Supabase,
// para que las pruebas SQL no repitan (ni desordenen) la lista de migraciones.
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const root = new URL("../../", import.meta.url);
export const sqlFile = (path) => readFileSync(new URL(path, root), "utf8");

const authShim = `
  create schema auth;
  create role anon nologin;
  create role authenticated nologin;
  create table auth.users(
    id uuid primary key default gen_random_uuid(),
    email text,
    raw_user_meta_data jsonb default '{}'::jsonb,
    created_at timestamptz default now()
  );
  create table auth.current_user(id uuid, aal text);
  create function auth.uid() returns uuid language sql stable as
    $$select id from auth.current_user limit 1$$;
  create function auth.jwt() returns jsonb language sql stable as
    $$select jsonb_build_object('aal', aal) from auth.current_user limit 1$$;
  grant usage on schema auth to anon, authenticated;
  grant select on auth.current_user to anon, authenticated;
`;

// Catálogo base: el fixture neutro reemplaza a 00002_seed.sql (vaciada).
// Mismos ids estables que las suites referencian; sin clases programadas.
const first = [
  "supabase/migrations/00001_schema.sql",
  "tests/fixtures/base-catalog.sql",
  "tests/fixtures/finance-bank-accounts.sql",
  "supabase/migrations/00012_profiles_self_read.sql",
  "supabase/migrations/00020_clients_crm.sql",
  "supabase/migrations/00022_crm_finance_compat.sql",
  "supabase/migrations/00023_finance_read_bank_accounts.sql",
  "supabase/migrations/00024_finance_movements.sql",
  "supabase/migrations/00025_account_assigned_plan.sql",
  "supabase/migrations/00026_booking_read_policy.sql",
  "supabase/migrations/00027_client_finance_read.sql",
  "supabase/migrations/00028_debts_payments.sql",
  "supabase/migrations/00029_cash_change.sql",
  "supabase/migrations/00030_access_hardening.sql",
];

// La prueba no necesita la versión endurecida de `crm_is_staff` de 00032: se
// reemplaza por una equivalente más simple para poder cambiar de rol.
const crmStaff = `
  create or replace function public.crm_is_staff()
  returns boolean language sql stable security definer set search_path = public, pg_temp as $$
    select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
       and exists(select 1 from public.profiles where id = auth.uid() and role::text in ('admin','cashier'));
  $$;
  revoke all on function public.crm_is_staff() from public, anon;
  grant execute on function public.crm_is_staff() to authenticated;
`;

const second = [
  "supabase/migrations/00032_mfa_is_staff_y_privilegios_anon.sql",
  "supabase/migrations/00033_roles_fase_a.sql",
  "supabase/migrations/00034_roles_fase_b.sql",
  "supabase/migrations/00035_asignacion_entrenador.sql",
  "supabase/migrations/00036_personal_no_es_cliente.sql",
  "supabase/migrations/00037_cierre_caja_interruptor.sql",
  "supabase/migrations/00038_caja_resumen_deudas.sql",
  "supabase/migrations/00039_medidas_metas_rutinas.sql",
  "supabase/migrations/00040_mi_progreso_cliente.sql",
  "supabase/migrations/00041_asistencia_cliente.sql",
  "supabase/migrations/00042_productos_stock_categorias.sql",
  "supabase/migrations/00043_plan_nutricion_interruptor.sql",
  "supabase/migrations/00044_calculadora_cliente.sql",
  "supabase/migrations/00045_registro_gimnasio_calculadora.sql",
  "supabase/migrations/00046_meta_rutina_desde_calculadora.sql",
  "supabase/migrations/00047_menores_consentimiento_aprobacion.sql",
  "supabase/migrations/00048_edad_desde_fecha_nacimiento.sql",
  "supabase/migrations/00049_personal_datos_y_baja.sql",
];

const coachShim = `
  alter table public.coaches add column if not exists full_name text;
  alter table public.coaches add column if not exists specialty text;
  update public.coaches set full_name = coalesce(full_name, name),
    specialty = coalesce(specialty, role_es);
`;

const third = [
  "supabase/migrations/00050_coaches_vista_publica.sql",
  "supabase/migrations/00051_coaches_vista_landing.sql",
  "supabase/migrations/00052_altura_en_ficha.sql",
  "supabase/migrations/00053_correccion_altura_admin.sql",
  "supabase/migrations/00054_mi_progreso_altura_ficha.sql",
  "supabase/migrations/00055_menores_rutas_personal.sql",
  "supabase/migrations/00056_permisos_caja_separados.sql",
  "supabase/migrations/00057_pase_del_dia_tarifa.sql",
  "supabase/migrations/00058_tarifas_gimnasio_nio.sql",
  "supabase/migrations/00059_cobro_con_productos.sql",
  "supabase/migrations/00064_disciplinas_activas.sql",
  "supabase/migrations/00067_vigencias_planes.sql",
  "supabase/migrations/00068_catalogo_planes.sql",
  "supabase/migrations/00069_catalogo_planes_plan_class_state.sql",
];

/**
 * Crea una base limpia con el esquema y los datos base del gimnasio.
 * `extra` recibe migraciones adicionales que la prueba necesite aplicar.
 */
export async function createTestDb({ extra = [] } = {}) {
  const db = new PGlite();
  await db.exec(authShim);
  for (const file of first) await db.exec(sqlFile(file));
  await db.exec(crmStaff);
  for (const file of second) await db.exec(sqlFile(file));
  await db.exec(coachShim);
  for (const file of third) await db.exec(sqlFile(file));
  for (const file of extra) await db.exec(sqlFile(file));
  return db;
}

/** Helpers de rol: ejecutan como `authenticated` con el usuario indicado. */
export function actors(db) {
  const row = async (query, args = []) => (await db.query(query, args)).rows[0];

  async function as(actor, aal, query, args = []) {
    await db.exec("reset role; delete from auth.current_user");
    if (actor) await db.query("insert into auth.current_user values($1,$2)", [actor, aal]);
    await db.exec("set role authenticated");
    try {
      return await db.query(query, args);
    } finally {
      await db.exec("reset role; delete from auth.current_user");
    }
  }

  const rpcAs = async (actor, aal, name, args) =>
    (
      await as(
        actor,
        aal,
        `select public.${name}(${args.map((_, i) => `$${i + 1}`).join(",")}) as value`,
        args,
      )
    ).rows[0].value;

  return { row, as, rpcAs };
}
