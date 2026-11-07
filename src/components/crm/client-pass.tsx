"use client";
import { useEffect, useState } from "react";
import { ClientCard } from "./client-card";
import { useApp } from "@/components/providers/app-provider";
export function ClientPass() {
  const { user, isDemo } = useApp();
  const [pass, setPass] = useState<{
    name: string;
    number: number;
    token: string;
  } | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    if (!user || isDemo) return;
    const ctl = new AbortController();
    fetch("/api/account/pass", { cache: "no-store", signal: ctl.signal })
      .then(async (r) => {
        const body = await r.json();
        if (!r.ok)
          throw new Error(
            "Carnet no disponible. Pedí búsqueda manual en recepción.",
          );
        setPass(body.data);
        setError("");
      })
      .catch(() => {
        if (!ctl.signal.aborted)
          setError("Carnet no disponible. Pedí búsqueda manual en recepción.");
      });
    return () => ctl.abort();
  }, [user?.id, isDemo, user]);
  if (!user || isDemo) return null;
  return (
    <section className="container-x my-8 rounded-2xl border border-line bg-card p-5">
      <h2 className="mb-4 text-xl font-bold">Mi carnet Power Box</h2>
      {pass ? (
        <ClientCard {...pass} />
      ) : (
        <p className="text-sm text-fog">
          {error ||
            "Si tu ficha está vinculada a esta cuenta, aquí aparecerá tu carnet. También podés solicitarlo en recepción."}
        </p>
      )}
    </section>
  );
}
