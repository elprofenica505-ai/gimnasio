import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { isOpenAt, openingHoursSummary, siteConfig, whatsappLink } from "@/config/site";
import type { ArmKnowledge, ArmLocale } from "./brain";

/**
 * Carga lo que el cerebro sabe del gimnasio, TODO desde la base (nunca
 * inventado): planes activos con su precio real, clases activas, productos
 * de la tienda y el horario del sitio. Si algo falla, devuelve lo que haya:
 * el cerebro responde con lo que tenga y sale honesto con lo que falte.
 */
export async function cargarConocimiento(
  db: SupabaseClient,
  locale: ArmLocale,
): Promise<ArmKnowledge> {
  const [planes, clases, productos] = await Promise.all([
    db
      .from("plans")
      .select("name_es,name_en,price,price_nio,period")
      .eq("is_active", true)
      .order("sort_order")
      .limit(8),
    db
      .from("classes")
      .select("name_es,name_en")
      .eq("is_active", true)
      .order("name_es")
      .limit(10),
    db.rpc("tienda_productos"),
  ]);

  const es = locale === "es";
  const sufijoPeriodo = (period: string) =>
    period === "month" ? (es ? "al mes" : "per month") : period === "week" ? (es ? "a la semana" : "per week") : es ? "por clase" : "per class";

  const planesTexto = (planes.data ?? [])
    .map((p) => {
      const nombre = (es ? p.name_es : p.name_en) || p.name_es;
      if (p.price_nio !== null && p.price_nio !== undefined) {
        return `${nombre} — C$${Number(p.price_nio).toLocaleString("es-NI")} ${sufijoPeriodo(String(p.period))}`;
      }
      if (p.price !== null && p.price !== undefined) {
        return `${nombre} — $${Number(p.price).toLocaleString("en-US")} ${sufijoPeriodo(String(p.period))}`;
      }
      return es ? `${nombre} — precio por consultar` : `${nombre} — price on request`;
    })
    .filter((s) => s.length > 0);

  const clasesTexto = (clases.data ?? [])
    .map((c) => (es ? c.name_es : c.name_en) || c.name_es)
    .filter(Boolean)
    .slice(0, 8);

  const productosTexto = (productos.data ?? [])
    .map((p: { name: string; price: number | null }) =>
      p.price !== null && p.price !== undefined
        ? `${p.name} (C$${Number(p.price).toLocaleString("es-NI")})`
        : p.name,
    )
    .slice(0, 6);

  const horarioResumen = openingHoursSummary(locale)
    .map((fila) => `${fila.days}: ${fila.hours}`)
    .join(" · ");

  // El servidor vive en UTC: llevar «ahora» a la hora de Managua para que
  // abierto/cerrado no mienta.
  const ahoraManagua = new Date(Date.now() + siteConfig.utcOffsetMinutes * 60_000);

  return {
    gimnasio: siteConfig.name,
    planes: planesTexto,
    clases: clasesTexto,
    productos: productosTexto,
    horarioResumen,
    abiertoAhora: horarioResumen ? isOpenAt(ahoraManagua) : null,
    whatsappUrl: whatsappLink(
      es ? "¡Hola! Vengo del chat de la web." : "Hi! I'm coming from the website chat.",
    ),
    urlPlanes: `/${locale}#planes`,
    urlHorarios: `/${locale}/horarios`,
    urlTienda: `/${locale}#tienda`,
  };
}
