import 'dart:async';

import 'package:app_alumno/models/attendance_confirmation.dart';
import 'package:app_alumno/models/student_academic_profile.dart';
import 'package:app_alumno/models/student_schedule_entry.dart';
import 'package:app_alumno/screens/attendance_bottom_sheet.dart';
import 'package:app_alumno/screens/home_screen.dart';
import 'package:app_alumno/services/attendance_session_service.dart';
import 'package:app_alumno/services/ble_advertiser_service.dart';
import 'package:app_alumno/services/local_storage_service.dart';
import 'package:app_alumno/services/student_device_binding_service.dart';
import 'package:app_alumno/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStorage extends LocalStorageService {
  _FakeStorage({this.testMatricula = '123456', this.schedule = const []});

  final String testMatricula;
  final List<StudentScheduleEntry> schedule;

  @override
  String get matricula => testMatricula;

  @override
  String get classroomBeaconUuid => '11111111-2222-3333-4444-555555555555';

  @override
  String get attendanceUuid => 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

  @override
  List<StudentScheduleEntry> get studentSchedule => schedule;

  @override
  bool get isProfileSet => true;
}

class _FakeBleAdvertiser extends BleAdvertiserService {
  final _confirmationController =
      StreamController<AttendanceConfirmation>.broadcast();

  @override
  Stream<AttendanceConfirmation> get confirmationStream =>
      _confirmationController.stream;

  void emitConfirmation(AttendanceConfirmation confirmation) {
    _confirmationController.add(confirmation);
  }

  @override
  void dispose() {
    _confirmationController.close();
    super.dispose();
  }
}

class _FakeAttendanceSession extends AttendanceSessionService {
  _FakeAttendanceSession({
    required super.storage,
    required super.advertiser,
    this.initialSnapshot = const AttendanceSessionSnapshot(
      state: AttendanceSessionState.checkingRoom,
    ),
  });

  final AttendanceSessionSnapshot initialSnapshot;
  final _controller = StreamController<AttendanceSessionSnapshot>.broadcast();
  bool permissionWasRequested = false;

  @override
  Stream<AttendanceSessionSnapshot> get stateStream => _controller.stream;

  @override
  Future<void> start({bool requestPermissions = false}) async {
    permissionWasRequested = permissionWasRequested || requestPermissions;
    _controller.add(
      requestPermissions
          ? const AttendanceSessionSnapshot(
              state: AttendanceSessionState.checkingRoom,
            )
          : initialSnapshot,
    );
  }

  @override
  Future<void> stop() async {
    _controller.add(
      const AttendanceSessionSnapshot(state: AttendanceSessionState.idle),
    );
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }
}

void main() {
  testWidgets(
    'bottom sheet displays scanning animation, 30s countdown and class info',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = _FakeStorage();
      final ble = _FakeBleAdvertiser();
      final session = _FakeAttendanceSession(storage: storage, advertiser: ble);

      final occurrence = StudentScheduleOccurrence(
        entry: const StudentScheduleEntry(
          externalGroupId: 'g1',
          subject: 'Programación Móvil',
          classroom: 'LAB-3',
          group: 'A',
          slots: [],
        ),
        slot: const StudentScheduleSlot(weekday: 1, raw: '08:00 - 10:00'),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  AttendanceBottomSheet.show(
                    context,
                    attendanceSession: session,
                    bleService: ble,
                    storage: storage,
                    currentOccurrence: occurrence,
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Registrando asistencia'), findsOneWidget);
      expect(find.text('30s'), findsOneWidget);
      expect(find.text('Programación Móvil'), findsOneWidget);
      expect(find.text('LAB-3 · Grupo A'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);
    },
  );

  testWidgets(
    'bottom sheet transitions to timeout state after 30s with Cancelar and Reintentar buttons',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = _FakeStorage();
      final ble = _FakeBleAdvertiser();
      final session = _FakeAttendanceSession(storage: storage, advertiser: ble);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  AttendanceBottomSheet.show(
                    context,
                    attendanceSession: session,
                    bleService: ble,
                    storage: storage,
                    timeoutDuration: const Duration(seconds: 30),
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('30s'), findsOneWidget);

      // Avanzar 10 segundos
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('20s'), findsOneWidget);

      // Avanzar los restantes 20 segundos hasta que se agote el tiempo
      await tester.pump(const Duration(seconds: 20));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('No se pudo registrar la asistencia'), findsOneWidget);
      expect(
        find.byKey(const Key('attendance_timeout_cancel_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('attendance_timeout_retry_button')),
        findsOneWidget,
      );

      // Probar pulsar "Reintentar"
      await tester.tap(
        find.byKey(const Key('attendance_timeout_retry_button')),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // Debe volver al estado de escaneo con el contador reiniciado a 30s
      expect(find.text('Registrando asistencia'), findsOneWidget);
      expect(find.text('30s'), findsOneWidget);
    },
  );

  testWidgets(
    'bottom sheet displays confirmation check and subject on success, then closes automatically',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = _FakeStorage(testMatricula: '20261234');
      final ble = _FakeBleAdvertiser();
      final session = _FakeAttendanceSession(storage: storage, advertiser: ble);

      final occurrence = StudentScheduleOccurrence(
        entry: const StudentScheduleEntry(
          externalGroupId: 'g2',
          subject: 'Cálculo Vectorial',
          classroom: 'Aula 204',
          group: 'B',
          slots: [],
        ),
        slot: const StudentScheduleSlot(weekday: 1, raw: '10:00 - 12:00'),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  AttendanceBottomSheet.show(
                    context,
                    attendanceSession: session,
                    bleService: ble,
                    storage: storage,
                    currentOccurrence: occurrence,
                    autoCloseDuration: const Duration(seconds: 3),
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Registrando asistencia'), findsOneWidget);

      // Simular llegada de confirmación exitosa de asistencia
      ble.emitConfirmation(
        const AttendanceConfirmation(
          version: 2,
          status: 'confirmed',
          matricula: '20261234',
          materia: 'Cálculo Vectorial',
          classroom: 'Aula 204',
          group: 'B',
        ),
      );

      // Esperar que finalice la transición de AnimatedSwitcher (350ms)
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      // Verificar estado de éxito
      expect(find.text('Se tomó correctamente la asistencia'), findsOneWidget);
      expect(
        find.byKey(const Key('attendance_success_check_icon')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('attendance_success_subject_name')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('attendance_success_subject_name')),
            )
            .data,
        'Cálculo Vectorial',
      );
      expect(find.text('Aula 204 · Grupo B'), findsOneWidget);
      expect(find.text('Cerrando automáticamente...'), findsOneWidget);

      // Esperar que transcurran los 3 segundos de auto-cierre
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 400));

      // El modal debe haberse cerrado
      expect(find.text('Se tomó correctamente la asistencia'), findsNothing);
      expect(find.text('Open Sheet'), findsOneWidget);
    },
  );

  testWidgets('muestra el permiso faltante y solo inicia después de aceptar', (
    WidgetTester tester,
  ) async {
    final storage = _FakeStorage();
    final ble = _FakeBleAdvertiser();
    final session = _FakeAttendanceSession(
      storage: storage,
      advertiser: ble,
      initialSnapshot: const AttendanceSessionSnapshot(
        state: AttendanceSessionState.permissionRequired,
        message: 'Permite el acceso a dispositivos cercanos.',
        action: AttendanceRequirementAction.requestPermissions,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => AttendanceBottomSheet.show(
                context,
                attendanceSession: session,
                bleService: ble,
                storage: storage,
              ),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Se necesita tu permiso'), findsOneWidget);
    expect(find.text('Permitir'), findsOneWidget);
    expect(find.text('Registrando asistencia'), findsNothing);

    await tester.tap(find.byKey(const Key('attendance_requirement_action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(session.permissionWasRequested, isTrue);
    expect(find.text('Registrando asistencia'), findsOneWidget);
  });

  testWidgets('no mantiene el escaneo si Bluetooth está apagado', (
    WidgetTester tester,
  ) async {
    final storage = _FakeStorage();
    final ble = _FakeBleAdvertiser();
    final session = _FakeAttendanceSession(
      storage: storage,
      advertiser: ble,
      initialSnapshot: const AttendanceSessionSnapshot(
        state: AttendanceSessionState.bluetoothOff,
        message: 'Bluetooth está apagado.',
        action: AttendanceRequirementAction.openBluetoothSettings,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => AttendanceBottomSheet.show(
                context,
                attendanceSession: session,
                bleService: ble,
                storage: storage,
              ),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth no está disponible'), findsOneWidget);
    expect(find.text('Abrir Bluetooth'), findsOneWidget);
    expect(find.text('Registrando asistencia'), findsNothing);
  });

  testWidgets(
    'HomeScreen opens AttendanceBottomSheet when Registrar asistencia is tapped',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final weekday = DateTime.now().weekday;
      final storage = _FakeStorage(
        testMatricula: '123456',
        schedule: [
          StudentScheduleEntry(
            externalGroupId: 'today-1',
            subject: 'Estructuras de Datos',
            classroom: 'LAB 2',
            group: 'C',
            slots: [
              StudentScheduleSlot(
                weekday: weekday,
                raw: '07:00 - 23:59',
                startTime: '07:00',
                endTime: '23:59',
              ),
            ],
          ),
        ],
      );

      final advertiser = _FakeBleAdvertiser();
      final session = _FakeAttendanceSession(
        storage: storage,
        advertiser: advertiser,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: HomeScreen(
            storage: storage,
            bleService: advertiser,
            attendanceSession: session,
            deviceBindingService: StudentDeviceBindingService(),
            profile: const StudentAcademicProfile(
              matricula: '123456',
              institutionalEmail: 'alumno@alumnos.uat.edu.mx',
              displayName: 'Alumno Prueba',
            ),
            initialUatSessionId: null,
            demoMode: false,
            themeMode: ThemeMode.light,
            onThemeModeChanged: (_) {},
            onLogout: () async {},
          ),
        ),
      );

      await tester.pump();
      expect(find.text('Registrar asistencia'), findsOneWidget);

      // Pulsar el botón de registrar asistencia
      await tester.tap(find.text('Registrar asistencia'));
      await tester.pump(const Duration(milliseconds: 300));

      // El bottom sheet debe estar visible con la materia seleccionada
      expect(find.text('30s'), findsOneWidget);
      expect(find.text('Estructuras de Datos'), findsWidgets);
      expect(find.text('LAB 2 · Grupo C'), findsOneWidget);
    },
  );
}
