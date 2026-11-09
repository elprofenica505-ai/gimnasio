"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import {
  BadgeDollarSign,
  CheckCircle2,
  ExternalLink,
  Loader2,
  MessageCircle,
  Users,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";

export interface OrdenRow {
  id: string;
  public_id: string;
  status: "pendiente" | "por_verificar" | "pagada" | "cancelada";
  full_name: string;
  phone: string;
  email: string | null;
  plan_name: string | null;
  plan_amount: number | null;
  items: { name?: string; qty?: number; total?: number }[] | null;
  total: number;
  currency: string;
  pay_reference: string | null;
  pay_notified_at: string | null;
  confirmed_at: string | null;
  created_at: string;
}

export interface LeadRow {
  id: string;
  full_name: string;
  phone: string;
  email: string | null;
  source: string;
  interest: string | null;
  stage: "nuevo" | "contactado" | "visito" | "comprador" | "perdido";
  note: string | null;
  last_touch: string;
  created_at: string;
}

const ETAPAS: { id: LeadRow["stage"]; label: string }[] = [
  { id: "nuevo", label: "Nuevo" },
  { id: "contactado", label: "Contactado" },
  { id: "visito", label: "Visitó" },
  { id: "comprador", label: "Comprador" },
  { id: "perdido", label: "Perdido" },
];

const ESTADO_ORDEN: Record<OrdenRow["status"], { label: string; clase: string }> = {
  pendiente: { label: "Sin pago informado", clase: "border-line text-fog" },
  por_verificar: { label: "POR VERIFICAR", clase: "border-brand/60 bg-brand/10 text-brand-300" },
  pagada: { label: "Pagada", clase: "border-ok/50 bg-ok/10 text-ok" },
  cancelada: { label: "Cancelada", clase: "border-alert/40 text-alert" },
};

function wa(phone: string, texto: string): string {
  const digits = phone.replace(/\D/g, "");
  const conPais = digits.startsWith("505") ? digits : `505${digits}`;
  return `https://wa.me/${conPais}?text=${encodeURIComponent(texto)}`;
}

const fecha = (iso: string) =>
  new Date(iso).toLocaleString("es-NI", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });

/**
 * Ventas online: órdenes de la web (confirmar pago con 1 toque) y el
 * pipeline de leads con WhatsApp prellenado por etapa. Las reglas y la
 * idempotencia viven en la base (embudo_confirmar_orden); acá sólo
 * disparamos las RPCs y mostramos el estado que devuelven.
 */
export function VentasPanel({
  ordenes,
  leads,
  instruccionesInicial,
  errorCarga,
}: {
  ordenes: OrdenRow[];
  leads: LeadRow[];
  instruccionesInicial: string | null;
  errorCarga: string | null;
}) {
  const router = useRouter();
  const [tab, setTab] = useState<"ordenes" | "leads">(
    ordenes.some((o) => o.status === "por_verificar") ? "ordenes" : "leads",
  );
  const [ocupado, setOcupado] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [instrucciones, setInstrucciones] = useState(instruccionesInicial ?? "");
  const [editandoInstr, setEditandoInstr] = useState(false);

  const porVerificar = useMemo(() => ordenes.filter((o) => o.status === "por_verificar"), [ordenes]);
  const pendientes = useMemo(() => ordenes.filter((o) => o.status === "pendiente"), [ordenes]);
  const enPipeline = useMemo(() => leads.filter((l) => l.stage !== "comprador" && l.stage !== "perdido"), [leads]);

  async function confirmar(o: OrdenRow) {
    setOcupado(o.id);
    setAviso(null);
    try {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) return setAviso("Sin Supabase conectado.");
      const { error } = await supabase.rpc("embudo_confirmar_orden", {
        p_order_id: o.id,
        p_cuenta: null,
      });
      if (error) {
        setAviso(
          error.message?.includes("FINANCE")
            ? "La caja no permite escrituras todavía (FINANCE_REVIEW). Revisá Caja."
            : `No se pudo confirmar: ${error.message}`,
        );
      } else {
        setAviso(`Orden ${o.public_id} confirmada: membresía activada.`);
        router.refresh();
      }
    } finally {
      setOcupado(null);
    }
  }

  async function rechazar(o: OrdenRow) {
    if (
      !window.confirm(
        `¿Rechazar la orden ${o.public_id} de ${o.full_name}? Queda cancelada: no se cobra ni se activa nada.`,
      )
    ) {
      return;
    }
    setOcupado(o.id);
    setAviso(null);
    try {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) return setAviso("Sin Supabase conectado.");
      const { error } = await supabase.rpc("embudo_cancelar_orden", {
        p_order_id: o.id,
        p_nota: null,
      });
      if (error) {
        setAviso(`No se pudo rechazar: ${error.message}`);
      } else {
        setAviso(`Orden ${o.public_id} rechazada (cancelada).`);
        router.refresh();
      }
    } finally {
      setOcupado(null);
    }
  }

  async function avanzar(l: LeadRow, stage: LeadRow["stage"]) {
    setOcupado(l.id);
    setAviso(null);
    try {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) return setAviso("Sin Supabase conectado.");
      const { error } = await supabase.rpc("embudo_avanzar_lead", {
        p_lead_id: l.id,
        p_stage: stage,
        p_note: null,
      });
      if (error) setAviso(`No se pudo actualizar: ${error.message}`);
      else router.refresh();
    } finally {
      setOcupado(null);
    }
  }

  async function guardarInstrucciones() {
    setOcupado("instr");
    setAviso(null);
    try {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) return setAviso("Sin Supabase conectado.");
      const { error } = await supabase.rpc("embudo_config_set", {
        p_key: "instrucciones",
        p_value: instrucciones,
      });
      if (error) setAviso(`No se pudo guardar: ${error.message}`);
      else {
        setAviso("Instrucciones de pago actualizadas.");
        setEditandoInstr(false);
      }
    } finally {
      setOcupado(null);
    }
  }

  const textoContacto = (l: LeadRow) =>
    `Hola ${l.full_name}, te escribimos de Power Box Gym. ${l.interest ? `Nos dijiste que te interesa ${l.interest}. ` : ""}¿Te contamos horarios y precios?`;

  return (
    <div className="mt-8">
      {/* Resumen */}
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="rounded-2xl border border-brand/50 bg-brand/10 p-4">
          <p className="display-xl text-3xl text-brand">{porVerificar.length}</p>
          <p className="text-sm text-mist">pagos por verificar</p>
        </div>
        <div className="rounded-2xl border border-line bg-card p-4">
          <p className="display-xl text-3xl text-ink">{pendientes.length}</p>
          <p className="text-sm text-fog">órdenes sin pagar</p>
        </div>
        <div className="rounded-2xl border border-line bg-card p-4">
          <p className="display-xl text-3xl text-ink">{enPipeline.length}</p>
          <p className="text-sm text-fog">interesados en seguimiento</p>
        </div>
      </div>

      {errorCarga && (
        <p role="alert" className="mt-4 rounded-xl border border-alert/40 bg-alert/10 px-4 py-3 text-sm text-white">
          No se pudieron cargar las ventas: {errorCarga}
        </p>
      )}
      {aviso && (
        <p className="mt-4 rounded-xl border border-ok/40 bg-ok/10 px-4 py-3 text-sm text-white">{aviso}</p>
      )}

      {/* Tabs */}
      <div className="mt-8 flex gap-2">
        <button
          type="button"
          onClick={() => setTab("ordenes")}
          className={cn(
            "flex items-center gap-2 rounded-full border px-4 py-2 text-sm font-semibold transition-colors",
            tab === "ordenes" ? "border-brand bg-brand/10 text-brand-300" : "border-line text-fog",
          )}
        >
          <BadgeDollarSign className="size-4" aria-hidden="true" />
          Órdenes ({ordenes.length})
        </button>
        <button
          type="button"
          onClick={() => setTab("leads")}
          className={cn(
            "flex items-center gap-2 rounded-full border px-4 py-2 text-sm font-semibold transition-colors",
            tab === "leads" ? "border-brand bg-brand/10 text-brand-300" : "border-line text-fog",
          )}
        >
          <Users className="size-4" aria-hidden="true" />
          Interesados ({leads.length})
        </button>
      </div>

      {/* Órdenes */}
      {tab === "ordenes" && (
        <div className="mt-6 space-y-3">
          {ordenes.length === 0 && <p className="text-fog">Todavía no hay órdenes de la web.</p>}
          {ordenes.map((o) => {
            const estado = ESTADO_ORDEN[o.status];
            const productos = (o.items ?? []).map((i) => `${i.qty}× ${i.name}`).join(", ");
            return (
              <article
                key={o.id}
                className={cn(
                  "rounded-2xl border bg-card p-5",
                  o.status === "por_verificar" ? "border-brand/40" : "border-line",
                )}
              >
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="font-mono text-sm tracking-wide text-brand">{o.public_id}</p>
                    <p className="mt-0.5 font-bold text-white">
                      {o.full_name} · {o.phone}
                    </p>
                    <p className="mt-0.5 text-sm text-fog">
                      {fecha(o.created_at)}
                      {o.plan_name ? ` · ${o.plan_name}` : ""}
                      {productos ? ` · ${productos}` : ""}
                    </p>
                    {o.pay_reference && (
                      <p className="mt-1 text-sm text-mist">
                        Ref: <strong className="text-white">{o.pay_reference}</strong>
                        {o.pay_notified_at ? ` · informado ${fecha(o.pay_notified_at)}` : ""}
                      </p>
                    )}
                  </div>
                  <div className="text-right">
                    <p className="display-xl text-2xl text-brand">
                      C${Number(o.total).toLocaleString("es-NI")}
                    </p>
                    <span className={cn("mt-1 inline-block rounded-full border px-2.5 py-0.5 text-xs font-semibold", estado.clase)}>
                      {estado.label}
                    </span>
                  </div>
                </div>
                {o.status === "por_verificar" && (
                  <div className="mt-4 flex flex-wrap gap-2">
                    <Button size="sm" disabled={ocupado === o.id} onClick={() => confirmar(o)}>
                      {ocupado === o.id ? (
                        <Loader2 className="size-4 animate-spin" aria-hidden="true" />
                      ) : (
                        <CheckCircle2 className="size-4" aria-hidden="true" />
                      )}
                      Confirmar pago y activar
                    </Button>
                    <Button
                      size="sm"
                      variant="dark"
                      disabled={ocupado === o.id}
                      onClick={() => rechazar(o)}
                    >
                      Rechazar
                    </Button>
                    <a
                      href={wa(o.phone, `Hola ${o.full_name}, recibimos tu pago de la orden ${o.public_id}. ¡Bienvenido/a a Power Box Gym!`)}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex items-center gap-2 rounded-full border border-line px-4 py-2 text-sm font-semibold text-mist transition-colors hover:border-brand/50"
                    >
                      <MessageCircle className="size-4" aria-hidden="true" />
                      WhatsApp
                    </a>
                  </div>
                )}
              </article>
            );
          })}
        </div>
      )}

      {/* Leads */}
      {tab === "leads" && (
        <div className="mt-6 space-y-3">
          {leads.length === 0 && <p className="text-fog">Todavía no hay interesados capturados.</p>}
          {leads.map((l) => (
            <article key={l.id} className="rounded-2xl border border-line bg-card p-5">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <p className="font-bold text-white">
                    {l.full_name}
                    <span className="ml-2 text-xs font-normal text-fog">{fecha(l.created_at)}</span>
                  </p>
                  <p className="text-sm text-fog">
                    {l.phone}
                    {l.email ? ` · ${l.email}` : ""}
                    {l.interest ? ` · le interesa ${l.interest}` : ""}
                    {" · "}
                    {l.source}
                  </p>
                  {l.note && <p className="mt-1 text-sm text-mist">Nota: {l.note}</p>}
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {ETAPAS.map((e) => (
                    <button
                      key={e.id}
                      type="button"
                      disabled={ocupado === l.id || l.stage === e.id}
                      onClick={() => avanzar(l, e.id)}
                      className={cn(
                        "rounded-full border px-2.5 py-1 text-xs font-semibold transition-colors disabled:opacity-50",
                        l.stage === e.id
                          ? e.id === "comprador"
                            ? "border-ok/60 bg-ok/10 text-ok"
                            : "border-brand bg-brand/10 text-brand-300"
                          : "border-line text-fog hover:border-brand/50",
                      )}
                    >
                      {e.label}
                    </button>
                  ))}
                </div>
              </div>
              <div className="mt-3 flex flex-wrap gap-2">
                <a
                  href={wa(l.phone, textoContacto(l))}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-2 rounded-full border border-line px-3.5 py-1.5 text-sm font-semibold text-mist transition-colors hover:border-brand/50"
                >
                  <MessageCircle className="size-4" aria-hidden="true" />
                  Escribir por WhatsApp
                </a>
              </div>
            </article>
          ))}
        </div>
      )}

      {/* Instrucciones de pago */}
      <div className="mt-10 rounded-2xl border border-line bg-card p-5">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p className="font-bold text-white">Instrucciones de pago del checkout</p>
          {!editandoInstr && (
            <Button size="sm" variant="outline-dark" onClick={() => setEditandoInstr(true)}>
              <ExternalLink className="size-4" aria-hidden="true" />
              Editar
            </Button>
          )}
        </div>
        {editandoInstr ? (
          <div className="mt-3 space-y-3">
            <textarea
              value={instrucciones}
              onChange={(e) => setInstrucciones(e.target.value)}
              rows={4}
              maxLength={1000}
              className="w-full rounded-xl border border-line bg-paper p-3 text-sm text-mist"
            />
            <div className="flex gap-2">
              <Button size="sm" disabled={ocupado === "instr"} onClick={guardarInstrucciones}>
                {ocupado === "instr" ? (
                  <Loader2 className="size-4 animate-spin" aria-hidden="true" />
                ) : undefined}
                Guardar
              </Button>
              <Button size="sm" variant="outline-dark" onClick={() => setEditandoInstr(false)}>
                Cancelar
              </Button>
            </div>
          </div>
        ) : (
          <p className="mt-2 text-sm text-mist">{instrucciones || "Sin instrucciones configuradas."}</p>
        )}
      </div>
    </div>
  );
}
