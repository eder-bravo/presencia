import 'package:app_alumno/models/attendance_history_entry.dart';
import 'package:app_alumno/models/student_academic_profile.dart';
import 'package:app_alumno/models/student_schedule_entry.dart';
import 'package:app_alumno/screens/home_screen.dart';
import 'package:app_alumno/screens/login_screen.dart';
import 'package:app_alumno/services/attendance_session_service.dart';
import 'package:app_alumno/services/ble_advertiser_service.dart';
import 'package:app_alumno/services/local_storage_service.dart';
import 'package:app_alumno/services/student_auth_service.dart';
import 'package:app_alumno/services/student_device_binding_service.dart';
import 'package:app_alumno/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _EmptyStorage extends LocalStorageService {
  @override
  bool get isProfileSet => false;

  @override
  int get attendanceHistoryCount => 0;

  @override
  List<AttendanceHistoryEntry> get attendanceHistory => const [];
}

class _SyncStorage extends _EmptyStorage {
  @override
  bool get isProfileSet => true;

  @override
  String get matricula => '123456';

  @override
  Future<void> setDeviceBindingSyncPending(bool pending) async {}
}

class _ScheduleStorage extends _EmptyStorage {
  _ScheduleStorage(this.schedule, {this.history = const []});

  final List<StudentScheduleEntry> schedule;
  final List<AttendanceHistoryEntry> history;

  @override
  List<StudentScheduleEntry> get studentSchedule => schedule;

  @override
  List<AttendanceHistoryEntry> get attendanceHistory => history;
}

class _RecordingAuth extends StudentAuthService {
  _RecordingAuth({required this.online, required this.events});

  final bool online;
  final List<String> events;
  int syncCount = 0;

  @override
  Future<bool> isServerOnline() async {
    events.add('online');
    return online;
  }

  @override
  Future<StudentInfoSyncResult> syncAcademicInfo(
    LocalStorageService storage, {
    String? sessionId,
  }) async {
    events.add('academic');
    syncCount++;
    return StudentInfoSyncResult(
      schedule: const [],
      partialGradesCount: 0,
      finalGradesCount: 0,
      syncedAt: DateTime(2026, 8, 3, 12, 30),
      profile: syncCount > 1
          ? const StudentAcademicProfile(
              matricula: '123456',
              institutionalEmail: 'alumno@alumnos.uat.edu.mx',
              displayName: 'Nombre Actualizado',
              programName: 'Ingeniería Actualizada',
              cycleName: '2026-3',
              average: '95',
              approvedCredits: '210',
            )
          : null,
    );
  }
}

class _RecordingDeviceBinding extends StudentDeviceBindingService {
  _RecordingDeviceBinding(this.events);

  final List<String> events;

  @override
  Future<bool> sync(LocalStorageService storage) async {
    events.add('device');
    return true;
  }
}

void main() {
  testWidgets('login fields have enough height to render entered text', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: LoginScreen(
          storage: _EmptyStorage(),
          onAuthenticated: (_, _, _) async {},
        ),
      ),
    );

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    expect(tester.getSize(fields.at(0)).height, greaterThanOrEqualTo(52));
    expect(tester.getSize(fields.at(1)).height, greaterThanOrEqualTo(52));

    await tester.enterText(fields.at(0), 'alumno@alumnos.uat.edu.mx');
    await tester.enterText(fields.at(1), 'contraseña');
    await tester.pumpAndSettle();

    expect(find.text('alumno@alumnos.uat.edu.mx'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home keeps its content visible and all tabs navigate', (
    WidgetTester tester,
  ) async {
    final storage = _EmptyStorage();
    final advertiser = BleAdvertiserService();
    final attendance = AttendanceSessionService(
      storage: storage,
      advertiser: advertiser,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: HomeScreen(
          storage: storage,
          bleService: advertiser,
          attendanceSession: attendance,
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

    expect(tester.getSize(find.byType(IndexedStack)).height, greaterThan(300));
    expect(find.text('Hola, Alumno.'), findsOneWidget);
    expect(find.text('Inicio'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar,
      isNotNull,
    );

    expect(find.text('Tus clases'), findsNothing);
    expect(find.text('Ver semana'), findsNothing);
    expect(find.text('Registrar asistencia').hitTestable(), findsOneWidget);

    await tester.tap(find.text('Horario'));
    await tester.pump();
    expect(find.text('Mi horario'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

    await tester.tap(find.text('Historial'));
    await tester.pump();
    expect(find.text('Tus asistencias aparecerán aquí'), findsOneWidget);
    await tester.tap(find.text('Inicio'));
    await tester.pump();

    await tester.tap(find.byTooltip('Abrir perfil'));
    await tester.pump();
    expect(find.text('Tu información estudiantil'), findsOneWidget);
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const Key('profile-page-background')))
          .color,
      AppPalette.light.background,
    );
    final avatar = tester.widget<Container>(
      find.byKey(const Key('profile-avatar')),
    );
    expect(
      (avatar.decoration! as BoxDecoration).color,
      AppPalette.light.accent,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('full schedule matches the weekly card layout', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    final storage = _ScheduleStorage(
      [
        StudentScheduleEntry(
          externalGroupId: 'group-registered',
          subject: 'Fundamentos de programación',
          classroom: 'Aula 101',
          slots: [
            StudentScheduleSlot(
              weekday: now.weekday,
              raw: '00:00 - 23:59',
              startTime: '00:00',
              endTime: '23:59',
            ),
          ],
        ),
      ],
      history: [
        AttendanceHistoryEntry(
          recordedAt: now,
          classId: 'group-registered',
          className: 'Fundamentos de programación',
        ),
      ],
    );
    final advertiser = BleAdvertiserService();

    await tester.pumpWidget(
      MaterialApp(
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

    final registeredButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Asistencia registrada'),
    );
    expect(registeredButton.onPressed, isNull);

    await tester.tap(find.text('Horario'));
    await tester.pumpAndSettle();

    expect(find.text('Mi horario'), findsOneWidget);
    expect(find.textContaining('SEMANA '), findsOneWidget);
    expect(find.byKey(const Key('full-schedule-day-selector')), findsOneWidget);
    expect(find.byKey(const Key('full-schedule-scroll')), findsOneWidget);
    expect(
      find.byKey(const Key('full-schedule-section-title')),
      findsOneWidget,
    );
    expect(find.text('00:00–23:59'), findsWidgets);
    expect(find.byKey(const ValueKey('full-schedule-card-0')), findsOneWidget);
    expect(find.text('Asistencia registrada'), findsOneWidget);
    final registeredCard = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('full-schedule-card-0')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (registeredCard.decoration! as BoxDecoration).color,
      AppPalette.light.successSurface,
    );
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const Key('full-schedule-background')))
          .color,
      AppPalette.light.background,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('today shows free hours, classrooms and attendance states', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final weekday = DateTime.now().weekday;
    final storage = _ScheduleStorage([
      StudentScheduleEntry(
        externalGroupId: 'early',
        subject: 'Materia temprana',
        classroom: 'Aula 101',
        slots: [
          StudentScheduleSlot(
            weekday: weekday,
            raw: '00:00 - 00:01',
            startTime: '00:00',
            endTime: '00:01',
          ),
        ],
      ),
      StudentScheduleEntry(
        externalGroupId: 'late',
        subject: 'Materia nocturna',
        classroom: 'Aula 102',
        slots: [
          StudentScheduleSlot(
            weekday: weekday,
            raw: '00:31 - 23:59',
            startTime: '00:31',
            endTime: '23:59',
          ),
        ],
      ),
    ]);
    final advertiser = BleAdvertiserService();
    await tester.pumpWidget(
      MaterialApp(
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

    final homeScroll = find
        .descendant(
          of: find.byKey(const Key('attendance-class-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('attendance-class-1')),
      -100,
      scrollable: homeScroll,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('attendance-class-1')));
    await tester.pumpAndSettle();
    expect(find.text('Un respiro entre clases.'), findsWidgets);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Hora libre'))
          .onPressed,
      isNull,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('attendance-class-2')),
      150,
      scrollable: homeScroll,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('attendance-class-2')));
    await tester.pumpAndSettle();
    final actionBar = find.byKey(const Key('attendance-action-bar'));
    expect(
      find.descendant(of: actionBar, matching: find.text('Materia nocturna')),
      findsOneWidget,
    );
    expect(find.text('Registrar asistencia').hitTestable(), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('attendance-class-0')),
      -100,
      scrollable: homeScroll,
    );
    final missedCard = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('attendance-class-0')),
        matching: find.byKey(const Key('attendance-card-surface')),
      ),
    );
    expect(
      (missedCard.decoration! as BoxDecoration).color,
      AppPalette.light.warningSurface,
    );

    await tester.tap(find.text('Horario'));
    await tester.pumpAndSettle();
    expect(find.text('00:01–00:31 · Hora libre'), findsOneWidget);
    expect(find.text('Aula 102'), findsOneWidget);
    final missedScheduleCard = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('full-schedule-card-0')),
            matching: find.byType(Container),
          )
          .first,
    );
    final currentScheduleCard = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('full-schedule-card-2')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (missedScheduleCard.decoration! as BoxDecoration).color,
      AppPalette.light.warningSurface,
    );
    expect(
      (currentScheduleCard.decoration! as BoxDecoration).color,
      AppPalette.light.surface,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('schedule header and classes move in one vertical scroll', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final weekday = DateTime.now().weekday;
    final storage = _ScheduleStorage([
      for (var index = 0; index < 5; index++)
        StudentScheduleEntry(
          externalGroupId: 'group-$index',
          subject: 'Materia ${index + 1}',
          classroom: 'Aula ${index + 1}',
          slots: [
            StudentScheduleSlot(
              weekday: weekday,
              raw:
                  '${(8 + index * 2).toString().padLeft(2, '0')}:00 - ${(9 + index * 2).toString().padLeft(2, '0')}:00',
              startTime: '${(8 + index * 2).toString().padLeft(2, '0')}:00',
              endTime: '${(9 + index * 2).toString().padLeft(2, '0')}:00',
            ),
          ],
        ),
    ]);
    final advertiser = BleAdvertiserService();
    await tester.pumpWidget(
      MaterialApp(
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
    await tester.tap(find.text('Horario'));
    await tester.pumpAndSettle();
    expect(find.text('Mi horario'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('full-schedule-scroll')),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mi horario'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark theme colors the home, schedule and history surfaces', (
    WidgetTester tester,
  ) async {
    final storage = _EmptyStorage();
    final advertiser = BleAdvertiserService();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: HomeScreen(
          storage: storage,
          bleService: advertiser,
          attendanceSession: AttendanceSessionService(
            storage: storage,
            advertiser: advertiser,
          ),
          deviceBindingService: StudentDeviceBindingService(),
          profile: const StudentAcademicProfile(
            matricula: '123456',
            institutionalEmail: 'alumno@alumnos.uat.edu.mx',
            displayName: 'Alumno Prueba',
          ),
          initialUatSessionId: null,
          demoMode: false,
          themeMode: ThemeMode.dark,
          onThemeModeChanged: (_) {},
          onLogout: () async {},
        ),
      ),
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppPalette.dark.background,
    );
    await tester.tap(find.text('Horario'));
    await tester.pump();
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const Key('full-schedule-background')))
          .color,
      AppPalette.dark.background,
    );
    await tester.tap(find.text('Historial'));
    await tester.pump();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppPalette.dark.background,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting an agenda class updates the attendance action', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final weekday = DateTime.now().weekday;
    final storage = _ScheduleStorage([
      for (var index = 0; index < 5; index++)
        StudentScheduleEntry(
          externalGroupId: 'today-$index',
          subject: 'Materia ${index + 1}',
          classroom: 'Aula ${index + 1}',
          slots: [
            StudentScheduleSlot(weekday: weekday, raw: 'Horario ${index + 1}'),
          ],
        ),
    ]);
    final advertiser = BleAdvertiserService();

    await tester.pumpWidget(
      MaterialApp(
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
            matricula: '123456',
            institutionalEmail: 'alumno@alumnos.uat.edu.mx',
            displayName: 'Jared Castillo',
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

    final list = find.byKey(const Key('attendance-class-list'));
    final actionBar = find.byKey(const Key('attendance-action-bar'));
    expect(
      find.descendant(of: actionBar, matching: find.text('Materia 1')),
      findsOneWidget,
    );
    final register = find.widgetWithText(FilledButton, 'Registrar asistencia');
    final buttonPosition = tester.getTopLeft(register);
    expect(register.hitTestable(), findsOneWidget);
    expect(
      tester.getBottomLeft(register).dy,
      lessThan(tester.getTopLeft(find.text('Inicio')).dy),
    );
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    final fifth = find.byKey(const ValueKey('attendance-class-4'));
    await tester.scrollUntilVisible(fifth, 180, scrollable: scrollable);
    await tester.pumpAndSettle();
    final scrollOffset = tester
        .widget<CustomScrollView>(list)
        .controller!
        .offset;
    expect(scrollOffset, greaterThan(0));
    expect(tester.getTopLeft(register), buttonPosition);
    expect(register.hitTestable(), findsOneWidget);
    await tester.tap(fifth);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: actionBar, matching: find.text('Materia 5')),
      findsOneWidget,
    );
    expect(register.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(register), buttonPosition);
    expect(
      tester.widget<CustomScrollView>(list).controller!.offset,
      scrollOffset,
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'attendance keeps a finished class available on compact screens',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final advertiser = BleAdvertiserService();
      final storage = _ScheduleStorage([
        StudentScheduleEntry(
          externalGroupId: 'today-1',
          subject: 'Arquitectura móvil',
          classroom: 'LAB 1',
          group: 'A',
          slots: [
            StudentScheduleSlot(
              weekday: DateTime.now().weekday,
              raw: '00:00 - 00:00',
              startTime: '00:00',
              endTime: '00:00',
            ),
          ],
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
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

      expect(find.text('Arquitectura móvil'), findsWidgets);
      final register = find.widgetWithText(
        FilledButton,
        'Registrar asistencia',
      );
      expect(tester.widget<FilledButton>(register).onPressed, isNotNull);
      expect(register.hitTestable(), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('day-finished-banner')),
        150,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('attendance-class-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.text('Jornada terminada · El registro sigue disponible'),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('profile checks the server before synchronizing information', (
    WidgetTester tester,
  ) async {
    final events = <String>[];
    final storage = _SyncStorage();
    final advertiser = BleAdvertiserService();
    final auth = _RecordingAuth(online: true, events: events);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: HomeScreen(
          storage: storage,
          bleService: advertiser,
          attendanceSession: AttendanceSessionService(
            storage: storage,
            advertiser: advertiser,
          ),
          deviceBindingService: _RecordingDeviceBinding(events),
          profile: const StudentAcademicProfile(
            matricula: '123456',
            institutionalEmail: 'alumno@alumnos.uat.edu.mx',
            displayName: 'Nombre Anterior',
          ),
          initialUatSessionId: null,
          demoMode: false,
          themeMode: ThemeMode.light,
          onThemeModeChanged: (_) {},
          onLogout: () async {},
          studentAuth: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Abrir perfil'));
    await tester.pump();
    await tester.ensureVisible(find.text('Actualizar información'));
    events.clear();

    await tester.tap(find.text('Actualizar información'));
    await tester.pump();

    expect(events, ['online', 'academic', 'device']);
    expect(find.text('Nombre Actualizado'), findsOneWidget);
    expect(find.text('Ingeniería Actualizada'), findsNWidgets(2));
    expect(
      find.text('Tu perfil y horario están actualizados.'),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('profile does not synchronize while the server is offline', (
    WidgetTester tester,
  ) async {
    final events = <String>[];
    final storage = _SyncStorage();
    final advertiser = BleAdvertiserService();
    final auth = _RecordingAuth(online: false, events: events);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: HomeScreen(
          storage: storage,
          bleService: advertiser,
          attendanceSession: AttendanceSessionService(
            storage: storage,
            advertiser: advertiser,
          ),
          deviceBindingService: _RecordingDeviceBinding(events),
          profile: const StudentAcademicProfile(
            matricula: '123456',
            institutionalEmail: 'alumno@alumnos.uat.edu.mx',
            displayName: 'Nombre Anterior',
          ),
          initialUatSessionId: null,
          demoMode: false,
          themeMode: ThemeMode.light,
          onThemeModeChanged: (_) {},
          onLogout: () async {},
          studentAuth: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Abrir perfil'));
    await tester.pump();
    await tester.ensureVisible(find.text('Actualizar información'));
    events.clear();

    await tester.tap(find.text('Actualizar información'));
    await tester.pump();

    expect(events, ['online']);
    expect(
      find.text('Sin conexión. Revisa tu internet e inténtalo de nuevo.'),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('profile confirms before closing the student session', (
    WidgetTester tester,
  ) async {
    var logoutCount = 0;
    final storage = _EmptyStorage();
    final advertiser = BleAdvertiserService();

    await tester.pumpWidget(
      MaterialApp(
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
            matricula: '123456',
            institutionalEmail: 'alumno@alumnos.uat.edu.mx',
            displayName: 'Alumno Prueba',
          ),
          initialUatSessionId: null,
          demoMode: false,
          themeMode: ThemeMode.light,
          onThemeModeChanged: (_) {},
          onLogout: () async => logoutCount++,
        ),
      ),
    );

    await tester.tap(find.byTooltip('Abrir perfil'));
    await tester.pump();
    await tester.ensureVisible(find.text('Cerrar sesión'));
    await tester.tap(find.text('Cerrar sesión'));
    await tester.pumpAndSettle();

    expect(find.text('¿Cerrar sesión?'), findsOneWidget);
    expect(logoutCount, 0);

    await tester.tap(find.widgetWithText(FilledButton, 'Cerrar sesión'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(logoutCount, 1);
    expect(tester.takeException(), isNull);
  });
}
