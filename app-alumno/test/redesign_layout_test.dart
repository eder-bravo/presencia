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
import 'package:flutter_test/flutter_test.dart';

class _LayoutStorage extends LocalStorageService {
  @override
  bool get isProfileSet => false;
  @override
  List<AttendanceHistoryEntry> get attendanceHistory => [
    AttendanceHistoryEntry(
      recordedAt: DateTime.now(),
      classId: '0',
      className: 'Cálculo integral',
    ),
  ];
  @override
  List<StudentScheduleEntry> get studentSchedule => [
    for (var index = 0; index < 3; index++)
      StudentScheduleEntry(
        externalGroupId: '$index',
        subject: [
          'Cálculo integral',
          'Diseño de interfaces',
          'Arquitectura de software',
        ][index],
        classroom: ['Aula 204', 'Laboratorio 3', 'Aula 108'][index],
        professor: 'Dra. Ana Martínez',
        slots: [
          StudentScheduleSlot(
            weekday: DateTime.now().weekday,
            raw: 'Horario',
            startTime: ['07:00', '09:00', '11:30'][index],
            endTime: ['09:00', '11:00', '13:00'][index],
          ),
        ],
      ),
  ];
}

class _FocusedScheduleStorage extends _LayoutStorage {
  @override
  List<AttendanceHistoryEntry> get attendanceHistory => const [];

  @override
  List<StudentScheduleEntry> get studentSchedule => [
    // A full-day interval keeps this layout check independent of wall time.
    for (var index = 0; index < 4; index++)
      StudentScheduleEntry(
        externalGroupId: 'focus-$index',
        subject: [
          'A. Anterior',
          'B. Actual',
          'C. Siguiente',
          'D. Última',
        ][index],
        classroom: 'Aula ${index + 1}',
        slots: [
          StudentScheduleSlot(
            weekday: DateTime.now().weekday,
            raw: 'Horario',
            startTime: index < 2 ? '00:00' : '24:00',
            endTime: index == 0 ? '00:00' : '24:00',
          ),
        ],
      ),
  ];
}

Widget _layoutApp(
  Brightness brightness, {
  double textScale = 1,
  LocalStorageService? testStorage,
}) {
  final storage = testStorage ?? _LayoutStorage();
  final advertiser = BleAdvertiserService();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: HomeScreen(
      storage: storage,
      bleService: advertiser,
      attendanceSession: AttendanceSessionService(
        storage: storage,
        advertiser: advertiser,
      ),
      deviceBindingService: StudentDeviceBindingService(),
      profile: const StudentAcademicProfile(
        matricula: '2024001234',
        institutionalEmail: 'alex@alumnos.uat.edu.mx',
        displayName: 'Alex Martínez',
        programName: 'Ingeniería en Sistemas Computacionales',
        cycleName: '2026-3',
      ),
      initialUatSessionId: null,
      demoMode: false,
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      onThemeModeChanged: (_) {},
      onLogout: () async {},
    ),
  );
}

void main() {
  testWidgets(
    'agenda opens at the current class with the previous card peeking above',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _layoutApp(Brightness.dark, testStorage: _FocusedScheduleStorage()),
      );
      await tester.pumpAndSettle();
      final agenda = find.byKey(const Key('attendance-class-list'));
      final previous = find.byKey(const ValueKey('attendance-class-0'));
      final current = find.byKey(const ValueKey('attendance-class-1'));
      final next = find.byKey(const ValueKey('attendance-class-2'));
      final agendaTop = tester.getTopLeft(agenda).dy;
      expect(tester.getTopLeft(current).dy - agendaTop, closeTo(40, 1));
      expect(tester.getTopLeft(previous).dy, lessThan(agendaTop));
      expect(tester.getBottomLeft(previous).dy, greaterThan(agendaTop));
      expect(current.hitTestable(), findsOneWidget);
      expect(next.hitTestable(), findsOneWidget);
      expect(find.text('Clases hoy').hitTestable(), findsOneWidget);
      final button = find.widgetWithText(FilledButton, 'Registrar asistencia');
      final buttonPosition = tester.getTopLeft(button);
      // Earlier classes remain reachable; the button stays fixed during scrolling.
      await tester.drag(agenda, const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(previous.hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(button), buttonPosition);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'attendance and navigation remain usable with large text in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_layoutApp(brightness, textScale: 1.4));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final register = find.widgetWithText(
          FilledButton,
          'Registrar asistencia',
        );
        expect(register.hitTestable(), findsOneWidget);
        final buttonPosition = tester.getTopLeft(register);
        await tester.drag(
          find.byKey(const Key('attendance-class-list')),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        expect(register.hitTestable(), findsOneWidget);
        expect(tester.getTopLeft(register), buttonPosition);
        for (final tab in ['Horario', 'Historial', 'Perfil', 'Inicio']) {
          await tester.tap(find.text(tab).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
