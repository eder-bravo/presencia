import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';
import 'package:appprofesoresuniversidad/services/api_service.dart';
import 'package:appprofesoresuniversidad/services/asistencia_local_service.dart';
import 'package:appprofesoresuniversidad/services/attendance_batch_service.dart';
import 'package:appprofesoresuniversidad/shared/models/alumno.dart';
import 'package:appprofesoresuniversidad/shared/models/asistencia_registro.dart';
import 'package:appprofesoresuniversidad/shared/models/grupo.dart';

class _MockApiService extends Mock implements ApiService {}

const _group = Grupo(
  id: '947699',
  group: 'M',
  classroom: 'D-407',
  name: 'Aplicaciones Web II',
  students: [Alumno(id: '371591', matricula: '2001', number: 1, name: 'Ada')],
);

const _secondGroup = Grupo(
  id: '947700',
  group: 'K',
  classroom: 'D-407',
  name: 'Aplicaciones Móviles',
  students: [Alumno(id: '371591', matricula: '2001', number: 1, name: 'Ada')],
);

AsistenciaRegistro _record(String id, {String groupId = '947699'}) =>
    AsistenciaRegistro(
      id: id,
      grupoId: groupId,
      profesorId: 'teacher-1',
      fecha: DateTime(2026, 10, 6),
      asistenciasAlumnos: const {'2001': true},
      fechaCreacion: DateTime(2026, 10, 6),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory testDir;
  final localService = AsistenciaLocalService();
  late _MockApiService apiService;
  late AttendanceBatchService batchService;

  setUpAll(() async {
    registerFallbackValue(DateTime(2026));
    testDir = Directory.systemTemp.createTempSync('attendance_batch_test_');
    Hive.init(testDir.path);
    await localService.init();
  });

  setUp(() {
    apiService = _MockApiService();
    batchService = AttendanceBatchService(
      apiService: apiService,
      localService: localService,
    );
  });

  tearDown(localService.limpiarTodo);
  tearDownAll(() async {
    await localService.close();
    await Hive.close();
    testDir.deleteSync(recursive: true);
  });

  void stubUpload(
    Future<Either<String, Map<String, dynamic>>> Function(Invocation) answer,
  ) {
    when(
      () => apiService.uploadAttendance(
        token: any(named: 'token'),
        clientRecordId: any(named: 'clientRecordId'),
        groupId: any(named: 'groupId'),
        code: any(named: 'code'),
        groupLetter: any(named: 'groupLetter'),
        period: any(named: 'period'),
        date: any(named: 'date'),
        attendances: any(named: 'attendances'),
        groupName: any(named: 'groupName'),
        classroom: any(named: 'classroom'),
        level: any(named: 'level'),
        schedule: any(named: 'schedule'),
      ),
    ).thenAnswer(answer);
  }

  test('prepara todas las listas en un único contrato de lote', () {
    final service = AttendanceBatchService();
    final group = Grupo(
      id: '947699',
      code: '947699',
      groupLetter: 'A',
      period: '2026-2',
      group: 'A',
      classroom: 'A1',
      name: 'Cálculo',
      students: const [
        Alumno(id: '371591', matricula: '2001', number: 7, name: 'Ada'),
      ],
    );
    final record = AsistenciaRegistro(
      id: 'local-1',
      grupoId: group.id,
      profesorId: 'teacher-1',
      fecha: DateTime(2026, 7, 6),
      asistenciasAlumnos: const {'2001': true},
      fechaCreacion: DateTime(2026, 7, 6),
    );

    final prepared = service.prepare([record], [group]);

    expect(prepared.skipped, 0);
    expect(prepared.payload, hasLength(1));
    expect(prepared.payload.single['clientRecordId'], 'local-1');
    expect(prepared.payload.single['Id_Grupo'], 947699);
    expect(prepared.payload.single['Fec_Ini'], '06/07/2026');
    expect(prepared.payload.single['Asistencia'], [
      {
        'id_alumno': 371591,
        'num_pase_lista': 1,
        'num_dia': 1,
        'sn_asistencia': true,
      },
    ]);
  });

  test('completa la lista y usa el mismo pase UAT para todos los alumnos', () {
    final service = AttendanceBatchService();
    final group = Grupo(
      id: '947699',
      group: 'A',
      classroom: 'A1',
      name: 'Cálculo',
      students: const [
        Alumno(id: '371591', matricula: '2001', number: 7, name: 'Ada'),
        Alumno(id: '371592', matricula: '2002', number: 8, name: 'Alan'),
      ],
    );
    final record = AsistenciaRegistro(
      id: 'local-2',
      grupoId: group.id,
      profesorId: 'teacher-1',
      fecha: DateTime(2026, 7, 6),
      asistenciasAlumnos: const {'2001': true},
      fechaCreacion: DateTime(2026, 7, 6),
    );

    final prepared = service.prepare([record], [group]);
    final attendance = prepared.payload.single['Asistencia'] as List<dynamic>;

    expect(attendance, [
      {
        'id_alumno': 371591,
        'num_pase_lista': 1,
        'num_dia': 1,
        'sn_asistencia': true,
      },
      {
        'id_alumno': 371592,
        'num_pase_lista': 1,
        'num_dia': 1,
        'sn_asistencia': false,
      },
    ]);
  });

  for (final status in ['COMPLETED', 'SKIPPED']) {
    test(
      'cierra la lista cuando la captura devuelve $status sin esperar un job',
      () async {
        final record = _record('local-$status');
        await localService.guardarAsistencia(record);
        stubUpload(
          (_) async => Right({
            'data': {'uploadStatus': status},
          }),
        );

        final result = await batchService.submitDirectToBackend(
          token: 'session',
          records: [record],
          groups: [_group],
        );

        expect(result.accepted, 1);
        expect(result.failed, 0);
        expect(localService.obtenerAsistenciasPendientes(), isEmpty);
      },
    );
  }

  test(
    'reenviar una materia con cero cambios permite procesar la siguiente',
    () async {
      final record = _record(
        'sin-cambios',
      ).copyWith(asistenciasSincronizadas: const {'2001': true});
      final second = _record('con-cambios', groupId: '947700');
      await localService.guardarAsistencia(record);
      await localService.guardarAsistencia(second);
      stubUpload(
        (invocation) async => Right({
          'data': {
            'uploadStatus':
                invocation.namedArguments[#clientRecordId] == record.id
                ? 'SKIPPED'
                : 'PENDING',
          },
        }),
      );

      final result = await batchService.submitDirectToBackend(
        token: 'session',
        records: [record, second],
        groups: [_group, _secondGroup],
      );

      expect(result.accepted, 2);
      expect(result.skipped, 0);
      expect(result.failed, 0);
      expect(localService.obtenerAsistenciasPendientes().map((r) => r.id), [
        second.id,
      ]);
      expect(await batchService.markCompletedIfUnchanged(second.id), isTrue);
      expect(localService.obtenerAsistenciasPendientes(), isEmpty);
    },
  );

  test('una lista fallida sigue pendiente y las demás se envían', () async {
    final first = _record('fallida');
    final second = _record('aceptada', groupId: '947700');
    await localService.guardarAsistencia(first);
    await localService.guardarAsistencia(second);
    stubUpload(
      (invocation) async =>
          invocation.namedArguments[#clientRecordId] == first.id
          ? const Left('Sin conexión')
          : const Right({
              'data': {'uploadStatus': 'COMPLETED'},
            }),
    );

    final result = await batchService.submitDirectToBackend(
      token: 'session',
      records: [first, second],
      groups: [_group, _secondGroup],
    );

    expect(result.accepted, 1);
    expect(result.failed, 1);
    expect(localService.obtenerAsistenciasPendientes().map((r) => r.id), [
      first.id,
    ]);
    expect(
      localService.obtenerAsistencia(first.id)!.asistenciasSincronizadas,
      isNull,
    );
  });

  for (final status in ['PENDING', 'COMPLETED', 'SKIPPED']) {
    test(
      'conserva las ediciones durante un envío que responde $status',
      () async {
        final record = _record('editada-$status');
        await localService.guardarAsistencia(record);
        final started = Completer<void>();
        final response = Completer<Either<String, Map<String, dynamic>>>();
        stubUpload((_) {
          started.complete();
          return response.future;
        });
        final sending = batchService.submitDirectToBackend(
          token: 'session',
          records: [record],
          groups: [_group],
        );
        await started.future;
        await localService.guardarAsistencia(
          record.copyWith(asistenciasAlumnos: const {'2001': false}),
        );
        response.complete(
          Right({
            'data': {'uploadStatus': status},
          }),
        );
        await sending;

        final saved = localService.obtenerAsistencia(record.id)!;
        expect(saved.asistenciasSincronizadas, const {'2001': true});
        expect(saved.asistenciasAlumnos, const {'2001': false});
        expect(saved.sincronizado, isFalse);
        expect(await batchService.markCompletedIfUnchanged(record.id), isFalse);
        expect(localService.obtenerAsistenciasPendientes(), hasLength(1));
      },
    );
  }
}
