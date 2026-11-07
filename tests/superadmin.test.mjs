import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isStaffRole,
  isFinanceRole,
  isAdminRole,
  isSuperAdminRole,
  mfaStateFromLevels,
} from "../src/lib/auth/current-user.ts";
import { panelAccess, visibleModules } from "../src/lib/admin/modules.ts";

test("el súper administrador es staff, finanzas y administrador", () => {
  assert.equal(isStaffRole("superadmin"), true);
  assert.equal(isFinanceRole("superadmin"), true);
  assert.equal(isAdminRole("superadmin"), true);
  assert.equal(isSuperAdminRole("superadmin"), true);
  // Los demás roles no se ven afectados.
  assert.equal(isSuperAdminRole("admin"), false);
  assert.equal(isSuperAdminRole("cashier"), false);
  assert.equal(isAdminRole("cashier"), false);
  assert.equal(isStaffRole("member"), false);
  assert.equal(isStaffRole(null), false);
});

test("el MFA también le aplica al súper administrador", () => {
  assert.equal(mfaStateFromLevels("superadmin", { currentLevel: "aal2" }), "ok");
  assert.equal(
    mfaStateFromLevels("superadmin", { currentLevel: "aal1", nextLevel: "aal2" }),
    "verify",
  );
  assert.equal(
    mfaStateFromLevels("superadmin", { currentLevel: "aal1", nextLevel: "aal1" }),
    "enroll",
  );
});

test("el panel del súper administrador es idéntico al del administrador", () => {
  assert.equal(panelAccess("superadmin"), "all");
  const admin = visibleModules("admin");
  const superadmin = visibleModules("superadmin");
  assert.deepEqual(superadmin.map((m) => m.id), admin.map((m) => m.id));
  // La sección nueva de ventas online también para el dueño del aplicativo.
  const finanzas = superadmin.find((m) => m.id === "finanzas");
  assert.equal(finanzas.children.some((c) => c.id === "ventas"), true);
});

test("el súper administrador nunca aparece como opción asignable", async () => {
  // La lista de roles asignables vive en el gestor: no incluye superadmin.
  // (La base lo rechaza además con SUPERADMIN_PROTECTED.)
  const origen = await import("fs").then((fs) =>
    fs.readFileSync(new URL("../src/components/admin/roles-manager.tsx", import.meta.url), "utf8"),
  );
  assert.match(origen, /"member", "cashier", "trainer", "admin"/);
  assert.doesNotMatch(origen, /SELECTABLE = \[[^\]]*superadmin/);
});
