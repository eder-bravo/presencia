// Captures the production widgets and their interactions with fictional data.
// flutter test --no-pub --dart-define=CAPTURE_ATTENDANCE_VIDEO=true \
//   tool/video/capture_attendance_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:appprofesoresuniversidad/core/theme/uat_theme.dart';
import 'package:appprofesoresuniversidad/features/authentication/providers/profesor_auth_provider.dart';
import 'package:appprofesoresuniversidad/features/groups/screens/grupo_detail_page.dart';
import 'package:appprofesoresuniversidad/features/groups/screens/grupos_page.dart';
import 'package:appprofesoresuniversidad/features/groups/screens/student_scanner_page.dart';
import 'package:appprofesoresuniversidad/features/groups/screens/upload_management_page.dart';
import 'package:appprofesoresuniversidad/services/api_service.dart';
import 'package:appprofesoresuniversidad/services/asistencia_local_service.dart';
import 'package:appprofesoresuniversidad/services/auth_storage_service.dart';
import 'package:appprofesoresuniversidad/shared/models/alumno.dart';
import 'package:appprofesoresuniversidad/shared/models/grupo.dart';
import 'package:appprofesoresuniversidad/shared/models/profesor.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:intl/date_symbol_data_local.dart';

const _enabled = bool.fromEnvironment('CAPTURE_ATTENDANCE_VIDEO');
const _validationOnly = bool.fromEnvironment('VIDEO_VALIDATE_ONLY');
const _captureKey = Key('attendance-video');
const _viewport = Size(432, 768);
const _roomUuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const _profesor = Profesor(
  id: 'demo-docente',
  name: 'Laura Hernández',
  institutionalEmail: 'docente.demo@uat.edu.mx',
);
final _students = [
  for (final (index, name) in [
    'Ana Martínez',
    'Bruno López',
    'Carla Rivera',
    'Diego Torres',
    'Elena García',
    'Fernando Díaz',
    'Gabriela Ruiz',
    'Hugo Ramírez',
  ].indexed)
    Alumno(
      id: 'demo-alumno-${index + 1}',
      matricula: 'DEMO00${index + 1}',
      number: index + 1,
      name: name,
      beaconUuid: '${index + 1}'.padLeft(32, '0'),
    ),
];
Map<String, String?> _schedule(String hours) => {
  for (final day in [
    'lunes',
    'martes',
    'miercoles',
    'jueves',
    'viernes',
    'sabado',
    'domingo',
  ])
    day: hours,
};

class _DemoApi extends ApiService {
  @override
  Future<Either<String, List<Map<String, dynamic>>>>
  listAvailableClassroomBeacons() async => const Right([
    {'classroom': 'A-204', 'uuid': _roomUuid},
  ]);

  @override
  Future<Either<String, List<Map<String, dynamic>>>>
  resolveStudentDeviceBindings({required List<String> matriculas}) async =>
      Right([
        for (final student in _students)
          {
            'matricula': student.matricula,
            'attendanceUuid': student.beaconUuid,
            'deviceBindingId': 'demo-vinculo-${student.number}',
          },
      ]);

  @override
  Future<Either<String, Map<String, dynamic>>> recordProfessorBeaconEntry({
    required String token,
    required String externalGroupId,
    required DateTime detectedAt,
    required String beaconUuid,
    int? rssi,
    double? distance,
    String? bluetoothAddress,
  }) async => const Right({'demo': true});

  @override
  Future<Either<String, Map<String, dynamic>>> recordProfessorExit({
    required String token,
    required String externalGroupId,
    required DateTime detectedAt,
  }) async => const Right({'demo': true});

  @override
  Future<Either<String, Map<String, dynamic>>> uploadAttendance({
    required String token,
    required String clientRecordId,
    required String code,
    required String groupLetter,
    required String period,
    required DateTime date,
    required List<Map<String, dynamic>> attendances,
    String? groupName,
    String? classroom,
    String? level,
    Map<String, String?>? schedule,
    String? groupId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    return const Right({'demo': true});
  }
}

class _DemoAuth extends ProfesorAuthNotifier {
  _DemoAuth(ApiService api, List<Grupo> groups)
    : super(api, AuthStorageService()) {
    state = ProfesorAuthState(
      status: ProfesorAuthStatus.authenticated,
      profesor: _profesor,
      grupos: groups,
      token: 'fictional-video-session',
    );
  }
}

class _Recorder {
  _Recorder(this.tester, this.directory);
  final WidgetTester tester;
  final Directory directory;
  final List<Map<String, dynamic>> frames = [];
  final List<Map<String, dynamic>> chapters = [];
  double seconds = 0;

  void chapter(String label) =>
      chapters.add({'seconds': seconds, 'label': label});

  Future<void> frame({double duration = 1 / 15}) async {
    await tester.pump();
    // Flutter's widget-test engine uses Ahem as its native fallback. Button
    // styles without an explicit family otherwise become solid rectangles.
    // Give only those fallback paragraphs the app's Android Roboto family;
    // retain the actual text, weights, layout, colors, and icon fonts.
    for (final richText in find.byType(RichText).evaluate()) {
      final renderObject = richText.renderObject;
      if (renderObject is! RenderParagraph || renderObject.text is! TextSpan)
        continue;
      final span = renderObject.text as TextSpan;
      final family = span.style?.fontFamily;
      if (family != null && family != 'Ahem') continue;
      renderObject.text = TextSpan(
        text: span.text,
        children: span.children,
        style: (span.style ?? const TextStyle()).copyWith(fontFamily: 'Roboto'),
      );
    }
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final name = 'frame_${frames.length.toString().padLeft(5, '0')}.png';
    await tester.runAsync(() async {
      if (_validationOnly) {
        await Future<void>.delayed(const Duration(milliseconds: 4));
        return;
      }
      final screenshot = await boundary.toImage(
        pixelRatio: 1080 / _viewport.width,
      );
      final data = await screenshot.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${directory.path}/$name',
      ).writeAsBytes(data!.buffer.asUint8List());
      screenshot.dispose();
    });
    frames.add({'file': name, 'duration': duration});
    seconds += duration;
  }

  Future<void> animate(double duration) async {
    for (var i = 0; i < (duration * 15).round(); i++) {
      await tester.pump(const Duration(microseconds: 66667));
      await frame();
    }
  }

  Future<void> hold(double duration) async {
    await tester.pump(const Duration(milliseconds: 120));
    await frame(duration: duration);
  }

  Future<void> tap(Finder target, {double duration = 0.7}) async {
    expect(target, findsOneWidget);
    await tester.tap(target);
    await animate(duration);
  }

  Future<void> scroll(double distance, {double duration = 1.4}) async {
    final scrollable = find.byType(Scrollable).first;
    final state = tester.state<ScrollableState>(scrollable);
    final begin = state.position.pixels;
    final end = (begin + distance).clamp(0.0, state.position.maxScrollExtent);
    final count = (duration * 15).round();
    for (var i = 1; i <= count; i++) {
      final t = i / count;
      final eased = t * t * (3 - 2 * t);
      state.position.jumpTo(begin + (end - begin) * eased);
      await tester.pump(const Duration(microseconds: 66667));
      await frame();
    }
  }

  Future<void> flush() async {
    if (_validationOnly) return;
    await tester.runAsync(() async {
      await File('${directory.parent.path}/timeline.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'width': 1080,
          'height': 1920,
          'fps': 30,
          'duration': seconds,
          'chapters': chapters,
          'frames': frames,
          'disclosure':
              'Production Flutter views. Fictional roster, mocked BLE events and API responses. No production attendance is created.',
        }),
      );
    });
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final api = _DemoApi();
  final attendance = AsistenciaLocalService();
  final authStorage = AuthStorageService();
  late Directory temporaryHive;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channelNames = [
    'plugins.it_nomads.com/flutter_secure_storage',
    'flutter.baseflow.com/permissions/methods',
    'com.presencia/altbeacon',
    'com.presencia/altbeacon_events',
    'com.presencia/student_attendance_ble',
    'com.presencia/student_attendance_ble_events',
  ];

  Future<void> emit(String channel, Object payload) async {
    await messenger.handlePlatformMessage(
      channel,
      const StandardMethodCodec().encodeSuccessEnvelope(payload),
      (_) {},
    );
  }

  setUpAll(() async {
    if (!_enabled) return;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final name in channelNames) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (name.contains('flutter_secure_storage')) return null;
        if (name.contains('permissions')) {
          if (call.method == 'requestPermissions') {
            return {for (final p in call.arguments as List) p: 1};
          }
          return 1;
        }
        if (call.method == 'checkBluetoothState') return 'poweredOn';
        if (call.method == 'getAndroidSdkInt') return 35;
        if (call.method == 'startScanning' ||
            call.method == 'confirmAttendance' ||
            call.method == 'updateBindings')
          return true;
        return null;
      });
    }
    temporaryHive = Directory.systemTemp.createTempSync('presencia_video_');
    Hive.init(temporaryHive.path);
    await attendance.init();
    await authStorage.init();
    await authStorage.saveToken('fictional-video-session');
    await authStorage.saveProfesor(_profesor);
    await initializeDateFormatting('es_ES');
    Future<ByteData> roboto() async {
      final bytes = await File(
        'test/fixtures/Roboto-Regular.ttf',
      ).readAsBytes();
      return ByteData.sublistView(bytes);
    }

    for (final family in ['Roboto', 'Ahem']) {
      await (FontLoader(family)..addFont(roboto())).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  tearDownAll(() {
    if (!_enabled) return;
    // This single capture runs in its own flutter_tester process. Its Hive
    // handles are released when that process exits. Awaiting Hive.close here
    // can wait on callbacks owned by the completed widget-test fake clock.
    if (temporaryHive.existsSync()) temporaryHive.deleteSync(recursive: true);
    for (final name in channelNames) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'record teacher and student attendance walkthrough',
    (tester) async {
      binding.platformDispatcher.localeTestValue = const Locale('es', 'MX');
      tester.view.physicalSize = _viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        binding.platformDispatcher.clearLocaleTestValue();
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      });
      final now = DateTime.now();
      final start = now.subtract(const Duration(minutes: 2));
      final end = now.add(const Duration(hours: 2));
      String hhmm(DateTime d) =>
          '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
      final hours = '${hhmm(start)}-${hhmm(end)}';
      final groups = [
        Grupo(
          id: 'demo-video-A',
          code: 'DEMO.A',
          group: 'A',
          groupLetter: 'A',
          period: '2026-3',
          name: 'Diseño de interfaces',
          classroom: 'A-204',
          students: _students,
          studentsCount: 8,
          schedule: _schedule(hours),
        ),
        Grupo(
          id: 'demo-video-B',
          group: 'B',
          name: 'Arquitectura de software',
          classroom: 'Lab 3',
          students: const [],
          studentsCount: 32,
          schedule: _schedule(
            '${hhmm(end)}-${hhmm(end.add(const Duration(hours: 2)))}',
          ),
        ),
        Grupo(
          id: 'demo-video-C',
          group: 'C',
          name: 'Redes de computadoras',
          classroom: 'B-108',
          students: const [],
          studentsCount: 24,
          schedule: _schedule(
            '${hhmm(end.add(const Duration(hours: 2)))}-${hhmm(end.add(const Duration(hours: 4)))}',
          ),
        ),
      ];
      await tester.runAsync(() => authStorage.saveGrupos(groups));
      final output = Directory('build/attendance_video/frames');
      await tester.runAsync(() => output.create(recursive: true));
      final recorder = _Recorder(tester, output);

      Future<void> show(Widget page) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          RepaintBoundary(
            key: _captureKey,
            child: ProviderScope(
              overrides: [
                profesorAuthProvider.overrideWith(
                  (ref) => _DemoAuth(api, groups),
                ),
                apiServiceProvider.overrideWithValue(api),
              ],
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: UATTheme.lightTheme.copyWith(
                  textTheme: UATTheme.lightTheme.textTheme.apply(
                    fontFamily: 'Roboto',
                  ),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: _viewport,
                    padding: const EdgeInsets.only(top: 24, bottom: 12),
                  ),
                  child: child!,
                ),
                home: page,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 700));
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump(const Duration(milliseconds: 500));
      }

      recorder.chapter('Grupos y próxima clase');
      await show(const GruposPage());
      await recorder.hold(3);
      await recorder.tap(find.byIcon(Icons.unfold_more));
      await recorder.hold(3);
      await recorder.scroll(170);
      await recorder.hold(2);

      recorder.chapter('Mi asistencia');
      await show(
        GrupoDetailPage(
          grupo: groups.first,
          gradientColors: const [Color(0xFF8B5CF6), Color(0xFF7C3AED)],
          accentColor: Colors.white,
          horario: hours,
          dias: 'Todos los días',
          apiService: api,
        ),
      );
      await recorder.hold(3);
      await recorder.scroll(160);
      await recorder.hold(2);

      Future<void> mark(Finder target) async {
        await recorder.tap(target, duration: 1);
        await emit('com.presencia/altbeacon_events', [
          {'uuid': _roomUuid, 'rssi': -48, 'distance': 1.2},
        ]);
        await recorder.animate(4.2);
        await recorder.animate(1.2);
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pump();
      }

      recorder.chapter('Verificación y entrada del profesor');
      await mark(find.text('Marcar entrada'));
      expect(find.textContaining('Entrada:'), findsOneWidget);
      await recorder.hold(3);

      recorder.chapter('Pase de lista manual');
      await recorder.scroll(-1000, duration: 1.2);
      await recorder.tap(find.text('Alumnos'));
      await recorder.hold(2);
      await recorder.scroll(300);
      await recorder.hold(1);
      await recorder.tap(find.byKey(const ValueKey('regular-student-DEMO001')));
      await recorder.hold(1);
      await recorder.tap(find.byKey(const ValueKey('regular-student-DEMO002')));
      await recorder.hold(2);

      recorder.chapter('Escaneo Bluetooth de alumnos');
      await recorder.scroll(-1000, duration: 1.2);
      await recorder.scroll(170, duration: 0.8);
      await recorder.tap(
        find.byKey(const ValueKey('open-student-scanner')),
        duration: 1.2,
      );
      expect(find.byType(StudentScannerPage), findsOneWidget);
      expect(find.text('Escaneando alumnos'), findsOneWidget);
      await recorder.animate(2);
      for (final index in [2, 3, 4, 5, 6, 7]) {
        await emit('com.presencia/student_attendance_ble_events', [
          {'uuid': _students[index].beaconUuid, 'rssi': -52 - index},
        ]);
        await recorder.animate(0.5);
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await recorder.animate(0.5);
        await recorder.hold(1.3);
      }
      expect(find.text('6 de 8 detectados'), findsOneWidget);
      await recorder.animate(2);
      // The scanner keeps its own scrollable roster while scanning is active.
      await recorder.scroll(400);
      await recorder.hold(2);
      await recorder.tap(
        find.byKey(const ValueKey('cancel-student-scan')),
        duration: 1.2,
      );
      expect(find.byType(StudentScannerPage), findsNothing);
      await recorder.hold(2);

      recorder.chapter('Alumnos confirmados');
      await recorder.scroll(400);
      await recorder.tap(find.text('Alumnos detectados automáticamente'));
      await recorder.hold(2);
      await recorder.scroll(240);
      await recorder.hold(2);
      await recorder.scroll(-1000);
      await recorder.tap(find.text('Mi asistencia'));
      await recorder.scroll(180);
      await recorder.hold(2);

      recorder.chapter('Salida del profesor');
      await mark(find.text('Marcar salida'));
      expect(find.textContaining('Salida:'), findsOneWidget);
      await recorder.hold(3);

      recorder.chapter('Envío de asistencia');
      await recorder.tap(find.text('Enviar asistencia'), duration: 2.2);
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump();
      expect(find.text('¡Asistencia guardada!'), findsOneWidget);
      await recorder.hold(3);
      await recorder.tap(find.text('Entendido'));
      await recorder.hold(2);

      // Use the local management view without a session so it only reads the
      // isolated demo Hive box and never reconciles against the production API.
      await tester.runAsync(() async {
        final record = attendance.obtenerAsistenciaPorGrupoYFecha(
          groups.first.id,
          now,
        );
        expect(record, isNotNull);
        await attendance.marcarComoSincronizada(record!.id);
        await authStorage.clearToken();
      });
      recorder.chapter('Historial y calendario');
      await show(const UploadManagementPage());
      await recorder.hold(3);
      expect(find.text('¡Estás al día!'), findsOneWidget);
      await recorder.tap(find.byIcon(Icons.calendar_month_rounded));
      await recorder.hold(3);
      await recorder.tap(find.text('${now.day}').last);
      await recorder.hold(3);
      await recorder.flush();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
      print(
        'Captured ${recorder.frames.length} frames, ${recorder.seconds.toStringAsFixed(1)} seconds',
      );
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
