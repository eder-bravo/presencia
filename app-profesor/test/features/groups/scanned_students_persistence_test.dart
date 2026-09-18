import 'dart:io';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDir;
  final attendanceService = AsistenciaLocalService();

  setUpAll(() async {
    testDir = Directory.systemTemp.createTempSync(
      'scanned_students_persistence_test_',
    );
    Hive.init(testDir.path);
    await attendanceService.init();
  });

  tearDownAll(() async {
    await attendanceService.close();
    await Hive.close();
    if (testDir.existsSync()) testDir.deleteSync(recursive: true);
  });

  testWidgets(
    'restaura los escaneados en el contador y solo en la lista inferior',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const permissionChannel = MethodChannel(
        'flutter.baseflow.com/permissions/methods',
      );
      const studentBleChannel = MethodChannel(
        'com.presencia/student_attendance_ble',
      );
      const studentBleEventsChannel = MethodChannel(
        'com.presencia/student_attendance_ble_events',
      );
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        if (call.method == 'requestPermissions') {
          final permissions = List<int>.from(call.arguments as List);
          return <int, int>{
            for (final permission in permissions) permission: 1,
          };
        }
        return 1;
      });
      messenger.setMockMethodCallHandler(studentBleChannel, (call) async {
        if (call.method == 'getAndroidSdkInt') return 35;
        if (call.method == 'checkBluetoothState') return 'poweredOn';
        if (call.method == 'startScanning') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(studentBleEventsChannel, (_) async {
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(permissionChannel, null);
        messenger.setMockMethodCallHandler(studentBleChannel, null);
        messenger.setMockMethodCallHandler(studentBleEventsChannel, null);
      });

      final apiService = _MockApiService();
      when(() => apiService.listAvailableClassroomBeacons()).thenAnswer(
        (_) async => const Right<String, List<Map<String, dynamic>>>([]),
      );
      when(
        () => apiService.resolveStudentDeviceBindings(
          matriculas: any(named: 'matriculas'),
        ),
      ).thenAnswer(
        (_) async =>
            const Left<String, List<Map<String, dynamic>>>('Sin conexión'),
      );

      const students = [
        Alumno(
          id: '1',
          matricula: '1001',
          beaconUuid: '11111111-1111-1111-1111-111111111111',
          number: 1,
          name: 'Ana Martínez',
        ),
        Alumno(
          id: '2',
          matricula: '1002',
          beaconUuid: '22222222-2222-2222-2222-222222222222',
          number: 2,
          name: 'Bruno López',
        ),
      ];
      const group = Grupo(
        id: 'persisted-group',
        group: 'A',
        name: 'Matemáticas',
        classroom: 'A101',
        students: students,
      );
      final now = DateTime.now();
      final recordId = '${group.id}_${now.year}-${now.month}-${now.day}';
      await tester.runAsync(
        () => attendanceService.guardarAsistencia(
          AsistenciaRegistro(
            id: recordId,
            grupoId: group.id,
            profesorId: 'teacher-1',
            fecha: now,
            asistenciasAlumnos: const {'1001': false, '1002': true},
            alumnosDetectadosAutomaticamente: const ['1002'],
            fechaCreacion: now,
            nombreClase: group.name,
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GrupoDetailPage(
            grupo: group,
            gradientColors: const [Colors.blue, Colors.purple],
            accentColor: Colors.blue,
            horario: '10:00 - 12:00',
            dias: 'Lunes a viernes',
            apiService: apiService,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 800));

      await tester.tap(find.text('Alumnos'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('regular-student-1001')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('regular-student-1002')), findsNothing);
      expect(find.text('1 confirmados automáticamente'), findsOneWidget);

      await tester.ensureVisible(
        find.text('Alumnos detectados automáticamente'),
      );
      await tester.pump();
      await tester.tap(find.text('Alumnos detectados automáticamente'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey('automatic-student-1002')),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('open-student-scanner')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('open-student-scanner')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final scanner = tester.widget<StudentScannerPage>(
        find.byType(StudentScannerPage),
      );
      expect(scanner.detectedStudentKeys.value, const ['1002']);
      expect(scanner.availableStudentCount, 2);
      expect(
        find.byKey(const ValueKey('detected-student-1002')),
        findsOneWidget,
      );
      expect(find.text('1 de 2 detectados'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cancel-student-scan')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(attendanceService.limpiarTodo);
    },
  );
}
