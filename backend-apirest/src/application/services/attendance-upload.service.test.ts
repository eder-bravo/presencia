import { describe, expect, it } from 'vitest';
import type { AttendanceUploadRepository } from '../../domain/attendance-upload/attendance-upload.repository.js';
import type { CreateAttendanceUploadBatchInput } from '../../domain/attendance-upload/attendance-upload.types.js';
import { AttendanceUploadService } from './attendance-upload.service.js';

describe('AttendanceUploadService', () => {
  it('genera la misma clave idempotente aunque cambie el orden del lote', async () => {
    const captured: CreateAttendanceUploadBatchInput[] = [];
    const repository = fakeRepository(captured);
    const service = new AttendanceUploadService(repository);
    const records = [
      record('local-2', 22, 8),
      record('local-1', 11, 4),
    ];

    await service.submit({ ownerUsername: 'PROFESOR@UAT.EDU.MX', credentialCipher: 'cipher', records });
    await service.submit({ ownerUsername: 'profesor@uat.edu.mx', credentialCipher: 'cipher', records: [...records].reverse() });

    expect(captured[0]?.idempotencyKey).toBe(captured[1]?.idempotencyKey);
    expect(captured[0]?.records.map((item) => item.clientRecordId)).toEqual(['local-1', 'local-2']);
  });

  it('almacena el marcador de captura diaria que el worker expande a los pases UAT', async () => {
    const captured: CreateAttendanceUploadBatchInput[] = [];
    const service = new AttendanceUploadService(fakeRepository(captured));
    const input = record('local-1', 11, 515722);
    input.attendances[0]!.num_pase_lista = 6;

    await service.submit({
      ownerUsername: 'profesor@uat.edu.mx',
      credentialCipher: 'cipher',
      records: [input],
    });

    expect(captured[0]?.records[0]?.attendances[0]?.num_pase_lista).toBe(1);
  });
});

function record(clientRecordId: string, idGrupo: number, idAlumno: number) {
  return {
    clientRecordId,
    attendanceSessionId: `attendance-${clientRecordId}`,
    attendanceVersion: 1,
    idGrupo,
    fechaInicio: '06/07/2026',
    attendances: [{ id_alumno: idAlumno, num_pase_lista: 1, num_dia: 1, sn_asistencia: true }],
  };
}

function fakeRepository(captured: CreateAttendanceUploadBatchInput[]): AttendanceUploadRepository {
  return {
    createBatch: async (input) => {
      captured.push(input);
      return {
        id: 'batch', status: 'PENDING', totalRecords: input.records.length, completedRecords: 0,
        failedRecords: 0, createdAt: new Date(), completedAt: null,
        jobs: input.records.map((item) => ({ clientRecordId: item.clientRecordId, status: 'PENDING', attempts: 0, error: null })),
      };
    },
    findLatestJobStatuses: async () => [],
    recoverStaleJobs: async () => 0,
    claimNextJob: async () => null,
    completeJob: async () => undefined,
    retryJob: async () => undefined,
    failJob: async () => undefined,
    refreshBatch: async () => undefined,
  };
}
