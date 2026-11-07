"use client";

import { useState } from "react";
import { Check, Plus } from "lucide-react";
import { useCart } from "@/components/cart/cart-provider";
import type { CartItem } from "@/lib/cart";
import { cn } from "@/lib/utils";

/** Botón «Agregar» de la tienda: suma al carrito del navegador, sin cuenta. */
export function AddToCartButton({
  item,
  label,
  addedLabel,
}: {
  item: CartItem;
  label: string;
  addedLabel: string;
}) {
  const { addItem } = useCart();
  const [agregado, setAgregado] = useState(false);

  return (
    <button
      type="button"
      onClick={() => {
        addItem(item);
        setAgregado(true);
        window.setTimeout(() => setAgregado(false), 1600);
      }}
      className={cn(
        "inline-flex w-full items-center justify-center gap-2 rounded-full px-4 py-2.5 text-sm font-semibold transition-colors",
        agregado ? "bg-ok text-white" : "bg-brand text-onbrand hover:opacity-90",
      )}
    >
      {agregado ? (
        <Check className="size-4" aria-hidden="true" />
      ) : (
        <Plus className="size-4" aria-hidden="true" />
      )}
      {agregado ? addedLabel : label}
    </button>
  );
}
