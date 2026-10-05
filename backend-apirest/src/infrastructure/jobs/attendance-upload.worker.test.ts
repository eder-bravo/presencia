import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AttendanceUploadJobClaim, AttendanceUploadRecordInput, CreateAttendanceUploadBatchInput } from '../../domain/attendance-upload/attendance-upload.types.js';
import { AttendanceUploadService } from '../../application/services/attendance-upload.service.js';
import { AttendanceUploadWorker } from './attendance-upload.worker.js';

const workers: AttendanceUploadWorker[] = [];
afterEach(async () => {
  for (const worker of workers.splice(0)) await worker.stop();
});

describe('AttendanceUploadWorker daily passes', () => {
  it.each([1, 2, 4, 9])('publica todos los %i pases desde una captura de la app encolada con pase 1', async (count) => {
    const fixture = makeWorker(count);
    // Exercise normalization, the durable job boundary and the actual worker.
    await new AttendanceUploadService(fixture.repository).submit({
      ownerUsername: fixture.job.ownerUsername, credentialCipher: 'cipher',
      records: [fixture.job as AttendanceUploadRecordInput],
    });
    const stored = fixture.repository.createBatch.mock.calls[0]![0].records[0]!;
    Object.assign(fixture.job, stored);

    await fixture.worker.start();
    await vi.waitFor(() => expect(fixture.repository.completeJob).toHaveBeenCalledWith(fixture.job));

    expect(fixture.client.getAsistenciaGrupo).toHaveBeenCalledWith({
      Id_Grupo: 947699, fec_ini: '28/09/2026', fec_fin: '04/10/2026',
    });
    const payload = fixture.client.guardaAsistencias.mock.calls[0]![0];
    expect(payload).toMatchObject({ Id_Grupo: 947699, Fec_Ini: '28/09/2026' });
    const attendance = JSON.parse(payload.Asistencia);
    expect(attendance).toHaveLength(2 * count);
    expect(attendance.filter((row: { id_alumno: number }) => row.id_alumno === 101).map((row: { num_pase_lista: number }) => row.num_pase_lista))
      .toEqual(Array.from({ length: count }, (_, index) => index + 1));
    expect(attendance.filter((row: { id_alumno: number }) => row.id_alumno === 102).every((row: { sn_asistencia: boolean }) => row.sn_asistencia === false)).toBe(true);
    expect(fixture.repository.retryJob).not.toHaveBeenCalled();
  });

  it('reintenta sin publicar ni completar cuando falla la consulta de los pases', async () => {
    const fixture = makeWorker(4);
    fixture.client.getAsistenciaGrupo.mockRejectedValue(new Error('Portal temporalmente indisponible'));
    await fixture.worker.start();
    await vi.waitFor(() => expect(fixture.repository.retryJob).toHaveBeenCalled());

    expect(fixture.client.guardaAsistencias).not.toHaveBeenCalled();
    expect(fixture.repository.completeJob).not.toHaveBeenCalled();
    expect(fixture.repository.refreshBatch).toHaveBeenCalledWith('batch-1');
  });

  it('normaliza la fecha de un job histórico al consultar y publicar la misma semana', async () => {
    const fixture = makeWorker(4);
    fixture.job.fechaInicio = '2026-09-28';
    await fixture.worker.start();
    await vi.waitFor(() => expect(fixture.repository.completeJob).toHaveBeenCalled());

    expect(fixture.client.getAsistenciaGrupo).toHaveBeenCalledWith({
      Id_Grupo: 947699, fec_ini: '28/09/2026', fec_fin: '04/10/2026',
    });
    expect(fixture.client.guardaAsistencias.mock.calls[0]![0].Fec_Ini).toBe('28/09/2026');
  });

  it('no reporta éxito parcial cuando falta un alumno en el padrón UAT', async () => {
    const fixture = makeWorker(4);
    fixture.client.getAsistenciaGrupo.mockResolvedValue({ exito: true, alumnos: [
      { Id_Alumno: 101, Txt_Alumno: 'Alumno A', Num_Pl_Viernes: 4, Txt_Pl_Viernes: '1,1' },
    ] });
    await fixture.worker.start();
    await vi.waitFor(() => expect(fixture.repository.retryJob).toHaveBeenCalled());

    expect(fixture.client.guardaAsistencias).not.toHaveBeenCalled();
    expect(fixture.repository.completeJob).not.toHaveBeenCalled();
  });

  it('marca el job como fallido al agotar reintentos si UAT rechaza los pases', async () => {
    const fixture = makeWorker(4);
    fixture.job.attempts = 5;
    fixture.client.guardaAsistencias.mockResolvedValue({ exito: false, mensaje: 'Lista rechazada' });
    await fixture.worker.start();
    await vi.waitFor(() => expect(fixture.repository.failJob).toHaveBeenCalledWith(fixture.job, 'Lista rechazada'));

    expect(fixture.repository.completeJob).not.toHaveBeenCalled();
    expect(fixture.repository.retryJob).not.toHaveBeenCalled();
  });
});

function makeWorker(count: number) {
  const job: AttendanceUploadJobClaim = {
    id: 'job-1', batchId: 'batch-1', ownerUsername: 'profesor@uat.edu.mx', clientRecordId: 'local-1',
    attendanceSessionId: 'attendance-1', attendanceVersion: 1, idGrupo: 947699,
    fechaInicio: '28/09/2026', attempts: 1, credentialCipher: 'cipher',
    attendances: [
      { id_alumno: 101, num_pase_lista: 1, num_dia: 5, sn_asistencia: true },
      { id_alumno: 102, num_pase_lista: 1, num_dia: 5, sn_asistencia: false },
    ],
  };
  const repository = {
    createBatch: vi.fn(async (input: CreateAttendanceUploadBatchInput) => ({
      id: 'batch-1', status: 'PENDING' as const, totalRecords: input.records.length, completedRecords: 0,
      failedRecords: 0, createdAt: new Date(), completedAt: null, jobs: [],
    })),
    findLatestJobStatuses: vi.fn(async () => []),
    recoverStaleJobs: vi.fn(async () => 0),
    claimNextJob: vi.fn<() => Promise<AttendanceUploadJobClaim | null>>().mockResolvedValueOnce(job).mockResolvedValue(null),
    completeJob: vi.fn(async () => undefined), retryJob: vi.fn(async () => undefined),
    failJob: vi.fn(async () => undefined), refreshBatch: vi.fn(async () => undefined),
  };
  const client = {
    authenticate: vi.fn(async () => ({ exito: true })),
    getAsistenciaGrupo: vi.fn(async () => ({ exito: true, alumnos: [
      { Id_Alumno: 101, Txt_Alumno: 'Alumno A', Num_Pl_Viernes: count, Txt_Pl_Viernes: '1,1' },
      { Id_Alumno: 102, Txt_Alumno: 'Alumno B', Num_Pl_Viernes: count, Txt_Pl_Viernes: '1,0' },
    ] })),
    guardaAsistencias: vi.fn(async (_payload: { Id_Grupo: number; Fec_Ini: string; Asistencia: string }) => ({ exito: true, mensaje: 'Guardado' })),
  };
  const worker = new AttendanceUploadWorker(
    repository, { create: () => client } as never, { decrypt: () => 'ephemeral-password' } as never,
    { info: vi.fn(), warn: vi.fn(), error: vi.fn() } as never,
  );
  workers.push(worker);
  return { job, repository, client, worker };
}
