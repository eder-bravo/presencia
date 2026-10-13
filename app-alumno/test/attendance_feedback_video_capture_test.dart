import 'dart:async';
import 'dart:convert';
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

// Render the real widgets frame by frame with fictional data and simulated BLE.
// This is a visual demo, not a recording of a physical attendance exchange.
const _captureEnabled = bool.fromEnvironment('CAPTURE_ATTENDANCE_VIDEO');
const _captureRoot = Key('attendance-video-root');
const _fps = 24;

class _VideoStorage extends LocalStorageService {
  final now = DateTime.now();
  final _history = <AttendanceHistoryEntry>[];

  @override
  bool get isProfileSet => false;

  @override
  String get matricula => '2026001234';

  @override
  List<AttendanceHistoryEntry> get attendanceHistory => List.of(_history);

  @override
  List<StudentScheduleEntry> get studentSchedule => [
    StudentScheduleEntry(
      externalGroupId: 'demo-programacion',
      subject: 'Programación Móvil',
      classroom: 'LAB-3',
      group: 'A',
      professor: 'Docente de ejemplo',
      slots: [
        StudentScheduleSlot(
          weekday: now.weekday,
          raw: 'Horario de ejemplo',
          startTime: '${now.hour.toString().padLeft(2, '0')}:00',
          endTime: now.hour == 23
              ? '23:59'
              : '${(now.hour + 1).toString().padLeft(2, '0')}:59',
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

class _VideoAdvertiser extends BleAdvertiserService {
  final _confirmations = StreamController<AttendanceConfirmation>.broadcast();

  @override
  Stream<AttendanceConfirmation> get confirmationStream =>
      _confirmations.stream;

  void confirm() => _confirmations.add(
    const AttendanceConfirmation(
      version: 2,
      status: 'confirmed',
      matricula: '2026001234',
      classId: 'demo-programacion',
      materia: 'Programación Móvil',
      className: 'Programación Móvil',
      classroom: 'LAB-3',
      group: 'A',
    ),
  );

  @override
  void dispose() {
    _confirmations.close();
    super.dispose();
  }
}

class _VideoSession extends AttendanceSessionService {
  _VideoSession({required super.storage, required super.advertiser});

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
  Future<void> stop() async => emit(AttendanceSessionState.idle);

  @override
  void dispose() {
    _snapshots.close();
    super.dispose();
  }
}

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter');
    for (final weight in [
      'Regular',
      'Medium',
      'SemiBold',
      'Bold',
      'ExtraBold',
    ]) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$weight.ttf'));
    }
    await inter.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('render attendance and feedback video', (tester) async {
    final output = Directory('videos/asistencia-feedback');
    Directory('${output.path}/frames').createSync(recursive: true);
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final storage = _VideoStorage();
    final advertiser = _VideoAdvertiser();
    final session = _VideoSession(storage: storage, advertiser: advertiser);
    addTearDown(advertiser.dispose);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureRoot,
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: 720 / 1.75,
            height: 1280 / 1.75,
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

    var frame = 0;
    final scenes = <Map<String, Object>>[];
    final taps = <Map<String, Object>>[];

    void scene(String label) => scenes.add({'frame': frame, 'label': label});

    Future<void> record(int count) async {
      for (var i = 0; i < count; i++) {
        // Accumulate rounded frame times without drifting from 24 fps.
        final micros =
            ((frame + 1) * 1000000 / _fps).round() -
            (frame * 1000000 / _fps).round();
        await tester.pump(Duration(microseconds: micros));
        await expectLater(
          find.byKey(_captureRoot),
          matchesGoldenFile(
            '../videos/asistencia-feedback/frames/'
            '${frame.toString().padLeft(5, '0')}.png',
          ),
        );
        frame++;
      }
    }

    Future<void> tap(Finder target) async {
      final point = tester.getCenter(target);
      taps.add({'frame': frame, 'x': point.dx, 'y': point.dy});
      final gesture = await tester.startGesture(point);
      await record(4);
      await gesture.up();
    }

    scene('El alumno toca «Registrar asistencia»');
    await record(48);
    await tap(find.text('Registrar asistencia').last);

    scene('La app verifica la presencia en el aula');
    await record(56);
    expect(find.text('Registrando asistencia'), findsOneWidget);
    expect(find.text('Verificando presencia en el aula...'), findsOneWidget);

    session.emit(AttendanceSessionState.roomVerified);
    await record(16);
    session.emit(AttendanceSessionState.broadcasting);
    scene('Se envía la asistencia al profesor');
    await record(60);
    expect(
      find.text('Enviando señal de asistencia al profesor...'),
      findsOneWidget,
    );

    advertiser.confirm();
    scene('El alumno recibe la confirmación de asistencia');
    await record(42);
    expect(find.text('Se tomó correctamente la asistencia'), findsOneWidget);
    expect(
      find.byKey(const Key('attendance_success_check_icon')),
      findsOneWidget,
    );

    await record(20);
    expect(find.text('Se tomó correctamente la asistencia'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('attendance-action-bar')),
        matching: find.text('Asistencia registrada'),
      ),
      findsOneWidget,
    );
    scene('La clase queda marcada como registrada');
    await record(28);

    await tap(find.text('Historial').last);
    scene('El registro también aparece en el historial');
    await record(62);
    expect(storage.attendanceHistory, hasLength(1));
    expect(storage.attendanceHistory.single.className, 'Programación Móvil');

    File('${output.path}/timeline.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'fps': _fps,
        'frames': frame,
        'width': 720,
        'height': 1280,
        'simulation': true,
        'scenes': scenes,
        'taps': taps,
      }),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  }, skip: !_captureEnabled);
}
