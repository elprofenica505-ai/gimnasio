import { test } from "node:test";
import assert from "node:assert/strict";
import {
  addItem,
  cartCount,
  cartTotal,
  loadCart,
  normalizeCart,
  removeItem,
  saveCart,
  setQty,
} from "../src/lib/cart.ts";

const AGUA = { productId: "a", name: "Agua", price: 24, qty: 1, image: null };
const CREATINA = { productId: "b", name: "Creatina", price: 1200, qty: 1, image: null };

test("agregar suma cantidades del mismo producto y normaliza", () => {
  const cart = addItem(addItem([], AGUA), AGUA);
  assert.equal(cart.length, 1);
  assert.equal(cart[0].qty, 2);
  assert.equal(cartTotal(cart), 48);
});

test("la cantidad se topa en 10 y el carrito en 20 productos", () => {
  let cart = addItem([], { ...AGUA, qty: 25 });
  assert.equal(cart[0].qty, 10);
  const muchos = Array.from({ length: 30 }, (_, i) => ({
    ...AGUA,
    productId: `p${i}`,
  }));
  assert.equal(normalizeCart(muchos).length, 20);
});

test("cambiar cantidad a cero quita el producto; quitar por id también", () => {
  let cart = addItem(addItem([], AGUA), CREATINA);
  cart = setQty(cart, "a", 0);
  assert.equal(cart.length, 1);
  cart = removeItem(cart, "b");
  assert.equal(cart.length, 0);
});

test("el storage podrido no rompe el carrito", () => {
  assert.deepEqual(loadCart({ getItem: () => "{basura" }), []);
  assert.deepEqual(loadCart({ getItem: () => JSON.stringify([{ price: "x" }]) }), []);
  assert.deepEqual(loadCart(null), []);
});

test("guardar y leer devuelve lo mismo", () => {
  const store = new Map();
  const fake = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) };
  const cart = addItem([], CREATINA);
  saveCart(fake, cart);
  assert.deepEqual(loadCart(fake), cart);
  assert.equal(cartCount(cart), 1);
});

test("una imagen que no sea data URI se descarta", () => {
  const cart = normalizeCart([{ ...AGUA, image: "javascript:alert(1)" }]);
  assert.equal(cart[0].image, null);
});
