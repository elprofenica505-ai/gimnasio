import { dayOfWeek, fromGymTime, gymParts } from "@/lib/schedule";
import type { Coach, GymClass, SessionDetail, WeekRange } from "@/lib/types";
import { demoClasses, demoCoaches } from "./demo-content";

/**
 * ============================================================
 *  Grilla semanal de clases — VACÍA (gimnasio nuevo)
 * ============================================================
 *  FUENTE DE VERDAD de los horarios. De acá sale el SQL:
 *  después de tocar WEEKLY_TEMPLATE hay que correr
 *      node scripts/build-sql.mjs
 *  y se regeneran 00001_schema.sql, 00003_datos_reales.sql y
 *  supabase/SETUP.sql / ACTUALIZAR.sql.
 *
 *  Está VACÍA a propósito: este repositorio es la instalación de
 *  un gimnasio nuevo y no hereda la grilla de nadie. Cuando el
 *  dueño pase los horarios reales (o se carguen desde el panel),
 *  se completan acá las clases con cupo y reserva, día por día
 *  (0 = lunes … 6 = domingo), y se vuelve a correr el generador.
 *
 *  Con la grilla vacía:
 *    · generate_week_sessions() en SQL no crea ninguna clase.
 *    · El modo demo de la web muestra la agenda vacía.
 * ============================================================
 */

interface Slot {
  /** Hora local del gimnasio, formato "HH:MM". */
  time: string;
  /** Slug de la disciplina (ver demo-content.ts). */
  slug: string;
}

const WEEKLY_TEMPLATE: Record<number, Slot[]> = {
  // Lunes
  0: [],
  // Martes
  1: [],
  // Miércoles
  2: [],
  // Jueves
  3: [],
  // Viernes
  4: [],
  // Sábado
  5: [],
  // Domingo
  6: [],
};

/** Sala por disciplina. Vacío: la función SQL usa «Salón principal». */
const ROOMS: Record<string, string> = {
  // Sin salas por disciplina a propósito: la web y el SQL usan «Salón
  // principal» para todo (la rama else del case en generate_week_sessions).
};

const classesBySlug = new Map<string, GymClass>(demoClasses.map((c) => [c.slug, c]));

function coachesFor(slug: string): Coach[] {
  return demoCoaches.filter((coach) => coach.specialties.includes(slug));
}

/** Hash determinista (FNV-1a) para que el servidor y el cliente coincidan. */
function hash(value: string): number {
  let h = 2166136261;
  for (let i = 0; i < value.length; i++) {
    h ^= value.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/**
 * Ocupación simulada de una clase. Es determinista (misma clase, mismo
 * número siempre) y más alta en los horarios pico.
 */
function simulatedBookedCount(sessionId: string, capacity: number, hour: number): number {
  const h = hash(sessionId);
  const roll = (h % 1000) / 1000;

  // Una de cada doce clases aparece completa, para probar ese estado.
  if (h % 12 === 0) return capacity;

  const peak = hour >= 17 && hour <= 21 ? 1 : hour <= 8 ? 0.82 : 0.55;
  const ratio = Math.min(0.97, Math.max(0.18, roll * peak + (peak - 0.55) * 0.3));
  return Math.min(capacity, Math.round(capacity * ratio));
}

/** Todas las clases de una semana, con su profe y su ocupación. */
export function generateWeekSessions(
  week: WeekRange,
  options?: { includeInactiveClasses?: boolean },
): SessionDetail[] {
  const includeInactiveClasses = options?.includeInactiveClasses === true;
  const sessions: SessionDetail[] = [];
  let counter = 0;

  for (let dayIndex = 0; dayIndex < 7; dayIndex++) {
    const date = dayOfWeek(week, dayIndex);
    const parts = gymParts(date);
    const slots = WEEKLY_TEMPLATE[dayIndex] ?? [];

    for (const slot of slots) {
      const gymClass = classesBySlug.get(slot.slug);
      if (!gymClass || (!includeInactiveClasses && !gymClass.is_active)) {
        continue;
      }

      const [hour, minute] = slot.time.split(":").map(Number);
      const startsAt = fromGymTime(parts.year, parts.month, parts.day, hour, minute);
      const endsAt = new Date(startsAt.getTime() + gymClass.duration_min * 60_000);

      const candidates = coachesFor(slot.slug);
      const coach = candidates.length > 0 ? candidates[counter % candidates.length] : null;

      const id = `ses_${week.key}_${dayIndex}_${counter}`;
      const bookedCount = simulatedBookedCount(id, gymClass.capacity, hour);

      sessions.push({
        id,
        class_id: gymClass.id,
        coach_id: coach?.id ?? null,
        starts_at: startsAt.toISOString(),
        ends_at: endsAt.toISOString(),
        capacity: gymClass.capacity,
        room: ROOMS[slot.slug] ?? "Salón principal",
        status: "scheduled",
        gymClass,
        coach,
        bookedCount,
        spotsLeft: Math.max(0, gymClass.capacity - bookedCount),
      });

      counter++;
    }
  }

  return sessions.sort(
    (a, b) => new Date(a.starts_at).getTime() - new Date(b.starts_at).getTime(),
  );
}

/** Ocupación media del gimnasio (para el panel de administración). */
export function averageOccupancy(sessions: SessionDetail[]): number {
  if (sessions.length === 0) return 0;
  const total = sessions.reduce((acc, s) => acc + s.bookedCount / Math.max(1, s.capacity), 0);
  return Math.round((total / sessions.length) * 100);
}
