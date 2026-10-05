import { describe, expect, it } from 'vitest';
import type { UatAsistenciaAlumnoItem, UatAsistenciaGrupoResponse } from '../types/uat.interfaces.js';
import { expandDailyAttendances, uatAttendanceWeekRange } from './uat-daily-attendance.js';

describe('expandDailyAttendances', () => {
  it.each([1, 2, 4, 9])('expande la captura a %i pases sin usar el número de lista del alumno', (count) => {
    const result = expandDailyAttendances([
      { id_alumno: 101, num_pase_lista: 1, num_dia: 5, sn_asistencia: true },
      { id_alumno: 102, num_pase_lista: 1, num_dia: 5, sn_asistencia: false },
    ], { alumnos: [student(101, { Num_Pl_Viernes: count }), student(102, { Num_Pl_Viernes: count })] });

    expect(result).toHaveLength(2 * count);
    for (const [id, present] of [[101, true], [102, false]] as const) {
      expect(result.filter(({ id_alumno }) => id_alumno === id)).toEqual(
        Array.from({ length: count }, (_, index) => ({
          id_alumno: id, num_pase_lista: index + 1, num_dia: 5, sn_asistencia: present,
        })),
      );
    }
  });

  it.each(['Lunes', 'Martes', 'Miercoles', 'Jueves', 'Viernes', 'Sabado', 'Domingo'])('usa sólo los pases del %s', (day) => {
    const number = ['Lunes', 'Martes', 'Miercoles', 'Jueves', 'Viernes', 'Sabado', 'Domingo'].indexOf(day) + 1;
    const result = expandDailyAttendances([
      { id_alumno: 101, num_pase_lista: 1, num_dia: number, sn_asistencia: true },
    ], { alumnos: [student(101, { [`Num_Pl_${day}`]: '2', Txt_Pl_Viernes: '1,1' })] });

    expect(result.map(({ num_dia, num_pase_lista }) => [num_dia, num_pase_lista])).toEqual([[number, 1], [number, 2]]);
  });

  it('usa el total programado aunque UAT sólo tenga guardado el primer pase', () => {
    const result = expandDailyAttendances([
      { id_alumno: 101, num_pase_lista: 1, num_dia: 5, sn_asistencia: true },
    ], { exito: true, result: [student(101, { Num_Pl_Viernes: 4, Txt_Pl_Viernes: '1,1' })] });
    expect(result.map(({ num_pase_lista }) => num_pase_lista)).toEqual([1, 2, 3, 4]);
  });

  it('consulta el total de cada alumno y no duplica capturas repetidas', () => {
    const result = expandDailyAttendances([
      { id_alumno: 102, num_pase_lista: 1, num_dia: 5, sn_asistencia: false },
      { id_alumno: 101, num_pase_lista: 1, num_dia: 5, sn_asistencia: true },
      { id_alumno: 101, num_pase_lista: 2, num_dia: 5, sn_asistencia: true },
    ], { alumnos: [student(101, { Num_Pl_Viernes: 2 }), student(102, { Num_Pl_Viernes: 1 })] });
    expect(result.map(({ id_alumno, num_pase_lista }) => [id_alumno, num_pase_lista])).toEqual([[101, 1], [101, 2], [102, 1]]);
  });

  it.each([undefined, null, '', 0, -1, 1.5, 'sin horario', true])('rechaza un total inválido (%s) sin preparar una lista parcial', (count) => {
    expect(() => expandDailyAttendances([
      { id_alumno: 101, num_pase_lista: 1, num_dia: 5, sn_asistencia: true },
    ], { alumnos: [student(101, { Num_Pl_Viernes: count })] })).toThrow('pases válidos');
  });

  it.each([
    { exito: false, alumnos: [student(101, { Num_Pl_Viernes: 4 })] },
    {},
    { alumnos: [] },
    { alumnos: [student(102, { Num_Pl_Viernes: 4 })] },
  ])('rechaza una consulta fallida o un padrón incompleto', (response) => {
    expect(() => expandDailyAttendances([
      { id_alumno: 101, num_pase_lista: 1, num_dia: 5, sn_asistencia: true },
    ], response as UatAsistenciaGrupoResponse)).toThrow();
  });

  it('rechaza estados contradictorios en una captura diaria', () => {
    expect(() => expandDailyAttendances([
      { id_alumno: 101, num_pase_lista: 1, num_dia: 5, sn_asistencia: true },
      { id_alumno: 101, num_pase_lista: 2, num_dia: 5, sn_asistencia: false },
    ], { alumnos: [student(101, { Num_Pl_Viernes: 4 })] })).toThrow('estados distintos');
  });

  it('rechaza capturas vacías o de varios días', () => {
    const response = { alumnos: [student(101, { Num_Pl_Viernes: 4 })] };
    expect(() => expandDailyAttendances([], response)).toThrow('único día');
    expect(() => expandDailyAttendances([
      { id_alumno: 101, num_pase_lista: 1, num_dia: 5, sn_asistencia: true },
      { id_alumno: 101, num_pase_lista: 1, num_dia: 6, sn_asistencia: true },
    ], response)).toThrow('único día');
  });
});

describe('uatAttendanceWeekRange', () => {
  it.each([
    ['28/09/2026', '04/10/2026'],
    ['28/12/2026', '03/01/2027'],
    ['26/02/2024', '03/03/2024'],
    ['2026-09-28', '04/10/2026'],
  ])('consulta la semana completa desde %s', (start, end) => {
    expect(uatAttendanceWeekRange(start)).toEqual({ fec_ini: start === '2026-09-28' ? '28/09/2026' : start, fec_fin: end });
  });

  it.each(['31/02/2026', '00/01/2026', '28/13/2026', 'invalid'])('rechaza fechas inválidas: %s', (start) => {
    expect(() => uatAttendanceWeekRange(start)).toThrow('fecha válida');
  });
});

function student(id: number, fields: Record<string, unknown>): UatAsistenciaAlumnoItem {
  return { Id_Alumno: id, Txt_Alumno: 'Alumno de prueba', Num_Lista: 37, ...fields } as UatAsistenciaAlumnoItem;
}
