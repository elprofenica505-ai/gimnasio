"use client";

import { useState } from "react";
import { CheckCircle2, Loader2, Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/field";
import { Reveal } from "@/components/ui/reveal";
import { Section, SectionHeading } from "@/components/ui/section";
import type { Locale } from "@/i18n/config";

/**
 * Captura de interesados: el visitante que todavía no compra deja su
 * número y queda en el pipeline del CRM (nuevo → contactado → visitó).
 * Deduplicado por teléfono en la base; el seguimiento es por WhatsApp.
 */
export function LeadCapture({ locale }: { locale: Locale }) {
  const es = locale === "es";
  const [nombre, setNombre] = useState("");
  const [telefono, setTelefono] = useState("");
  const [intereses, setIntereses] = useState("");
  const [web, setWeb] = useState(""); // honeypot
  const [estado, setEstado] = useState<"idle" | "enviando" | "listo" | "error">("idle");

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (estado === "enviando") return;
    setEstado("enviando");
    try {
      const r = await fetch("/api/leads", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          full_name: nombre,
          phone: telefono,
          interest: intereses || null,
          source: "landing",
          website: web,
        }),
      });
      setEstado(r.ok ? "listo" : "error");
      if (r.ok) {
        setNombre("");
        setTelefono("");
        setIntereses("");
      }
    } catch {
      setEstado("error");
    }
  }

  return (
    <Section id="interesado" className="border-b border-line">
      <SectionHeading
        eyebrow={es ? "Empezá hoy" : "Start today"}
        title={es ? "¿Te da vueltas entrenar con nosotros?" : "Thinking about training with us?"}
        subtitle={
          es
            ? "Dejanos tu número y te escribimos por WhatsApp: te contamos los horarios, respondemos tus dudas y coordinamos tu primera visita. Sin compromiso."
            : "Leave your number and we'll message you on WhatsApp with schedules, answers and your first visit. No strings attached."
        }
      />
      <Reveal>
        <div className="mx-auto mt-10 max-w-xl rounded-3xl border border-line bg-card p-6 sm:p-8">
          {estado === "listo" ? (
            <div className="flex flex-col items-center gap-3 py-6 text-center">
              <CheckCircle2 className="size-12 text-ok" aria-hidden="true" />
              <p className="text-lg font-bold text-white">
                {es ? "¡Listo! Te escribimos enseguida." : "All set! We'll message you shortly."}
              </p>
              <p className="text-sm text-fog">
                {es
                  ? "Guardá nuestro número para que te llegue el WhatsApp."
                  : "Save our number so the WhatsApp reaches you."}
              </p>
            </div>
          ) : (
            <form className="space-y-4" onSubmit={onSubmit}>
              <div>
                <label htmlFor="lead-nombre" className="mb-1.5 block text-sm font-semibold text-mist">
                  {es ? "Tu nombre" : "Your name"}
                </label>
                <Input
                  id="lead-nombre"
                  required
                  minLength={2}
                  autoComplete="name"
                  value={nombre}
                  onChange={(e) => setNombre(e.target.value)}
                />
              </div>
              <div>
                <label htmlFor="lead-tel" className="mb-1.5 block text-sm font-semibold text-mist">
                  {es ? "Tu número de WhatsApp" : "Your WhatsApp number"}
                </label>
                <Input
                  id="lead-tel"
                  type="tel"
                  inputMode="tel"
                  required
                  minLength={6}
                  autoComplete="tel"
                  placeholder="8888 0000"
                  value={telefono}
                  onChange={(e) => setTelefono(e.target.value)}
                />
              </div>
              <div>
                <label htmlFor="lead-int" className="mb-1.5 block text-sm font-semibold text-mist">
                  {es ? "¿Qué te interesa? (opcional)" : "What are you interested in? (optional)"}
                </label>
                <Input
                  id="lead-int"
                  placeholder={es ? "Pesas, boxeo, zumba…" : "Weights, boxing, dance…"}
                  value={intereses}
                  onChange={(e) => setIntereses(e.target.value)}
                />
              </div>
              {/* Honeypot: invisible para personas. */}
              <input
                type="text"
                name="website"
                tabIndex={-1}
                autoComplete="off"
                value={web}
                onChange={(e) => setWeb(e.target.value)}
                className="hidden"
                aria-hidden="true"
              />
              {estado === "error" && (
                <p role="alert" className="rounded-xl border border-alert/40 bg-alert/10 px-4 py-3 text-sm text-white">
                  {es
                    ? "No se pudo enviar. Probá de nuevo o escribinos por WhatsApp."
                    : "Could not send. Try again or reach us on WhatsApp."}
                </p>
              )}
              <Button type="submit" disabled={estado === "enviando"} className="w-full">
                {estado === "enviando" ? (
                  <Loader2 className="size-4 animate-spin" aria-hidden="true" />
                ) : (
                  <Send className="size-4" aria-hidden="true" />
                )}
                {es ? "Quiero que me escriban" : "Message me, please"}
              </Button>
            </form>
          )}
        </div>
      </Reveal>
    </Section>
  );
}
