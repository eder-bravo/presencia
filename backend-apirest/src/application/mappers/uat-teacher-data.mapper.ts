import type { Coordination } from '../../domain/entities/coordination.js';
import type { Group, ScheduleDay, ScheduleSlot, WeeklySchedule } from '../../domain/entities/group.js';
import type { Subject } from '../../domain/entities/subject.js';
import type { AuthenticatedTeacherIdentity } from '../../domain/events/teacher-authenticated.event.js';
import type { JsonRecord, JsonValue, UatDesItem, UatHorarioItem, UatProfesorGrupoItem } from '../../domain/types/uat.interfaces.js';

export interface MappedTeacherGroup {
  coordination: Coordination;
  subject: Subject;
  group: Group;
}

export class UatTeacherDataMapper {
  mapGroup(input: {
    raw: UatProfesorGrupoItem;
    teacher: AuthenticatedTeacherIdentity;
    des: UatDesItem;
    cycleExternalId: string;
    cycleName: string | null;
    educationLevel: string | null;
    schedule?: UatHorarioItem | UatHorarioItem[];
  }): MappedTeacherGroup {
    const firstSchedule = Array.isArray(input.schedule) ? input.schedule[0] : input.schedule;
    const coordinationExternalId = String(input.des.Id_DES);
    const coordinationName =
      readString(input.des, ['Txt_DES', 'txt_des', 'DES', 'Txt_Nombre', 'Nombre', 'Txt_Nombre_Corto']) ??
      `Coordinacion ${coordinationExternalId}`;
    const subjectName = readString(input.raw, ['Txt_Materia', 'Materia', 'txt_materia']) ?? 'Materia sin nombre';
    const sourceSubjectId = readString(input.raw, [
      'Id_Materia',
      'id_materia',
      'Cve_Materia',
      'Clave_Materia',
      'Txt_Clave_Materia',
    ]);
    const subjectExternalId = `${coordinationExternalId}:${sourceSubjectId ?? `nombre:${slug(subjectName)}`}`;
    const externalGroupId = readString(input.raw, ['Id_Grupo', 'id_grupo', 'idGrupo']);

    if (!externalGroupId) {
      throw new Error('El grupo UAT no contiene un Id_Grupo estable.');
    }

    return {
      coordination: {
        externalId: coordinationExternalId,
        name: coordinationName,
        shortName: readString(input.des, ['Txt_Nombre_Corto', 'txt_nombre_corto', 'Nombre_Corto', 'shortName']),
      },
      subject: {
        externalId: subjectExternalId,
        code: sourceSubjectId,
        name: subjectName,
        coordinationExternalId,
      },
      group: {
        externalGroupId,
        groupCode: readString(input.raw, ['Txt_Letra', 'Grupo', 'txt_letra']),
        schoolCycleExternalId: input.cycleExternalId,
        schoolCycleName: readString(input.raw, ['Ciclo', 'Txt_Ciclo_Escolar']) ?? input.cycleName,
        classroom: cleanNullable(firstSchedule?.Txt_Espacio_Fisico),
        educationLevel: input.educationLevel,
        period: firstSchedule?.Num_Periodo == null ? null : String(firstSchedule.Num_Periodo),
        schedule: mapWeeklySchedule(input.schedule),
        teacherExternalId: input.teacher.externalId,
        subjectExternalId,
        coordinationExternalId,
        rawPayload: sanitizeRecord(input.raw),
      },
    };
  }
}

const UAT_DAY_FIELDS: Array<[ScheduleDay, keyof UatHorarioItem]> = [
  ['monday', 'Txt_Lunes'],
  ['tuesday', 'Txt_Martes'],
  ['wednesday', 'Txt_Miercoles'],
  ['thursday', 'Txt_Jueves'],
  ['friday', 'Txt_Viernes'],
  ['saturday', 'Txt_Sabado'],
  ['sunday', 'Txt_Domingo'],
];

export function mapWeeklySchedule(item?: UatHorarioItem | UatHorarioItem[]): WeeklySchedule {
  const result = Object.fromEntries(UAT_DAY_FIELDS.map(([day]) => [day, []])) as unknown as WeeklySchedule;
  if (!item) return result;
  const items = Array.isArray(item) ? item : [item];

  for (const [day, field] of UAT_DAY_FIELDS) {
    const slots = new Map<string, ScheduleSlot>();
    for (const row of items) {
      const rawValue = row[field];
      if (typeof rawValue !== 'string' || !rawValue.trim()) continue;
      for (const slot of parseScheduleSlots(rawValue)) {
        const key = slot.startTime && slot.endTime ? `${slot.startTime}-${slot.endTime}` : slot.raw;
        if (!slots.has(key)) slots.set(key, slot);
      }
    }
    result[day] = [...slots.values()].sort((left, right) => (left.startTime ?? '~').localeCompare(right.startTime ?? '~'));
  }
  return result;
}

export function parseScheduleSlots(value: string): ScheduleSlot[] {
  return value.split(/[;\n]+/).map((part) => part.trim()).filter((part) => part && !isEmptyScheduleMarker(part)).map((raw) => {
    const match = raw.match(/\b(\d{1,2}:\d{2})\s*(?:-|a)\s*(\d{1,2}:\d{2})\b/i);
    return { raw, startTime: match?.[1] ? padTime(match[1]) : null, endTime: match?.[2] ? padTime(match[2]) : null };
  });
}

function isEmptyScheduleMarker(value: string): boolean {
  return /^(?:-+|n\/?[ad]|no aplica|sin horario)$/i.test(value.trim());
}

function padTime(value: string): string {
  const [hours, minutes] = value.split(':');
  return `${hours?.padStart(2, '0')}:${minutes}`;
}

function readString(record: JsonRecord, keys: string[]): string | null {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === 'string' || typeof value === 'number') {
      const normalized = String(value).trim();
      if (normalized) return normalized;
    }
  }
  return null;
}

function cleanNullable(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}

function slug(value: string): string {
  return value.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

function sanitizeRecord(record: JsonRecord): JsonRecord {
  return Object.fromEntries(
    Object.entries(record).filter((entry): entry is [string, JsonValue] => entry[1] !== undefined),
  );
}
