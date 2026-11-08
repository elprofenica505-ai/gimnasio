"use client";

import { useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useCart } from "@/components/cart/cart-provider";
import {
  ArrowLeft,
  CheckCircle2,
  ChevronRight,
  ClipboardCheck,
  Loader2,
  Minus,
  Plus,
  ShieldCheck,
  ShoppingCart,
  Trash2,
} from "lucide-react";
import { Button, ButtonLink } from "@/components/ui/button";
import { Input } from "@/components/ui/field";
import { cartTotal, formatCórdobas } from "@/lib/cart";
import { cn } from "@/lib/utils";

interface PlanEnVenta {
  id: string;
  slug: string;
  nombre: string;
  periodo: string;
  precio: number;
}

interface OrdenCreada {
  public_id: string;
  total: number;
  currency: string;
  plan_name: string | null;
  instrucciones: string | null;
}

type Paso = "carrito" | "datos" | "pago" | "listo";

const PERIODO_ES: Record<string, string> = {
  session: "por día",
  week: "por semana",
  fortnight: "por quincena",
  month: "por mes",
};
const PERIODO_EN: Record<string, string> = {
  session: "per day",
  week: "per week",
  fortnight: "per 15 days",
  month: "per month",
};

/**
 * Checkout: plan y/o productos del carrito → datos → pagar por
 * Transferencia/voucher → número de referencia. El visitante NUNCA se
 * registra para comprar: los datos se piden al generar la orden, y el
 * total lo confirma el servidor (nunca el navegador). El personal
 * activa la membresía con un toque cuando verifica el pago.
 */
export function CheckoutFlow({
  locale,
  planes,
}: {
  locale: "es" | "en";
  planes: PlanEnVenta[];
}) {
  const es = locale === "es";
  const params = useSearchParams();
  const planInicial = params.get("plan") ?? "";
  const { items, total: totalCarrito, setQty, removeItem, clear, ready } = useCart();

  const [paso, setPaso] = useState<Paso>(
    planInicial && planes.length ? "datos" : "carrito",
  );
  const [planId, setPlanId] = useState(planInicial);
  const [nombre, setNombre] = useState("");
  const [telefono, setTelefono] = useState("");
  const [correo, setCorreo] = useState("");
  const [web, setWeb] = useState(""); // honeypot
  const [cargando, setCargando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [orden, setOrden] = useState<OrdenCreada | null>(null);
  const [referencia, setReferencia] = useState("");

  const plan = useMemo(() => planes.find((p) => p.id === planId), [planes, planId]);
  const periodoTexto = (p: PlanEnVenta) => (es ? PERIODO_ES[p.periodo] : PERIODO_EN[p.periodo]);
  const estimado = (plan?.precio ?? 0) + totalCarrito;

  async function crearOrden() {
    setError(null);
    if (nombre.trim().length < 2) return setError(es ? "Escribí tu nombre." : "Enter your name.");
    if (telefono.replace(/\D/g, "").length < 6)
      return setError(es ? "Escribí un teléfono válido." : "Enter a valid phone.");
    setCargando(true);
    try {
      const r = await fetch("/api/checkout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          full_name: nombre,
          phone: telefono,
          email: correo || null,
          plan_id: planId || null,
          items: items.map((i) => ({ product_id: i.productId, qty: i.qty })),
          website: web,
        }),
      });
      const j = await r.json();
      if (!r.ok || !j.orden) {
        if (j.error === "ORDEN_VACIA") {
          setError(es ? "Tu carrito quedó vacío: elegí un plan o un producto." : "Your cart is empty: pick a plan or a product.");
          setPaso("carrito");
          return;
        }
        setError(
          j.error === "RATE_LIMIT"
            ? es
              ? "Demasiados intentos. Probá de nuevo en un rato."
              : "Too many attempts. Try again later."
            : es
              ? "No se pudo crear la orden. Revisá los datos e intentá de nuevo."
              : "We could not create the order. Check your details.",
        );
        return;
      }
      setOrden(j.orden as OrdenCreada);
      setPaso("pago");
    } finally {
      setCargando(false);
    }
  }

  async function informarPago() {
    setError(null);
    if (!orden) return;
    if (referencia.trim().length < 4)
      return setError(es ? "Cargá el número de referencia de tu pago." : "Enter your payment reference.");
    setCargando(true);
    try {
      const r = await fetch("/api/checkout/pago", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ public_id: orden.public_id, reference: referencia, website: web }),
      });
      if (r.ok) {
        clear();
        setPaso("listo");
      } else {
        setError(es ? "No se pudo registrar. Intentá de nuevo." : "Could not save it. Try again.");
      }
    } finally {
      setCargando(false);
    }
  }

  /* ------------------------------------------------------------ */
  return (
    <section className="container-x flex min-h-[80vh] flex-col justify-center py-14">
      <div className="mx-auto w-full max-w-2xl">
        {/* Título + pasos */}
        <div className="mb-10">
          <p className="eyebrow">{es ? "Membresías y tienda" : "Memberships and store"}</p>
          <h1 className="display-xl mt-3 text-4xl sm:text-5xl">
            {paso === "listo" ? (es ? "¡Listo!" : "All set!") : es ? "Completá tu compra" : "Complete your order"}
          </h1>
          <ol className="mt-4 flex items-center gap-2 text-xs text-fog">
            {[
              ["carrito", es ? "Carrito" : "Cart"],
              ["datos", es ? "Tus datos" : "Details"],
              ["pago", es ? "Pago" : "Payment"],
            ].map(([id, label], i) => (
              <li key={id} className="flex items-center gap-2">
                {i > 0 && <ChevronRight className="size-3" aria-hidden="true" />}
                <span
                  className={cn(
                    "rounded-full border px-2.5 py-1",
                    paso === id || (paso === "listo" && id === "pago")
                      ? "border-brand/60 bg-brand/10 text-brand-300"
                      : "border-line",
                  )}
                >
                  {i + 1}. {label}
                </span>
              </li>
            ))}
          </ol>
        </div>

        {error && (
          <p role="alert" className="mb-6 rounded-xl border border-alert/40 bg-alert/10 px-4 py-3 text-sm text-white">
            {error}
          </p>
        )}

        {/* PASO 1: carrito (plan + productos) */}
        {paso === "carrito" && (
          <div className="space-y-6">
            {planes.length > 0 && (
              <div className="space-y-3">
                <p className="text-sm font-semibold text-mist">{es ? "1. ¿Sumás un plan?" : "1. Add a plan?"}</p>
                {planes.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    onClick={() => setPlanId(planId === p.id ? "" : p.id)}
                    className={cn(
                      "flex w-full items-center justify-between rounded-2xl border p-5 text-left transition-colors hover:border-brand/60",
                      planId === p.id ? "border-brand bg-brand/10" : "border-line bg-card",
                    )}
                  >
                    <span>
                      <span className="block font-bold text-white">{p.nombre}</span>
                      <span className="text-sm text-fog">{periodoTexto(p)}</span>
                    </span>
                    <span className="display-xl text-2xl text-brand">{formatCórdobas(p.precio)}</span>
                  </button>
                ))}
              </div>
            )}
            {ready && items.length > 0 && (
              <p className="text-sm text-mist">
                {es
                  ? `2. Tu carrito con ${items.length} producto(s) se incluye en la orden.`
                  : `2. Your cart with ${items.length} product(s) is included in the order.`}
              </p>
            )}
            <Button
              type="button"
              disabled={!planId && items.length === 0}
              onClick={() => setPaso("datos")}
              className="w-full"
            >
              <ClipboardCheck className="size-4" aria-hidden="true" />
              {es ? "Continuar" : "Continue"}
            </Button>
            <ButtonLink href={`/${locale}/#tienda`} variant="outline-dark" className="w-full">
              <ShoppingCart className="size-4" aria-hidden="true" />
              {es ? "Ver la tienda" : "Browse the store"}
            </ButtonLink>
          </div>
        )}

        {/* PASO 2: datos + resumen */}
        {paso === "datos" && (
          <form
            className="space-y-4"
            onSubmit={(e) => {
              e.preventDefault();
              crearOrden();
            }}
          >
            {/* Resumen editable */}
            <div className="space-y-3 rounded-2xl border border-line bg-card p-5">
              {plan && (
                <div className="flex items-center justify-between gap-3">
                  <span className="font-bold text-white">{plan.nombre}</span>
                  <span className="display-xl text-lg text-brand">{formatCórdobas(plan.precio)}</span>
                </div>
              )}
              {items.map((i) => (
                <div key={i.productId} className="flex items-center gap-3 border-t border-line pt-3">
                  <span className="min-w-0 flex-1 truncate text-sm text-mist">{i.name}</span>
                  <button
                    type="button"
                    aria-label="−"
                    onClick={() => setQty(i.productId, i.qty - 1)}
                    className="grid size-7 place-items-center rounded-full border border-line text-mist"
                  >
                    <Minus className="size-3" aria-hidden="true" />
                  </button>
                  <span className="w-5 text-center text-sm font-bold text-ink">{i.qty}</span>
                  <button
                    type="button"
                    aria-label="+"
                    onClick={() => setQty(i.productId, i.qty + 1)}
                    className="grid size-7 place-items-center rounded-full border border-line text-mist"
                  >
                    <Plus className="size-3" aria-hidden="true" />
                  </button>
                  <span className="w-20 text-right text-sm font-semibold text-brand">
                    {formatCórdobas(i.price * i.qty)}
                  </span>
                  <button
                    type="button"
                    aria-label={es ? "Quitar" : "Remove"}
                    onClick={() => removeItem(i.productId)}
                    className="text-fog hover:text-alert"
                  >
                    <Trash2 className="size-3.5" aria-hidden="true" />
                  </button>
                </div>
              ))}
              <div className="flex items-center justify-between border-t border-line pt-3">
                <span className="text-sm font-semibold text-mist">{es ? "Total estimado" : "Estimated total"}</span>
                <span className="display-xl text-2xl text-brand">{formatCórdobas(estimado)}</span>
              </div>
            </div>

            <div>
              <label htmlFor="ck-nombre" className="mb-1.5 block text-sm font-semibold text-mist">
                {es ? "Nombre completo" : "Full name"}
              </label>
              <Input
                id="ck-nombre"
                name="full_name"
                autoComplete="name"
                required
                minLength={2}
                value={nombre}
                onChange={(e) => setNombre(e.target.value)}
              />
            </div>
            <div>
              <label htmlFor="ck-tel" className="mb-1.5 block text-sm font-semibold text-mist">
                {es ? "Teléfono (WhatsApp)" : "Phone (WhatsApp)"}
              </label>
              <Input
                id="ck-tel"
                name="phone"
                type="tel"
                inputMode="tel"
                autoComplete="tel"
                required
                placeholder="8888 0000"
                value={telefono}
                onChange={(e) => setTelefono(e.target.value)}
              />
            </div>
            <div>
              <label htmlFor="ck-mail" className="mb-1.5 block text-sm font-semibold text-mist">
                {es ? "Correo (opcional, si ya tenés cuenta en la app)" : "Email (optional, if you already have an account)"}
              </label>
              <Input
                id="ck-mail"
                name="email"
                type="email"
                autoComplete="email"
                value={correo}
                onChange={(e) => setCorreo(e.target.value)}
              />
            </div>
            {/* Honeypot: invisible para personas. */}
            <input
              type="text"
              name="website"
              tabIndex={-1}
              autoComplete="off"
              value={web}
              onChange={(e) => setWeb(e.target.value)}
              className="hidden"
              aria-hidden="true"
            />
            <div className="flex gap-3 pt-2">
              <Button type="button" variant="outline-dark" onClick={() => setPaso("carrito")}>
                <ArrowLeft className="size-4" aria-hidden="true" />
                {es ? "Atrás" : "Back"}
              </Button>
              <Button type="submit" disabled={cargando || (!plan && items.length === 0)} className="flex-1">
                {cargando ? (
                  <Loader2 className="size-4 animate-spin" aria-hidden="true" />
                ) : (
                  <ClipboardCheck className="size-4" aria-hidden="true" />
                )}
                {es ? "Generar mi orden de pago" : "Create my order"}
              </Button>
            </div>
            <p className="flex items-center gap-2 pt-1 text-xs text-fog">
              <ShieldCheck className="size-3.5 text-ok" aria-hidden="true" />
              {es
                ? "El total lo confirma el sistema: nunca te vamos a cobrar un precio distinto al publicado."
                : "The total is confirmed by the system: you will never be charged a different price."}
            </p>
          </form>
        )}

        {/* PASO 3: pagar */}
        {paso === "pago" && orden && (
          <div className="space-y-6">
            <div className="rounded-2xl border border-line bg-card p-6">
              <p className="text-sm text-fog">{es ? "Orden" : "Order"}</p>
              <p className="display-xl text-3xl tracking-wide text-white">{orden.public_id}</p>
              {orden.plan_name && <p className="mt-1 text-mist">{orden.plan_name}</p>}
              <p className="display-xl mt-3 text-4xl text-brand">
                {formatCórdobas(Number(orden.total))}
                <span className="ml-2 text-sm font-normal tracking-normal text-fog">{orden.currency}</span>
              </p>
            </div>
            <div className="rounded-2xl border border-line bg-card p-6 text-sm leading-relaxed text-mist">
              {orden.instrucciones ||
                (es
                  ? "Pagá por transferencia bancaria, Tigo Money o Claro Pay y cargá el número de referencia acá abajo."
                  : "Pay by bank transfer, Tigo Money or Claro Pay and enter the reference number below.")}
            </div>
            <form
              className="space-y-3"
              onSubmit={(e) => {
                e.preventDefault();
                informarPago();
              }}
            >
              <label htmlFor="ck-ref" className="block text-sm font-semibold text-mist">
                {es ? "Número de referencia de tu pago" : "Your payment reference number"}
              </label>
              <Input
                id="ck-ref"
                name="reference"
                required
                minLength={4}
                placeholder={es ? "Ej: número de comprobante 123456" : "e.g. 123456"}
                value={referencia}
                onChange={(e) => setReferencia(e.target.value)}
              />
              <Button type="submit" disabled={cargando} className="w-full">
                {cargando ? (
                  <Loader2 className="size-4 animate-spin" aria-hidden="true" />
                ) : (
                  <ClipboardCheck className="size-4" aria-hidden="true" />
                )}
                {es ? "Ya pagué: avisar al gimnasio" : "I paid: notify the gym"}
              </Button>
            </form>
          </div>
        )}

        {/* PASO 4: listo */}
        {paso === "listo" && orden && (
          <div className="space-y-6 text-center">
            <CheckCircle2 className="mx-auto size-14 text-ok" aria-hidden="true" />
            <div className="space-y-2">
              <p className="text-lg font-bold text-white">
                {es ? "¡Pago informado!" : "Payment submitted!"}
              </p>
              <p className="mx-auto max-w-md text-sm leading-relaxed text-mist">
                {es ? (
                  <>
                    Tu orden <strong className="text-white">{orden.public_id}</strong> quedó en la cola de
                    verificación. En cuanto el gimnasio confirme tu pago, tu compra queda activa y te
                    avisamos al <strong className="text-white">{telefono}</strong>.
                  </>
                ) : (
                  <>
                    Your order <strong className="text-white">{orden.public_id}</strong> is in the
                    verification queue. Once the gym confirms your payment, your purchase is activated and
                    we contact you at <strong className="text-white">{telefono}</strong>.
                  </>
                )}
              </p>
            </div>
            <ButtonLink href={`/${locale}`} variant="outline-dark">
              {es ? "Volver al inicio" : "Back to home"}
            </ButtonLink>
          </div>
        )}
      </div>
    </section>
  );
}
