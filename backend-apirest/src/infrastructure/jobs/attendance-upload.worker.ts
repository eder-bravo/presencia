import type { FastifyBaseLogger } from 'fastify';
import type { AttendanceUploadRepository } from '../../domain/attendance-upload/attendance-upload.repository.js';
import { expandDailyAttendances, uatAttendanceWeekRange } from '../../domain/attendance-upload/uat-daily-attendance.js';
import type { UatClientFactory } from '../http/client/uat-client.factory.js';
import type { CredentialCipher } from '../security/credential-cipher.js';

const MAX_ATTEMPTS = 5;
const POLL_INTERVAL_MS = 1_000;
const STALE_LOCK_MS = 5 * 60_000;

/** Durable database-backed worker. PostgreSQL is the queue source of truth. */
export class AttendanceUploadWorker {
  private timer?: NodeJS.Timeout;
  private running = false;
  private stopped = true;
  private lastRecoveryAt = 0;

  constructor(
    private readonly repository: AttendanceUploadRepository,
    private readonly clientFactory: UatClientFactory,
    private readonly credentialCipher: CredentialCipher,
    private readonly logger: FastifyBaseLogger,
  ) {}

  async start(): Promise<void> {
    if (!this.stopped) return;
    this.stopped = false;
    const recovered = await this.repository.recoverStaleJobs(new Date(Date.now() - STALE_LOCK_MS));
    if (recovered > 0) this.logger.warn({ recovered }, 'Se recuperaron jobs de asistencia interrumpidos.');
    this.timer = setInterval(() => void this.drain(), POLL_INTERVAL_MS);
    this.timer.unref();
    void this.drain();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    while (this.running) await new Promise((resolve) => setTimeout(resolve, 25));
  }

  wake(): void {
    void this.drain();
  }

  private async drain(): Promise<void> {
    if (this.running || this.stopped) return;
    this.running = true;
    try {
      if (Date.now() - this.lastRecoveryAt >= 30_000) {
        await this.repository.recoverStaleJobs(new Date(Date.now() - STALE_LOCK_MS));
        this.lastRecoveryAt = Date.now();
      }
      while (!this.stopped) {
        const job = await this.repository.claimNextJob(new Date());
        if (!job) break;
        await this.process(job);
      }
    } catch (error) {
      this.logger.error({ err: error }, 'Falló el ciclo del worker de asistencias.');
    } finally {
      this.running = false;
    }
  }

  private async process(job: NonNullable<Awaited<ReturnType<AttendanceUploadRepository['claimNextJob']>>>): Promise<void> {
    try {
      const password = this.credentialCipher.decrypt(job.credentialCipher);
      const client = this.clientFactory.create();
      await client.authenticate({ username: job.ownerUsername, password });
      const week = uatAttendanceWeekRange(job.fechaInicio);
      const weeklyAttendance = await client.getAsistenciaGrupo({
        Id_Grupo: job.idGrupo,
        ...week,
      });
      const attendances = expandDailyAttendances(job.attendances, weeklyAttendance);
      const response = await client.guardaAsistencias({
        Id_Grupo: job.idGrupo,
        Fec_Ini: week.fec_ini,
        Asistencia: JSON.stringify(attendances),
      });
      if (response.exito === false) throw new Error(response.mensaje || 'UAT rechazó la lista de asistencia.');
      await this.repository.completeJob(job);
      this.logger.info({ jobId: job.id, batchId: job.batchId, clientRecordId: job.clientRecordId }, 'Lista de asistencia procesada.');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Error desconocido al subir asistencia.';
      if (job.attempts >= MAX_ATTEMPTS) {
        await this.repository.failJob(job, message);
        this.logger.error({ jobId: job.id, err: error }, 'Lista de asistencia agotó sus reintentos.');
      } else {
        const delay = Math.min(60_000, 1_000 * 2 ** (job.attempts - 1));
        await this.repository.retryJob(job.id, message, new Date(Date.now() + delay));
        this.logger.warn({ jobId: job.id, attempt: job.attempts, delay }, 'Lista de asistencia programada para reintento.');
      }
    } finally {
      await this.repository.refreshBatch(job.batchId);
    }
  }
}
