import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config/app_environment.dart';
import 'models/student_academic_profile.dart';
import 'services/local_storage_service.dart';
import 'services/ble_advertiser_service.dart';
import 'services/attendance_session_service.dart';
import 'services/student_device_binding_service.dart';
import 'services/student_auth_service.dart';
import 'services/app_log_service.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/app_splash_screen.dart';

void main() {
  runZonedGuarded<Future<void>>(_bootstrap, (error, stackTrace) {
    unawaited(
      AppLogService.instance.record(
        level: 'FATAL',
        eventName: 'app.zone_unhandled_error',
        message: 'Error no controlado en la zona principal.',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  try {
    await AppLogService.instance.initialize(
      baseUrl: AppEnvironment.presenceApiBaseUrl,
      ingestionKey: AppEnvironment.appLogIngestionKey,
      application: 'STUDENT',
      appVersion: AppEnvironment.appVersion,
      buildNumber: AppEnvironment.appBuildNumber,
    );
  } catch (error, stackTrace) {
    // La telemetría nunca debe impedir que el alumno abra la aplicación.
    developer.log(
      'No se pudo inicializar la cola de logs.',
      name: 'APP_LOG_QUEUE',
      error: error,
      stackTrace: stackTrace,
    );
  }
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    unawaited(
      AppLogService.instance.record(
        level: 'FATAL',
        eventName: 'app.flutter_error',
        message: details.exceptionAsString(),
        error: details.exception,
        stackTrace: details.stack,
        context: {
          'library': details.library,
          'context': details.context?.toDescription(),
        },
      ),
    );
    (previousFlutterError ?? FlutterError.presentError)(details);
  };
  final previousPlatformError = ui.PlatformDispatcher.instance.onError;
  ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
    unawaited(
      AppLogService.instance.record(
        level: 'FATAL',
        eventName: 'app.platform_unhandled_error',
        message: 'Error asíncrono no controlado.',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    return previousPlatformError?.call(error, stackTrace) ?? true;
  };
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const PresenciaAlumnoBootstrap());
}

Future<void> _syncDeviceBindingInBackground(
  StudentDeviceBindingService service,
  LocalStorageService storage,
) async {
  if (storage.isDemoMode) return;
  final synced = await service.sync(storage);
  await storage.setDeviceBindingSyncPending(!synced);
}

class PresenciaAlumnoBootstrap extends StatefulWidget {
  const PresenciaAlumnoBootstrap({super.key});

  @override
  State<PresenciaAlumnoBootstrap> createState() =>
      _PresenciaAlumnoBootstrapState();
}

class _PresenciaAlumnoBootstrapState extends State<PresenciaAlumnoBootstrap> {
  _AlumnoServices? _services;
  Object? _initializationError;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (_initializationError != null) {
      setState(() => _initializationError = null);
    }

    try {
      final storage = LocalStorageService();
      await storage.init();
      await storage.ensureDeviceBinding();
      AppLogService.instance.setUserIdentifierProvider(() => storage.matricula);

      final bleService = BleAdvertiserService();
      final attendanceSession = AttendanceSessionService(
        storage: storage,
        advertiser: bleService,
      );
      final deviceBindingService = StudentDeviceBindingService();

      // Restore the local identity before showing the authenticated interface.
      if (storage.isProfileSet) {
        await bleService.setStudentIdentity(
          matricula: storage.matricula,
          attendanceUuid: storage.attendanceUuid,
          deviceBindingId: storage.deviceBindingId,
        );
      }

      if (!mounted) return;
      setState(() {
        _services = _AlumnoServices(
          storage: storage,
          bleService: bleService,
          attendanceSession: attendanceSession,
          deviceBindingService: deviceBindingService,
        );
      });

      // Server reconciliation continues without delaying the first app screen.
      if (storage.isProfileSet) {
        unawaited(
          _syncDeviceBindingInBackground(deviceBindingService, storage),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _initializationError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    if (services != null) {
      return PresenciaAlumnoApp(
        storage: services.storage,
        bleService: services.bleService,
        attendanceSession: services.attendanceSession,
        deviceBindingService: services.deviceBindingService,
      );
    }

    return MaterialApp(
      title: 'Presencia: Alumnos',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: AppSplashScreen(
        audience: 'Alumnos',
        errorMessage: _initializationError == null
            ? null
            : 'No pudimos iniciar la aplicación.',
        onRetry: _initialize,
      ),
    );
  }
}

class _AlumnoServices {
  const _AlumnoServices({
    required this.storage,
    required this.bleService,
    required this.attendanceSession,
    required this.deviceBindingService,
  });

  final LocalStorageService storage;
  final BleAdvertiserService bleService;
  final AttendanceSessionService attendanceSession;
  final StudentDeviceBindingService deviceBindingService;
}

class PresenciaAlumnoApp extends StatefulWidget {
  final LocalStorageService storage;
  final BleAdvertiserService bleService;
  final AttendanceSessionService attendanceSession;
  final StudentDeviceBindingService deviceBindingService;

  const PresenciaAlumnoApp({
    super.key,
    required this.storage,
    required this.bleService,
    required this.attendanceSession,
    required this.deviceBindingService,
  });

  @override
  State<PresenciaAlumnoApp> createState() => _PresenciaAlumnoAppState();
}

class _PresenciaAlumnoAppState extends State<PresenciaAlumnoApp> {
  static const _themePreferenceKey = 'student_theme_mode';
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _restoreThemeMode();
  }

  Future<void> _restoreThemeMode() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _themeMode = switch (preferences.getString(_themePreferenceKey)) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      };
    });
  }

  Future<void> _setThemeMode(ThemeMode value) async {
    setState(() => _themeMode = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themePreferenceKey, value.name);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Presencia: Alumnos',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: _themeMode,
      home: _AppRouter(
        storage: widget.storage,
        bleService: widget.bleService,
        attendanceSession: widget.attendanceSession,
        deviceBindingService: widget.deviceBindingService,
        onThemeModeChanged: _setThemeMode,
        themeMode: _themeMode,
      ),
    );
  }
}

/// Handles routing between setup and home, including navigation after setup
class _AppRouter extends StatefulWidget {
  final LocalStorageService storage;
  final BleAdvertiserService bleService;
  final AttendanceSessionService attendanceSession;
  final StudentDeviceBindingService deviceBindingService;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  const _AppRouter({
    required this.storage,
    required this.bleService,
    required this.attendanceSession,
    required this.deviceBindingService,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  State<_AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<_AppRouter> {
  late bool _profileSet;
  StudentAcademicProfile? _academicProfile;
  String? _initialUatSessionId;
  late bool _demoMode;

  Future<void> _logout() async {
    await widget.attendanceSession.stop();
    await widget.storage.clearStudentSession();
    await widget.bleService.setStudentIdentity(
      matricula: '',
      attendanceUuid: '',
      deviceBindingId: '',
    );
    if (!mounted) return;
    setState(() {
      _profileSet = false;
      _academicProfile = null;
      _initialUatSessionId = null;
      _demoMode = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _demoMode = widget.storage.isDemoMode;
    _profileSet = widget.storage.isProfileSet;
    _academicProfile = widget.storage.academicProfile;
    if (_profileSet && _academicProfile == null) {
      _academicProfile = StudentAcademicProfile(
        matricula: widget.storage.matricula,
        institutionalEmail: widget.storage.institutionalEmail,
        displayName: widget.storage.institutionalEmail.isEmpty
            ? widget.storage.matricula
            : widget.storage.institutionalEmail,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_profileSet) {
      return LoginScreen(
        storage: widget.storage,
        onAuthenticated: (username, password, result) async {
          await widget.storage.saveInstitutionalCredentials(
            username: username,
            password: password,
          );
          await widget.storage.saveDemoMode(result.demoMode);
          if (result.reviewAttendanceUuid != null) {
            await widget.storage.saveAppReviewAttendanceUuid(
              result.reviewAttendanceUuid!,
            );
          }
          if (result.deviceBindingToken.isNotEmpty) {
            await widget.storage.saveDeviceBindingToken(
              result.deviceBindingToken,
            );
          }
          await widget.storage.saveAcademicProfile(result.profile);
          await widget.bleService.setStudentIdentity(
            matricula: result.matricula,
            attendanceUuid: widget.storage.attendanceUuid,
            deviceBindingId: widget.storage.deviceBindingId,
          );
          setState(() {
            _academicProfile = result.profile;
            _initialUatSessionId = result.sessionId;
            _demoMode = result.demoMode;
            _profileSet = true;
          });
          if (!result.demoMode) {
            unawaited(
              _syncDeviceBindingInBackground(
                widget.deviceBindingService,
                widget.storage,
              ),
            );
          }
        },
      );
    }

    return HomeScreen(
      storage: widget.storage,
      bleService: widget.bleService,
      attendanceSession: widget.attendanceSession,
      deviceBindingService: widget.deviceBindingService,
      profile: _academicProfile!,
      initialUatSessionId: _initialUatSessionId,
      demoMode: _demoMode,
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
      studentAuth: StudentAuthService(),
      onLogout: _logout,
    );
  }
}
