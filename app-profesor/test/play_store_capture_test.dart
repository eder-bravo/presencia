import 'dart:io';
import 'dart:typed_data';

import 'package:appprofesoresuniversidad/core/theme/uat_theme.dart';
import 'package:appprofesoresuniversidad/features/authentication/providers/profesor_auth_provider.dart';
import 'package:appprofesoresuniversidad/features/groups/screens/grupo_detail_page.dart';
import 'package:appprofesoresuniversidad/features/groups/screens/grupos_page.dart';
import 'package:appprofesoresuniversidad/services/api_service.dart';
import 'package:appprofesoresuniversidad/shared/models/alumno.dart';
import 'package:appprofesoresuniversidad/shared/models/grupo.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

// flutter test --no-pub --dart-define=CAPTURE_PLAY_STORE=true \
//   --update-goldens test/play_store_capture_test.dart
// Captures current app widgets using fictional names and groups.
const _captureEnabled = bool.fromEnvironment('CAPTURE_PLAY_STORE');
const _captureKey = Key('play-store-capture');

class _MockApiService extends Mock implements ApiService {}

Map<String, String?> _schedule(String hours) => {
  for (final day in [
    'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo',
  ])
    day: hours,
};

final _groups = <Grupo>[
  Grupo(
    id: 'demo-1',
    group: 'A',
    classroom: 'A-204',
    name: 'Diseño de interfaces',
    studentsCount: 8,
    students: const [
      Alumno(id: '1', matricula: 'DEMO001', number: 1, name: 'Ana Martínez'),
      Alumno(id: '2', matricula: 'DEMO002', number: 2, name: 'Bruno López'),
      Alumno(id: '3', matricula: 'DEMO003', number: 3, name: 'Carla Rivera'),
      Alumno(id: '4', matricula: 'DEMO004', number: 4, name: 'Diego Torres'),
      Alumno(id: '5', matricula: 'DEMO005', number: 5, name: 'Elena García'),
      Alumno(id: '6', matricula: 'DEMO006', number: 6, name: 'Fernando Díaz'),
      Alumno(id: '7', matricula: 'DEMO007', number: 7, name: 'Gabriela Ruiz'),
      Alumno(id: '8', matricula: 'DEMO008', number: 8, name: 'Hugo Ramírez'),
    ],
    schedule: _schedule('08:00-10:00'),
  ),
  Grupo(
    id: 'demo-2',
    group: 'B',
    classroom: 'Lab 3',
    name: 'Arquitectura de software',
    students: const [],
    studentsCount: 32,
    schedule: _schedule('10:00-12:00'),
  ),
  Grupo(
    id: 'demo-3',
    group: 'C',
    classroom: 'B-108',
    name: 'Redes de computadoras',
    students: const [],
    studentsCount: 24,
    schedule: _schedule('12:00-14:00'),
  ),
];

Future<void> _show(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(
          width: 360,
          height: 640,
          child: ProviderScope(
            overrides: [
              profesorGruposProvider.overrideWithValue(_groups),
              profesorAuthLoadingProvider.overrideWithValue(false),
              profesorGroupsLoadingProvider.overrideWithValue(false),
              profesorGroupsNoticeProvider.overrideWithValue(null),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: UATTheme.lightTheme.copyWith(
                textTheme: UATTheme.lightTheme.textTheme.apply(
                  fontFamily: 'Roboto',
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: const Size(360, 640)),
                child: child!,
              ),
              home: page,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
}

Future<void> _capture(String name) async {
  await expectLater(
    find.byKey(_captureKey),
    matchesGoldenFile('../store_listing/phone/$name.png'),
  );
}

void main() {
  setUpAll(() async {
    Future<ByteData> roboto() => File('test/fixtures/Roboto-Regular.ttf')
        .readAsBytes()
        .then((bytes) => ByteData.view(bytes.buffer));
    await (FontLoader('Roboto')..addFont(roboto())).load();
    await (FontLoader('Ahem')..addFont(roboto())).load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });

  testWidgets('capture group cards', (tester) async {
    await _show(tester, const GruposPage());
    await tester.tap(find.byIcon(Icons.unfold_more));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 500));
    await _capture('01-grupos');
  }, skip: !_captureEnabled);

  testWidgets('capture next class', (tester) async {
    await _show(tester, const GruposPage());
    await _capture('02-proxima-clase');
  }, skip: !_captureEnabled);

  for (final (name, studentsTab) in [
    ('03-mi-asistencia', false),
    ('04-alumnos', true),
  ]) {
    testWidgets('capture $name', (tester) async {
      final api = _MockApiService();
      when(() => api.listAvailableClassroomBeacons())
          .thenAnswer((_) async => const Right<String, List<Map<String, dynamic>>>([]));
      when(() => api.resolveStudentDeviceBindings(
            matriculas: any(named: 'matriculas'),
          )).thenAnswer((_) async => const Right<String, List<Map<String, dynamic>>>([]));
      await _show(
        tester,
        GrupoDetailPage(
          grupo: _groups.first,
          gradientColors: const [Color(0xFF8B5CF6), Color(0xFF7C3AED)],
          accentColor: Colors.white,
          horario: '08:00-10:00',
          dias: 'Todos los días',
          apiService: api,
        ),
      );
      if (studentsTab) {
        await tester.tap(find.text('Alumnos'));
        await tester.pump(const Duration(milliseconds: 900));
        await tester.pump(const Duration(milliseconds: 500));
      }
      await _capture(name);
    }, skip: !_captureEnabled);
  }
}
