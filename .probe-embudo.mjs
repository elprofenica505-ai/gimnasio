import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import { authMinimo } from "./scripts/helpers/pglite-auth-min.mjs";
const db = new PGlite();
await authMinimo(db);
try {
  await db.exec(readFileSync("supabase/INSTALAR-BASE.sql", "utf8"));
} catch (e) {
  console.log("ERROR:", String(e).slice(0, 300));
}
const checks = [
  ["tabla plans", "to_regclass('public.plans') is not null"],
  ["tabla gym_clients", "to_regclass('public.gym_clients') is not null"],
  ["tabla products", "to_regclass('public.products') is not null"],
  ["tabla payment_methods", "to_regclass('public.payment_methods') is not null"],
  ["fn finance_record_movement(10)", "to_regprocedure('public.finance_record_movement(uuid,text,uuid,numeric,text,text,text,text,numeric,text)') is not null"],
  ["fn plan_register_segment(7)", "to_regprocedure('public.plan_register_segment(uuid,text,numeric,text,uuid,uuid,text)') is not null"],
  ["fn crm_is_staff()", "to_regprocedure('public.crm_is_staff()') is not null"],
];
for (const [nombre, cond] of checks) {
  const r = await db.query(`select ${cond} as ok`);
  console.log(r.rows[0].ok ? "OK " : "FALTA", nombre);
}
process.exit(0);
