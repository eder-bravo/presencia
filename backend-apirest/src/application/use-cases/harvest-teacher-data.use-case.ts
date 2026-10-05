import { createHash } from 'node:crypto';
import type { Coordination } from '../../domain/entities/coordination.js';
import type { TeacherAuthenticatedEvent } from '../../domain/events/teacher-authenticated.event.js';
import type { JsonRecord, UatCicloEscolarItem, UatDesItem, UatHorarioItem, UatNivelEducativoItem } from '../../domain/types/uat.interfaces.js';
import type { UatService } from '../services/uat.service.js';
import { MappedTeacherGroup, UatTeacherDataMapper } from '../mappers/uat-teacher-data.mapper.js';
import type {
  AcademicSnapshotPublisher,
  AcademicSnapshotStudent,
  ProfessorAcademicSnapshotInput,
} from '../ports/academic-snapshot.publisher.js';

export interface HarvestTeacherDataResult {
  teacherExternalId: string;
  coordinationCount: number;
  groupCount: number;
  skipped: boolean;
  skipReason?: string;
}

export interface HarvestTeacherDataOptions {
  preferredCycleId?: number | (() => Promise<number | undefined>);
}

export interface HarvestLogger {
  warn(bindings: object, message: string): void;
}

export class HarvestTeacherDataUseCase {
  constructor(
    private readonly uatService: UatService,
    private readonly academicSnapshotPublisher: AcademicSnapshotPublisher,
    private readonly options: HarvestTeacherDataOptions = {},
    private readonly mapper = new UatTeacherDataMapper(),
    private readonly logger?: HarvestLogger,
  ) {}

  async execute(event: TeacherAuthenticatedEvent): Promise<HarvestTeacherDataResult> {
    if (!event.teacher.plantillaId) {
      return {
        teacherExternalId: event.teacher.externalId,
        coordinationCount: 0,
        groupCount: 0,
        skipped: true,
        skipReason: 'La respuesta de login no incluyo Id_Plantilla_AdmonUAT.',
      };
    }

    const cyclesResponse = await this.uatService.getCiclosEscolaresPorSesion(event.sessionId);
    const preferredCycleId = typeof this.options.preferredCycleId === 'function'
      ? await this.options.preferredCycleId()
      : this.options.preferredCycleId;
    const cycles = selectHarvestCycles(cyclesResponse.data, preferredCycleId);
    const desItems = await this.discoverCoordinations(event.sessionId);
    let groupCount = 0;
    const academicGroups: Array<{
      mapped: MappedTeacherGroup;
      rosterAuthoritative: boolean;
      students: AcademicSnapshotStudent[];
    }> = [];

    for (const context of desItems) {
      const { des } = context;

      for (const cycle of cycles) {
        const cycleExternalId = String(cycle.Id_Ciclo_Escolar);
        const cycleName = cycle.Ciclo ?? cycle.Txt_Ciclo_Escolar ?? cycle.Txt_Nombre_Corto ?? null;
        const response = await this.uatService.getGruposProfesorPorSesion(event.sessionId, {
          Id_Des: des.Id_DES,
          Id_Ciclo: cycle.Id_Ciclo_Escolar,
          Id_Plantilla: event.teacher.plantillaId,
        });
        if (response.data.length === 0) continue;

        const schedules = await this.uatService.getHorariosPorSesion(event.sessionId, {
          Id_Ciclo_Escolar: cycle.Id_Ciclo_Escolar,
          Id_DES: des.Id_DES,
        });
        const scheduleByGroup = new Map<string, UatHorarioItem[]>();
        for (const item of schedules.data) {
          const groupId = String(item.Id_Grupo);
          const rows = scheduleByGroup.get(groupId) ?? [];
          rows.push(item);
          scheduleByGroup.set(groupId, rows);
        }
        for (const raw of response.data) {
          const mapped = this.mapper.mapGroup({
            raw,
            teacher: event.teacher,
            des,
            cycleExternalId,
            cycleName,
            educationLevel: context.level.Txt_Nivel_Educativo || context.level.Txt_Nombre_Corto || null,
            schedule: scheduleByGroup.get(String(raw.Id_Grupo)),
          });

          const roster = await this.loadGroupRoster(event.sessionId, mapped.group.externalGroupId);
          academicGroups.push({ mapped, ...roster });
          groupCount += 1;
        }
      }
    }

    for (const cycle of cycles) {
      const cycleExternalId = String(cycle.Id_Ciclo_Escolar);
      const cycleName = cycle.Ciclo ?? cycle.Txt_Ciclo_Escolar ?? cycle.Txt_Nombre_Corto ?? cycleExternalId;
      const groups = academicGroups.filter(({ mapped }) => mapped.group.schoolCycleExternalId === cycleExternalId);
      await this.academicSnapshotPublisher.publishProfessorSnapshot(
        toAcademicSnapshot(event, cycleExternalId, cycleName, groups),
      );
    }

    return {
      teacherExternalId: event.teacher.externalId,
      coordinationCount: desItems.length,
      groupCount,
      skipped: false,
    };
  }

  private async loadGroupRoster(
    sessionId: string,
    externalGroupId: string,
  ): Promise<{ rosterAuthoritative: boolean; students: AcademicSnapshotStudent[] }> {
    const groupId = Number(externalGroupId);
    if (!Number.isSafeInteger(groupId) || groupId <= 0) {
      this.logger?.warn({ externalGroupId }, 'No se consulto el roster: Id_Grupo UAT invalido.');
      return { rosterAuthoritative: false, students: [] };
    }

    try {
      const weeks = (await this.uatService.getSemanasGrupoPorSesion(sessionId, { Id_Grupo: groupId })).data;
      const week = weeks.find((item) => {
        const start = readString(item, ['Fec_Ini', 'fec_ini']);
        const end = readString(item, ['Fec_Fin', 'fec_fin']);
        return Boolean(start && end);
      });
      const start = week ? readString(week, ['Fec_Ini', 'fec_ini']) : null;
      const end = week ? readString(week, ['Fec_Fin', 'fec_fin']) : null;
      if (!start || !end) {
        this.logger?.warn({ externalGroupId }, 'La UAT no devolvio una semana valida; se conserva el roster previo.');
        return { rosterAuthoritative: false, students: [] };
      }

      const response = (await this.uatService.getAsistenciaGrupoPorSesion(sessionId, {
        Id_Grupo: groupId,
        fec_ini: start,
        fec_fin: end,
      })).data;
      if (response.exito === false) {
        this.logger?.warn({ externalGroupId, message: response.mensaje ?? null }, 'La UAT rechazo la consulta del roster.');
        return { rosterAuthoritative: false, students: [] };
      }
      const rawStudents = response.alumnos ?? response.Alumnos ?? response.data;
      if (!Array.isArray(rawStudents)) {
        this.logger?.warn({ externalGroupId }, 'La respuesta UAT no incluyo una lista de alumnos; se conserva el roster previo.');
        return { rosterAuthoritative: false, students: [] };
      }

      const students = new Map<string, AcademicSnapshotStudent>();
      for (const item of rawStudents) {
        const matricula = readString(item, ['Num_Matricula', 'num_matricula', 'Matricula', 'Id_Alumno', 'id_alumno']);
        if (!matricula) continue;
        students.set(matricula.toUpperCase(), {
          matricula: matricula.toUpperCase(),
          name: readString(item, ['Txt_Alumno', 'txt_alumno', 'Nombre', 'Alumno']) ?? matricula,
          uatStudentId: readNumber(item, ['Id_Alumno', 'id_alumno']),
          listNumber: readNumber(item, ['Num_Lista', 'num_lista']),
        });
      }
      return { rosterAuthoritative: true, students: [...students.values()] };
    } catch (error) {
      this.logger?.warn({
        externalGroupId,
        error: error instanceof Error ? error.message : 'Unknown error',
      }, 'No se pudo consultar el roster UAT; se conserva el roster previo.');
      return { rosterAuthoritative: false, students: [] };
    }
  }

  private async discoverCoordinations(
    sessionId: string,
  ): Promise<Array<{ des: UatDesItem; level: UatNivelEducativoItem }>> {
    const levels = (await this.uatService.getNivelesEducativosPorSesion(sessionId)).data;
    const coordinations = new Map<number, { des: UatDesItem; level: UatNivelEducativoItem }>();

    for (const level of levels) {
      const campuses = (await this.uatService.getCampusPorSesion(sessionId, level.Id_Nivel_Educativo)).data;

      for (const campus of campuses) {
        const items = (await this.uatService.getDesPorSesion(sessionId, level.Id_Nivel_Educativo, campus.Id_CU)).data;
        for (const item of items) {
          const normalized = normalizeDesItem(item);
          if (normalized) coordinations.set(normalized.Id_DES, { des: normalized, level });
        }
      }
    }

    return [...coordinations.values()];
  }
}

function toAcademicSnapshot(
  event: TeacherAuthenticatedEvent,
  cycleExternalId: string,
  cycleName: string,
  groups: Array<{
    mapped: MappedTeacherGroup;
    rosterAuthoritative: boolean;
    students: AcademicSnapshotStudent[];
  }>,
): ProfessorAcademicSnapshotInput {
  return {
    snapshotId: stableSnapshotId(event.eventId, cycleExternalId),
    correlationId: event.correlationId,
    causationId: event.eventId,
    teacher: {
      externalId: event.teacher.externalId,
      institutionalCode: event.teacher.institutionalCode,
      name: event.teacher.name,
      email: event.teacher.email,
      authenticatedAt: event.occurredAt.toISOString(),
    },
    cycle: { externalId: cycleExternalId, name: cycleName },
    groups: groups.map(({ mapped, rosterAuthoritative, students }) => ({
      externalGroupId: mapped.group.externalGroupId,
      code: mapped.group.externalGroupId,
      groupLetter: mapped.group.groupCode ?? '',
      name: mapped.subject.name,
      level: mapped.group.educationLevel,
      classroom: mapped.group.classroom,
      period: mapped.group.period,
      schedule: Object.fromEntries(Object.entries(mapped.group.schedule)),
      subject: {
        externalId: mapped.subject.externalId,
        code: mapped.subject.code,
        name: mapped.subject.name,
      },
      coordination: {
        externalId: mapped.coordination.externalId,
        name: mapped.coordination.name,
        shortName: mapped.coordination.shortName,
      },
      rosterAuthoritative,
      students,
    })),
  };
}

function stableSnapshotId(eventId: string, cycleExternalId: string): string {
  const bytes = createHash('sha256').update(`${eventId}:${cycleExternalId}`).digest().subarray(0, 16);
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x50;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const value = bytes.toString('hex');
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

function toCoordination(item: UatDesItem): Coordination {
  const name =
    readString(item, ['Txt_DES', 'txt_des', 'DES', 'Txt_Nombre', 'Nombre', 'Txt_Nombre_Corto']) ??
    `Coordinacion ${item.Id_DES}`;

  return {
    externalId: String(item.Id_DES),
    name,
    shortName: readString(item, ['Txt_Nombre_Corto', 'txt_nombre_corto', 'Nombre_Corto', 'shortName']),
  };
}

function normalizeDesItem(item: UatDesItem): UatDesItem | null {
  const id = readNumber(item, ['Id_DES', 'Id_Des', 'id_des', 'idDes']);
  if (id == null) return null;
  return { ...item, Id_DES: id };
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

function readNumber(record: JsonRecord, keys: string[]): number | null {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string') {
      const parsed = Number(value.trim());
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return null;
}

function selectHarvestCycles(
  cycles: UatCicloEscolarItem[],
  preferredCycleId?: number,
): UatCicloEscolarItem[] {
  if (preferredCycleId) {
    const preferred = cycles.find((cycle) => cycle.Id_Ciclo_Escolar === preferredCycleId);
    return [preferred ?? {
      Id_Ciclo_Escolar: preferredCycleId,
      Ciclo: String(preferredCycleId),
      Txt_Ciclo_Escolar: String(preferredCycleId),
    }];
  }

  const active = cycles.filter((cycle) => isTruthyFlag(cycle.Sn_Activo));
  return active.length > 0 ? active : cycles;
}

function isTruthyFlag(value: boolean | string | number | undefined): boolean {
  if (value === true || value === 1) return true;
  if (typeof value !== 'string') return false;
  return ['1', 'true', 'si', 'sí', 'activo'].includes(value.trim().toLowerCase());
}
