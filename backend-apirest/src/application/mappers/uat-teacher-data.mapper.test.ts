import { describe, expect, it } from 'vitest';
import type { UatHorarioItem } from '../../domain/types/uat.interfaces.js';
import { mapWeeklySchedule, parseScheduleSlots } from './uat-teacher-data.mapper.js';

describe('UatTeacherDataMapper schedule normalization', () => {
  it('normaliza rangos por dia y conserva valores no interpretables', () => {
    const schedule = mapWeeklySchedule({ Txt_Lunes: '7:00 - 8:30', Txt_Martes: 'Por definir' } as UatHorarioItem);
    expect(schedule.monday[0]).toEqual({ raw: '7:00 - 8:30', startTime: '07:00', endTime: '08:30' });
    expect(schedule.tuesday[0]).toEqual({ raw: 'Por definir', startTime: null, endTime: null });
    expect(schedule.wednesday).toEqual([]);
  });

  it('separa multiples bloques horarios', () => {
    expect(parseScheduleSlots('07:00-08:00; 10:00 a 11:30')).toHaveLength(2);
  });

  it('conserva todas las filas del mismo grupo y elimina horarios repetidos', () => {
    const schedule = mapWeeklySchedule([
      { Txt_Viernes: '14:00-15:00' },
      { Txt_Viernes: '12:00-13:00' },
      { Txt_Viernes: '13:00-14:00', Txt_Lunes: '18:00-20:00' },
      { Txt_Viernes: '15:00-16:00' },
      { Txt_Viernes: '12:00 - 13:00' },
    ] as UatHorarioItem[]);
    expect(schedule.friday.map(({ startTime, endTime }) => [startTime, endTime])).toEqual([
      ['12:00', '13:00'], ['13:00', '14:00'], ['14:00', '15:00'], ['15:00', '16:00'],
    ]);
    expect(schedule.monday).toHaveLength(1);
    expect(schedule.tuesday).toEqual([]);
  });

  it('ignora marcadores que representan dias sin horario', () => {
    expect(parseScheduleSlots('-; --; N/A; sin horario')).toEqual([]);
  });
});
