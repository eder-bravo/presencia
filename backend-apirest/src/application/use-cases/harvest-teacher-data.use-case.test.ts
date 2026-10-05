import { describe, expect, it } from 'vitest';
import { TEACHER_AUTHENTICATED_EVENT, type TeacherAuthenticatedEvent } from '../../domain/events/teacher-authenticated.event.js';
import type { UatService } from '../services/uat.service.js';
import type { AcademicSnapshotPublisher, ProfessorAcademicSnapshotInput } from '../ports/academic-snapshot.publisher.js';
import { HarvestTeacherDataUseCase } from './harvest-teacher-data.use-case.js';

describe('HarvestTeacherDataUseCase', () => {
  it('publica en Academic grupos aunque la DES no incluya Txt_DES', async () => {
    const capture = captureSnapshots();
    const result = await new HarvestTeacherDataUseCase(
      makeUatService(),
      capture.publisher,
    ).execute(makeEvent());

    expect(result).toMatchObject({ coordinationCount: 1, groupCount: 1, skipped: false });
    expect(capture.snapshots).toHaveLength(1);
    expect(capture.snapshots[0]?.groups[0]).toMatchObject({
      externalGroupId: '947699',
      groupLetter: 'A',
      classroom: 'A1',
      level: 'Licenciatura',
      coordination: { externalId: '12', name: 'FI', shortName: 'FI' },
      subject: { name: 'Calculo I' },
      schedule: {
        monday: [{ raw: '7:00 - 8:00', startTime: '07:00', endTime: '08:00' }],
      },
    });
  });

  it('continua con otras coordinaciones cuando una DES no tiene grupos asignados', async () => {
    const capture = captureSnapshots();
    const schedulesRequested: number[] = [];
    const uatService = makeUatService({
      getDesPorSesion: async () => uatList([
        { Id_DES: 99, Txt_Nombre_Corto: 'SIN' },
        { Id_DES: 12, Txt_Nombre_Corto: 'FI' },
      ]),
      getGruposProfesorPorSesion: async (_sessionId: string, params: { Id_Des: number }) => uatList(
        params.Id_Des === 99 ? [] : [{ Id_Grupo: 947699, Txt_Materia: 'Calculo I', Txt_Letra: 'A' }],
      ),
      getHorariosPorSesion: async (_sessionId: string, params: { Id_DES: number }) => {
        schedulesRequested.push(params.Id_DES);
        return uatList([{ Id_Grupo: 947699, Txt_Espacio_Fisico: 'A1', Txt_Lunes: '7:00 - 8:00', Num_Periodo: 1 }]);
      },
    });

    const result = await new HarvestTeacherDataUseCase(uatService, capture.publisher).execute(makeEvent());

    expect(result).toMatchObject({ coordinationCount: 2, groupCount: 1, skipped: false });
    expect(capture.snapshots[0]?.groups).toEqual([
      expect.objectContaining({ externalGroupId: '947699', coordination: expect.objectContaining({ externalId: '12' }) }),
    ]);
    expect(schedulesRequested).toEqual([12]);
  });

  it('publica todas las horas cuando BuscaHorarios devuelve varias filas para el mismo grupo', async () => {
    const capture = captureSnapshots();
    const uatService = makeUatService({
      getHorariosPorSesion: async () => uatList([
        { Id_Grupo: 947699, Txt_Espacio_Fisico: 'A1', Txt_Viernes: '12:00-13:00' },
        { Id_Grupo: 947699, Txt_Espacio_Fisico: 'A1', Txt_Viernes: '13:00-14:00' },
        { Id_Grupo: 947699, Txt_Espacio_Fisico: 'A1', Txt_Viernes: '14:00-15:00' },
        { Id_Grupo: 947699, Txt_Espacio_Fisico: 'A1', Txt_Viernes: '15:00-16:00' },
      ]),
    });
    await new HarvestTeacherDataUseCase(uatService, capture.publisher).execute(makeEvent());
    expect(capture.snapshots[0]?.groups[0]?.schedule.friday).toHaveLength(4);
  });

  it('prefiere el ciclo configurado sobre el ciclo activo del catalogo UAT', async () => {
    const capture = captureSnapshots();
    const cyclesRequested: number[] = [];
    const uatService = makeUatService({
      getCiclosEscolaresPorSesion: async () => uatList([
        { Id_Ciclo_Escolar: 151, Ciclo: '2026-2', Sn_Activo: true },
        { Id_Ciclo_Escolar: 150, Ciclo: '2026-1', Sn_Activo: false },
      ]),
      getGruposProfesorPorSesion: async (_sessionId: string, params: { Id_Ciclo: number }) => {
        cyclesRequested.push(params.Id_Ciclo);
        return uatList([{ Id_Grupo: 947699, Txt_Materia: 'Calculo I', Txt_Letra: 'A' }]);
      },
      getHorariosPorSesion: async (_sessionId: string, params: { Id_Ciclo_Escolar: number }) => uatList([
        { Id_Grupo: 947699, Id_Ciclo_Escolar: params.Id_Ciclo_Escolar, Txt_Materia: 'Calculo I' },
      ]),
    });

    const result = await new HarvestTeacherDataUseCase(
      uatService,
      capture.publisher,
      { preferredCycleId: async () => 150 },
    ).execute(makeEvent());

    expect(result.groupCount).toBe(1);
    expect(cyclesRequested).toEqual([150]);
    expect(capture.snapshots[0]?.cycle).toEqual({ externalId: '150', name: '2026-1' });
  });

  it('publica un snapshot diferencial con roster UAT y sin datos de sesion', async () => {
    const capture = captureSnapshots();
    const uatService = makeUatService({
      getDesPorSesion: async () => uatList([{ Id_DES: 12, Txt_DES: 'Ingenieria', Txt_Nombre_Corto: 'FI' }]),
      getHorariosPorSesion: async () => uatList([{ Id_Grupo: 947699, Txt_Lunes: '07:00 - 08:00' }]),
      getSemanasGrupoPorSesion: async () => uatList([{ Id_Grupo: 947699, Fec_Ini: '2026-08-03', Fec_Fin: '2026-08-09' }]),
      getAsistenciaGrupoPorSesion: async () => ({
        source: 'UAT', endpoint: 'BuscaAsistenciaGrupo', query: {}, fetchedAt: new Date().toISOString(),
        data: { exito: true, alumnos: [{ Id_Alumno: 1, Num_Matricula: '9900000001', Txt_Alumno: 'Ana Alumna' }] },
      }),
    });

    await new HarvestTeacherDataUseCase(uatService, capture.publisher).execute(makeEvent());

    expect(capture.snapshots).toHaveLength(1);
    expect(capture.snapshots[0]).toMatchObject({
      correlationId: 'request-1', causationId: 'event-1',
      cycle: { externalId: '150', name: '2026-1' },
      groups: [{
        externalGroupId: '947699', rosterAuthoritative: true,
        students: [{ matricula: '9900000001', name: 'Ana Alumna', uatStudentId: 1 }],
      }],
    });
    expect(capture.snapshots[0]?.snapshotId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(JSON.stringify(capture.snapshots[0])).not.toMatch(/sessionId|password|cookie/i);
  });

  it('omite la cosecha sin plantilla UAT y no publica un snapshot incompleto', async () => {
    const capture = captureSnapshots();
    const event = makeEvent();
    event.teacher.plantillaId = null;

    const result = await new HarvestTeacherDataUseCase(makeUatService(), capture.publisher).execute(event);

    expect(result).toMatchObject({ skipped: true, groupCount: 0, coordinationCount: 0 });
    expect(capture.snapshots).toEqual([]);
  });
});

function makeUatService(overrides: Record<string, unknown> = {}): UatService {
  return {
    getCiclosEscolaresPorSesion: async () => uatList([{ Id_Ciclo_Escolar: 150, Ciclo: '2026-1', Sn_Activo: true }]),
    getNivelesEducativosPorSesion: async () => uatList([{ Id_Nivel_Educativo: 1, Txt_Nivel_Educativo: 'Licenciatura' }]),
    getCampusPorSesion: async () => uatList([{ Id_CU: 1, Txt_CU: 'Tampico' }]),
    getDesPorSesion: async () => uatList([{ Id_DES: 12, Txt_Nombre_Corto: 'FI' }]),
    getGruposProfesorPorSesion: async () => uatList([{ Id_Grupo: 947699, Txt_Materia: 'Calculo I', Txt_Letra: 'A' }]),
    getHorariosPorSesion: async () => uatList([{ Id_Grupo: 947699, Txt_Espacio_Fisico: 'A1', Txt_Lunes: '7:00 - 8:00', Num_Periodo: 1 }]),
    getSemanasGrupoPorSesion: async () => uatList([]),
    getAsistenciaGrupoPorSesion: async () => ({
      source: 'UAT', endpoint: 'BuscaAsistenciaGrupo', query: {}, fetchedAt: new Date().toISOString(),
      data: { exito: true, alumnos: [] },
    }),
    ...overrides,
  } as unknown as UatService;
}

function captureSnapshots() {
  const snapshots: ProfessorAcademicSnapshotInput[] = [];
  const publisher: AcademicSnapshotPublisher = {
    publishProfessorSnapshot: async (snapshot) => { snapshots.push(snapshot); },
  };
  return { snapshots, publisher };
}

function uatList<T>(data: T[]) {
  return { source: 'UAT' as const, endpoint: 'test', query: {}, data, fetchedAt: new Date().toISOString() };
}

function makeEvent(): TeacherAuthenticatedEvent {
  return {
    eventId: 'event-1',
    eventType: TEACHER_AUTHENTICATED_EVENT,
    occurredAt: new Date('2026-07-04T00:00:00.000Z'),
    producer: 'uat-integration',
    correlationId: 'request-1',
    causationId: 'request-1',
    aggregateId: '308127',
    schemaVersion: 1,
    sessionId: 'uat-session-1',
    teacher: {
      externalId: '308127',
      plantillaId: 308127,
      institutionalCode: '308127',
      name: 'Eder Jahir Gonzalez Bravo',
      email: 'profesor.prueba@uat.edu.mx',
    },
  };
}
