import 'package:dartz/dartz.dart';
import 'package:dio/dio.dart';

import '../core/constants/api_constants.dart';
import '../core/utils/utils.dart';
import '../data/models/uat_asistencia_model.dart';
import '../data/models/uat_horario_model.dart';
import '../services/auth_storage_service.dart';
import '../shared/models/alumno.dart';
import '../shared/models/grupo.dart';
import '../shared/models/profesor.dart';
import '../shared/models/sync_status.dart';

class AcademicCycleContext {
  final int externalId;
  final int year;
  final int term;
  final String name;

  const AcademicCycleContext({
    required this.externalId,
    required this.year,
    required this.term,
    required this.name,
  });

  factory AcademicCycleContext.fromActiveResponse(
    Map<String, dynamic> response,
  ) {
    final data = _mapValue(response['data']);
    final active = _mapValue(data['active']);
    final externalId = _intValue(active['externalId']);
    final year = _intValue(active['year']);
    final term = _intValue(active['term']);
    final name = active['name']?.toString().trim() ?? '';

    if (externalId == null ||
        externalId <= 0 ||
        year == null ||
        term == null ||
        term < 1 ||
        term > 3 ||
        name.isEmpty) {
      throw const FormatException(
        'El servidor no devolvio un ciclo escolar activo valido.',
      );
    }

    return AcademicCycleContext(
      externalId: externalId,
      year: year,
      term: term,
      name: name,
    );
  }

  factory AcademicCycleContext.fromUatCatalog(List<dynamic> catalog) {
    final activeCycles =
        catalog
            .map(_mapValue)
            .where((item) => _truthyFlag(item['Sn_Activo']))
            .toList()
          ..sort((left, right) {
            final leftId = _intValue(left['Id_Ciclo_Escolar']) ?? 0;
            final rightId = _intValue(right['Id_Ciclo_Escolar']) ?? 0;
            return rightId.compareTo(leftId);
          });

    if (activeCycles.isEmpty) {
      throw const FormatException(
        'El portal UAT no reporto un ciclo escolar activo.',
      );
    }

    final active = activeCycles.first;
    final externalId = _intValue(active['Id_Ciclo_Escolar']);
    final name =
        [
              active['Ciclo'],
              active['Txt_Ciclo_Escolar'],
              active['Txt_Nombre_Corto'],
            ]
            .map((value) => value?.toString().trim() ?? '')
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final nameMatch = RegExp(r'(\d{4})\D+([123])').firstMatch(name);
    final offset = externalId == null ? -1 : externalId - 150;
    final year =
        int.tryParse(nameMatch?.group(1) ?? '') ??
        (offset >= 0 ? 2026 + (offset ~/ 3) : null);
    final term =
        int.tryParse(nameMatch?.group(2) ?? '') ??
        (offset >= 0 ? (offset % 3) + 1 : null);

    if (externalId == null ||
        externalId <= 0 ||
        year == null ||
        term == null ||
        term < 1 ||
        term > 3) {
      throw const FormatException(
        'El portal UAT devolvio un ciclo escolar activo invalido.',
      );
    }

    return AcademicCycleContext(
      externalId: externalId,
      year: year,
      term: term,
      name: name.isEmpty ? '$year-$term' : name,
    );
  }
}

class ProfesorGroupsData {
  final List<Grupo> grupos;
  final List<Map<String, dynamic>> beacons;
  final AcademicCycleContext cycle;
  final int unavailableRosterCount;
  final Set<String> unavailableRosterGroupIds;
  final Set<String> failedRosterGroupIds;

  const ProfesorGroupsData({
    required this.grupos,
    required this.beacons,
    required this.cycle,
    this.unavailableRosterCount = 0,
    this.unavailableRosterGroupIds = const {},
    this.failedRosterGroupIds = const {},
  });

  bool get classesPending => grupos.isEmpty;
  bool get rostersPending => unavailableRosterCount > 0;
}

class ApiService {
  static void Function()? _globalSessionExpiredHandler;
  late final Dio _presenceDio;
  Future<String?>? _refreshInFlight;
  bool _lastLoginCredentialsRejected = false;
  bool _lastRefreshCredentialsRejected = false;

  bool get lastLoginCredentialsRejected => _lastLoginCredentialsRejected;

  /// Callback que se dispara cuando el servidor retorna 401.
  void Function()? _onSessionExpired;

  void Function()? get onSessionExpired => _onSessionExpired;

  set onSessionExpired(void Function()? callback) {
    _onSessionExpired = callback;
    if (callback != null) _globalSessionExpiredHandler = callback;
  }

  ApiService({void Function()? onSessionExpired}) {
    this.onSessionExpired = onSessionExpired;
    _presenceDio = Dio(
      BaseOptions(
        baseUrl: ApiConstants.baseUrl,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        connectTimeout: Duration(
          milliseconds: ApiConstants.presenceTimeoutDuration,
        ),
        receiveTimeout: Duration(
          milliseconds: ApiConstants.presenceTimeoutDuration,
        ),
        sendTimeout: Duration(
          milliseconds: ApiConstants.presenceTimeoutDuration,
        ),
      ),
    );
    _presenceDio.interceptors.add(
      InterceptorsWrapper(
        onError: (DioException error, ErrorInterceptorHandler handler) async {
          final options = error.requestOptions;
          final canRefresh =
              error.response?.statusCode == 401 &&
              options.extra['skipAutoUatRefresh'] != true &&
              options.extra['uatSessionRetried'] != true;
          if (canRefresh) {
            final refreshedToken = await _refreshSessionOnce();
            if (refreshedToken != null && refreshedToken.isNotEmpty) {
              try {
                options.headers['X-UAT-Session-Id'] = refreshedToken;
                options.extra['uatSessionRetried'] = true;
                final response = await _presenceDio.fetch(options);
                handler.resolve(response);
                return;
              } on DioException catch (retryError) {
                handler.next(retryError);
                return;
              }
            }
            // La pantalla para volver a escribir la contraseña sólo debe
            // aparecer cuando UAT rechazó explícitamente la credencial
            // guardada, no por una expiración normal ni por falta de red.
            if (_lastRefreshCredentialsRejected) {
              (_onSessionExpired ?? _globalSessionExpiredHandler)?.call();
            }
          }
          handler.next(error);
        },
      ),
    );
  }

  Future<Either<String, LoginResponse>> loginProfesor({
    required String email,
    required String password,
  }) => _loginProfesorViaBackendApiRest(email: email, password: password);

  Future<Either<String, LoginResponse>> _loginProfesorViaBackendApiRest({
    required String email,
    required String password,
  }) async {
    _lastLoginCredentialsRejected = false;
    try {
      Logger.info('Intentando login UAT contra backend-apirest para: $email');

      final response = await _presenceDio.post(
        ApiConstants.uatSessions,
        data: {'username': email, 'password': password},
        options: Options(extra: {'skipAutoUatRefresh': true}),
      );
      final data = _asMap(response.data);
      final login = _asMap(data['login']);
      final parametros = _asMap(login['parametros']);
      final sessionId = data['sessionId']?.toString() ?? '';
      final authenticated = data['authenticated'] == true;
      final capabilities = _asMap(data['demoCapabilities']);
      ApiConstants.configureRuntimeMode(
        demoMode: data['demoMode'] == true,
        simulateRoomBeacon: capabilities['simulateRoomBeacon'] == true,
      );
      final message =
          login['mensaje']?.toString() ?? 'Sesion UAT creada correctamente';

      if (sessionId.isEmpty || !authenticated) {
        _lastLoginCredentialsRejected = !authenticated;
        return const Left('No pudimos iniciar sesión. Revisa tus datos.');
      }

      final profesor = Profesor(
        id:
            parametros['Id_Plantilla_AdmonUAT']?.toString() ??
            parametros['Id_Usuario_AdmonUAT']?.toString() ??
            email,
        name:
            parametros['Txt_Usuario_AdmonUAT']?.toString() ??
            email.split('@').first,
        institutionalEmail: email,
      );

      return Right(
        LoginResponse(
          message: message,
          profesor: profesor,
          token: sessionId,
          needsSync: true,
        ),
      );
    } on DioException catch (e) {
      _lastLoginCredentialsRejected = e.response?.statusCode == 401;
      final errorMessage = _handleDioError(e);
      Logger.error('Error de conexion en login UAT: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error('Error inesperado en login UAT', e, stackTrace);
      return Left(_cleanException(e));
    }
  }

  Future<String?> _refreshBackendApiRestSession() async {
    _lastRefreshCredentialsRejected = false;
    final authStorage = AuthStorageService();
    final sessionGeneration = authStorage.sessionGeneration;
    final profesor = authStorage.getProfesor();
    final password = authStorage.getCachedUatPassword();

    if (profesor == null ||
        profesor.institutionalEmail.isEmpty ||
        password == null ||
        password.isEmpty) {
      Logger.error(
        'No se pudo renovar sesion UAT: falta profesor o credencial protegida.',
      );
      return null;
    }

    Logger.info(
      'Renovando sesion UAT para API REST: ${profesor.institutionalEmail}',
    );
    final result = await _loginProfesorViaBackendApiRest(
      email: profesor.institutionalEmail,
      password: password,
    );

    String? refreshedToken;
    await result.fold(
      (error) async {
        _lastRefreshCredentialsRejected = _lastLoginCredentialsRejected;
        Logger.error('No se pudo renovar sesion UAT: $error');
      },
      (login) async {
        if (authStorage.sessionGeneration != sessionGeneration) {
          Logger.info(
            'Se descartó una renovación terminada después del cierre de sesión.',
          );
          return;
        }
        refreshedToken = login.token;
        await authStorage.saveToken(login.token);
        await authStorage.saveProfesor(login.profesor);
      },
    );

    return refreshedToken;
  }

  Future<String?> _refreshSessionOnce() {
    final active = _refreshInFlight;
    if (active != null) return active;
    final refresh = _refreshBackendApiRestSession();
    _refreshInFlight = refresh;
    refresh.whenComplete(() {
      if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
    });
    return refresh;
  }

  Future<Either<String, bool>> logoutProfesor(String sessionId) async {
    try {
      final response = await _presenceDio.delete(
        '${ApiConstants.uatSessions}/$sessionId',
        options: Options(extra: {'skipAutoUatRefresh': true}),
      );
      return Right(_asMap(response.data)['deleted'] == true);
    } on DioException catch (error) {
      final message = _handleDioError(error);
      Logger.error('No se pudo revocar la sesion remota: $message', error);
      return Left(message);
    } catch (error, stackTrace) {
      Logger.error(
        'Error inesperado revocando la sesion remota',
        error,
        stackTrace,
      );
      return Left(_cleanException(error));
    }
  }

  /// Obtiene las clases asignadas al profesor autenticado
  /// Usa el API Gateway como unica entrada a UAT Integration.
  /// Retorna clases, beacons y disponibilidad de listas para el ciclo activo.
  Future<Either<String, ProfesorGroupsData>> getGruposProfesor(String token) =>
      _getGruposProfesorViaBackendApiRest(token);

  Future<Either<String, ProfesorGroupsData>>
  _getGruposProfesorViaBackendApiRest(String sessionId) async {
    try {
      Logger.info('Obteniendo clases UAT desde backend-apirest');

      final profesor = AuthStorageService().getProfesor();
      final idPlantilla = int.tryParse(profesor?.id ?? '');
      if (idPlantilla == null || idPlantilla <= 0) {
        return const Left('No pudimos encontrar la información del profesor.');
      }

      final requestOptions = Options(headers: {'X-UAT-Session-Id': sessionId});
      final cycle = await _loadActiveAcademicCycle(requestOptions);
      final horariosResponse = await _presenceDio.get(
        ApiConstants.uatHorarios,
        queryParameters: {
          'Id_Ciclo_Escolar': cycle.externalId,
          'Id_DES': ApiConstants.uatDefaultIdDes,
        },
        options: requestOptions,
      );
      final gruposResponse = await _presenceDio.get(
        ApiConstants.uatControlGrupos,
        queryParameters: {
          'Id_Des': ApiConstants.uatDefaultIdDes,
          'Id_Ciclo': cycle.externalId,
          'Id_Plantilla': idPlantilla,
        },
        options: requestOptions,
      );

      final horarios = _dataList(horariosResponse.data)
          .map((item) => UatHorarioModel.fromJson(_asMap(item)))
          .where((item) => item.idGrupo > 0)
          .toList();
      final horariosByGrupo = <int, UatHorarioModel>{};
      for (final horario in horarios) {
        horariosByGrupo.update(
          horario.idGrupo,
          (current) => current.merge(horario),
          ifAbsent: () => horario,
        );
      }
      final gruposPortal = _dataList(gruposResponse.data)
          .map((item) => UatGrupoModel.fromJson(_asMap(item)))
          .where((item) => item.idGrupo > 0)
          .toList();

      final grupos = <Grupo>[];
      var unavailableRosterCount = 0;
      final unavailableRosterGroupIds = <String>{};
      final failedRosterGroupIds = <String>{};
      for (final grupoPortal in gruposPortal) {
        final roster = await _loadAlumnosForGroup(
          sessionId: sessionId,
          idGrupo: grupoPortal.idGrupo,
        );
        if (!roster.available) {
          unavailableRosterCount += 1;
          unavailableRosterGroupIds.add(grupoPortal.idGrupo.toString());
        }
        if (roster.failed) {
          failedRosterGroupIds.add(grupoPortal.idGrupo.toString());
        }
        grupos.add(
          grupoPortal.toGrupo(
            students: roster.students,
            horario: horariosByGrupo[grupoPortal.idGrupo],
          ),
        );
      }

      var sharedGroups = <Grupo>[];
      try {
        final sharedResponse = await _presenceDio.get(
          ApiConstants.uatSharedClasses,
          queryParameters: {'year': cycle.year, 'term': cycle.term},
          options: requestOptions,
        );
        sharedGroups = _dataList(
          sharedResponse.data,
        ).map((item) => Grupo.fromJson(_asMap(item))).toList();
      } on DioException catch (error) {
        Logger.error('No se pudieron cargar las clases compartidas', error);
      }
      for (final sharedGroup in sharedGroups) {
        final idGrupo = int.tryParse(sharedGroup.id);
        final roster = sharedGroup.students.isNotEmpty
            ? (students: sharedGroup.students, available: true, failed: false)
            : idGrupo == null
            ? (students: const <Alumno>[], available: false, failed: false)
            : await _loadAlumnosForGroup(
                sessionId: sessionId,
                idGrupo: idGrupo,
              );
        if (!roster.available) {
          unavailableRosterCount += 1;
          unavailableRosterGroupIds.add(sharedGroup.id);
        }
        if (roster.failed) failedRosterGroupIds.add(sharedGroup.id);
        grupos.add(
          sharedGroup.copyWith(
            students: roster.students,
            studentsCount: roster.students.length,
          ),
        );
      }

      var beacons = await _resolveBeaconsForGroups(grupos);
      await _loadAttendanceSettings(
        AuthStorageService().getToken() ?? sessionId,
      );
      final debugData = withDebugCurrentClass(grupos, beacons);
      Logger.info(
        'Clases del ciclo ${cycle.name}: ${gruposPortal.length} oficiales, '
        '${sharedGroups.length} compartidas, $unavailableRosterCount listas '
        'pendientes, beacons: ${debugData.beacons.length}',
      );
      return Right(
        ProfesorGroupsData(
          grupos: debugData.grupos,
          beacons: debugData.beacons,
          cycle: cycle,
          unavailableRosterCount: unavailableRosterCount,
          unavailableRosterGroupIds: unavailableRosterGroupIds,
          failedRosterGroupIds: failedRosterGroupIds,
        ),
      );
    } on DioException catch (e) {
      final errorMessage = _handleDioError(e);
      Logger.error('Error de conexion obteniendo clases UAT: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error('Error inesperado obteniendo clases UAT', e, stackTrace);
      return Left(_cleanException(e));
    }
  }

  Future<AcademicCycleContext> _loadActiveAcademicCycle(
    Options requestOptions,
  ) async {
    try {
      final response = await _presenceDio.get(
        ApiConstants.uatActiveAcademicCycle,
        options: requestOptions,
      );
      return AcademicCycleContext.fromActiveResponse(_asMap(response.data));
    } on DioException catch (error) {
      // Compatibilidad durante un despliegue gradual: versiones anteriores del
      // BFF no exponen el ciclo centralizado, pero el catalogo UAT si indica el
      // ciclo activo. Nunca se vuelve al ID fijo de un ciclo anterior.
      if (error.response?.statusCode != 404) rethrow;
      final response = await _presenceDio.get(
        ApiConstants.uatCatalogoCiclos,
        options: requestOptions,
      );
      return AcademicCycleContext.fromUatCatalog(_dataList(response.data));
    }
  }

  Future<void> _loadAttendanceSettings(String sessionId) async {
    try {
      final response = await _presenceDio.get(
        ApiConstants.uatAttendanceSettings,
        options: Options(headers: {'X-UAT-Session-Id': sessionId}),
      );
      final data = _asMap(_asMap(response.data)['data']);
      final tolerance = int.tryParse(
        data['teacherAttendanceToleranceMinutes']?.toString() ?? '',
      );
      if (tolerance != null) {
        await AuthStorageService().saveAttendanceTolerance(tolerance);
      }
    } on DioException catch (error) {
      Logger.error(
        'No se pudo actualizar la tolerancia; se conserva la local',
        error,
      );
    }
  }

  ({List<Grupo> grupos, List<Map<String, dynamic>> beacons})
  withDebugCurrentClass(
    List<Grupo> grupos,
    List<Map<String, dynamic>> beacons,
  ) {
    if (!ApiConstants.isDemoMode || !ApiConstants.debugExtraCurrentClass) {
      return (grupos: grupos, beacons: beacons);
    }

    final now = DateTime.now();
    final debugClassHours = ApiConstants.debugExtraClassHours < 1
        ? 1
        : ApiConstants.debugExtraClassHours;
    final start = now.subtract(const Duration(minutes: 10));
    final end = start.add(Duration(hours: debugClassHours));
    final scheduleValue = '${_formatHour(start)}-${_formatHour(end)}';
    final dayKeys = _debugAllDayKeys();
    final schedule = <String, String?>{
      for (final key in dayKeys) key: scheduleValue,
    };

    final debugGroup = Grupo(
      id: ApiConstants.debugExtraClassCode,
      code: ApiConstants.debugExtraClassCode,
      groupLetter: ApiConstants.debugExtraClassGroupLetter,
      period: ApiConstants.debugExtraClassPeriod,
      group: ApiConstants.debugExtraClassGroupLetter,
      classroom: ApiConstants.debugExtraClassroom,
      name: ApiConstants.debugExtraClassName,
      level: 'DEBUG',
      students: const [
        Alumno(
          id: '99000101',
          matricula: 'DEBUG001',
          number: 1,
          name: 'Alumno Debug 1',
        ),
        Alumno(
          id: '99000102',
          matricula: 'DEBUG002',
          number: 2,
          name: 'Alumno Debug 2',
        ),
        Alumno(
          id: '99000103',
          matricula: 'DEBUG003',
          number: 3,
          name: 'Alumno Debug 3',
        ),
      ],
      studentsCount: 3,
      schedule: schedule,
      source: 'DEBUG',
    );

    final filteredGroups = grupos
        .where((grupo) => grupo.code != ApiConstants.debugExtraClassCode)
        .toList();
    final filteredBeacons = beacons.where((beacon) {
      final classroom = beacon['classroom']?.toString();
      final classroomKey = beacon['classroomKey']?.toString();
      return classroom != ApiConstants.debugExtraClassroom &&
          classroomKey !=
              AuthStorageService.classroomKey(ApiConstants.debugExtraClassroom);
    }).toList();

    final debugBeacon = {
      'classroom': ApiConstants.debugExtraClassroom,
      'classroomKey': AuthStorageService.classroomKey(
        ApiConstants.debugExtraClassroom,
      ),
      'uuid': ApiConstants.debugExtraBeaconUuid,
      'source': 'DEBUG',
    };

    Logger.info(
      '[DEBUG] Materia extra actual agregada: '
      '${debugGroup.name}, salon=${debugGroup.classroom}, '
      'horario=$scheduleValue, beacon=${ApiConstants.debugExtraBeaconUuid}',
    );

    return (
      grupos: [debugGroup, ...filteredGroups],
      beacons: [debugBeacon, ...filteredBeacons],
    );
  }

  List<String> _debugAllDayKeys() {
    return const [
      'monday',
      'lunes',
      'tuesday',
      'martes',
      'wednesday',
      'miercoles',
      'jueves',
      'thursday',
      'friday',
      'viernes',
      'saturday',
      'sabado',
      'sunday',
      'domingo',
    ];
  }

  String _formatHour(DateTime value) {
    return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  Future<({List<Alumno> students, bool available, bool failed})>
  _loadAlumnosForGroup({
    required String sessionId,
    required int idGrupo,
  }) async {
    try {
      final requestOptions = Options(headers: {'X-UAT-Session-Id': sessionId});
      final semanasResponse = await _presenceDio.get(
        ApiConstants.uatControlSemanas,
        queryParameters: {'Id_Grupo': idGrupo},
        options: requestOptions,
      );
      final semanas = _dataList(semanasResponse.data)
          .map((item) => UatSemanaModel.fromJson(_asMap(item)))
          .where((item) => item.isValid)
          .toList();

      for (final semana in semanas) {
        final asistenciaResponse = await _presenceDio.get(
          ApiConstants.uatControlAsistenciaGrupo,
          queryParameters: {
            'Id_Grupo': idGrupo,
            'fec_ini': semana.fecIni,
            'fec_fin': semana.fecFin,
          },
          options: requestOptions,
        );
        final envelope = _asMap(asistenciaResponse.data);
        final data = _asMap(envelope['data']);
        final asistencia = UatAsistenciaGrupoModel.fromJson(
          data.isNotEmpty ? data : envelope,
        );
        if (asistencia.alumnos.isNotEmpty) {
          return (
            students: asistencia.alumnos
                .map((alumno) => alumno.toAlumno())
                .toList(),
            available: true,
            failed: false,
          );
        }
      }
    } catch (e, stackTrace) {
      Logger.error(
        'No se pudieron cargar alumnos del grupo $idGrupo',
        e,
        stackTrace,
      );
      return (students: const <Alumno>[], available: false, failed: true);
    }

    return (students: const <Alumno>[], available: false, failed: false);
  }

  /// Encola una nueva cosecha academica usando la sesion UAT vigente.
  Future<Either<String, String>> forceSync({required String token}) async {
    try {
      final syncResponse = await _presenceDio.post(
        ApiConstants.uatProfessorSync,
        options: Options(headers: {'X-UAT-Session-Id': token}),
      );
      final groups = await getGruposProfesor(token);
      final result = groups.fold<Either<String, String>>(
        (error) => Left(error),
        (data) => Right(
          '${_asMap(syncResponse.data)['message'] ?? 'Sincronizacion academica encolada.'} '
          '${data.grupos.length} clases cargadas.',
        ),
      );
      return result;
    } on DioException catch (e) {
      final errorMessage = _handleDioError(e);
      Logger.error('Error encolando sincronizacion: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error('Error inesperado en sincronizacion', e, stackTrace);
      return Left(_cleanException(e));
    }
  }

  Future<Either<String, SyncStatusResponse>> getSyncStatus(String token) async {
    return Right(
      SyncStatusResponse(
        status: 'COMPLETED',
        step: 5,
        totalSteps: 5,
        stepDescription: 'Datos disponibles desde servicios academicos',
        percentage: 100,
        message: 'Sincronizacion completada',
        completedAt: DateTime.now(),
      ),
    );
  }

  Future<Either<String, Map<String, dynamic>>> getSyncStatusV2(
    String token,
  ) async {
    return Right({
      'hasSync': true,
      'status': 'COMPLETED',
      'step': 5,
      'totalSteps': 5,
      'percentage': 100,
      'message': 'Datos disponibles desde servicios academicos',
      'retryAvailable': false,
    });
  }

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
    await refreshClassroomCatalog();
    return _uploadAttendanceViaBackendApiRest(
      token: token,
      clientRecordId: clientRecordId,
      groupId: groupId,
      code: code,
      groupLetter: groupLetter,
      period: period,
      groupName: groupName,
      classroom: classroom,
      level: level,
      schedule: schedule,
      date: date,
      attendances: attendances,
    );
  }

  Future<Either<String, Map<String, dynamic>>>
  _uploadAttendanceViaBackendApiRest({
    required String token,
    required String clientRecordId,
    String? groupId,
    required String code,
    String groupLetter = '',
    String period = '',
    String? groupName,
    String? classroom,
    String? level,
    Map<String, String?>? schedule,
    required DateTime date,
    required List<Map<String, dynamic>> attendances,
    bool debugReportOnly = false,
    bool retrySession = true,
  }) async {
    try {
      final idGrupo = int.tryParse(groupId ?? '') ?? int.tryParse(code);
      if (idGrupo == null || idGrupo <= 0) {
        return const Left('No pudimos preparar la información del grupo.');
      }

      final asistencia = <Map<String, dynamic>>[];
      for (final item in attendances) {
        final idAlumno =
            int.tryParse(
              item['id_alumno']?.toString() ??
                  item['idAlumno']?.toString() ??
                  item['studentId']?.toString() ??
                  item['id']?.toString() ??
                  '',
            ) ??
            0;
        if (idAlumno <= 0) continue;
        asistencia.add({
          'id_alumno': idAlumno,
          // UAT expects the daily pass number here, never the roster index.
          'num_pase_lista': 1,
          'num_dia':
              int.tryParse(item['num_dia']?.toString() ?? '') ?? date.weekday,
          'sn_asistencia':
              item['sn_asistencia'] == true ||
              item['snAsistencia'] == true ||
              item['present'] == true ||
              item['isPresent'] == true ||
              item['status']?.toString() == 'PRESENT' ||
              item['status']?.toString() == 'LATE',
        });
      }

      if (asistencia.isEmpty && !debugReportOnly) {
        return const Left('No hay alumnos validos para subir asistencia.');
      }

      final formattedDate =
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

      if (debugReportOnly) {
        Logger.info(
          '[DEBUG] Registrando asistencia para reportes sin enviar a UAT/API REST externa. '
          'groupId=$idGrupo, code=$code, groupLetter=$groupLetter, period=$period, '
          'date=$formattedDate, alumnos=${asistencia.length}, '
          'presenceAuthority=attendance-service',
        );
      }

      final response = await _presenceDio.post(
        ApiConstants.uatAsistenciaGuardar,
        data: {
          'ClientRecordId': clientRecordId,
          'Id_Grupo': idGrupo,
          'Fec_Ini': formatUatWeekStart(date),
          if (debugReportOnly) ...{
            'DebugReportOnly': true,
            'Code': code,
            'GroupLetter': groupLetter,
            'Period': period,
            if (groupName != null) 'GroupName': groupName,
            if (classroom != null) 'Classroom': classroom,
            if (level != null) 'Level': level,
            if (schedule != null) 'Schedule': schedule,
            'CreateMissingGroup': true,
            'Date': formattedDate,
          },
          'Asistencia': asistencia,
        },
        options: Options(headers: {'X-UAT-Session-Id': token}),
      );

      final responseMap = _asMap(response.data);
      if (debugReportOnly) {
        responseMap['debug'] = true;
        responseMap['skippedApiRestUpload'] = true;
        responseMap['reportVisible'] = true;
      }
      return Right(responseMap);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && retrySession) {
        final refreshedToken = await _refreshBackendApiRestSession();
        if (refreshedToken != null && refreshedToken.isNotEmpty) {
          Logger.info('Reintentando subida con sesion UAT renovada.');
          return _uploadAttendanceViaBackendApiRest(
            token: refreshedToken,
            clientRecordId: clientRecordId,
            groupId: groupId,
            code: code,
            groupLetter: groupLetter,
            period: period,
            groupName: groupName,
            classroom: classroom,
            level: level,
            schedule: schedule,
            date: date,
            attendances: attendances,
            debugReportOnly: debugReportOnly,
            retrySession: false,
          );
        }
      }

      final errorMessage = _handleDioError(e);
      Logger.error('Error subiendo asistencia UAT: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error('Error inesperado subiendo asistencia UAT', e, stackTrace);
      return Left(_cleanException(e));
    }
  }

  Future<Map<String, bool>> checkSyncedRecords({
    required String token,
    required List<Map<String, String>> records,
  }) async {
    final statuses = await checkSyncedRecordsStatus(
      token: token,
      records: records,
    );
    return statuses.map((key, value) => MapEntry(key, value == 'COMPLETED'));
  }

  Future<Map<String, String>> checkSyncedRecordsStatus({
    required String token,
    required List<Map<String, String>> records,
  }) async {
    if (records.isEmpty) return {};

    try {
      final recordsWithIds = records
          .where((record) => record['clientRecordId']?.isNotEmpty == true)
          .toList();
      if (recordsWithIds.isEmpty) return {};
      final response = await _presenceDio.post(
        ApiConstants.uatAttendanceRecordStatuses,
        data: {
          'clientRecordIds': recordsWithIds
              .map((record) => record['clientRecordId'])
              .toList(),
        },
        options: Options(headers: {'X-UAT-Session-Id': token}),
      );
      final data = _asMap(response.data)['data'] as List<dynamic>? ?? [];
      final lookupKeys = {
        for (final record in recordsWithIds)
          record['clientRecordId']!: '${record['groupId']}_${record['date']}',
      };
      final statuses = <String, String>{};
      for (final item in data) {
        final map = Map<String, dynamic>.from(item as Map);
        final lookupKey = lookupKeys[map['clientRecordId']?.toString()];
        final status = map['status']?.toString();
        if (lookupKey != null && status != null) statuses[lookupKey] = status;
      }
      return statuses;
    } catch (e, stackTrace) {
      Logger.error(
        'Error verificando asistencias sincronizadas',
        e,
        stackTrace,
      );
      return {};
    }
  }

  String _cleanException(Object error) {
    return 'No pudimos completar la operación. Intenta de nuevo.';
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  List<dynamic> _dataList(Object? value) {
    final envelope = _asMap(value);
    final data = envelope['data'];
    if (data is List) return data;
    if (value is List) return value;
    return const [];
  }

  Future<Either<String, List<Map<String, dynamic>>>> resolveClassroomBeacons({
    required List<String> classrooms,
  }) async {
    try {
      final normalizedClassrooms = classrooms
          .map((classroom) => classroom.trim().toUpperCase())
          .where((classroom) => classroom.isNotEmpty)
          .toSet()
          .toList();

      if (normalizedClassrooms.isEmpty) return const Right([]);

      Logger.info(
        'Resolviendo beacons mediante Attendance para ${normalizedClassrooms.length} salones',
      );

      final uatSessionId = AuthStorageService().getToken();
      if (uatSessionId == null || uatSessionId.isEmpty) {
        return const Left('Tu sesión expiró. Inicia sesión de nuevo.');
      }

      final response = await _presenceDio.post(
        ApiConstants.uatBeaconsResolve,
        data: {'classrooms': normalizedClassrooms},
        options: Options(headers: {'X-UAT-Session-Id': uatSessionId}),
      );

      if (response.statusCode == 200) {
        final data = response.data['data'] as List<dynamic>? ?? [];
        final missing = response.data['missing'] as List<dynamic>? ?? [];
        Logger.info(
          'Beacons resueltos: ${data.length}, salones sin beacon: ${missing.length}',
        );
        return Right(
          data.map((item) => Map<String, dynamic>.from(item as Map)).toList(),
        );
      }

      return const Left('No pudimos preparar la verificación del aula.');
    } on DioException catch (e) {
      final errorMessage = _handleDioError(e);
      Logger.error('Error obteniendo beacons de salones: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error('Error inesperado obteniendo beacons', e, stackTrace);
      return const Left('No pudimos preparar la verificación del aula.');
    }
  }

  Future<Either<String, List<Map<String, dynamic>>>>
  listAvailableClassroomBeacons() async {
    try {
      final uatSessionId = AuthStorageService().getToken();
      if (uatSessionId == null || uatSessionId.isEmpty) {
        return const Left('Tu sesión expiró. Inicia sesión de nuevo.');
      }

      final response = await _presenceDio.get(
        ApiConstants.uatAvailableBeacons,
        options: Options(headers: {'X-UAT-Session-Id': uatSessionId}),
      );
      if (response.statusCode == 200) {
        final data = response.data['data'] as List<dynamic>? ?? [];
        final beacons = data
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        await AuthStorageService().saveBeacons(beacons);
        return Right(beacons);
      }
      return const Left('No pudimos cargar los salones disponibles.');
    } on DioException catch (e) {
      final errorMessage = _handleDioError(e);
      Logger.error('Error obteniendo salones disponibles: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error(
        'Error inesperado obteniendo salones disponibles',
        e,
        stackTrace,
      );
      return const Left('No pudimos cargar los salones disponibles.');
    }
  }

  /// Actualiza en el equipo el catálogo completo de salones. Las operaciones
  /// en línea de asistencia lo invocan primero, pero una falla no bloquea el
  /// uso de la última copia local.
  Future<void> refreshClassroomCatalog() async {
    final result = await listAvailableClassroomBeacons();
    result.fold(
      (error) => Logger.error(
        'No se pudo actualizar el catálogo completo de salones: $error',
      ),
      (beacons) => Logger.info(
        '${beacons.length} salones actualizados antes de la operación en línea',
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _resolveBeaconsForGroups(
    List<Grupo> grupos,
  ) async {
    final completeCatalog = await listAvailableClassroomBeacons();
    if (completeCatalog.isRight()) {
      return completeCatalog.getOrElse(() => const <Map<String, dynamic>>[]);
    }

    final classrooms = grupos
        .map((grupo) => grupo.classroom)
        .where((classroom) => classroom.trim().isNotEmpty)
        .toSet()
        .toList();
    if (classrooms.isEmpty) return const <Map<String, dynamic>>[];

    final result = await resolveClassroomBeacons(classrooms: classrooms);
    return result.fold((error) {
      Logger.error('No se pudieron resolver beacons de grupos: $error');
      return const <Map<String, dynamic>>[];
    }, (beacons) => beacons);
  }

  Future<Either<String, List<Map<String, dynamic>>>>
  resolveStudentDeviceBindings({required List<String> matriculas}) async {
    try {
      final normalizedMatriculas = matriculas
          .map((matricula) => matricula.trim().toUpperCase())
          .where((matricula) => matricula.isNotEmpty)
          .toSet()
          .toList();

      if (normalizedMatriculas.isEmpty) return const Right([]);

      final uatSessionId = AuthStorageService().getToken();
      if (uatSessionId == null || uatSessionId.isEmpty) {
        return const Left('Tu sesión expiró. Inicia sesión de nuevo.');
      }

      final response = await _presenceDio.post(
        ApiConstants.uatDeviceBindingsResolve,
        data: {'matriculas': normalizedMatriculas},
        options: Options(headers: {'X-UAT-Session-Id': uatSessionId}),
      );

      if (response.statusCode == 200) {
        final data = response.data['data'] as List<dynamic>? ?? [];
        return Right(
          data.map((item) => Map<String, dynamic>.from(item as Map)).toList(),
        );
      }

      return const Left('No pudimos preparar la detección automática.');
    } on DioException catch (e) {
      final errorMessage = _handleDioError(e);
      Logger.error('Error obteniendo UUIDs de alumnos: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error(
        'Error inesperado resolviendo UUIDs de alumnos',
        e,
        stackTrace,
      );
      return const Left('No pudimos preparar la detección automática.');
    }
  }

  Future<Either<String, Map<String, dynamic>>> recordProfessorBeaconEntry({
    required String token,
    required String externalGroupId,
    required DateTime detectedAt,
    required String beaconUuid,
    int? rssi,
    double? distance,
    String? bluetoothAddress,
  }) async {
    await refreshClassroomCatalog();
    try {
      final response = await _presenceDio.post(
        ApiConstants.uatPresenceEntry,
        data: {
          'externalGroupId': externalGroupId,
          'clientDetectedAt': detectedAt.toUtc().toIso8601String(),
          'beaconUuid': beaconUuid,
          if (rssi != null) 'rssi': rssi,
          if (distance != null) 'distance': distance,
          if (bluetoothAddress != null) 'bluetoothAddress': bluetoothAddress,
        },
        options: Options(headers: {'X-UAT-Session-Id': token}),
      );

      if ((response.statusCode ?? 0) >= 200 &&
          (response.statusCode ?? 0) < 300) {
        return Right(response.data as Map<String, dynamic>);
      }

      return const Left('No pudimos guardar la entrada. Intenta de nuevo.');
    } on DioException catch (e) {
      final errorMessage = _handleDioError(e);
      Logger.error('Error registrando entrada por beacon: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error(
        'Error inesperado registrando entrada por beacon',
        e,
        stackTrace,
      );
      return const Left('No pudimos guardar la entrada. Intenta de nuevo.');
    }
  }

  Future<Either<String, Map<String, dynamic>>> recordProfessorExit({
    required String token,
    required String externalGroupId,
    required DateTime detectedAt,
  }) async {
    await refreshClassroomCatalog();
    try {
      final response = await _presenceDio.post(
        ApiConstants.uatPresenceExit,
        data: {
          'externalGroupId': externalGroupId,
          'clientDetectedAt': detectedAt.toUtc().toIso8601String(),
        },
        options: Options(headers: {'X-UAT-Session-Id': token}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return Right(response.data as Map<String, dynamic>);
      }

      return const Left('No pudimos guardar la salida. Intenta de nuevo.');
    } on DioException catch (e) {
      final errorMessage = _handleDioError(e);
      Logger.error('Error registrando salida del profesor: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error(
        'Error inesperado registrando salida del profesor',
        e,
        stackTrace,
      );
      return const Left('No pudimos guardar la salida. Intenta de nuevo.');
    }
  }

  Future<Either<String, Map<String, dynamic>>> recordStudentBeaconDetections({
    required String token,
    required String externalGroupId,
    required List<Map<String, dynamic>> detections,
  }) async {
    await refreshClassroomCatalog();
    try {
      final response = await _presenceDio.post(
        ApiConstants.uatStudentPresence,
        data: {'externalGroupId': externalGroupId, 'detections': detections},
        options: Options(headers: {'X-UAT-Session-Id': token}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return Right(response.data as Map<String, dynamic>);
      }

      return const Left(
        'No pudimos guardar la detección de los alumnos. Intenta de nuevo.',
      );
    } on DioException catch (e) {
      final errorMessage = _handleDioError(e);
      Logger.error('Error registrando beacons de alumnos: $errorMessage', e);
      return Left(errorMessage);
    } catch (e, stackTrace) {
      Logger.error(
        'Error inesperado registrando beacons de alumnos',
        e,
        stackTrace,
      );
      return const Left(
        'No pudimos guardar la detección de los alumnos. Intenta de nuevo.',
      );
    }
  }

  /// Maneja errores de Dio y devuelve mensajes amigables
  String _handleDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return 'No pudimos conectar. Revisa tu internet e intenta de nuevo.';
      case DioExceptionType.sendTimeout:
        return 'El envío tardó demasiado. Revisa tu internet e intenta de nuevo.';
      case DioExceptionType.receiveTimeout:
        return 'No recibimos respuesta a tiempo. Intenta de nuevo más tarde.';
      case DioExceptionType.badResponse:
        switch (e.response?.statusCode) {
          case 400:
            return 'Revisa la información e intenta de nuevo.';
          case 401:
            return 'Tu sesión expiró. Inicia sesión de nuevo.';
          case 403:
            return 'No puedes realizar esta acción con tu cuenta.';
          case 404:
            return 'No encontramos la información solicitada.';
          case 409:
            return 'Esta asistencia ya se está enviando.';
          case 500:
          case 502:
          case 503:
            return 'El servicio no está disponible en este momento. Intenta más tarde.';
          case 504:
            return 'No recibimos respuesta a tiempo. Intenta de nuevo.';
          default:
            return 'No pudimos completar la operación. Intenta de nuevo más tarde.';
        }
      case DioExceptionType.cancel:
        return 'La operación se canceló.';
      case DioExceptionType.connectionError:
        return 'No pudimos conectar. Revisa tu internet e intenta de nuevo.';
      default:
        return 'Hubo un problema de conexión. Revisa tu internet e intenta de nuevo.';
    }
  }
}

Map<String, dynamic> _mapValue(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '');
}

bool _truthyFlag(Object? value) {
  if (value == true || value == 1) return true;
  if (value is! String) return false;
  return const {
    '1',
    'true',
    'si',
    'sí',
    'activo',
  }.contains(value.trim().toLowerCase());
}
