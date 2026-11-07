import Link from "next/link";
import { siteConfig } from "@/config/site";
import { cn } from "@/lib/utils";
import { BrandMark } from "./brand-mark";

/**
 * Logo del sitio: el emblema del triángulo + el nombre del gimnasio.
 *
 * `tone` describe la superficie donde va apoyado, no el color del texto:
 *  - "dark"  → fondo oscuro (el caso de todo el sitio) → texto blanco.
 *  - "light" → fondo claro (rojo o blanco) → texto negro.
 * El triángulo rojo funciona igual en las dos.
 */
export function Logo({
  locale,
  name,
  className,
  compact = false,
  tone = "dark",
}: {
  locale: string;
  name?: string;
  className?: string;
  compact?: boolean;
  tone?: "light" | "dark";
}) {
  return (
    <Link
      href={`/${locale}`}
      aria-label={name ?? siteConfig.name}
      className={cn("group flex items-center gap-2.5", className)}
    >
      <BrandMark className="size-9 shrink-0 transition-transform duration-300 group-hover:scale-110 sm:size-10" />

      {!compact ? (
        <span className="flex flex-col leading-none">
          <span
            className={cn(
              "display-xl text-[1.0625rem] tracking-[0.01em] sm:text-[1.1875rem]",
              tone === "dark" ? "text-white" : "text-night",
            )}
          >
            Power Box
          </span>
          <span
            className={cn(
              "mt-0.5 text-[0.5625rem] font-semibold tracking-[0.22em] uppercase sm:text-[0.625rem]",
              tone === "dark" ? "text-white/55" : "text-night/60",
            )}
          >
            Gym
          </span>
        </span>
      ) : null}
    </Link>
  );
}
