import test from "node:test";
import assert from "node:assert/strict";
import { createLoader } from "./helpers/react-loader.mjs";
const { getSiteUrl, siteConfig } = await createLoader()("config/site.ts");
const keys = [
  "NODE_ENV",
  "NEXT_PUBLIC_SITE_URL",
  "VERCEL_PROJECT_PRODUCTION_URL",
  "VERCEL_URL",
  "VERCEL_BRANCH_URL",
  "VERCEL_ENV",
];
function env(values, check) {
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  try {
    for (const key of keys) delete process.env[key];
    Object.assign(process.env, values);
    check();
  } finally {
    for (const key of keys)
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
  }
}
test("metadatos: producción sin variables usa el dominio público confirmado, no localhost", () => {
  env({ NODE_ENV: "production" }, () =>
    assert.equal(getSiteUrl(), "https://gimnasio-wheat.vercel.app"),
  );
  assert.equal(siteConfig.productionUrl, "https://gimnasio-wheat.vercel.app");
});
test("metadatos: desarrollo local sigue disponible", () => {
  env({ NODE_ENV: "development" }, () =>
    assert.equal(getSiteUrl(), "http://localhost:3000"),
  );
});
test("metadatos: configuración explícita se respeta y quita slash final", () => {
  env(
    {
      NODE_ENV: "production",
      NEXT_PUBLIC_SITE_URL: " https://sitio-ejemplo.test/ ",
      VERCEL_PROJECT_PRODUCTION_URL: "otro-ejemplo.vercel.app",
    },
    () => assert.equal(getSiteUrl(), "https://sitio-ejemplo.test"),
  );
});
test("metadatos: variable de dominio de producción de Vercel sigue soportada", () => {
  env(
    {
      NODE_ENV: "production",
      VERCEL_PROJECT_PRODUCTION_URL: "produccion-ejemplo.vercel.app",
      VERCEL_URL: "preview-ejemplo.vercel.app",
    },
    () => assert.equal(getSiteUrl(), "https://produccion-ejemplo.vercel.app"),
  );
});
test("metadatos: un Preview no se convierte en URL canónica por defecto", () => {
  env(
    {
      NODE_ENV: "production",
      VERCEL_ENV: "preview",
      VERCEL_URL: "preview-ejemplo.vercel.app",
      VERCEL_BRANCH_URL: "rama-ejemplo.vercel.app",
    },
    () => assert.equal(getSiteUrl(), "https://gimnasio-wheat.vercel.app"),
  );
});

test("metadatos: localhost de una plantilla vieja no se publica en producción", () => {
  for (const url of [
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://[::1]:3000",
    "http://prueba.localhost:3000",
  ]) {
    env({ NODE_ENV: "production", NEXT_PUBLIC_SITE_URL: url }, () =>
      assert.equal(getSiteUrl(), "https://gimnasio-wheat.vercel.app"),
    );
  }
  env(
    { NODE_ENV: "development", NEXT_PUBLIC_SITE_URL: "http://localhost:4000" },
    () => assert.equal(getSiteUrl(), "http://localhost:4000"),
  );
});
