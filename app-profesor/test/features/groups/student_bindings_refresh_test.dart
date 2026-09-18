import 'dart:async';

import 'package:appprofesoresuniversidad/features/groups/screens/grupo_detail_page.dart';
import 'package:appprofesoresuniversidad/features/groups/screens/student_scanner_page.dart';
import 'package:appprofesoresuniversidad/services/api_service.dart';
import 'package:appprofesoresuniversidad/services/asistencia_local_service.dart';
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

typedef BindingsResult = Either<String, List<Map<String, dynamic>>>;

const _firstUuid = '11111111-1111-1111-1111-111111111111';
const _secondUuid = '22222222-2222-2222-2222-222222222222';
Map<String, dynamic> _binding(String matricula, String uuid) => {
  'matricula': matricula,
  'attendanceUuid': uuid,
  'deviceBindingId': 'binding-$matricula',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final attendance = AsistenciaLocalService();
  late _MockApiService api;
  late List<MethodCall> nativeCalls;
  late int requests;
  var groupNumber = 0;
  late Future<BindingsResult> Function() resolve;
  const ble = MethodChannel('com.presencia/student_attendance_ble');
  const events = MethodChannel('com.presencia/student_attendance_ble_events');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    // Hive en memoria mantiene estas pruebas bajo el reloj de widgets.
    Hive.registerAdapter(AsistenciaRegistroAdapter());
    await Hive.openBox<AsistenciaRegistro>('asistencias', bytes: Uint8List(0));
    await attendance.init();
  });
  tearDownAll(() async {
    await attendance.close();
    await Hive.close();
  });
  setUp(() {
    api = _MockApiService();
    nativeCalls = [];
    requests = 0;
    groupNumber++;
    resolve = () async => Right([_binding('1001', _firstUuid)]);
    when(
      () => api.listAvailableClassroomBeacons(),
    ).thenAnswer((_) async => const Right([]));
    when(
      () => api.resolveStudentDeviceBindings(
        matriculas: any(named: 'matriculas'),
      ),
    ).thenAnswer((_) {
      requests++;
      return resolve();
    });
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final p in List<int>.from(call.arguments as List)) p: 1};
      }
      return 1;
    });
    messenger.setMockMethodCallHandler(ble, (call) async {
      nativeCalls.add(call);
      if (call.method == 'getAndroidSdkInt') return 35;
      if (call.method == 'checkBluetoothState') return 'poweredOn';
      return true;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(ble, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(permissions, null);
  });

  Future<void> openStudents(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GrupoDetailPage(
          grupo: Grupo(
            id: 'refresh-group-$groupNumber',
            group: 'A',
            name: 'Matemáticas',
            classroom: 'A101',
            students: const [
              Alumno(
                id: '1',
                matricula: '1001',
                number: 1,
                name: 'Ana Martínez',
              ),
              Alumno(
                id: '2',
                matricula: '1002',
                number: 2,
                name: 'Bruno López',
              ),
            ],
          ),
          gradientColors: const [Colors.blue, Colors.purple],
          accentColor: Colors.blue,
          horario: '10:00 - 12:00',
          dias: 'Todos los días',
          apiService: api,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('Alumnos'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openScanner(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(const ValueKey('open-student-scanner')),
    );
    await tester.tap(find.byKey(const ValueKey('open-student-scanner')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('Escaneando alumnos'), findsOneWidget);
  }

  Future<void> detect(WidgetTester tester, String uuid) async {
    await messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope([
        {'uuid': uuid},
      ]),
      (_) {},
    );
    bool wasConfirmed() => nativeCalls.any(
      (call) =>
          call.method == 'confirmAttendance' &&
          (call.arguments as Map)['uuid'] == uuid.replaceAll('-', ''),
    );
    for (var attempt = 0; attempt < 10 && !wasConfirmed(); attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      wasConfirmed(),
      isTrue,
      reason: 'La asistencia debe persistirse antes de confirmar',
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'actualiza durante el escaneo y conserva detecciones al perder internet',
    (tester) async {
      await openStudents(tester);
      await openScanner(tester);
      expect(find.text('0 de 1 detectados'), findsOneWidget);
      await detect(tester, _firstUuid);
      expect(find.text('1 de 1 detectados'), findsOneWidget);

      resolve = () async =>
          Right([_binding('1001', _firstUuid), _binding('1002', _secondUuid)]);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(find.text('1 de 2 detectados'), findsOneWidget);
      final update = nativeCalls.singleWhere(
        (call) => call.method == 'updateBindings',
      );
      final payloads = (update.arguments as Map)['confirmationPayloads'] as Map;
      expect(payloads.keys, contains(_secondUuid.replaceAll('-', '')));
      expect(
        nativeCalls.where((call) => call.method == 'startScanning'),
        hasLength(1),
      );
      expect(
        nativeCalls.where((call) => call.method == 'stopScanning'),
        isEmpty,
      );
      await detect(tester, _secondUuid);
      expect(find.text('2 de 2 detectados'), findsOneWidget);

      resolve = () async => const Left('Sin internet');
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(find.text('2 de 2 detectados'), findsOneWidget);
      expect(find.text('Escaneando alumnos'), findsOneWidget);
      expect(
        nativeCalls.where((call) => call.method == 'updateBindings'),
        hasLength(1),
      );

      // Recuperación: el servidor revocó un vínculo, sin borrar su asistencia.
      resolve = () async => Right([_binding('1002', _secondUuid)]);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      final scanner = tester.widget<StudentScannerPage>(
        find.byType(StudentScannerPage),
      );
      expect(scanner.availableStudentCountListenable!.value, 1);
      expect(scanner.detectedStudentKeys.value, ['1002', '1001']);
      expect(
        nativeCalls.where((call) => call.method == 'updateBindings'),
        hasLength(2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'comparte consultas lentas con el inicio del escáner y no las solapa',
    (tester) async {
      final pending = Completer<BindingsResult>();
      resolve = () => pending.future;
      await openStudents(tester);
      expect(requests, 1);
      await tester.ensureVisible(
        find.byKey(const ValueKey('open-student-scanner')),
      );
      await tester.tap(find.byKey(const ValueKey('open-student-scanner')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 90));
      expect(requests, 1);
      pending.complete(Right([_binding('1001', _firstUuid)]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Escaneando alumnos'), findsOneWidget);
      expect(find.text('0 de 1 detectados'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(requests, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('actualiza la lista, pausa en segundo plano y cancela al salir', (
    tester,
  ) async {
    await openStudents(tester);
    expect(find.text('Listo para detección'), findsOneWidget);
    resolve = () async =>
        Right([_binding('1001', _firstUuid), _binding('1002', _secondUuid)]);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(find.text('Listo para detección'), findsNWidgets(2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final beforePause = requests;
    await tester.pump(const Duration(seconds: 90));
    expect(requests, beforePause);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(requests, beforePause + 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final beforeExit = requests;
    await tester.pump(const Duration(seconds: 90));
    expect(requests, beforeExit);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignora una respuesta pendiente cuando se cierra el grupo', (
    tester,
  ) async {
    final pending = Completer<BindingsResult>();
    resolve = () => pending.future;
    await openStudents(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(Right([_binding('1001', _firstUuid)]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });
}
