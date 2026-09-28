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

// Run with --dart-define=CAPTURE_LANDING_SCREENSHOTS=true --update-goldens.
// Captures the real HomeScreen for the landing using fictional student data.
const _captureEnabled = bool.fromEnvironment('CAPTURE_LANDING_SCREENSHOTS');

class _StoreStorage extends LocalStorageService {
  _StoreStorage(this.now);

  final DateTime now;

  @override
  bool get isProfileSet => false;

  @override
  List<StudentScheduleEntry> get studentSchedule {
    final subjects = [
      'Cálculo integral',
      'Diseño de interfaces',
      'Arquitectura de software',
      'Redes de computadoras',
    ];
    final baseHour = now.hour.clamp(8, 17);
    return [
      for (var index = 0; index < subjects.length; index++)
        StudentScheduleEntry(
          externalGroupId: 'ejemplo-$index',
          subject: subjects[index],
          classroom: ['204', 'Lab 3', '108', '302'][index],
          professor: 'Docente de ejemplo',
          slots: [
            StudentScheduleSlot(
              weekday: now.weekday,
              raw: 'Horario de ejemplo',
              startTime: _time(baseHour + index * 2 - 3),
              endTime: _time(baseHour + index * 2 - 1),
            ),
          ],
        ),
    ];
  }

  @override
  List<AttendanceHistoryEntry> get attendanceHistory => [
    AttendanceHistoryEntry(
      recordedAt: DateTime(now.year, now.month, now.day, 8, 55),
      classId: 'ejemplo-0',
      className: 'Cálculo integral',
      classroom: '204',
    ),
    AttendanceHistoryEntry(
      recordedAt: now.subtract(const Duration(days: 1)),
      classId: 'ejemplo-1',
      className: 'Diseño de interfaces',
      classroom: 'Lab 3',
    ),
    AttendanceHistoryEntry(
      recordedAt: now.subtract(const Duration(days: 2)),
      classId: 'ejemplo-2',
      className: 'Arquitectura de software',
      classroom: '108',
    ),
  ];
}

String _time(int hour) => '${hour.toString().padLeft(2, '0')}:00';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final (name, tab) in [
    ('01-inicio', 'Inicio'),
    ('02-horario', 'Horario'),
    ('03-historial', 'Historial'),
  ]) {
    testWidgets('capture $tab for landing', (tester) async {
      tester.view.physicalSize = const Size(1440, 2560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = _StoreStorage(DateTime.now());
      final advertiser = BleAdvertiserService();
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('store-capture-root'),
          child: FittedBox(
            fit: BoxFit.fill,
            child: SizedBox(
              width: 1440 / 3.5,
              height: 2560 / 3.5,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildAppTheme(Brightness.light),
                home: HomeScreen(
                  storage: storage,
                  bleService: advertiser,
                  attendanceSession: AttendanceSessionService(
                    storage: storage,
                    advertiser: advertiser,
                  ),
                  deviceBindingService: StudentDeviceBindingService(),
                  profile: const StudentAcademicProfile(
                    matricula: '2026001234',
                    institutionalEmail: 'alex@alumnos.uat.edu.mx',
                    displayName: 'Alex Rivera',
                    programName: 'Ingeniería en Sistemas Computacionales',
                    cycleName: '2026-3',
                    average: '9.4',
                    approvedCredits: '115',
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
      if (tab != 'Inicio') {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
      }

      await expectLater(
        find.byKey(const Key('store-capture-root')),
        matchesGoldenFile(
          '../../landing-alumnos/assets/alumnos-${name.substring(3)}.png',
        ),
      );
    }, skip: !_captureEnabled);
  }
}
