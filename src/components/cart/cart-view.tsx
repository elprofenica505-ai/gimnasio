"use client";

import Link from "next/link";
import { Loader2, Minus, Plus, ShoppingCart, Trash2 } from "lucide-react";
import { useCart } from "@/components/cart/cart-provider";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { cartTotal, formatCórdobas } from "@/lib/cart";
import { ButtonLink } from "@/components/ui/button";
import type { Locale } from "@/i18n/config";

/**
 * Revisión del carrito antes de pagar: cantidades, quitar productos y
 * total estimado. El total definitivo lo confirma la base al crear la
 * orden (precios canónicos, nunca el navegador).
 */
export function CartView({ locale }: { locale: Locale }) {
  const { dict } = useDictionary();
  const { items, total, ready, setQty, removeItem } = useCart();
  const es = locale === "es";

  return (
    <section className="container-x flex min-h-[70vh] flex-col justify-center py-14">
      <div className="mx-auto w-full max-w-2xl">
        <p className="eyebrow">{es ? "Tienda" : "Store"}</p>
        <h1 className="display-xl mt-3 text-4xl sm:text-5xl">{dict.cart.title}</h1>

        {!ready ? (
          <p className="mt-10 text-fog" aria-live="polite">
            <Loader2 className="mr-2 inline size-4 animate-spin" aria-hidden="true" />
            …
          </p>
        ) : items.length === 0 ? (
          <div className="mt-10 rounded-3xl border border-line bg-card p-8 text-center">
            <ShoppingCart className="mx-auto size-10 text-fog" aria-hidden="true" />
            <p className="mt-4 text-mist">{dict.cart.empty}</p>
            <ButtonLink href={`/${locale}/#tienda`} variant="outline-dark" className="mt-6">
              {dict.cart.emptyCta}
            </ButtonLink>
          </div>
        ) : (
          <>
            <ul className="mt-10 space-y-3">
              {items.map((i) => (
                <li
                  key={i.productId}
                  className="flex items-center gap-4 rounded-2xl border border-line bg-card p-4"
                >
                  {i.image ? (
                    // eslint-disable-next-line @next/next/no-img-element -- foto del gimnasio (data URI)
                    <img src={i.image} alt={i.name} className="size-16 rounded-xl object-cover" />
                  ) : (
                    <div className="grid size-16 place-items-center rounded-xl bg-paper text-fog">
                      <ShoppingCart className="size-5" aria-hidden="true" />
                    </div>
                  )}
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-bold text-white">{i.name}</p>
                    <p className="text-sm text-fog">{formatCórdobas(i.price)} c/u</p>
                    <div className="mt-2 flex items-center gap-2">
                      <button
                        type="button"
                        aria-label={`${dict.cart.qty} −`}
                        onClick={() => setQty(i.productId, i.qty - 1)}
                        className="grid size-8 place-items-center rounded-full border border-line text-mist hover:border-brand/50"
                      >
                        <Minus className="size-3.5" aria-hidden="true" />
                      </button>
                      <span className="w-6 text-center text-sm font-bold text-ink">{i.qty}</span>
                      <button
                        type="button"
                        aria-label={`${dict.cart.qty} +`}
                        onClick={() => setQty(i.productId, i.qty + 1)}
                        className="grid size-8 place-items-center rounded-full border border-line text-mist hover:border-brand/50"
                      >
                        <Plus className="size-3.5" aria-hidden="true" />
                      </button>
                    </div>
                  </div>
                  <div className="flex flex-col items-end gap-2">
                    <p className="display-xl text-lg text-brand">
                      {formatCórdobas(i.price * i.qty)}
                    </p>
                    <button
                      type="button"
                      onClick={() => removeItem(i.productId)}
                      className="inline-flex items-center gap-1 text-xs text-fog hover:text-alert"
                    >
                      <Trash2 className="size-3.5" aria-hidden="true" />
                      {dict.cart.remove}
                    </button>
                  </div>
                </li>
              ))}
            </ul>

            <div className="mt-6 flex items-center justify-between rounded-2xl border border-brand/40 bg-brand/10 p-5">
              <p className="font-bold text-mist">{dict.cart.total}</p>
              <p className="display-xl text-3xl text-brand">{formatCórdobas(cartTotal(items))}</p>
            </div>

            <div className="mt-6 flex flex-col gap-3 sm:flex-row">
              <ButtonLink href={`/${locale}/checkout`} className="flex-1">
                <ShoppingCart className="size-4" aria-hidden="true" />
                {dict.cart.checkout}
              </ButtonLink>
              <ButtonLink href={`/${locale}/#tienda`} variant="outline-dark">
                {dict.cart.emptyCta}
              </ButtonLink>
            </div>
            <p className="mt-4 text-xs text-fog">{dict.cart.note}</p>
          </>
        )}
      </div>
    </section>
  );
}
