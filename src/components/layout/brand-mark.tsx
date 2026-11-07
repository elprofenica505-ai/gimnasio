import { cn } from "@/lib/utils";

/**
 * Emblema de POWER BOX GYM: guante de boxeo rojo, dibujado en vectores
 * para que se vea nítido en cualquier tamaño y sobre cualquier fondo.
 * La costura oscura asume fondo oscuro (el caso de todo el sitio),
 * igual que la marca anterior. El favicon (src/app/icon.svg) y la
 * imagen para compartir (opengraph-image.tsx) dibujan el mismo guante.
 */
export function BrandMark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 100 100"
      className={cn("size-9", className)}
      aria-hidden="true"
      focusable="false"
    >
      {/* Guante: puño redondeado + pulgar + muñequera, separados del fondo. */}
      <rect x="26" y="16" width="48" height="50" rx="24" fill="#d81a22" />
      <ellipse cx="22" cy="50" rx="10" ry="13" fill="#d81a22" />
      <rect x="40" y="70" width="26" height="14" rx="6" fill="#d81a22" />
      {/* Costura del pulgar y línea del puño, en el color del fondo oscuro. */}
      <path
        d="M36 38 C29 46 29 56 36 64"
        stroke="#0c0c0e"
        strokeWidth="4"
        strokeLinecap="round"
        fill="none"
      />
      <path d="M44 72 h18" stroke="#0c0c0e" strokeWidth="3" strokeLinecap="round" />
    </svg>
  );
}
