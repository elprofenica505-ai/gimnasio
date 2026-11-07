import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { QRCodeSVG } from "qrcode.react";
import sharp from "sharp";
import zxing from "@zxing/library";
import {
  cardPayload,
  parseCard,
  frequency,
  categories,
} from "../src/lib/crm/types.ts";
import { crmActionSchema } from "../src/lib/crm/schemas.ts";
const token = "ac000000-0000-4000-8000-000000000001";
test("QR usa token opaco; no acepta URL, nombre ni UUID suelto", () => {
  assert.equal(parseCard(cardPayload(token)), token);
  for (const invalid of [
    token,
    "https://gym.example/" + token,
    "nombre y teléfono",
    "strong-gym:client:no-es-uuid",
  ])
    assert.equal(parseCard(invalid), null);
});
test("las tres etiquetas no son roles ni reglas de precios", () => {
  assert.deepEqual(Object.values(categories), [
    "Clientes",
    "Clientes amigos",
    "Clientes familia Power Box",
  ]);
  assert.equal(
    crmActionSchema.safeParse({ action: "create", name: "Cliente nuevo" })
      .success,
    true,
  );
  assert.equal(
    crmActionSchema.safeParse({
      action: "create",
      name: "Cliente nuevo",
      email: "mal-correo",
    }).success,
    false,
  );
  assert.ok(frequency(4).includes("4 días en 30 días"));
});
test("no permite asistencia QR sin token ni pagos con tasa NIO diferente a 1", () => {
  assert.equal(
    crmActionSchema.safeParse({ action: "check-in", id: token, source: "qr" })
      .success,
    false,
  );
  assert.equal(
    crmActionSchema.safeParse({
      action: "check-in",
      id: token,
      source: "manual",
    }).success,
    true,
  );
  assert.equal(
    crmActionSchema.safeParse({
      action: "payment",
      id: token,
      requestId: token,
      amount: 200,
      currency: "NIO",
      method: "cash",
      account: "cash",
      concept: "Pago prueba",
      fx: 36.5,
    }).success,
    false,
  );
});
test("el QR generado realmente se puede decodificar con ZXing", async () => {
  const svg = renderToStaticMarkup(
    createElement(QRCodeSVG, {
      value: cardPayload(token),
      size: 246,
      marginSize: 4,
      level: "M",
    }),
  );
  const { data, info } = await sharp(Buffer.from(svg))
    .flatten({ background: "#fff" })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const gray = new Uint8ClampedArray(info.width * info.height);
  for (let i = 0; i < gray.length; i++)
    gray[i] = (data[i * 3] + 2 * data[i * 3 + 1] + data[i * 3 + 2]) / 4;
  const source = new zxing.RGBLuminanceSource(gray, info.width, info.height);
  const result = new zxing.QRCodeReader().decode(
    new zxing.BinaryBitmap(new zxing.HybridBinarizer(source)),
  );
  assert.equal(result.getText(), cardPayload(token));
});
