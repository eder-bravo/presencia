import type { UatAsistenciaAlumnoInput, UatAsistenciaGrupoResponse } from '../types/uat.interfaces.js';

const UAT_DAYS = ['Lunes', 'Martes', 'Miercoles', 'Jueves', 'Viernes', 'Sabado', 'Domingo'] as const;

/** A daily capture applies to every pass UAT schedules for that student/day. */
export function expandDailyAttendances(
  dailyAttendances: readonly UatAsistenciaAlumnoInput[],
  weeklyAttendance: UatAsistenciaGrupoResponse,
): UatAsistenciaAlumnoInput[] {
  if (weeklyAttendance.exito === false) {
    throw new Error('UAT rechazó la consulta de los pases de asistencia.');
  }
  const students = weeklyAttendance.alumnos ?? weeklyAttendance.Alumnos ?? weeklyAttendance.data ?? weeklyAttendance.result;
  if (!Array.isArray(students) || students.length === 0) {
    throw new Error('UAT no devolvió el padrón con los pases de asistencia.');
  }
  const days = new Set(dailyAttendances.map(({ num_dia }) => num_dia));
  const day = dailyAttendances[0]?.num_dia;
  if (days.size !== 1 || day === undefined || !Number.isInteger(day) || day < 1 || day > 7) {
    throw new Error('La captura debe corresponder a un único día de asistencia.');
  }
  const field = `Num_Pl_${UAT_DAYS[day - 1]}`;
  const roster = new Map(students.flatMap((student) => {
    if (!student || typeof student !== 'object' || Array.isArray(student)) return [];
    return [[Number(student.Id_Alumno ?? student.id_alumno), student] as const];
  }));
  const dailyByStudent = new Map<number, UatAsistenciaAlumnoInput>();
  for (const attendance of dailyAttendances) {
    const previous = dailyByStudent.get(attendance.id_alumno);
    if (previous && previous.sn_asistencia !== attendance.sn_asistencia) {
      throw new Error('La captura contiene estados distintos para el mismo alumno y día.');
    }
    dailyByStudent.set(attendance.id_alumno, attendance);
  }

  return [...dailyByStudent.values()].sort((a, b) => a.id_alumno - b.id_alumno).flatMap((attendance) => {
    const student = roster.get(attendance.id_alumno);
    if (!student) throw new Error('Un alumno de la captura no aparece en el padrón UAT de esa semana.');
    const rawCount = student[field];
    const passCount = typeof rawCount === 'number' || (typeof rawCount === 'string' && rawCount.trim())
      ? Number(rawCount) : NaN;
    if (!Number.isSafeInteger(passCount) || passCount < 1) {
      throw new Error('UAT no devolvió pases válidos para un alumno en el día de la captura.');
    }
    return Array.from({ length: passCount }, (_, index) => ({
      id_alumno: attendance.id_alumno,
      num_pase_lista: index + 1,
      num_dia: day,
      sn_asistencia: attendance.sn_asistencia,
    }));
  });
}

/** Uses calendar dates in UTC so the requested week does not shift with DST. */
export function uatAttendanceWeekRange(start: string): { fec_ini: string; fec_fin: string } {
  const latin = start.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  const iso = latin ? `${latin[3]}-${latin[2]}-${latin[1]}` : start;
  const date = new Date(`${iso}T00:00:00.000Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(iso) || Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== iso) {
    throw new Error('La semana UAT no contiene una fecha válida.');
  }
  const fec_ini = formatUatDate(date);
  date.setUTCDate(date.getUTCDate() + 6);
  return { fec_ini, fec_fin: formatUatDate(date) };
}

function formatUatDate(date: Date): string {
  return `${String(date.getUTCDate()).padStart(2, '0')}/${String(date.getUTCMonth() + 1).padStart(2, '0')}/${date.getUTCFullYear()}`;
}
