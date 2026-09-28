import 'dart:async';
import 'dart:io';

import 'package:app_alumno/models/attendance_confirmation.dart';
import 'package:app_alumno/models/attendance_history_entry.dart';
import 'package:app_alumno/models/student_academic_profile.dart';
import 'package:app_alumno/models/student_schedule_entry.dart';
import 'package:app_alumno/screens/home_screen.dart';
import 'package:app_alumno/services/attendance_session_service.dart';
import 'package:app_alumno/services/ble_advertiser_service.dart';
import 'package:app_alumno/services/local_storage_service.dart';
import 'package:app_alumno/services/student_device_binding_service.dart';
import 'package:app_alumno/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Captures the current UI with simulated BLE events and fictional student data.
// Never present the resulting video as evidence of a physical BLE exchange.
const _captureEnabled = bool.fromEnvironment('CAPTURE_FGS_DEMO');

class _DemoStorage extends LocalStorageService {
  final List<AttendanceHistoryEntry> _history = [];

  @override
  bool get isProfileSet => false;

  @override
  String get matricula => '2026001234';

  @override
  List<AttendanceHistoryEntry> get attendanceHistory => List.of(_history);

  @override
  List<StudentScheduleEntry> get studentSchedule => [
    StudentScheduleEntry(
      externalGroupId: 'demo-clase',
      subject: 'Diseño de interfaces',
      classroom: 'Lab 3',
      slots: [
        StudentScheduleSlot(
          weekday: DateTime.now().weekday,
          raw: 'Horario de ejemplo',
          startTime: '00:00',
          endTime: '23:59',
        ),
      ],
    ),
  ];

  @override
  Future<void> addAttendanceHistoryEntry(
    DateTime recordedAt, {
    String? classId,
    String? className,
    String? group,
    String? classroom,
  }) async {
    _history.insert(
      0,
      AttendanceHistoryEntry(
        recordedAt: recordedAt,
        classId: classId,
        className: className,
        group: group,
        classroom: classroom,
      ),
    );
  }
}

class _DemoAdvertiser extends BleAdvertiserService {
  final _confirmations = StreamController<AttendanceConfirmation>.broadcast();

  @override
  Stream<AttendanceConfirmation> get confirmationStream =>
      _confirmations.stream;

  void confirm() => _confirmations.add(
    const AttendanceConfirmation(
      version: 2,
      status: 'confirmed',
      matricula: '2026001234',
      materia: 'Diseño de interfaces',
      className: 'Diseño de interfaces',
      classroom: 'Lab 3',
    ),
  );

  @override
  void dispose() {
    _confirmations.close();
    super.dispose();
  }
}

class _DemoSession extends AttendanceSessionService {
  _DemoSession({required super.storage, required super.advertiser});

  final _snapshots = StreamController<AttendanceSessionSnapshot>.broadcast();

  @override
  Stream<AttendanceSessionSnapshot> get stateStream => _snapshots.stream;

  @override
  Future<void> start({bool requestPermissions = false}) async {
    emit(AttendanceSessionState.checkingRoom);
  }

  void emit(AttendanceSessionState state) {
    _snapshots.add(AttendanceSessionSnapshot(state: state));
  }

  @override
  Future<void> stop() async {
    emit(AttendanceSessionState.idle);
  }

  @override
  void dispose() {
    _snapshots.close();
    super.dispose();
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('capture simulated attendance flow for explanation video', (
    tester,
  ) async {
    Directory(
      'videos/foreground-service-demo/frames',
    ).createSync(recursive: true);
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final storage = _DemoStorage();
    final advertiser = _DemoAdvertiser();
    final session = _DemoSession(storage: storage, advertiser: advertiser);
    addTearDown(advertiser.dispose);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('demo-capture-root'),
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: 1080 / 2.625,
            height: 1920 / 2.625,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(Brightness.light),
              home: HomeScreen(
                storage: storage,
                bleService: advertiser,
                attendanceSession: session,
                deviceBindingService: StudentDeviceBindingService(),
                profile: const StudentAcademicProfile(
                  matricula: '2026001234',
                  institutionalEmail: 'alex@alumnos.uat.edu.mx',
                  displayName: 'Alex Rivera',
                  programName: 'Ingeniería en Sistemas Computacionales',
                ),
                initialUatSessionId: null,
                demoMode: false,
                themeMode: ThemeMode.light,
                onThemeModeChanged: (_) {},
                onLogout: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> capture(String name) => expectLater(
      find.byKey(const Key('demo-capture-root')),
      matchesGoldenFile('../videos/foreground-service-demo/frames/$name.png'),
    );

    await capture('01-inicio');

    await tester.tap(find.text('Registrar asistencia').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Registrando asistencia'), findsOneWidget);
    await capture('02-verificando-aula');

    session.emit(AttendanceSessionState.broadcasting);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      find.text('Enviando señal de asistencia al profesor...'),
      findsOneWidget,
    );
    await capture('03-transmitiendo');

    advertiser.confirm();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Se tomó correctamente la asistencia'), findsOneWidget);
    await capture('04-confirmacion');

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Historial').last);
    await tester.pump(const Duration(milliseconds: 500));
    await capture('05-historial');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  }, skip: !_captureEnabled);
}
