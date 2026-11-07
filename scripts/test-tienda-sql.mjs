// TIENDA PÚBLICA: el catálogo se lee sin sesión y sin exponer costos.
import { createTestDb, sqlFile } from "./helpers/sql-test-db.mjs";
import assert from "node:assert/strict";

let checks = 0;
const ok = (label, cond) => {
  assert.ok(cond, label);
  checks += 1;
  console.log(`✅ ${label}`);
};

const db = await createTestDb();
await db.exec(sqlFile("supabase/migrations/00101_tienda_publica.sql"));
ok("00101 se aplica sobre la cadena completa sin error", true);

const row = async (query, args = []) => (await db.query(query, args)).rows[0];

await db.query(
  `insert into public.products (name, category, price, cost, status) values
   ('Creatina', 'Suplementos', 1200, 900, 'activo'),
   ('Agua', 'Bebidas', 24, 12, 'activo'),
   ('Producto interno', 'Varios', 100, 50, 'inactivo')`,
);

// Anónimo: ve sólo activos y sin costo.
await db.exec("reset role; delete from auth.current_user");
await db.exec("set role anon");
const ver = (await db.query("select * from public.tienda_productos()")).rows;
await db.exec("reset role; delete from auth.current_user");

ok("anónimo ve exactamente los productos activos (2)", ver.length === 2);
ok("el catálogo no expone el costo ni el estado",
  ver.every((p) => !("cost" in p) && !("status" in p) && !("stock_min" in p)));
ok("orden estable por categoría y nombre", ver[0].name === "Agua");

ok("la tabla products sigue sin lectura directa para anon",
  (await row(
    "select count(*) as n from information_schema.role_table_grants where table_schema='public' and table_name='products' and grantee='anon'",
  )).n === 0);

console.log(`\n🧪 ${checks} comprobaciones de la tienda pública`);
process.exit(0);
