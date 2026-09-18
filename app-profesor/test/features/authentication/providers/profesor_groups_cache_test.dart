import 'dart:async';
import 'dart:io';

import 'package:appprofesoresuniversidad/features/authentication/providers/profesor_auth_provider.dart';
import 'package:appprofesoresuniversidad/services/api_service.dart';
import 'package:appprofesoresuniversidad/services/auth_storage_service.dart';
import 'package:appprofesoresuniversidad/shared/models/alumno.dart';
import 'package:appprofesoresuniversidad/shared/models/grupo.dart';
import 'package:appprofesoresuniversidad/shared/models/profesor.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';

class _MockApiService extends Mock implements ApiService {}

const _cycle = AcademicCycleContext(
  externalId: 152,
  year: 2026,
  term: 3,
  name: '2026 - 3 OTOÑO',
);
const _student = Alumno(
  id: '1',
  matricula: '1001',
  number: 1,
  name: 'Ana Martínez',
);
const _group = Grupo(
  id: '947699',
  period: '2026 - 3 OTOÑO',
  group: 'A',
  classroom: 'A1',
  name: 'Matemáticas',
  students: [_student],
  studentsCount: 1,
);
const _beacons = [
  {'classroom': 'A1', 'uuid': 'classroom-beacon'},
];
const _profesor = Profesor(
  id: '123',
  name: 'Docente',
  institutionalEmail: 'docente@uat.edu.mx',
);

ProfesorGroupsData _data({
  List<Grupo> grupos = const [_group],
  Set<String> unavailable = const {},
  Set<String> failed = const {},
  AcademicCycleContext cycle = _cycle,
}) => ProfesorGroupsData(
  grupos: grupos,
  beacons: _beacons,
  cycle: cycle,
  unavailableRosterCount: unavailable.length,
  unavailableRosterGroupIds: unavailable,
  failedRosterGroupIds: failed,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storage = AuthStorageService();
  late Directory directory;
  late _MockApiService api;
  late Future<Either<String, ProfesorGroupsData>> Function() load;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('profesor_groups_cache_');
    Hive.init(directory.path);
    await storage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    directory.deleteSync(recursive: true);
  });
  setUp(() async {
    await storage.clearSession();
    await storage.saveSession(token: 'uat-session', profesor: _profesor);
    await storage.saveGrupos([_group], academicCycleId: _cycle.externalId);
    await storage.saveBeacons(_beacons);
    api = _MockApiService();
    load = () async => Right(_data());
    when(() => api.getGruposProfesor(any())).thenAnswer((_) => load());
    when(() => api.withDebugCurrentClass(any(), any())).thenAnswer(
      (call) => (
        grupos: call.positionalArguments[0] as List<Grupo>,
        beacons: call.positionalArguments[1] as List<Map<String, dynamic>>,
      ),
    );
  });

  ProfesorAuthNotifier notifier() {
    final notifier = ProfesorAuthNotifier(api, storage);
    addTearDown(() {
      if (notifier.mounted) notifier.dispose();
    });
    return notifier;
  }

  test(
    'reabrir con una descarga parcial conserva las listas en pantalla y disco',
    () async {
      final missingRoster = _group.copyWith(students: [], studentsCount: 0);
      load = () async => Right(
        _data(
          grupos: [missingRoster],
          unavailable: {_group.id},
          failed: {_group.id},
        ),
      );
      final first = notifier();
      await first.checkStoredSession();
      expect(first.state.grupos.single.students, [_student]);
      expect(first.state.groupsNotice, isNull);
      expect(storage.getGrupos()!.single.students, [_student]);
      expect(storage.getGruposAcademicCycleId(), _cycle.externalId);

      // Simular el cierre del proceso, reabriendo Hive y creando otro notifier.
      first.dispose();
      await Hive.close();
      await storage.init();
      final reopened = notifier();
      await reopened.checkStoredSession();
      expect(reopened.state.grupos.single.students, [_student]);
      expect(reopened.state.groupsNotice, isNull);
    },
  );

  test(
    'una actualización forzada fallida conserva grupos, listas y salones',
    () async {
      final auth = notifier();
      await auth.checkStoredSession();
      load = () async => const Left('Sin conexión');
      await auth.refreshGrupos();
      expect(auth.state.grupos, [_group]);
      expect(storage.getGrupos(), [_group]);
      expect(storage.getBeacons()!.single['uuid'], 'classroom-beacon');
      expect(auth.state.groupsNotice, contains('listas guardadas'));
      expect(
        auth.state.groupsNotice,
        isNot(contains('aún no están disponibles')),
      );
      expect(auth.state.isLoadingGroups, isFalse);
    },
  );

  test('una excepción inesperada tampoco borra la copia local', () async {
    final auth = notifier();
    await auth.checkStoredSession();
    load = () async => throw StateError('Respuesta no válida');
    await auth.refreshGrupos();
    expect(auth.state.grupos, [_group]);
    expect(storage.getGrupos(), [_group]);
    expect(storage.getGruposAcademicCycleId(), _cycle.externalId);
    expect(auth.state.isLoadingGroups, isFalse);
  });

  test(
    'renovar la sesión al reabrir no borra las listas si falla su descarga',
    () async {
      await storage.saveToken(
        'eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjE2MDAwMDAwMDB9.test',
      );
      await storage.cacheUatPasswordForProcess('contraseña-prueba');
      when(
        () => api.loginProfesor(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer(
        (_) async => Right(
          LoginResponse(message: 'OK', profesor: _profesor, token: 'renovada'),
        ),
      );
      load = () async => const Left('Portal temporalmente no disponible');
      final auth = notifier();
      await auth.checkStoredSession();
      expect(auth.state.isAuthenticated, isTrue);
      expect(auth.state.token, 'renovada');
      expect(auth.state.grupos, [_group]);
      expect(storage.getGrupos(), [_group]);
    },
  );

  test(
    'una lista pendiente reutiliza únicamente el grupo del mismo ciclo',
    () async {
      await storage.saveGrupos([_group]); // Caché anterior, sin ID de ciclo.
      load = () async => Right(
        _data(
          grupos: [_group.copyWith(students: [])],
          unavailable: {_group.id},
        ),
      );
      final auth = notifier();
      await auth.checkStoredSession();
      expect(auth.state.grupos.single.students, [_student]);
      expect(auth.state.groupsNotice, isNull);

      load = () async => Right(
        _data(
          grupos: [_group.copyWith(students: [])],
          unavailable: {_group.id},
          cycle: const AcademicCycleContext(
            externalId: 153,
            year: 2027,
            term: 1,
            name: '2027-1',
          ),
        ),
      );
      await auth.refreshGrupos();
      expect(auth.state.grupos.single.students, isEmpty);
      expect(auth.state.groupsNotice, contains('aún no están disponibles'));
    },
  );

  test(
    'un grupo sin ciclo conocido no reutiliza una lista posiblemente antigua',
    () async {
      const unknownPeriod = Grupo(
        id: '947699',
        group: 'A',
        classroom: 'A1',
        name: 'Matemáticas',
        students: [_student],
      );
      await storage.saveGrupos([unknownPeriod]);
      load = () async => Right(
        _data(
          grupos: [_group.copyWith(students: [])],
          unavailable: {_group.id},
        ),
      );
      final auth = notifier();
      await auth.checkStoredSession();
      expect(auth.state.grupos.single.students, isEmpty);
      expect(auth.state.groupsNotice, contains('aún no están disponibles'));
    },
  );

  test(
    'el aviso cuenta solo las listas que siguen faltando, no las recuperadas',
    () async {
      const other = Grupo(
        id: 'other',
        group: 'B',
        classroom: 'A2',
        name: 'Redes',
        students: [],
      );
      load = () async => Right(
        _data(
          grupos: [
            _group.copyWith(students: []),
            other,
          ],
          unavailable: {_group.id, other.id},
        ),
      );
      final auth = notifier();
      await auth.checkStoredSession();
      expect(auth.state.grupos.first.students, [_student]);
      expect(auth.state.groupsNotice, contains('para 1 clase.'));
    },
  );

  test(
    'sin copia local distingue un error de descarga de una lista pendiente',
    () async {
      await storage.clearGrupos();
      load = () async => Right(
        _data(
          grupos: [_group.copyWith(students: [])],
          unavailable: {_group.id},
          failed: {_group.id},
        ),
      );
      final auth = notifier();
      await auth.checkStoredSession();
      expect(auth.state.groupsNotice, contains('No se pudieron descargar'));
      expect(auth.state.groupsNotice, isNot(contains('aún no')));
    },
  );

  test(
    'una respuesta completa reemplaza la lista y elimina clases desasignadas',
    () async {
      final auth = notifier();
      await auth.checkStoredSession();
      const replacement = Alumno(
        id: '2',
        matricula: '1002',
        number: 1,
        name: 'Bruno',
      );
      load = () async => Right(
        _data(
          grupos: [
            _group.copyWith(students: [replacement]),
          ],
        ),
      );
      await auth.refreshGrupos();
      expect(auth.state.grupos.single.students, [replacement]);
      expect(storage.getGrupos()!.single.students, [replacement]);
      load = () async => Right(_data(grupos: []));
      await auth.refreshGrupos();
      expect(auth.state.grupos, isEmpty);
      expect(storage.getGrupos(), isEmpty);
    },
  );

  test(
    'una respuesta tardía no vuelve a guardar listas después de cerrar sesión',
    () async {
      final auth = notifier();
      await auth.checkStoredSession();
      final pending = Completer<Either<String, ProfesorGroupsData>>();
      load = () => pending.future;
      final refresh = auth.refreshGrupos();
      when(
        () => api.logoutProfesor(any()),
      ).thenAnswer((_) async => const Right(true));
      await auth.logout();
      pending.complete(Right(_data()));
      await refresh;
      expect(auth.state.status, ProfesorAuthStatus.unauthenticated);
      expect(storage.getGrupos(), isNull);
      expect(storage.getGruposAcademicCycleId(), isNull);
      expect(storage.getBeacons(), isNull);
    },
  );
}
