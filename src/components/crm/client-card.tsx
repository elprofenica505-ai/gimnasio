"use client";
import { QRCodeSVG } from "qrcode.react";
import { cardPayload } from "@/lib/crm/types";
import { Button } from "@/components/ui/button";
export function ClientCard({
  name,
  number,
  token,
}: {
  name: string;
  number: number;
  token: string;
}) {
  return (
    <div className="space-y-3">
      <div className="strong-client-card mx-auto max-w-xs rounded-2xl bg-white p-6 text-center text-black">
        <p className="text-lg font-black">STRONG FITNESS GYM</p>
        <p className="mt-2 break-words font-semibold">{name}</p>
        <p className="text-sm">Cliente #{number}</p>
        <QRCodeSVG
          value={cardPayload(token)}
          size={246}
          level="M"
          marginSize={4}
          className="mx-auto my-3 h-auto max-w-full"
          title="Identificación de cliente Power Box"
        />
        <p className="text-xs">
          Mostrá este carnet en recepción. No es un comprobante de pago.
        </p>
      </div>
      <Button type="button" variant="outline" onClick={() => window.print()}>
        Imprimir / guardar PDF
      </Button>
      <p className="text-xs text-fog">
        Podés usar el carnet en papel. Si no lo llevás, te buscamos por nombre o
        número.
      </p>
      <style>{`@media print { body * { visibility: hidden !important; } .strong-client-card, .strong-client-card * { visibility: visible !important; } .strong-client-card { position: absolute !important; left: 0; top: 0; margin: 0 !important; border: 1px solid #111; width: 300px; break-inside: avoid; } }`}</style>
    </div>
  );
}
