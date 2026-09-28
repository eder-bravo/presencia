import 'dart:io';
import 'dart:typed_data';

import 'package:appprofesoresuniversidad/core/theme/uat_theme.dart';
import 'package:appprofesoresuniversidad/features/authentication/providers/profesor_auth_provider.dart';
import 'package:appprofesoresuniversidad/features/groups/screens/grupos_page.dart';
import 'package:appprofesoresuniversidad/shared/models/grupo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// flutter test --no-pub --dart-define=CAPTURE_LANDING_SCREENSHOTS=true \
//   --update-goldens test/landing_capture_test.dart
// The screenshots render real app pages with fictional group data.
const _captureEnabled = bool.fromEnvironment('CAPTURE_LANDING_SCREENSHOTS');

Map<String, String?> _demoSchedule(String hours) => {
  for (final day in [
    'lunes',
    'martes',
    'miércoles',
    'jueves',
    'viernes',
    'sábado',
    'domingo',
  ])
    day: hours,
};

final _groups = <Grupo>[
  Grupo(
    id: 'demo-1',
    group: 'A',
    classroom: 'A-204',
    name: 'Diseño de interfaces',
    students: [],
    studentsCount: 28,
    schedule: _demoSchedule('08:00-10:00'),
  ),
  Grupo(
    id: 'demo-2',
    group: 'B',
    classroom: 'Lab 3',
    name: 'Arquitectura de software',
    students: [],
    studentsCount: 32,
    schedule: _demoSchedule('10:00-12:00'),
  ),
  Grupo(
    id: 'demo-3',
    group: 'C',
    classroom: 'B-108',
    name: 'Redes de computadoras',
    students: [],
    studentsCount: 24,
    schedule: _demoSchedule('12:00-14:00'),
  ),
];

void main() {
  setUpAll(() async {
    Future<ByteData> roboto() => File(
      'test/fixtures/Roboto-Regular.ttf',
    ).readAsBytes().then((bytes) => ByteData.view(bytes.buffer));
    await (FontLoader('Roboto')..addFont(roboto())).load();
    await (FontLoader('Ahem')..addFont(roboto())).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final (name, page) in [
    ('docentes-clases', const GruposPage()),
    ('docentes-grupos', const GruposPage()),
  ]) {
    testWidgets('capture $name for landing', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('landing-capture-root'),
          child: FittedBox(
            fit: BoxFit.fill,
            child: SizedBox(
              width: 360,
              height: 780,
              child: ProviderScope(
                overrides: [
                  profesorGruposProvider.overrideWithValue(_groups),
                  profesorAuthLoadingProvider.overrideWithValue(false),
                  profesorGroupsLoadingProvider.overrideWithValue(false),
                  profesorGroupsNoticeProvider.overrideWithValue(null),
                ],
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: UATTheme.lightTheme,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(size: const Size(360, 780)),
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
      if (name == 'docentes-grupos') {
        await tester.tap(find.byIcon(Icons.unfold_more));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
      }

      await expectLater(
        find.byKey(const Key('landing-capture-root')),
        matchesGoldenFile('../../landing-alumnos/assets/$name.png'),
      );
    }, skip: !_captureEnabled);
  }
}
