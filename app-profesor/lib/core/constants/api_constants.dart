import '../utils/utils.dart';

/// Endpoints publicos expuestos por el API Gateway de Presencia.
class ApiConstants {
  // Punto de entrada unico. El cliente movil no conoce URLs internas.
  // For Android emulator use:
  // --dart-define=API_BASE_URL=http://10.0.2.2:3000
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://dashboarduat.presenciauat.fit',
  );
  static const bool presenciaDebugMode = bool.fromEnvironment(
    'PRESENCIA_DEBUG_MODE',
    defaultValue: false,
  );
  static const bool debugExtraCurrentClass = bool.fromEnvironment(
    'PRESENCIA_DEBUG_EXTRA_CURRENT_CLASS',
    defaultValue: false,
  );
  static const bool debugSimulateRoomBeacon = bool.fromEnvironment(
    'PRESENCIA_DEBUG_SIMULATE_ROOM_BEACON',
    defaultValue: false,
  );
  static bool runtimeDemoMode = false;
  static bool runtimeSimulateRoomBeacon = false;
  // Respaldo local hasta que la sincronizacion obtenga el valor persistido
  // configurado por el coordinador.
  static const int defaultTeacherAttendanceToleranceMinutes = 10;
  static int _teacherAttendanceToleranceMinutes =
      defaultTeacherAttendanceToleranceMinutes;

  static bool get isDemoMode => presenciaDebugMode || runtimeDemoMode;
  static bool get shouldSimulateRoomBeacon =>
      runtimeSimulateRoomBeacon ||
      (presenciaDebugMode && debugSimulateRoomBeacon);
  static int get teacherAttendanceToleranceMinutes =>
      _teacherAttendanceToleranceMinutes;

  static void configureAttendanceTolerance(int value) {
    _teacherAttendanceToleranceMinutes = value.clamp(0, 120).toInt();
    Logger.info(
      'Tolerancia de asistencia del profesor: '
      '$_teacherAttendanceToleranceMinutes min',
    );
  }

  static void configureRuntimeMode({
    required bool demoMode,
    bool simulateRoomBeacon = false,
  }) {
    runtimeDemoMode = demoMode;
    runtimeSimulateRoomBeacon = demoMode && simulateRoomBeacon;
    Logger.info(
      'Runtime mode: ${isDemoMode ? 'demo' : 'uat'}; '
      'simulated beacon: $shouldSimulateRoomBeacon',
    );
  }

  static const String debugExtraClassCode = String.fromEnvironment(
    'PRESENCIA_DEBUG_EXTRA_CLASS_CODE',
    defaultValue: '990001',
  );
  static const String debugExtraClassGroupLetter = String.fromEnvironment(
    'PRESENCIA_DEBUG_EXTRA_CLASS_GROUP',
    defaultValue: 'DBG',
  );
  static const String debugExtraClassPeriod = String.fromEnvironment(
    'PRESENCIA_DEBUG_EXTRA_CLASS_PERIOD',
    defaultValue: '2026-2',
  );
  static const String debugExtraClassroom = String.fromEnvironment(
    'PRESENCIA_DEBUG_EXTRA_CLASSROOM',
    defaultValue: 'DEBUG-101',
  );
  static const String debugExtraClassName = String.fromEnvironment(
    'PRESENCIA_DEBUG_EXTRA_CLASS_NAME',
    defaultValue: 'DEBUG ASISTENCIA ACTUAL',
  );
  static const int debugExtraClassHours = int.fromEnvironment(
    'PRESENCIA_DEBUG_EXTRA_CLASS_HOURS',
    defaultValue: 4,
  );
  static const String debugExtraBeaconUuid = String.fromEnvironment(
    'PRESENCIA_DEBUG_EXTRA_BEACON_UUID',
    defaultValue: '11111111-2222-4333-8444-555555555555',
  );
  static const int timeoutDuration = int.fromEnvironment(
    'API_TIMEOUT',
    defaultValue: 30000,
  );
  static const int presenceTimeoutDuration = int.fromEnvironment(
    'PRESENCIA_API_TIMEOUT',
    defaultValue: timeoutDuration,
  );
  static const int studentBindingsRefreshSeconds = int.fromEnvironment(
    'STUDENT_BINDINGS_REFRESH_SECONDS',
    defaultValue: 30,
  );
  static const String appLogIngestionKey = String.fromEnvironment(
    'PRESENCIA_LOG_INGESTION_KEY',
    defaultValue: 'development-app-log-ingestion-key-change-me',
  );
  static const String appVersion = String.fromEnvironment(
    'PRESENCIA_APP_VERSION',
    defaultValue: '1.0.0',
  );
  static const String appBuildNumber = String.fromEnvironment(
    'PRESENCIA_APP_BUILD_NUMBER',
    defaultValue: '1',
  );
  static const int uatDefaultIdCiclo = int.fromEnvironment(
    'UAT_ID_CICLO',
    defaultValue: 150,
  );
  static const int uatDefaultIdDes = int.fromEnvironment(
    'UAT_ID_DES',
    defaultValue: 12,
  );
  static const int uatAcademicYear = int.fromEnvironment(
    'UAT_ACADEMIC_YEAR',
    defaultValue: 2026,
  );
  static const int uatAcademicTerm = int.fromEnvironment(
    'UAT_ACADEMIC_TERM',
    defaultValue: 1,
  );

  static void printConfig() {
    Logger.info('API Configuration:');
    Logger.info('   API Gateway baseUrl: $baseUrl');
    Logger.info('   Debug mode: $isDemoMode');
    Logger.info('   Debug extra current class: $debugExtraCurrentClass');
    Logger.info('   Debug simulate room beacon: $debugSimulateRoomBeacon');
    Logger.info('   Debug extra class hours: $debugExtraClassHours');
    Logger.info('   timeout: $timeoutDuration ms');
    Logger.info('   UAT cycle: $uatDefaultIdCiclo');
    Logger.info('   UAT DES: $uatDefaultIdDes');
    Logger.info('   UAT academic cycle: $uatAcademicYear-$uatAcademicTerm');
  }

  // UAT Integration/BFF, siempre atravesando el API Gateway.
  static const String uatSessions = '/api/uat/sessions';
  static const String uatProfessorSync = '/api/uat/profesor/sync';
  static const String uatActiveAcademicCycle =
      '/api/uat/profesor/ciclo-escolar';
  static const String uatAttendanceSettings =
      '/api/uat/profesor/asistencia/configuracion';
  static const String uatHorarios = '/api/uat/profesor/consultas/horarios';
  static const String uatExamenes = '/api/uat/profesor/consultas/examenes';
  static const String uatCatalogoNiveles =
      '/api/uat/catalogos/niveles-educativos';
  static const String uatCatalogoCampus = '/api/uat/catalogos/campus';
  static const String uatCatalogoDes = '/api/uat/catalogos/des';
  static const String uatCatalogoCiclos = '/api/uat/catalogos/ciclos-escolares';
  static const String uatControlGrupos =
      '/api/uat/profesor/control-asistencia/grupos';
  static const String uatSharedClasses = '/api/uat/profesor/clases-compartidas';
  static const String uatDeviceBindingsResolve =
      '/api/uat/profesor/device-bindings/resolve';
  static const String uatBeaconsResolve = '/api/uat/profesor/beacons/resolve';
  static const String uatAvailableBeacons = '/api/uat/profesor/beacons';
  static const String uatPresenceEntry = '/api/uat/profesor/presencia/entrada';
  static const String uatPresenceExit = '/api/uat/profesor/presencia/salida';
  static const String uatStudentPresence =
      '/api/uat/profesor/presencia/alumnos';
  static const String uatControlSemanas =
      '/api/uat/profesor/control-asistencia/semanas';
  static const String uatControlAsistenciaGrupo =
      '/api/uat/profesor/control-asistencia/asistencia-grupo';
  static const String uatControlGuardarAsistencias =
      '/api/uat/profesor/control-asistencia/asistencias';
  static const String uatAsistenciaGuardar = '/api/uat/asistencia/guardar';
  static const String uatAttendanceRecordStatuses =
      '/api/uat/asistencia/registros/estado';
}
