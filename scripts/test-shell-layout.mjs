import { readFileSync, readdirSync } from "node:fs";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import http from "node:http";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createLoader } from "../tests/helpers/react-loader.mjs";
import { chromium as playwright } from "playwright-core";
const root = fileURLToPath(new URL("..", import.meta.url));
const dict = (await createLoader()("i18n/dictionaries/es.ts")).default;
const monthly = [
  { month: "2026-10-01", incomeNio: 0, expenseNio: 86600, netNio: -86600 },
  { month: "2026-09-01", incomeNio: 0, expenseNio: 166500, netNio: -166500 },
];
const methods = [
  {
    paymentMethodId: null,
    nameEs: null,
    icon: "Wallet",
    txCount: 13,
    incomeNio: 0,
    expenseNio: 253100,
    totalNio: 253100,
  },
];
const summary = {
  incomeToday: 0,
  expenseToday: 0,
  netToday: 0,
  txToday: 0,
  incomeMonth: 0,
  expenseMonth: 86600,
  netMonth: -86600,
  txMonth: 6,
  pendingInvoices: null,
  totalOwed: 0,
  totalOwedUsd: 0,
  sourceModel: "bank_accounts_split",
  openRegisterCount: 0,
  openRegister: null,
};
const accounts = [
  {
    id: "ejemplo",
    name: "EJEMPLO - Caja NIO",
    currency: "NIO",
    balance: 0,
    kind: "caja_fuerte",
  },
];
const recent = [
  {
    id: "ejemplo",
    direction: "expense",
    status: "completed",
    amount: 11800,
    currency: "NIO",
    occurredAt: "2026-10-11T12:00:00Z",
    concept: "[SEED-GASTO] Alcaldía - tributos municipales de ejemplo",
    memberName: null,
  },
];
const pages = {};
for (const variant of ["ejemplo", "vacio", "importes-largos"]) {
  const large = variant === "importes-largos";
  const empty = variant === "vacio";
  const names = large
    ? "EJEMPLO Nombre de cuenta y método de pago muy largo para comprobar saltos de línea en celulares"
    : "Método EJEMPLO";
  const variantMethods = empty
    ? []
    : methods.map((m) => ({
        ...m,
        nameEs: names,
        totalNio: large ? 9999999999.99 : m.totalNio,
        expenseNio: large ? 9999999999.99 : m.expenseNio,
      }));
  const variantRecent = empty
    ? []
    : recent.map((t) => ({
        ...t,
        amount: large ? 9999999999.99 : t.amount,
        concept: large ? names : t.concept,
      }));
  const variantMonthly = empty
    ? []
    : monthly.map((m) => ({
        ...m,
        expenseNio: large ? 9999999999.99 : m.expenseNio,
        netNio: large ? -9999999999.99 : m.netNio,
      }));
  const variantSummary = empty
    ? { ...summary, expenseMonth: 0, netMonth: 0, txMonth: 0 }
    : summary;
  const variantAccounts = empty
    ? []
    : accounts.map((a) => ({
        ...a,
        name: large ? names : a.name,
        balance: large ? 9999999999.99 : a.balance,
      }));
  const debts = empty
    ? []
    : [
        {
          memberId: "ejemplo",
          fullName: large ? names : "Cliente EJEMPLO",
          email: large
            ? `${"ejemplo".repeat(12)}@example.com`
            : "prueba@example.com",
          phone: null,
          totalOwedNio: large ? 9999999999.99 : 10,
          totalOwedUsd: 5,
          invoicesOpen: null,
          daysOverdue: null,
          oldestDue: null,
        },
      ];
  const categories = empty
    ? []
    : [
        {
          id: "ejemplo",
          nameEs: large ? names : "Categoría EJEMPLO",
          slug: large ? "ejemplo".repeat(12) : "ejemplo",
        },
      ];
  const financeOptions = {
    protocol: "service-v1",
    writes_enabled: true,
    finance_layout: "bank_accounts_split",
    methods: [
      { id: "ejemplo", name_es: names, accepts_nio: true, accepts_usd: true },
    ],
    accounts: variantAccounts,
    categories,
  };
  const exampleReceipt = {
    id: "11111111-1111-4111-8111-111111111111",
    requestId: "22222222-2222-4222-8222-222222222222",
    kind: "expense",
    occurredAt: "2026-10-17T12:00:00Z",
    amount: large ? 99999999 : 10,
    currency: "NIO",
    amountNio: 10,
    amountUsd: 0.2723,
    fx: 36.7244,
    concept: names,
    clientId: null,
    clientName: null,
    categoryName: names,
    accountId: "ejemplo",
    accountName: names,
    methodName: names,
    actorId: "33333333-3333-4333-8333-333333333333",
    actorName: "Personal EJEMPLO",
    accountBefore: 100,
    accountAfter: 90,
    reference: "SG-EJEMPLO",
  };
  const debtExample={clientName:names,protocol:'debt-v1',clientId:'11111111-1111-4111-8111-111111111111',profileId:null,source:'client',
    writesEnabled:true,canOpen:true,balances:empty?null:{credit_nio:0,credit_usd:0,debt_nio:large?9999999999.99:100,debt_usd:20},entries:[]};
  const saleCatalogExample={products:empty?[]:[{id:'44444444-4444-4444-8444-444444444444',name:names,
    category:large?names:'Bebidas EJEMPLO',subcategory:large?names:null,
    attributes:{Detalle:names},price:large?9999999:25,stock:large?100000:5,low_stock:true}]};
  const load = createLoader({
    "server-only": "export {};",
    "@/lib/supabase/client": "export const getSupabaseBrowserClient=()=>null;",
    "@/lib/supabase/server": `export const getSupabaseServerClient=async()=>({rpc(){return {abortSignal:async()=>({data:globalThis.__layoutReceipt,error:null})}}});`,
    "@/components/crm/use-crm-resource": `export const useCrmResource=(url)=>({loading:false,error:'',data:(url||'').includes('catalog=sale')?${JSON.stringify(saleCatalogExample)}:(url||'').includes('/api/admin/debts')?${JSON.stringify(debtExample)}:(url||'').includes('history=')?[]:${JSON.stringify(financeOptions)}});`,
    "@/lib/supabase/env": "export const isSupabaseConfigured=true;export const DEMO_MODE=false;export const CONFIGURATION_UNAVAILABLE=false;",
    "@/lib/data/queries": `export const getCurrentUser=async()=>({role:'admin',mfa:'ok'});export const getCashierPermissions=async()=>({dailyClose:true,monthlyResult:true,charts:true,accountBalances:true,expenses:true,receivables:true,void:true});export const getMonthlyPnl=async()=>${JSON.stringify(variantMonthly)};export const getPaymentMethodsBreakdown=async()=>${JSON.stringify(variantMethods)};export const getCashSummary=async()=>(${JSON.stringify(variantSummary)});export const getAccounts=async()=>${JSON.stringify(variantAccounts)};export const getRecentTransactions=async()=>${JSON.stringify(variantRecent)};export const getAccountsReceivable=async()=>${JSON.stringify(debts)};export const getExpenseCategories=async()=>${JSON.stringify(categories)};export const getDailyCash=async()=>[];export const getPaymentMethods=async()=>[];export const getRecentVoids=async()=>[];export const getVoidPlanImpact=async()=>[];`,
    "@/components/providers/dictionary-provider": `export const useDictionary=()=>({locale:'es',dict:${JSON.stringify(dict)}});`,
    "@/components/providers/app-provider": `export const useApp=()=>({user:{role:'admin',fullName:'Admin EJEMPLO'},isDemo:false,hydrated:true,bookings:[],signOut(){},toast(){}});`,
    "@/components/cart/cart-provider": `export const useCart=()=>({items:[],count:0,total:0,ready:true,addItem(){},removeItem(){},setQty(){},clear(){}});`,
    "next/navigation": `export function notFound(){throw Error("NOT_FOUND")};export const usePathname=()=>'/es/panel/reportes';export const useRouter=()=>({});export function redirect(){throw Error('redirect')}`,
  });
  const { RecoveryForm } = await load("components/auth/recovery-form.tsx");
  const { DebtForm } = await load("components/crm/debt-form.tsx");
  const { ClientFinanceSummary, ClientIncomeHistory } = await load("components/crm/client-finance.tsx");
  const financeId = "11111111-1111-4111-8111-111111111111";
  const profileId = "22222222-2222-4222-8222-222222222222";
  const financeDetail = {
    client: { id: financeId, profile_id: profileId },
    finance: { version: 1, client_id: financeId, profile_id: profileId,
      layout: "bank_accounts_split", balance_status: empty ? "missing" : "ready", balance_nio: null,
      balances: empty ? null : { credit_nio: large ? 9999999999.99 : 100,
        credit_usd: large ? 9999999999.99 : 7, debt_nio: large ? 9999999999.99 : 20, debt_usd: 3 },
      collections: { count_nio: empty ? 0 : 12345, amount_nio: empty ? 0 : large ? 9999999999.99 : 453,
        count_usd: empty ? 0 : 1, amount_usd: empty ? 0 : 2 },
    },
    payments: empty ? [] : [{ id: financeId, occurred_at: "2026-10-18T01:00:00Z", concept: names,
      currency: "NIO", amount: large ? 9999999999.99 : 10, status: "completed" }],
  };
  const { SiteShell } = await load("components/layout/site-shell.tsx");
  const { SiteFooter } = await load("components/layout/site-footer.tsx");
  for (const key of [
    "caja",
    "reportes",
    "cuentas",
    "gastos",
    "cobro",
    "comprobante",
    "comprobante-vuelto",
    "saldo-cliente",
    "deudas-abonos",
    "recuperar",
    "nueva-clave",
  ]) {
    const cashApplied=large?99999998:20;
    globalThis.__layoutReceipt=key==='comprobante-vuelto'?{...exampleReceipt,kind:'debt_payment',clientId:exampleReceipt.id,clientName:names,
      categoryName:null,amount:cashApplied,amountNio:cashApplied,amountUsd:Number((cashApplied/exampleReceipt.fx).toFixed(4)),
      debtBefore:cashApplied+10,debtAfter:10,accountAfter:exampleReceipt.accountBefore+cashApplied,
      cashReceived:large?99999999:100,changeGiven:large?1:80}:exampleReceipt;
    const Page =
      (key === "recuperar" || key === "nueva-clave")
        ? () => React.createElement("section",{className:"container-x max-w-md py-8"},React.createElement(RecoveryForm,{
            mode:key === "recuperar" ? "request" : "update",expectedUserId:empty?undefined:financeId,
            email:large?"EXAMPLE-"+"long".repeat(40)+"@test.invalid":"example@test.invalid",
          }))
        : key === "deudas-abonos"
        ? () => React.createElement("section", {className:"container-x py-8"}, React.createElement(DebtForm,{clientId:financeId,locale:'es'}))
        : key === "saldo-cliente"
        ? () => React.createElement("section", {className:"container-x space-y-6 py-8"},
            React.createElement(ClientFinanceSummary, {detail:financeDetail,pending:false,stale:false,retry(){},disabled:false}),
            React.createElement(ClientIncomeHistory, {detail:financeDetail,pending:false,stale:false}))
        : key === "cobro"
        ? () =>
            React.createElement(MovementForm, {
              kind: "service_income",
              clientId: exampleReceipt.id,
              locale: "es",
            })
        : (
            await load(
              (key === "comprobante" || key === "comprobante-vuelto")
                ? "app/[locale]/panel/comprobantes/[id]/page.tsx"
                : `app/[locale]/panel/${key}/page.tsx`,
            )
          ).default;
    const { MovementForm } = await load("components/admin/movement-form.tsx");
    pages[`${key}-${variant}`] =
      '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">' +
      readdirSync(root + "/.next/static/chunks")
        .filter((f) => f.endsWith(".css"))
        .map((f) => `<link rel="stylesheet" href="/_next/static/chunks/${f}">`)
        .join("") +
      "</head><body>" +
      renderToStaticMarkup(
        React.createElement(
          SiteShell,
          { footer: React.createElement(SiteFooter, { locale: "es" }) },
          await Page({
            params: Promise.resolve({ locale: "es", id: exampleReceipt.id }),
          }),
        ),
      ) +
      "</body></html>";
  }
}
// Escenarios públicos fuera del panel. Las pantallas anteriores se
// renderizaron como personal (admin) dentro de /es/panel/reportes, donde
// por decisión aprobada no van ni el botón de reserva ni el pie largo.
// Acá se comprueba la otra cara: con un cliente el encabezado sí muestra
// el botón de reserva (visible desde 640 px) y el pie sí aparece; con
// personal fuera del panel el botón sigue oculto, pero el pie aparece.
const cssLinks = () =>
  readdirSync(root + "/.next/static/chunks")
    .filter((f) => f.endsWith(".css"))
    .map((f) => `<link rel="stylesheet" href="/_next/static/chunks/${f}">`)
    .join("");
for (const [name, role] of [
  ["publico-cliente", "member"],
  ["publico-personal", "admin"],
]) {
  const publicLoad = createLoader({
    "server-only": "export {};",
    "@/components/providers/dictionary-provider": `export const useDictionary=()=>({locale:'es',dict:${JSON.stringify(dict)}});`,
    "@/components/providers/app-provider": `export const useApp=()=>({user:{role:'${role}',fullName:'EJEMPLO'},isDemo:false,hydrated:true,bookings:[],signOut(){},toast(){}});`,
    "@/components/cart/cart-provider": `export const useCart=()=>({items:[],count:0,total:0,ready:true,addItem(){},removeItem(){},setQty(){},clear(){}});`,
    "next/navigation": `export function notFound(){throw Error("NOT_FOUND")};export const usePathname=()=>'/es/horarios';export const useRouter=()=>({});export function redirect(){throw Error('redirect')}`,
  });
  const { SiteShell: PublicShell } = await publicLoad(
    "components/layout/site-shell.tsx",
  );
  const { SiteFooter: PublicFooter } = await publicLoad(
    "components/layout/site-footer.tsx",
  );
  pages[name] =
    '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">' +
    cssLinks() +
    "</head><body>" +
    renderToStaticMarkup(
      React.createElement(
        PublicShell,
        { footer: React.createElement(PublicFooter, { locale: "es" }) },
        React.createElement(
          "section",
          { className: "container-x py-8" },
          "EJEMPLO: página pública",
        ),
      ),
    ) +
    "</body></html>";
}
const server = http.createServer((req, res) => {
  if (req.url.startsWith("/_next/static/") && !req.url.includes("..")) {
    try {
      res.setHeader(
        "Content-Type",
        req.url.endsWith(".css") ? "text/css" : "font/woff2",
      );
      res.end(readFileSync(root + "/.next/" + req.url.slice("/_next/".length)));
    } catch {
      res.statusCode = 404;
      res.end();
    }
  } else {
    res.setHeader("Content-Type", "text/html");
    res.statusCode = pages[req.url.slice(1)] ? 200 : 404;
    res.end(pages[req.url.slice(1)] ?? "Not found");
  }
});
await new Promise((resolve) => server.listen(0, "0.0.0.0", resolve));
let browser;
try {
  browser = await playwright.launch({
    executablePath: process.env.CHROMIUM_PATH,
    args: [
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--no-zygote",
      "--single-process",
    ],
    headless: true,
  });
  const page = await browser.newPage();
  const results = [];
  for (const name of Object.keys(pages))
    for (const width of [320, 360, 393, 414, 640, 768, 1024, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto(`http://127.0.0.1:${server.address().port}/${name}`);
      await page.evaluate(() => document.fonts.ready);
      // Se desactiva clip: la prueba falla si el contenido realmente desborda.
      await page.evaluate(() => {
        document.documentElement.style.overflowX = "visible";
        document.body.style.overflowX = "visible";
      });
      const before = await page.evaluate(() => ({
        viewport: innerWidth,
        doc: document.documentElement.scrollWidth,
        body: document.body.scrollWidth,
        headerCTA: [...document.querySelectorAll("header a")]
          .filter((a) => a.textContent.includes("Reservar"))
          .map((a) => ({
            display: getComputedStyle(a).display,
            right: a.getBoundingClientRect().right,
          })),
        hasSiteFooter: Boolean(document.querySelector("footer.bg-night")),
        overflow: [...document.querySelectorAll("body *")]
          .filter((el) => {
            let r = el.getBoundingClientRect();
            return (
              r.right > innerWidth + 1 &&
              r.width > 0 &&
              !el.closest('[role="region"], .overflow-x-auto') &&
              getComputedStyle(el).position !== "fixed"
            );
          })
          .slice(0, 8)
          .map((el) => ({
            tag: el.tagName,
            class: el.className,
            right: Math.round(el.getBoundingClientRect().right),
            text: el.textContent.slice(0, 50),
          })),
      }));
      await page.evaluate(() =>
        document
          .querySelectorAll('[role="region"], .overflow-x-auto')
          .forEach((el) => (el.scrollLeft = 1000)),
      );
      const after = await page.evaluate(() => ({
        doc: document.documentElement.scrollWidth,
        scrollX,
        tableScroll: document.querySelector("table")?.parentElement.scrollLeft,
      }));
      results.push({ name, width, before, after });
    }
  for (const r of results) {
    assert.ok(
      r.before.doc <= r.width,
      `${r.name}/${r.width}: desbordamiento real ${r.before.doc}px`,
    );
    assert.ok(
      r.after.doc <= r.width && r.after.scrollX === 0,
      `${r.name}/${r.width}: desplazamiento global al usar tabla`,
    );
    assert.deepEqual(
      r.before.overflow,
      [],
      `${r.name}/${r.width}: elemento fuera del viewport`,
    );
    // El botón de reserva y el pie largo dependen del contexto (decisión
    // aprobada): cliente fuera del panel los ve; el personal no ve el
    // botón en ningún lado y dentro del panel tampoco va el pie.
    if (r.name === "publico-cliente") {
      const cta = r.before.headerCTA[0];
      assert.ok(cta, `${r.name}: CTA falta`);
      assert.equal(
        cta.right > 0,
        r.width >= 640,
        `${r.name}/${r.width}: visibilidad CTA`,
      );
    } else {
      assert.deepEqual(
        r.before.headerCTA,
        [],
        `${r.name}/${r.width}: el personal no debe ver el botón de reserva`,
      );
    }
    assert.equal(
      r.before.hasSiteFooter,
      r.name.startsWith("publico-"),
      `${r.name}/${r.width}: el pie largo sólo va fuera del panel`,
    );
    if (r.name.startsWith("reportes-") && r.width < 640)
      assert.ok(
        r.after.tableScroll > 0,
        `${r.name}: tabla móvil no se desplaza localmente`,
      );
  }
  console.log(
    `PASS: ${results.length} casos (11 pantallas/formularios del panel × 3 fixtures EJEMPLO + 2 escenarios públicos, × 8 anchos, 320–1280 px). Sin overflow global, botón de reserva y pie según el contexto (cliente/personal/panel) y tablas desplazables. Render SSR completo con CSS de producción; no certifica hidratación ni escrituras remotas.`,
  );
} finally {
  if (browser) await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
