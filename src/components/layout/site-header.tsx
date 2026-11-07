"use client";

import { useEffect, useState } from "react";
import { CalendarCheck, Menu } from "lucide-react";
import { isOpenAt } from "@/config/site";
import { useDictionary } from "@/components/providers/dictionary-provider";
import { useApp } from "@/components/providers/app-provider";
import { ButtonLink } from "@/components/ui/button";
import { isStaffRole } from "@/lib/auth/current-user";
import { cn } from "@/lib/utils";
import { LanguageSwitcher } from "./language-switcher";
import { Logo } from "./logo";

/**
 * Barra superior simplificada: la navegación vive en el panel lateral
 * (SideNav), así que acá sólo quedan el botón de menú del celular, el
 * logo (sólo en el celular, donde el panel está oculto), el estado
 * abierto/cerrado, el idioma y el acceso directo a reservar.
 */
export function SiteHeader({
  onOpenMenu,
  showBookCta = true,
}: {
  onOpenMenu: () => void;
  showBookCta?: boolean;
}) {
  const { dict, locale } = useDictionary();
  const { user } = useApp();
  // El personal no reserva clases: no se muestra el botón de reserva en el encabezado.
  const staff = isStaffRole(user?.role);
  const [scrolled, setScrolled] = useState(false);
  const [abierto, setAbierto] = useState<boolean | null>(null);

  /* ¿Está abierto ahora? Se calcula en el navegador para no quedar
     pegado al momento en que se generó la página. */
  useEffect(() => {
    const revisar = () => setAbierto(isOpenAt(new Date()));
    revisar();
    const id = window.setInterval(revisar, 60_000);
    return () => window.clearInterval(id);
  }, []);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      className={cn(
        "sticky top-0 z-40 border-b bg-paper/95 backdrop-blur-xl transition-all duration-300",
        scrolled
          ? "border-brand/30 shadow-[0_10px_30px_-24px_rgba(216,26,34,0.55)]"
          : "border-line-soft",
      )}
    >
      <div className="container-x">
        <div className="flex h-16 items-center justify-between gap-3 sm:h-18">
          <div className="flex items-center gap-2">
            {/* Botón de menú: abre el panel lateral en el celular */}
            <button
              type="button"
              onClick={onOpenMenu}
              aria-label={dict.nav.menu}
              className="grid size-10 place-items-center rounded-full border border-line bg-card text-ink transition-colors hover:border-brand/40 lg:hidden"
            >
              <Menu className="size-5" aria-hidden="true" />
            </button>

            {/* En la computadora el logo ya está en el panel lateral */}
            <span className="lg:hidden">
              <Logo locale={locale} name={dict.nav.home} tone="dark" />
            </span>
          </div>

          <div className="flex items-center gap-2">
            {abierto !== null ? (
              <span
                className={cn(
                  "hidden items-center gap-1.5 rounded-full border px-3 py-1.5 text-[0.6875rem] font-semibold tracking-[0.08em] uppercase xl:inline-flex",
                  abierto
                    ? "border-ok/25 bg-ok/8 text-ok"
                    : "border-line bg-cloud text-fog",
                )}
              >
                <span
                  className={cn(
                    "size-1.5 rounded-full",
                    abierto ? "animate-pulse bg-ok" : "bg-fog",
                  )}
                  aria-hidden="true"
                />
                {abierto ? dict.contact.openNow : dict.contact.closedNow}
              </span>
            ) : null}

            <LanguageSwitcher locale={locale} label={dict.nav.language} />

            {/* La visibilidad pertenece al contenedor: ButtonLink usa inline-flex
                y no debe competir con hidden dentro del mismo elemento. */}
            {showBookCta && !staff ? (
            <div className="hidden sm:block">
              <ButtonLink href={`/${locale}/horarios`} size="sm">
                <CalendarCheck className="size-4" aria-hidden="true" />
                {dict.cta.book}
              </ButtonLink>
            </div>
            ) : null}
          </div>
        </div>
      </div>
    </header>
  );
}
