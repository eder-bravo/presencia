import 'dart:async';
import 'dart:io';

import 'package:appprofesoresuniversidad/features/groups/screens/upload_management_page.dart';
import 'package:appprofesoresuniversidad/services/api_service.dart';
import 'package:appprofesoresuniversidad/services/asistencia_local_service.dart';
import 'package:appprofesoresuniversidad/services/auth_storage_service.dart';
import 'package:appprofesoresuniversidad/shared/models/alumno.dart';
import 'package:appprofesoresuniversidad/shared/models/asistencia_registro.dart';
import 'package:appprofesoresuniversidad/shared/models/grupo.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockAuthStorage extends Mock implements AuthStorageService {}

const _group = Grupo(
  id: '947699',
  group: 'M',
  classroom: 'D-407',
  name: 'Aplicaciones Web II',
  students: [Alumno(id: '371591', matricula: '2001', number: 1, name: 'Ada')],
);

AsistenciaRegistro _record({
  String id = 'local-1',
  String groupId = '947699',
}) => AsistenciaRegistro(
  id: id,
  grupoId: groupId,
  profesorId: 'teacher-1',
  fecha: DateTime(2026, 10, 6),
  asistenciasAlumnos: const {'2001': true},
  asistenciasSincronizadas: const {'2001': true},
  fechaCreacion: DateTime(2026, 10, 6),
  nombreClase: groupId == _group.id ? _group.name : 'Aplicaciones Móviles',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final localService = AsistenciaLocalService();
  late _MockApiService api;
  late _MockAuthStorage auth;
  late Future<Map<String, String>> Function() statuses;
  late Future<Either<String, Map<String, dynamic>>> Function() upload;

  setUpAll(() async {
    final fontBytes = await File(
      'test/fixtures/Roboto-Regular.ttf',
    ).readAsBytes();
    await (FontLoader(
      'Roboto',
    )..addFont(Future.value(ByteData.sublistView(fontBytes)))).load();
    registerFallbackValue(DateTime(2026));
    Hive.registerAdapter(AsistenciaRegistroAdapter());
    await Hive.openBox<AsistenciaRegistro>('asistencias', bytes: Uint8List(0));
    await localService.init();
  });
  tearDown(localService.limpiarTodo);
  tearDownAll(() async {
    await localService.close();
    await Hive.close();
  });
  setUp(() {
    api = _MockApiService();
    auth = _MockAuthStorage();
    statuses = () async => {};
    upload = () async => const Right({
      'data': {'uploadStatus': 'PENDING'},
    });
    when(() => auth.getToken()).thenReturn('session');
    when(() => auth.getGrupos()).thenReturn([_group]);
    when(
      () => api.checkSyncedRecordsStatus(
        token: any(named: 'token'),
        records: any(named: 'records'),
      ),
    ).thenAnswer((_) => statuses());
    when(
      () => api.uploadAttendance(
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
    ).thenAnswer((_) => upload());
  });

  Future<void> openPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: UploadManagementPage(apiService: api, authStorage: auth),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'continúa consultando hasta confirmar un envío con respuesta inmediata',
    (tester) async {
      await localService.guardarAsistencia(_record());
      var checks = 0;
      statuses = () async {
        checks++;
        return checks == 1
            ? {}
            : {'947699_2026-10-06': checks == 2 ? 'PROCESSING' : 'COMPLETED'};
      };
      await openPage(tester);

      await tester.tap(find.text('Enviar asistencias'));
      await tester.pump();
      expect(checks, 2);
      expect(localService.obtenerAsistenciasPendientes(), hasLength(1));

      await tester.pump(const Duration(seconds: 4));
      await tester.pump();

      expect(checks, 3);
      expect(localService.obtenerAsistenciasPendientes(), isEmpty);
      expect(find.text('¡Estás al día!'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'el modal actualiza materias y contador al recibir la confirmación',
    (tester) async {
      await localService.guardarAsistencia(_record());
      await localService.guardarAsistencia(
        _record(id: 'local-2', groupId: '947700'),
      );
      final response = Completer<Map<String, String>>();
      statuses = () => response.future;
      await openPage(tester);

      await tester.tap(find.text('Revisar detalles'));
      await tester.pumpAndSettle();
      expect(find.text('2 registros'), findsOneWidget);
      expect(find.text('0 cambios'), findsNWidgets(2));

      response.complete({'947699_2026-10-06': 'COMPLETED'});
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('1 registro'), findsOneWidget);
      expect(find.text('Aplicaciones Web II'), findsNothing);
      expect(find.text('Aplicaciones Móviles'), findsOneWidget);
      expect(find.text('0 cambios'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('un error inesperado libera el botón para volver a enviar', (
    tester,
  ) async {
    await localService.guardarAsistencia(_record());
    upload = () async => throw StateError('Error de transporte');
    await openPage(tester);

    await tester.tap(find.text('Enviar asistencias'));
    await tester.pump();
    expect(find.text('Enviar asistencias'), findsOneWidget);
    expect(localService.obtenerAsistenciasPendientes(), hasLength(1));

    upload = () async => const Right({
      'data': {'uploadStatus': 'COMPLETED'},
    });
    await tester.tap(find.text('Enviar asistencias'));
    await tester.pump();

    expect(localService.obtenerAsistenciasPendientes(), isEmpty);
    expect(find.text('¡Estás al día!'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'ignora una confirmación de la revisión anterior durante un nuevo envío',
    (tester) async {
      final record = _record().copyWith(
        asistenciasAlumnos: const {'2001': false},
      );
      await localService.guardarAsistencia(record);
      final oldResponse = Completer<Map<String, String>>();
      var checks = 0;
      statuses = () {
        checks++;
        return checks == 1 ? oldResponse.future : Future.value({});
      };
      await openPage(tester);

      await tester.tap(find.text('Enviar asistencias'));
      await tester.pump();
      oldResponse.complete({'947699_2026-10-06': 'COMPLETED'});
      await tester.pump();

      expect(localService.obtenerAsistenciasPendientes(), hasLength(1));
      expect(
        localService.obtenerAsistencia(record.id)!.asistenciasSincronizadas,
        const {'2001': false},
      );
      expect(find.text('Enviar asistencias'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
