/**
 * Carrito de la tienda: lógica pura (probada) + persistencia en el
 * navegador. El visitante arma su compra SIN registrarse; los datos
 * se piden recién al generar la orden, y el total lo confirma
 * siempre la base (embudo_crear_orden re-lee precios y stock).
 */

export interface CartItem {
  productId: string;
  name: string;
  price: number;
  qty: number;
  image: string | null;
}

export const CART_MAX_ITEMS = 20;
export const CART_MAX_QTY = 10;
export const CART_STORAGE_KEY = "pbg-cart-v1";

/** Valida y normaliza lo que llegue del storage o de una sección. */
export function normalizeItem(input: unknown): CartItem | null {
  if (typeof input !== "object" || input === null) return null;
  const raw = input as Record<string, unknown>;
  const productId = typeof raw.productId === "string" ? raw.productId : "";
  const name = typeof raw.name === "string" ? raw.name.trim() : "";
  const price = Number(raw.price);
  const qty = Number(raw.qty);
  const image = typeof raw.image === "string" ? raw.image : null;
  if (!productId || !name || !Number.isFinite(price) || price < 0) return null;
  if (!Number.isInteger(qty) || qty < 1) return null;
  return {
    productId,
    name: name.slice(0, 120),
    price,
    qty: Math.min(qty, CART_MAX_QTY),
    image: image && image.startsWith("data:image/") ? image : null,
  };
}

export function normalizeCart(input: unknown): CartItem[] {
  if (!Array.isArray(input)) return [];
  const byId = new Map<string, CartItem>();
  for (const raw of input) {
    const item = normalizeItem(raw);
    if (!item) continue;
    const existing = byId.get(item.productId);
    if (existing) {
      existing.qty = Math.min(existing.qty + item.qty, CART_MAX_QTY);
    } else if (byId.size < CART_MAX_ITEMS) {
      byId.set(item.productId, item);
    }
  }
  return [...byId.values()];
}

export function cartTotal(items: CartItem[]): number {
  return items.reduce((sum, i) => sum + i.price * i.qty, 0);
}

export function cartCount(items: CartItem[]): number {
  return items.reduce((sum, i) => sum + i.qty, 0);
}

/** Agrega (o suma) un producto. Devuelve el carrito nuevo. */
export function addItem(items: CartItem[], item: CartItem): CartItem[] {
  return normalizeCart([...items, item]);
}

/** Cambia la cantidad de un producto (1..10; fuera de rango lo quita). */
export function setQty(items: CartItem[], productId: string, qty: number): CartItem[] {
  if (!Number.isInteger(qty) || qty < 1 || qty > CART_MAX_QTY) {
    return items.filter((i) => i.productId !== productId);
  }
  return items.map((i) => (i.productId === productId ? { ...i, qty } : i));
}

export function removeItem(items: CartItem[], productId: string): CartItem[] {
  return items.filter((i) => i.productId !== productId);
}

/** Lectura segura del storage (navegadores viejos/privados incluidos). */
export function loadCart(storage: Pick<Storage, "getItem"> | null): CartItem[] {
  if (!storage) return [];
  try {
    return normalizeCart(JSON.parse(storage.getItem(CART_STORAGE_KEY) ?? "[]"));
  } catch {
    return [];
  }
}

export function saveCart(storage: Pick<Storage, "setItem"> | null, items: CartItem[]): void {
  if (!storage) return;
  try {
    storage.setItem(CART_STORAGE_KEY, JSON.stringify(items));
  } catch {
    // Sin storage (modo privado lleno): el carrito vive sólo en memoria.
  }
}

export function formatCórdobas(n: number): string {
  return `C$${n.toLocaleString("es-NI")}`;
}
