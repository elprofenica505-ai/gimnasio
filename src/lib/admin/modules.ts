/**
 * Mapa de módulos del panel de gestión. Fuente única para el menú del panel,
 * las tarjetas del inicio y las pruebas. Sólo define rutas y permisos de
 * visibilidad; la seguridad real vive en la base (RLS y funciones) y en cada página.
 */

export type PanelRole = "admin" | "cashier" | "trainer" | "member" | "staff" | null | undefined;

/** "trainer": sólo el módulo del entrenador. "none": sin módulos. */
export type PanelAccessLevel = "all" | "finance" | "trainer" | "none";

export interface PanelChild {
  id: string;
  label: string;
  href: string;
  /** Sólo administrador. */
  adminOnly?: boolean;
}

export interface PanelModule {
  id: "inicio" | "clientes" | "finanzas" | "operacion" | "administracion" | "entrenador";
  label: string;
  description: string;
  href: string;
  /** Sólo administrador. */
  adminOnly?: boolean;
  /** Sólo entrenador (no lo ven administrador ni caja). */
  trainerOnly?: boolean;
  children: PanelChild[];
}

export const PANEL_MODULES: PanelModule[] = [
  {
    id: "entrenador",
    label: "Mis clientes",
    description: "Tus clientes asignados y su asistencia. Pedí acceso a otros clientes.",
    href: "/panel/entrenador",
    trainerOnly: true,
    children: [],
  },
  {
    id: "inicio",
    label: "Inicio",
    description: "Resumen del día, cifras clave y accesos a cada módulo.",
    href: "/panel",
    children: [],
  },
  {
    id: "clientes",
    label: "Clientes",
    description: "Fichas, búsqueda, recepción con QR, asistencias y etiquetas.",
    href: "/panel/clientes",
    children: [{ id: "progreso", label: "Progreso y medidas", href: "/panel/progreso" }],
  },
  {
    id: "finanzas",
    label: "Finanzas",
    description: "Caja, cuentas por cobrar, gastos y reportes del gimnasio.",
    href: "/panel/finanzas",
    children: [
      { id: "caja", label: "Caja", href: "/panel/caja" },
      { id: "ventas", label: "Ventas online", href: "/panel/ventas" },
      { id: "cuentas", label: "Cuentas por cobrar", href: "/panel/cuentas" },
      { id: "gastos", label: "Gastos", href: "/panel/gastos" },
      { id: "productos", label: "Productos y stock", href: "/panel/productos" },
      { id: "reportes", label: "Reportes", href: "/panel/reportes" },
    ],
  },
  {
    id: "operacion",
    label: "Operación",
    description: "Reservas, mensajes de contacto y estado de las clases.",
    href: "/panel/operacion",
    children: [],
  },
  {
    id: "administracion",
    label: "Administración",
    description: "Personal y roles, tarifas, importación, herramientas y guía de uso.",
    href: "/panel/administracion",
    adminOnly: true,
    children: [
      { id: "roles", label: "Personal y roles", href: "/panel/administracion/roles", adminOnly: true },
      { id: "entrenadores", label: "Entrenadores y accesos", href: "/panel/administracion/entrenadores", adminOnly: true },
      {
        id: "equipo",
        label: "Equipo de entrenadores",
        href: "/panel/administracion/equipo",
        adminOnly: true,
      },
      { id: "disciplinas", label: "Disciplinas", href: "/panel/administracion/disciplinas", adminOnly: true },
      { id: "planes", label: "Planes y modalidades", href: "/panel/administracion/planes", adminOnly: true },
      { id: "horarios", label: "Horarios y clases", href: "/panel/administracion/horarios", adminOnly: true },
      { id: "categorias", label: "Categorías", href: "/panel/administracion/categorias", adminOnly: true },
      { id: "tarifas", label: "Tarifas", href: "/panel/administracion/tarifas", adminOnly: true },
      {
        id: "dinero",
        label: "Cuentas y transferencias",
        href: "/panel/administracion/dinero",
        adminOnly: true,
      },
      { id: "importar", label: "Importar clientes", href: "/panel/importar", adminOnly: true },
      { id: "herramientas", label: "Herramientas", href: "/panel/herramientas", adminOnly: true },
      { id: "ayuda", label: "Guía de uso", href: "/panel/ayuda", adminOnly: true },
    ],
  },
];

/** Caja y administración ven el panel; el entrenador sólo ve su módulo "Mis clientes". */
export function panelAccess(role: PanelRole, demo = false): PanelAccessLevel {
  if (demo) return "all";
  if (role === "admin") return "all";
  if (role === "cashier") return "finance";
  if (role === "trainer") return "trainer";
  return "none";
}

/** Módulos y sub-opciones que puede ver ese rol. */
export function visibleModules(role: PanelRole, demo = false): PanelModule[] {
  const access = panelAccess(role, demo);
  if (access === "none") return [];
  if (access === "trainer") return PANEL_MODULES.filter((m) => m.trainerOnly).map((m) => ({ ...m, children: [] }));
  const isAdmin = access === "all";
  return PANEL_MODULES.filter((m) => !m.trainerOnly && (isAdmin || !m.adminOnly)).map((m) => ({
    ...m,
    children: m.children.filter((c) => isAdmin || !c.adminOnly),
  }));
}

/** Módulo activo según la ruta (la ruta más específica gana). */
export function activeModuleId(pathname: string, modules: PanelModule[]): string | null {
  let best: { id: string; length: number } | null = null;
  for (const m of modules) {
    const candidates = [m.href, ...m.children.map((c) => c.href)];
    for (const href of candidates) {
      const matches = href === "/panel" ? pathname === href : pathname === href || pathname.startsWith(href + "/");
      if (matches && (!best || href.length > best.length)) {
        best = { id: m.id, length: href.length };
      }
    }
  }
  return best?.id ?? null;
}
