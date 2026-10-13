import 'dart:io';

import 'package:appprofesoresuniversidad/services/asistencia_local_service.dart';
import 'package:appprofesoresuniversidad/shared/models/asistencia_registro.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory testDir;
  final service = AsistenciaLocalService();

  setUpAll(() async {
    testDir = Directory.systemTemp.createTempSync('attendance_local_test_');
    Hive.init(testDir.path);
    await service.init();
  });

  tearDown(() async {
    await service.limpiarTodo();
  });

  tearDownAll(() async {
    await service.close();
    await Hive.close();
    if (testDir.existsSync()) testDir.deleteSync(recursive: true);
  });

  test('conserva el pase de lista pendiente en el dispositivo', () async {
    final registro = AsistenciaRegistro(
      id: '947699_2026-8-28',
      grupoId: '947699',
      profesorId: '123',
      fecha: DateTime(2026, 8, 28),
      asistenciasAlumnos: const {'2251330008': true, '2251330009': false},
      alumnosDetectadosAutomaticamente: const ['2251330008'],
      fechaCreacion: DateTime(2026, 8, 28, 9),
    );

    await service.guardarAsistencia(registro);
    await service.close();
    await service.init();

    final saved = service.obtenerAsistencia(registro.id);
    expect(saved, isNotNull);
    expect(saved!.asistenciasAlumnos, registro.asistenciasAlumnos);
    expect(
      saved.alumnosDetectadosAutomaticamente,
      registro.alumnosDetectadosAutomaticamente,
    );
    expect(saved.sincronizado, isFalse);
    expect(service.obtenerAsistenciasPendientes(), hasLength(1));
  });

  test(
    'guardar una lista confirmada sin cambios no la vuelve pendiente',
    () async {
      final registro = AsistenciaRegistro(
        id: 'confirmada',
        grupoId: '947699',
        profesorId: '123',
        fecha: DateTime(2026, 10, 6),
        asistenciasAlumnos: const {'2001': true, '2002': false},
        fechaCreacion: DateTime(2026, 10, 6),
      );
      await service.guardarAsistencia(registro);
      await service.guardarSnapshotEnviado(
        registro.id,
        asistenciasEnviadas: registro.asistenciasAlumnos,
      );
      expect(await service.marcarComoSincronizada(registro.id), isTrue);

      // Una pantalla abierta conserva el registro anterior a la confirmación.
      await service.guardarAsistencia(
        registro.copyWith(horaSalida: DateTime(2026, 10, 6, 12)),
      );

      expect(service.obtenerAsistenciasPendientes(), isEmpty);
      expect(
        service.obtenerAsistencia(registro.id)!.asistenciasSincronizadas,
        registro.asistenciasAlumnos,
      );

      await service.guardarAsistencia(
        service
            .obtenerAsistencia(registro.id)!
            .copyWith(asistenciasAlumnos: const {'2001': false, '2002': false}),
      );
      expect(service.obtenerAsistenciasPendientes(), hasLength(1));
      expect(
        service.obtenerAsistencia(registro.id)!.asistenciasSincronizadas,
        registro.asistenciasAlumnos,
      );
    },
  );

  test(
    'una confirmación antigua no sincroniza una lista nunca enviada',
    () async {
      final registro = AsistenciaRegistro(
        id: 'sin-snapshot',
        grupoId: '947699',
        profesorId: '123',
        fecha: DateTime(2026, 10, 6),
        asistenciasAlumnos: const {'2001': true},
        fechaCreacion: DateTime(2026, 10, 6),
      );
      await service.guardarAsistencia(registro);

      expect(await service.marcarComoSincronizada(registro.id), isFalse);
      expect(service.obtenerAsistenciasPendientes(), hasLength(1));
    },
  );
}
