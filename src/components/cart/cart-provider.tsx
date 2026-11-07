"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import {
  addItem as addItemPure,
  type CartItem,
  cartCount as cartCountPure,
  cartTotal as cartTotalPure,
  loadCart,
  removeItem as removeItemPure,
  saveCart,
  setQty as setQtyPure,
} from "@/lib/cart";

interface CartContextValue {
  items: CartItem[];
  count: number;
  total: number;
  addItem: (item: CartItem) => void;
  removeItem: (productId: string) => void;
  setQty: (productId: string, qty: number) => void;
  clear: () => void;
  /** true cuando el storage del navegador ya se leyó (evita parpadeos). */
  ready: boolean;
}

const CartContext = createContext<CartContextValue | null>(null);

/**
 * Carrito del visitante: vive en el navegador (localStorage), sin cuenta.
 * Al generar la orden los precios se re-confirman en el servidor.
 */
export function CartProvider({ children }: { children: React.ReactNode }) {
  const [items, setItems] = useState<CartItem[]>([]);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    // El storage sólo existe en el navegador: la primera carga hidrata
    // acá. Síncrono a propósito (un solo pase, sin parpadeo de contador).
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setItems(loadCart(window.localStorage));
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setReady(true);
  }, []);

  useEffect(() => {
    if (ready) saveCart(window.localStorage, items);
  }, [items, ready]);

  const addItem = useCallback((item: CartItem) => {
    setItems((prev) => addItemPure(prev, item));
  }, []);
  const removeItem = useCallback((productId: string) => {
    setItems((prev) => removeItemPure(prev, productId));
  }, []);
  const setQty = useCallback((productId: string, qty: number) => {
    setItems((prev) => setQtyPure(prev, productId, qty));
  }, []);
  const clear = useCallback(() => setItems([]), []);

  const value = useMemo<CartContextValue>(
    () => ({
      items,
      count: cartCountPure(items),
      total: cartTotalPure(items),
      addItem,
      removeItem,
      setQty,
      clear,
      ready,
    }),
    [items, ready, addItem, removeItem, setQty, clear],
  );

  return <CartContext.Provider value={value}>{children}</CartContext.Provider>;
}

export function useCart(): CartContextValue {
  const ctx = useContext(CartContext);
  if (!ctx) throw new Error("useCart fuera de CartProvider");
  return ctx;
}
