"use client";

import { usePathname } from "next/navigation";
import { ArmChat } from "@/components/arm/arm-chat";

/**
 * La burbuja del asistente en la web pública. Se oculta sola donde tiene
 * su propia casa: el panel de gestión y la pantalla de Mensajes de Mi cuenta.
 */
export function ArmWidget({ locale }: { locale: string }) {
  const pathname = usePathname() ?? "";
  const relativa = pathname.replace(/^\/(es|en)(?=\/|$)/, "");
  if (relativa.startsWith("/panel") || relativa === "/mi-cuenta/mensajes") return null;
  return <ArmChat locale={locale} variante="burbuja" />;
}
