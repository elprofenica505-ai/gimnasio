import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const sql = name => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
let count = 0;
function check(label, value) { assert.ok(value, label); count++; console.log(`✅ ${label}`); }
for (const layout of ["repository", "bank_accounts_split"]) {
  const db = new PGlite();
  try {
    await db.exec(`create schema auth; create role anon nologin; create role authenticated nologin;
      create table auth.users(id uuid primary key default gen_random_uuid(),email text,raw_user_meta_data jsonb default '{}'::jsonb,created_at timestamptz default now());
      create table auth.current_user(id uuid);
      create function auth.uid() returns uuid language sql stable as $$select id from auth.current_user limit 1$$;
      grant usage on schema auth to anon,authenticated; grant select on auth.current_user to anon,authenticated;`);
    for (const name of ["supabase/migrations/00001_schema.sql", "tests/fixtures/base-catalog.sql",
      layout === "repository" ? "supabase/migrations/00010_finance.sql" : "tests/fixtures/finance-bank-accounts.sql",
      "supabase/migrations/00012_profiles_self_read.sql", "supabase/migrations/00020_clients_crm.sql"])
      await db.exec(sql(name));
    const row = async (q, args = []) => (await db.query(q, args)).rows[0];
    const user = async name => (await row("insert into auth.users(email) values($1) returning id", [`${name}@test.invalid`])).id;
    const admin = await user("admin"), member = await user("member"), other = await user("other");
    await db.query("update profiles set role='admin' where id=$1", [admin]);
    const client = (await row("select id from gym_clients where profile_id=$1", [member])).id;
    const plans = (await db.query("select id from plans order by id limit 2")).rows;
    assert.equal(plans.length, 2);
    await db.query("update profiles set plan_id=$1 where id=$2", [plans[0].id, member]);
    await db.query("update gym_clients set notes='SECRET INTERNO',plan_id=null where id=$1", [client]);
    const snapshot = async () => JSON.stringify((await db.query(`select 'client' as kind,to_jsonb(c) as value from gym_clients c union all select 'profile',to_jsonb(p) from profiles p union all select 'tx',to_jsonb(t) from transactions t order by kind,value`)).rows);
    const before = await snapshot();
    const migration = sql("supabase/migrations/00025_account_assigned_plan.sql");
    await db.exec(migration); await db.exec(migration);
    check(`${layout}: instalación repetida no modifica fichas, perfiles ni movimientos`, before === await snapshot());
    async function as(id, q, args = []) {
      await db.exec("reset role; delete from auth.current_user");
      if (id) await db.query("insert into auth.current_user values($1)", [id]);
      await db.exec(`set role ${id ? "authenticated" : "anon"}`);
      try { return await db.query(q, args); }
      finally { await db.exec("reset role; delete from auth.current_user"); }
    }
    const mine = async id => (await as(id, "select crm_my_assigned_plan() as value")).rows[0].value;
    assert.deepEqual(await mine(member), { linked: true, plan: null });
    check(`${layout}: quitar plan no resucita profiles.plan_id legado`, true);
    await as(admin, "select crm_update_client($1,'Cliente prueba',null,null,'client','active',$2,'SECRET INTERNO')", [client, plans[1].id]);
    const assigned = await mine(member);
    check(`${layout}: plan guardado por admin aparece al cliente aunque profile tenga otro`, assigned.plan.id === plans[1].id && (await row("select plan_id from profiles where id=$1", [member])).plan_id === plans[0].id);
    check(`${layout}: sólo expone nombres/id/actividad del plan, sin notas o datos privados`, !JSON.stringify(assigned).includes("SECRET") && Object.keys(assigned).sort().join() === "linked,plan" && Object.keys(assigned.plan).sort().join() === "id,is_active,name_en,name_es");
    assert.deepEqual(await mine(other), { linked: true, plan: null });
    check(`${layout}: otra identidad no recibe plan ajeno`, true);
    check(`${layout}: no se amplía SELECT directo a fichas internas del cliente`, (await as(member, "select * from gym_clients")).rows.length === 0);
    await assert.rejects(as(member, "select crm_my_assigned_plan($1)", [other]), /does not exist/);
    check(`${layout}: RPC sin argumento no permite pedir otra identidad`, true);
    await db.query("update plans set is_active=false where id=$1", [plans[1].id]);
    check(`${layout}: un plan inactivo asignado conserva nombre y no se disfraza de sin plan`, (await mine(member)).plan.is_active === false);
    await db.query("delete from gym_clients where profile_id=$1", [other]);
    assert.deepEqual(await mine(other), { linked: false, plan: null });
    check(`${layout}: sin ficha se distingue de ficha sin plan`, true);
    await assert.rejects(as(null, "select crm_my_assigned_plan()"), /permission denied/);
    check(`${layout}: anónimo sin execute`, true);
    await db.exec("set role authenticated");
    await assert.rejects(db.query("select crm_my_assigned_plan()"), /AUTH/);
    await db.exec("reset role");
    check(`${layout}: authenticated sin auth.uid también se rechaza`, true);
  } finally { await db.close(); }
}
console.log(`\n🎉 Plan propio: ${count} comprobaciones pasaron (PGlite, dos esquemas; sin SQL remoto).`);
