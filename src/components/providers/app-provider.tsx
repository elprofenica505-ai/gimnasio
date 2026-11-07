"use client";

import { validBirthDate } from "@/lib/age/birth-date";
import { LEGAL_VERSION } from "@/lib/legal/version";
import { useRouter } from "next/navigation";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { BookingDetail } from "@/lib/types";
import { authEmailFailure } from "@/lib/auth/email-errors";
import { validNewPassword } from "@/lib/auth/password-recovery";
import { inactivityLimitMs, isInactive } from "@/lib/auth/session-policy";
import { authCallbackUrl } from "@/lib/auth/redirects";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";

/* ============================================================
   Tipos
   ============================================================ */

export interface AppUser {
  id: string;
  email: string;
  fullName: string;
  role: "member" | "cashier" | "trainer" | "admin" | "superadmin" | null;
  phone: string | null;
  planId: string | null;
  createdAt: string;
  /** true cuando la sesión es simulada (sin Supabase conectado). */
  isDemo: boolean;
}

export type BookingStatus = "confirmed" | "cancelled" | "attended" | "no_show";

export interface AppBooking {
  id: string;
  sessionId: string;
  status: BookingStatus;
  createdAt: string;
  /** Detalle de la última lectura autenticada; nunca de la respuesta de escritura. */
  detail?: BookingDetail;
}

/** Lista vacía compartida: identidad estable cuando no hay sesión. */
const EMPTY_BOOKINGS: AppBooking[] = [];

export type BookingErrorCode =
  | "AUTH"
  | "FULL"
  | "ALREADY_BOOKED"
  | "LIMIT"
  | "PAST"
  | "CANCELLED"
  | "TOO_LATE"
  | "NOT_FOUND"
  | "UNCONFIRMED"
  | "UNKNOWN";

export type ToastType = "success" | "error" | "info";

interface Toast {
  id: number;
  message: string;
  type: ToastType;
}

interface AppContextValue {
  user: AppUser | null;
  isDemo: boolean;
  authLoading: boolean;
  /** true cuando ya leímos la sesión del navegador (evita parpadeos). */
  hydrated: boolean;
  bookings: AppBooking[];
  bookingsLoading: boolean;
  bookingsError: boolean;
  reloadBookings: () => Promise<void>;
  bookedSessionIds: Set<string>;
  book: (
    sessionId: string,
  ) => Promise<{ ok: boolean; error?: BookingErrorCode }>;
  cancelBooking: (
    bookingId: string,
    sessionId: string,
  ) => Promise<{ ok: boolean; error?: BookingErrorCode }>;
  cancelBySessionId: (
    sessionId: string,
  ) => Promise<{ ok: boolean; error?: BookingErrorCode }>;
  signIn: (
    email: string,
    password: string,
  ) => Promise<{ ok: boolean; error?: string }>;
  signUp: (data: {
    fullName: string;
    email: string;
    password: string;
    phone?: string;
    birthDate: string;
    legalAccepted: boolean;
  }) => Promise<{ ok: boolean; error?: string; needsConfirmation?: boolean }>;
  signOut: () => Promise<void>;
  updateProfile: (data: {
    fullName?: string;
    phone?: string;
  }) => Promise<boolean>;
  toast: (message: string, type?: ToastType) => void;
  toasts: Toast[];
  dismissToast: (id: number) => void;
}

const AppContext = createContext<AppContextValue | null>(null);

/* ============================================================
   Limpieza de almacenamiento demo legado
   ============================================================ */

/** Retirar contraseñas demo antiguas; nunca tocar sesión Supabase ni intentos financieros. */
function clearLegacyDemoStorage() {
  try {
    const keys = Object.keys(window.localStorage);
    for (const key of keys) if (key.startsWith("strong-gym:demo-")) window.localStorage.removeItem(key);
  } catch { /* Almacenamiento bloqueado: sin persistencia nueva de credenciales. */ }
}

/* ============================================================
   Provider
   ============================================================ */

/** Convierte las filas de la API al formato interno de reservas. */
function toAppBookings(rows: BookingDetail[], userId: string): AppBooking[] {
  return rows.map((b) => ({
    id: b.id,
    sessionId: b.session_id,
    status: b.status,
    createdAt: b.created_at,
    detail: b.user_id === userId && b.session?.id === b.session_id ? b : undefined,
  }));
}

export function AppProvider({
  children,
  initialUser,
  isDemo,
}: {
  children: ReactNode;
  initialUser: AppUser | null;
  isDemo: boolean;
}) {
  const router = useRouter();
  /* `initialUser` llega del servidor y cambia con router.refresh(). El cierre
     de sesión se marca con el usuario que se cerró: así el valor se deduce
     sin un efecto que copie el prop al estado. Una sesión nueva (otro
     `initialUser`) descarta la marca sola. */
  const [signedOutUser, setSignedOutUser] = useState<AppUser | null>(null);
  const user: AppUser | null =
    isDemo || (signedOutUser !== null && signedOutUser === initialUser) ? null : initialUser;
  const hydrated = true;
  const [authLoading, setAuthLoading] = useState(false);
  const [bookings, setBookings] = useState<AppBooking[]>([]);
  const [bookingsRead, setBookingsRead] = useState<{
    owner: string | null;
    status: "loading" | "ready" | "error";
  }>({ owner: null, status: "loading" });
  const bookingsRequest = useRef(0);
  const latestUser = useRef(user);
  useEffect(() => {
    latestUser.current = user;
  }, [user]);
  const invalidateRequests = useCallback(() => {
    bookingsRequest.current++;
  }, []);
  const bookingsReady =
    isDemo ||
    !user ||
    (bookingsRead.owner === user.id && bookingsRead.status === "ready");
  const bookingsError =
    !isDemo &&
    !!user &&
    bookingsRead.owner === user.id &&
    bookingsRead.status === "error";
  const bookingsLoading = !bookingsReady && !bookingsError;
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastId = useRef(0);

  /* ---------- feedback ---------- */

  const dismissToast = useCallback((id: number) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const toast = useCallback(
    (message: string, type: ToastType = "info") => {
      toastId.current += 1;
      const id = toastId.current;
      setToasts((prev) => [...prev.slice(-3), { id, message, type }]);
      window.setTimeout(() => dismissToast(id), 4200);
    },
    [dismissToast],
  );

  /* ---------- carga inicial ---------- */

  useEffect(() => { clearLegacyDemoStorage(); }, []);

  /** Lectura pura de reservas: valida la respuesta y no toca el estado. */
  const fetchBookings = useCallback(async (userId: string): Promise<BookingDetail[]> => {
    const response = await fetch("/api/bookings", {
      cache: "no-store",
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) throw new Error("BOOKINGS_UNAVAILABLE");
    const data = (await response.json()) as {
      bookings: BookingDetail[];
    };
    if (
      !Array.isArray(data.bookings) ||
      data.bookings.some(
        (b) =>
          !b ||
          typeof b.id !== "string" ||
          typeof b.session_id !== "string" ||
          !["confirmed", "attended", "cancelled", "no_show"].includes(
            b.status,
          ) ||
          typeof b.created_at !== "string" ||
          (b.user_id !== undefined && b.user_id !== userId),
      )
    )
      throw new Error("INVALID_BOOKINGS");
    return data.bookings;
  }, []);

  const loadBookings = useCallback(async (expected?: {
    id: string; sessionId: string; status: "confirmed" | "cancelled";
  }): Promise<boolean> => {
    // Una mutación de la sesión anterior puede terminar después del cambio de usuario.
    if (user?.id !== latestUser.current?.id) return false;
    const request = ++bookingsRequest.current;
    if (isDemo) { setBookings([]); return true; }

    if (!user) {
      setBookings([]);
      setBookingsRead({ owner: null, status: "ready" });
      return true;
    }

    setBookingsRead({ owner: user.id, status: "loading" });
    try {
      const rows = await fetchBookings(user.id);
      if (request !== bookingsRequest.current) return false;
      if (expected && !rows.some(b =>
        b.id === expected.id && b.session_id === expected.sessionId &&
        b.status === expected.status)) throw new Error("BOOKING_NOT_RECONCILED");
      setBookings(toAppBookings(rows, user.id));
      setBookingsRead({ owner: user.id, status: "ready" });
      return true;
    } catch {
      if (request !== bookingsRequest.current) return false;
      // Conservamos el último valor, pero no lo presentamos como confirmado.
      setBookingsRead({ owner: user.id, status: "error" });
      return false;
    }
  }, [isDemo, user, fetchBookings]);

  /* Primera lectura de reservas: espera la respuesta antes de aplicar el
     estado, así el efecto no encadena renders. */
  useEffect(() => {
    if (isDemo || !user) return;
    let cancelled = false;
    const owner = user.id;
    const request = ++bookingsRequest.current;

    void (async () => {
      try {
        const rows = await fetchBookings(owner);
        if (cancelled || request !== bookingsRequest.current) return;
        setBookings(toAppBookings(rows, owner));
        setBookingsRead({ owner, status: "ready" });
      } catch {
        if (cancelled || request !== bookingsRequest.current) return;
        setBookingsRead({ owner, status: "error" });
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [isDemo, user, fetchBookings]);

  /* ---------- reservas ---------- */

  const book = useCallback<AppContextValue["book"]>(
    async (sessionId) => {
      if (!user) return { ok: false, error: "AUTH" };
      if (!bookingsReady) return { ok: false, error: "UNKNOWN" };

      if (isDemo) return { ok: false, error: "AUTH" };

      try {
        const response = await fetch("/api/bookings", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId }),
          signal: AbortSignal.timeout(15000),
        });
        if (user.id !== latestUser.current?.id) return { ok: false, error: "UNCONFIRMED" };
        if (response.ok) {
          const result = await response.json().catch(() => null);
          const row = result?.booking;
          if (user.id !== latestUser.current?.id) return { ok: false, error: "UNCONFIRMED" };
          if (result?.ok !== true || typeof row?.id !== "string" || !row.id ||
              row.session_id !== sessionId || row.status !== "confirmed") {
            setBookingsRead({ owner: user.id, status: "error" });
            return { ok: false, error: "UNCONFIRMED" };
          }
          const reconciled = await loadBookings({ id: row.id, sessionId, status: "confirmed" });
          return reconciled ? { ok: true } : { ok: false, error: "UNCONFIRMED" };
        }
        const data = (await response.json().catch(() => ({}))) as {
          error?: BookingErrorCode;
        };
        const error = data.error ?? "UNCONFIRMED";
        if (error === "UNCONFIRMED" || error === "UNKNOWN") {
          if (user.id === latestUser.current?.id)
            setBookingsRead({ owner: user.id, status: "error" });
          return { ok: false, error: "UNCONFIRMED" };
        }
        return { ok: false, error };
      } catch {
        if (user.id === latestUser.current?.id)
          setBookingsRead({ owner: user.id, status: "error" });
        return { ok: false, error: "UNCONFIRMED" };
      }
    },
    [isDemo, user, bookingsReady, loadBookings],
  );

  const cancelBooking = useCallback<AppContextValue["cancelBooking"]>(
    async (bookingId, sessionId) => {
      if (!user) return { ok: false, error: "AUTH" };
      if (!bookingsReady) return { ok: false, error: "UNKNOWN" };

      if (isDemo) return { ok: false, error: "AUTH" };

      try {
        const response = await fetch(
          `/api/bookings?id=${encodeURIComponent(bookingId)}`,
          {
            method: "DELETE",
            signal: AbortSignal.timeout(15000),
          },
        );
        if (user.id !== latestUser.current?.id) return { ok: false, error: "UNCONFIRMED" };
        if (response.ok) {
          const reconciled = await loadBookings({ id: bookingId, sessionId, status: "cancelled" });
          return reconciled ? { ok: true } : { ok: false, error: "UNCONFIRMED" };
        }
        const data = (await response.json().catch(() => ({}))) as {
          error?: BookingErrorCode;
        };
        const error = data.error ?? "UNCONFIRMED";
        if (error === "UNCONFIRMED" || error === "UNKNOWN") {
          if (user.id === latestUser.current?.id)
            setBookingsRead({ owner: user.id, status: "error" });
          return { ok: false, error: "UNCONFIRMED" };
        }
        return { ok: false, error };
      } catch {
        if (user.id === latestUser.current?.id)
          setBookingsRead({ owner: user.id, status: "error" });
        return { ok: false, error: "UNCONFIRMED" };
      }
    },
    [isDemo, user, bookingsReady, loadBookings],
  );

  const cancelBySessionId = useCallback<AppContextValue["cancelBySessionId"]>(
    async (sessionId) => {
      const booking = bookings.find(
        (b) =>
          b.sessionId === sessionId &&
          (b.status === "confirmed" || b.status === "attended"),
      );
      if (!booking) return { ok: false, error: "NOT_FOUND" };
      return cancelBooking(booking.id, sessionId);
    },
    [bookings, cancelBooking],
  );

  /* ---------- autenticación ---------- */

  const signIn = useCallback<AppContextValue["signIn"]>(
    async (email, password) => {
      setAuthLoading(true);
      try {
        if (isDemo) return { ok: false, error: "genericError" };

        const supabase = getSupabaseBrowserClient();
        if (!supabase) return { ok: false, error: "genericError" };

        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        });
        if (error) {
          const emailFailure = authEmailFailure(error);
          if (emailFailure !== "error") return { ok: false, error: emailFailure };
          const message = error.message.toLowerCase();
          if (message.includes("invalid") || message.includes("credentials")) {
            return { ok: false, error: "invalidCredentials" };
          }
          return { ok: false, error: "genericError" };
        }

        router.refresh();
        return { ok: true };
      } catch {
        return { ok: false, error: "genericError" };
      } finally {
        setAuthLoading(false);
      }
    },
    [isDemo, router],
  );

  const signUp = useCallback<AppContextValue["signUp"]>(
    async ({ fullName, email, password, phone, birthDate, legalAccepted }) => {
      setAuthLoading(true);
      try {
        if (isDemo) return { ok: false, error: "genericError" };
        if (!validNewPassword(password)) return { ok: false, error: "weakPassword" };
        if (!validBirthDate(birthDate)) return { ok: false, error: "birthDateInvalid" };
        if (!legalAccepted) return { ok: false, error: "legalRequired" };

        const supabase = getSupabaseBrowserClient();
        if (!supabase) return { ok: false, error: "genericError" };

        const { data, error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: {
            data: {
              full_name: fullName.trim(),
              phone: phone ?? null,
              birth_date: birthDate,
              // Evidencia de la aceptación en el alta (versión y hora).
              legal_accepted: { version: LEGAL_VERSION, accepted_at: new Date().toISOString() },
            },
            emailRedirectTo:
              typeof window !== "undefined"
                ? authCallbackUrl(window.location.origin, window.location.pathname.split("/")[1], "signup")
                : undefined,
          },
        });

        if (error) {
          const emailFailure = authEmailFailure(error);
          if (emailFailure !== "error") return { ok: false, error: emailFailure };
          const message = error.message.toLowerCase();
          if (message.includes("already") || message.includes("registered")) {
            return { ok: false, error: "emailInUse" };
          }
          if (message.includes("password"))
            return { ok: false, error: "weakPassword" };
          return { ok: false, error: "genericError" };
        }

        // Si el proyecto exige confirmar el email, no hay sesión todavía.
        if (!data.session) return { ok: true, needsConfirmation: true };

        router.refresh();
        return { ok: true };
      } catch {
        return { ok: false, error: "genericError" };
      } finally {
        setAuthLoading(false);
      }
    },
    [isDemo, router],
  );

  const signOut = useCallback(async () => {
    if (isDemo) { setBookings([]); return; }

    try {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) throw new Error("AUTH_UNAVAILABLE");
      const { error } = await supabase.auth.signOut();
      if (error) throw new Error("SIGNOUT_UNCONFIRMED");
      invalidateRequests();
      setSignedOutUser(initialUser);
      setBookings([]);
      router.refresh();
    } catch {
      toast(window.location.pathname.startsWith("/en/")
        ? "Could not confirm sign-out. Your session may still be active; please try again."
        : "No pudimos confirmar el cierre. Tu sesión puede seguir activa; intentá de nuevo.", "error");
    }
  }, [isDemo, initialUser, router, toast, invalidateRequests]);

  /* Cierre por inactividad: administración y caja, 15 minutos sin actividad.
     Entrenador y clientes no se cierran solos. Demo no aplica. */
  const inactivityLimit = isDemo ? null : inactivityLimitMs(user?.role);
  const lastActivityRef = useRef<number>(0);
  useEffect(() => {
    if (inactivityLimit === null || !user) return;
    lastActivityRef.current = Date.now();
    const mark = () => { lastActivityRef.current = Date.now(); };
    const events: (keyof WindowEventMap)[] = ["pointerdown", "keydown", "touchstart", "scroll"];
    events.forEach(ev => window.addEventListener(ev, mark, { passive: true }));
    const timer = window.setInterval(() => {
      if (isInactive(lastActivityRef.current, Date.now(), inactivityLimit)) {
        window.clearInterval(timer);
        void signOut();
      }
    }, 30_000);
    return () => {
      events.forEach(ev => window.removeEventListener(ev, mark));
      window.clearInterval(timer);
    };
  }, [inactivityLimit, user, signOut]);

  const updateProfile = useCallback<AppContextValue["updateProfile"]>(
    async (data) => {
      if (!user) return false;

      if (isDemo) return false;

      try {
        const response = await fetch("/api/account", {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(data),
        });
        if (response.ok) {
          router.refresh();
          return true;
        }
        return false;
      } catch {
        return false;
      }
    },
    [isDemo, user, router],
  );

  /* ---------- valor del contexto ---------- */

  /* Sin sesión no se muestran reservas aunque quede una lectura anterior. */
  const visibleBookings = user ? bookings : EMPTY_BOOKINGS;

  const bookedSessionIds = useMemo(
    () =>
      new Set(
        visibleBookings
          .filter((b) => b.status === "confirmed" || b.status === "attended")
          .map((b) => b.sessionId),
      ),
    [visibleBookings],
  );

  const value = useMemo<AppContextValue>(
    () => ({
      user,
      isDemo,
      authLoading,
      hydrated,
      bookings: visibleBookings,
      bookingsLoading,
      bookingsError,
      reloadBookings: async () => { await loadBookings(); },
      bookedSessionIds,
      book,
      cancelBooking,
      cancelBySessionId,
      signIn,
      signUp,
      signOut,
      updateProfile,
      toast,
      toasts,
      dismissToast,
    }),
    [
      user,
      isDemo,
      authLoading,
      hydrated,
      visibleBookings,
      bookingsLoading,
      bookingsError,
      loadBookings,
      bookedSessionIds,
      book,
      cancelBooking,
      cancelBySessionId,
      signIn,
      signUp,
      signOut,
      updateProfile,
      toast,
      toasts,
      dismissToast,
    ],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useApp(): AppContextValue {
  const context = useContext(AppContext);
  if (!context)
    throw new Error("useApp() tiene que usarse dentro de <AppProvider>");
  return context;
}
