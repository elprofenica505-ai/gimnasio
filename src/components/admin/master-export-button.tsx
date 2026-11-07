"use client";

import { useState } from "react";
import { Download } from "lucide-react";

const ENDPOINT = "/api/admin/reportes/maestro";
const FILENAME = "Power-Box-Gym-Maestro.xlsx";
const DB_NAME = "strong-gym-export";
const STORE = "handles";
const KEY = "master-xlsx";

type SaveHandle = {
  queryPermission?: (d: { mode: "readwrite" }) => Promise<PermissionState>;
  requestPermission?: (d: { mode: "readwrite" }) => Promise<PermissionState>;
  createWritable: () => Promise<{ write: (data: Blob) => Promise<void>; close: () => Promise<void> }>;
};

type PickerWindow = Window & {
  showSaveFilePicker?: (opts: {
    suggestedName: string;
    types: { description: string; accept: Record<string, string[]> }[];
  }) => Promise<SaveHandle>;
};

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function readHandle(): Promise<SaveHandle | null> {
  try {
    const db = await openDb();
    return await new Promise((resolve, reject) => {
      const req = db.transaction(STORE, "readonly").objectStore(STORE).get(KEY);
      req.onsuccess = () => resolve((req.result as SaveHandle | undefined) ?? null);
      req.onerror = () => reject(req.error);
    });
  } catch {
    return null;
  }
}

async function writeHandle(handle: SaveHandle): Promise<void> {
  const db = await openDb();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(handle, KEY);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

/**
 * Descarga el Excel maestro. En Chrome/Edge de escritorio reemplaza el MISMO archivo
 * que eligió la primera vez (no crea copias). En otros navegadores se descarga normalmente.
 */
export function MasterExportButton({ label = "Exportar Excel maestro" }: { label?: string }) {
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function run() {
    setBusy(true);
    setMessage(null);
    try {
      const res = await fetch(ENDPOINT, { cache: "no-store", credentials: "same-origin" });
      if (!res.ok) {
        const body = (await res.json().catch(() => null)) as { message?: string } | null;
        setMessage(body?.message ?? "No se pudo generar el Excel. Intentá de nuevo.");
        return;
      }
      const blob = await res.blob();
      const picker = (window as PickerWindow).showSaveFilePicker;
      if (picker) {
        const result = await saveToSameFile(blob, picker);
        if (result === "fallback") {
          downloadBlob(blob);
          setMessage("Descargado. No se pudo reemplazar el archivo elegido; revisá la carpeta de descargas.");
          return;
        }
        if (result === "cancelled") {
          setMessage("Cancelado. El archivo anterior no cambió.");
          return;
        }
        setMessage(
          result === "replaced"
            ? "Listo: se actualizó el mismo archivo Power-Box-Gym-Maestro.xlsx."
            : "Listo: guardado. La próxima vez se actualizará este mismo archivo.",
        );
        return;
      }
      downloadBlob(blob);
      setMessage("Descargado. Este navegador no permite reemplazar el archivo; en Chrome o Edge de escritorio sí.");
    } catch {
      setMessage("No hubo conexión con el servidor. Revisá la red e intentá de nuevo.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-col items-end gap-1">
      <button
        type="button"
        onClick={run}
        disabled={busy}
        className="inline-flex items-center gap-2 rounded-full border border-brand/40 bg-brand/10 px-4 py-2 text-[0.8125rem] font-semibold text-ink transition-colors hover:border-brand disabled:opacity-60"
      >
        <Download className="size-4" aria-hidden="true" />
        {busy ? "Preparando…" : label}
      </button>
      {message ? (
        <p role="status" className="max-w-sm text-right text-[0.75rem] text-fog">
          {message}
        </p>
      ) : null}
    </div>
  );
}

async function saveToSameFile(
  blob: Blob,
  picker: NonNullable<PickerWindow["showSaveFilePicker"]>,
): Promise<"replaced" | "saved" | "cancelled" | "fallback"> {
  let handle = await readHandle();
  if (handle) {
    const perm =
      (await handle.queryPermission?.({ mode: "readwrite" })) === "granted"
        ? "granted"
        : await handle.requestPermission?.({ mode: "readwrite" });
    if (perm !== "granted") handle = null;
  }
  if (!handle) {
    try {
      handle = await picker({
        suggestedName: FILENAME,
        types: [{ description: "Libro de Excel", accept: { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": [".xlsx"] } }],
      });
    } catch (error) {
      // El usuario cerró el selector: no cambia nada. Otro error: se descarga normalmente.
      return (error as { name?: string })?.name === "AbortError" ? "cancelled" : "fallback";
    }
    await writeHandle(handle).catch(() => undefined);
    const writable = await handle.createWritable();
    await writable.write(blob);
    await writable.close();
    return "saved";
  }
  try {
    const writable = await handle.createWritable();
    await writable.write(blob);
    await writable.close();
  } catch {
    return "fallback";
  }
  return "replaced";
}

function downloadBlob(blob: Blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = FILENAME;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
