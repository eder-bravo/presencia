import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dartz/dartz.dart';

import '../../../shared/models/profesor.dart';
import '../../../shared/models/grupo.dart';
import '../../../services/api_service.dart';
import '../../../services/auth_storage_service.dart';
import '../../../core/utils/utils.dart';

/// Estado de la autenticación del profesor
enum ProfesorAuthStatus {
  initial,
  loading,
  authenticated,
  unauthenticated,
  // Nombre heredado. Este estado se usa únicamente cuando el backend rechazó
  // la contraseña guardada y se necesita que el profesor capture la nueva.
  sessionExpired,
  error,
}

/// Estado del profesor autenticado
class ProfesorAuthState {
  static const Object _notProvided = Object();

  final ProfesorAuthStatus status;
  final Profesor? profesor;
  final List<Grupo> grupos;
  final String? token;
  final String? errorMessage;
  final String? groupsNotice;
  final bool isLoadingGroups;

  const ProfesorAuthState({
    this.status = ProfesorAuthStatus.initial,
    this.profesor,
    this.grupos = const [],
    this.token,
    this.errorMessage,
    this.groupsNotice,
    this.isLoadingGroups = false,
  });

  ProfesorAuthState copyWith({
    ProfesorAuthStatus? status,
    Profesor? profesor,
    List<Grupo>? grupos,
    Object? token = _notProvided,
    Object? errorMessage = _notProvided,
    Object? groupsNotice = _notProvided,
    bool? isLoadingGroups,
  }) {
    return ProfesorAuthState(
      status: status ?? this.status,
      profesor: profesor ?? this.profesor,
      grupos: grupos ?? this.grupos,
      token: identical(token, _notProvided) ? this.token : token as String?,
      errorMessage: identical(errorMessage, _notProvided)
          ? this.errorMessage
          : errorMessage as String?,
      groupsNotice: identical(groupsNotice, _notProvided)
          ? this.groupsNotice
          : groupsNotice as String?,
      isLoadingGroups: isLoadingGroups ?? this.isLoadingGroups,
    );
  }

  bool get isAuthenticated =>
      status == ProfesorAuthStatus.authenticated && profesor != null;
  bool get isLoading => status == ProfesorAuthStatus.loading;
  bool get hasError => status == ProfesorAuthStatus.error;
  bool get isSessionExpired => status == ProfesorAuthStatus.sessionExpired;
}

/// Provider del servicio de API
final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService();
});

/// Provider del servicio de almacenamiento de autenticación
final authStorageServiceProvider = Provider<AuthStorageService>((ref) {
  return AuthStorageService();
});

/// Notifier para manejar la autenticación del profesor
class ProfesorAuthNotifier extends StateNotifier<ProfesorAuthState> {
  final ApiService _apiService;
  final AuthStorageService _authStorage;
  bool _isLoggingOut = false;
  int _groupsLoadGeneration = 0;
  Future<void>? _tokenClearInFlight;

  ProfesorAuthNotifier(this._apiService, this._authStorage)
    : super(const ProfesorAuthState());

  /// Iniciar sesión del profesor (crea cuenta automáticamente si no existe)
  Future<void> login(String email, String password) async {
    try {
      Logger.info('Iniciando login del profesor con email: $email');
      state = state.copyWith(
        status: ProfesorAuthStatus.loading,
        errorMessage: null,
      );

      final result = await _apiService.loginProfesor(
        email: email,
        password: password,
      );

      await result.fold(
        (error) async {
          Logger.error('Error en login: $error');
          state = state.copyWith(
            status: ProfesorAuthStatus.error,
            errorMessage: error,
          );
        },
        (loginResponse) async {
          Logger.info(
            'Login exitoso para: ${loginResponse.profesor.nombreCompleto}',
          );

          // Guardar sesión en almacenamiento local
          await _authStorage.saveSession(
            token: loginResponse.token,
            profesor: loginResponse.profesor,
          );

          // La credencial UAT queda cifrada por Keychain/Keystore y se usa
          // únicamente para operaciones de sincronización.
          await _authStorage.cacheUatPasswordForProcess(password);

          if (loginResponse.needsSync == true) {
            await _authStorage.setSyncInProgress(true);
          }

          state = state.copyWith(
            status: ProfesorAuthStatus.authenticated,
            profesor: loginResponse.profesor,
            token: loginResponse.token,
            grupos: [],
            groupsNotice: null,
          );

          // Cargar grupos y configuración de aulas desde el servidor
          await _loadGrupos(forceRefresh: true, preserveCache: false);
          await _authStorage.setSyncInProgress(false);
        },
      );
    } catch (e, stackTrace) {
      Logger.error('Error inesperado en login', e, stackTrace);
      state = state.copyWith(
        status: ProfesorAuthStatus.error,
        errorMessage: 'No pudimos iniciar sesión. Intenta de nuevo.',
      );
    }
  }

  /// Consulta el servidor conservando las listas locales si la actualización
  /// falla. Solo un login nuevo descarta la caché de una identidad anterior.
  Future<void> _loadGrupos({
    bool forceRefresh = false,
    bool preserveCache = true,
  }) async {
    final profesorId = state.profesor?.id;
    final token = state.token;
    if (profesorId == null || token == null) return;
    final generation = ++_groupsLoadGeneration;
    final sessionGeneration = _authStorage.sessionGeneration;
    bool isCurrent() =>
        mounted &&
        !_isLoggingOut &&
        generation == _groupsLoadGeneration &&
        sessionGeneration == _authStorage.sessionGeneration &&
        state.profesor?.id == profesorId;
    final cachedGrupos = preserveCache
        ? (state.grupos.isNotEmpty
              ? state.grupos
              : _authStorage.getGrupos() ?? const <Grupo>[])
        : const <Grupo>[];
    final cachedCycleId = _authStorage.getGruposAcademicCycleId();

    Future<void> handleFailure() async {
      if (!isCurrent()) return;
      if (!preserveCache) {
        await _authStorage.clearGrupos();
        if (!isCurrent()) return;
        await _authStorage.saveBeacons(const []);
        if (!isCurrent()) return;
      }
      state = state.copyWith(
        grupos: cachedGrupos,
        token: _authStorage.getToken() ?? state.token,
        isLoadingGroups: false,
        groupsNotice: cachedGrupos.isNotEmpty
            ? 'No se pudieron actualizar las clases. Puedes seguir usando '
                  'las listas guardadas en este equipo.'
            : preserveCache
            ? 'No se pudieron consultar las clases. Intenta actualizar de nuevo.'
            : 'No se pudieron consultar las clases del ciclo actual. '
                  'No se mostrarán datos guardados de ciclos anteriores.',
      );
    }

    try {
      if (!forceRefresh && cachedGrupos.isNotEmpty) {
        final debugData = _apiService.withDebugCurrentClass(
          cachedGrupos,
          _authStorage.getBeacons() ?? const <Map<String, dynamic>>[],
        );
        await _authStorage.saveBeacons(debugData.beacons);
        if (!isCurrent()) return;
        state = state.copyWith(grupos: debugData.grupos, groupsNotice: null);
      }
      state = state.copyWith(isLoadingGroups: true, groupsNotice: null);
      final result = await _apiService.getGruposProfesor(token);
      if (!isCurrent()) return;

      await result.fold(
        (error) async {
          Logger.error('Error cargando clases: $error');
          await handleFailure();
        },
        (data) async {
          final cachedById = {
            for (final group in cachedGrupos) group.id: group,
          };
          var restoredRosters = 0;
          final grupos = data.grupos.map((group) {
            final cached = cachedById[group.id];
            if (group.students.isNotEmpty ||
                !data.unavailableRosterGroupIds.contains(group.id) ||
                cached == null ||
                cached.students.isEmpty ||
                cached.esCompartida != group.esCompartida ||
                cached.sharedAssignmentId != group.sharedAssignmentId ||
                !_belongsToCycle(cached, data.cycle, cachedCycleId)) {
              return group;
            }
            // La clase sigue asignada en el ciclo activo, pero la consulta de
            // alumnos no entregó una lista. No convertir ese fallo en un borrado.
            restoredRosters++;
            return group.copyWith(
              students: cached.students,
              studentsCount: cached.students.length,
            );
          }).toList();
          final missingRosters = (data.unavailableRosterCount - restoredRosters)
              .clamp(0, data.unavailableRosterCount);
          final failedRosters = grupos
              .where(
                (group) =>
                    group.students.isEmpty &&
                    data.failedRosterGroupIds.contains(group.id),
              )
              .length;
          final pendingRosters = missingRosters - failedRosters;
          final notices = <String>[
            if (data.classesPending)
              'Las clases y listas del ciclo ${data.cycle.name} aún no '
                  'están disponibles. No se mostrarán clases de ciclos anteriores.',
            if (failedRosters > 0)
              'No se pudieron descargar las listas de $failedRosters '
                  '${failedRosters == 1 ? 'clase' : 'clases'}. Intenta actualizar de nuevo.',
            if (pendingRosters > 0)
              'Las listas de alumnos del ciclo ${data.cycle.name} aún no '
                  'están disponibles para $pendingRosters '
                  '${pendingRosters == 1 ? 'clase' : 'clases'}.',
          ];
          final groupsNotice = notices.isEmpty ? null : notices.join(' ');

          await _authStorage.saveGrupos(
            grupos,
            academicCycleId: data.cycle.externalId,
          );
          if (!isCurrent()) return;
          await _authStorage.saveBeacons(data.beacons);
          if (!isCurrent()) return;
          state = state.copyWith(
            grupos: grupos,
            token: _authStorage.getToken() ?? state.token,
            isLoadingGroups: false,
            groupsNotice: groupsNotice,
          );
          Logger.info(
            '${grupos.length} clases guardadas; $restoredRosters listas conservadas desde caché',
          );
        },
      );
    } catch (error, stackTrace) {
      Logger.error('Error inesperado cargando clases', error, stackTrace);
      await handleFailure();
    }
  }

  bool _belongsToCycle(
    Grupo group,
    AcademicCycleContext cycle,
    int? cachedCycleId,
  ) {
    if (cachedCycleId != null) return cachedCycleId == cycle.externalId;
    // Compatibilidad con listas guardadas antes de persistir el ID del ciclo.
    final period = RegExp(
      r'(\d{4})\D+([123])(?:\D|$)',
    ).firstMatch(group.period ?? '');
    return period != null &&
        int.tryParse(period.group(1)!) == cycle.year &&
        int.tryParse(period.group(2)!) == cycle.term;
  }

  /// Refrescar grupos del profesor (fuerza descarga desde servidor)
  Future<void> refreshGrupos() async {
    if (!state.isAuthenticated) return;
    Logger.info('🔄 Refrescando clases (forzando descarga desde servidor)');
    await _loadGrupos(forceRefresh: true);
  }

  /// Limpiar grupos locales (usado al iniciar nueva sincronización)
  Future<void> clearGrupos() async {
    _groupsLoadGeneration++;
    state = state.copyWith(
      grupos: [],
      isLoadingGroups: false,
      groupsNotice: null,
    );
    await _authStorage.clearGrupos();
  }

  /// Solicitar una nueva cosecha academica al backend.
  Future<Either<String, String>> syncGroups(String password) async {
    if (!state.isAuthenticated ||
        state.profesor == null ||
        state.token == null) {
      return Left('No hay sesión activa');
    }

    // Set sync in progress flag for app redirect on reopen
    await _authStorage.setSyncInProgress(true);

    // Mantiene disponible la credencial cifrada para reintentos automáticos.
    await _authStorage.cacheUatPasswordForProcess(password);

    final result = await _apiService.forceSync(token: state.token!);

    await result.fold(
      (error) async {
        await _authStorage.setSyncInProgress(false);
      },
      (message) async {
        await _authStorage.setSyncInProgress(false);
        await _loadGrupos(forceRefresh: true);
      },
    );

    return result;
  }

  /// Verificar si existe una sesión almacenada y restaurarla. Una expiración
  /// normal se renueva en silencio; sólo un rechazo explícito de la contraseña
  /// conduce a la pantalla de re-autenticación.
  Future<void> checkStoredSession() async {
    try {
      Logger.info('Verificando sesión almacenada');

      final token = _authStorage.getToken();
      final profesor = _authStorage.getProfesor();
      final cachedGrupos = _authStorage.getGrupos() ?? const <Grupo>[];

      if (profesor != null) {
        if (token != null && token.isNotEmpty) {
          // Validar si el JWT no ha expirado localmente
          final tokenValido = _authStorage.isTokenValid();

          if (!tokenValido) {
            Logger.info(
              'Token expirado para ${profesor.nombreCompleto}; renovando en segundo plano',
            );
            state = ProfesorAuthState(
              status: ProfesorAuthStatus.authenticated,
              profesor: profesor,
              grupos: cachedGrupos,
              token: token,
            );
            await relogin();
            return;
          }

          Logger.info(
            'Sesión válida encontrada para: ${profesor.nombreCompleto}',
          );
          state = state.copyWith(
            status: ProfesorAuthStatus.authenticated,
            profesor: profesor,
            token: token,
          );
          // Cargar grupos del profesor
          await _loadGrupos();
        } else {
          Logger.info('Identidad local disponible; renovando la sesión UAT');
          state = ProfesorAuthState(
            status: ProfesorAuthStatus.authenticated,
            profesor: profesor,
            grupos: cachedGrupos,
          );
          await relogin();
        }
      } else {
        Logger.info('No hay sesión almacenada');
        state = const ProfesorAuthState(
          status: ProfesorAuthStatus.unauthenticated,
        );
      }
    } catch (e, stackTrace) {
      Logger.error('Error verificando sesión almacenada', e, stackTrace);
      final profesor = _authStorage.getProfesor();
      if (profesor == null) {
        state = const ProfesorAuthState(
          status: ProfesorAuthStatus.unauthenticated,
        );
        return;
      }
      state = ProfesorAuthState(
        status: ProfesorAuthStatus.authenticated,
        profesor: profesor,
        grupos: _authStorage.getGrupos() ?? const <Grupo>[],
        token: _authStorage.getToken(),
        errorMessage:
            'No se pudo actualizar la sesión; continúas con los datos locales.',
      );
    }
  }

  Future<void> _clearLocalSession() async {
    _groupsLoadGeneration++;
    final tokenClear = _tokenClearInFlight;
    if (tokenClear != null) {
      await tokenClear;
      if (identical(_tokenClearInFlight, tokenClear)) {
        _tokenClearInFlight = null;
      }
    }
    await _authStorage.clearSession();
    state = const ProfesorAuthState(status: ProfesorAuthStatus.unauthenticated);
  }

  /// Cerrar sesión. La sesión local se elimina antes de intentar la revocación
  /// remota para que una falla de red nunca deje al profesor dentro de la app.
  Future<void> logout() async {
    if (_isLoggingOut) return;
    _isLoggingOut = true;
    Logger.info('Cerrando sesión del profesor');
    final token = state.token ?? _authStorage.getToken();
    try {
      await _clearLocalSession();

      if (token != null && token.isNotEmpty) {
        final result = await _apiService.logoutProfesor(token);
        result.fold(
          (error) => Logger.error(
            'La sesión local se cerró aunque no se pudo revocar la remota: $error',
          ),
          (_) {},
        );
      }
    } finally {
      _isLoggingOut = false;
    }
  }

  /// Solicitar una contraseña nueva después de que el backend rechazó la
  /// credencial protegida. Los 401 por expiración normal se renuevan antes de
  /// llegar aquí.
  void markSessionExpired() {
    if (_isLoggingOut ||
        state.status == ProfesorAuthStatus.unauthenticated ||
        state.status == ProfesorAuthStatus.initial ||
        (state.profesor ?? _authStorage.getProfesor()) == null) {
      Logger.info('Se ignoró un 401 recibido después del cierre de sesión.');
      return;
    }
    if (state.status == ProfesorAuthStatus.sessionExpired) return;
    Logger.info('La contraseña guardada fue rechazada; solicitando la nueva.');
    _tokenClearInFlight = _authStorage.clearToken();
    state = state.copyWith(
      status: ProfesorAuthStatus.sessionExpired,
      token: null,
      isLoadingGroups: false,
      errorMessage:
          'La contraseña guardada ya no es válida. Ingresa tu contraseña actual.',
    );
  }

  /// Re-autenticación ligera con la credencial cifrada o con
  /// una contraseña nueva ingresada por la persona usuaria.
  Future<void> relogin({String? plainPassword}) async {
    final tokenClear = _tokenClearInFlight;
    if (tokenClear != null) {
      await tokenClear;
      if (identical(_tokenClearInFlight, tokenClear)) {
        _tokenClearInFlight = null;
      }
    }

    final profesor = state.profesor ?? _authStorage.getProfesor();
    if (profesor == null) {
      // No hay datos de profesor — logout completo
      await logout();
      return;
    }

    state = state.copyWith(
      status: ProfesorAuthStatus.loading,
      errorMessage: null,
      profesor: profesor,
    );

    Either<String, LoginResponse> result;

    if (plainPassword != null && plainPassword.isNotEmpty) {
      // Login con contraseña nueva en texto plano
      result = await _apiService.loginProfesor(
        email: profesor.institutionalEmail,
        password: plainPassword,
      );
    } else {
      // Reusar la credencial protegida por Keychain/Keystore.
      final cachedPassword = _authStorage.getCachedUatPassword();
      if (cachedPassword == null || cachedPassword.isEmpty) {
        Logger.info(
          'No hay una credencial guardada para renovar; se cerrará la sesión local.',
        );
        await _clearLocalSession();
        return;
      }
      result = await _apiService.loginProfesor(
        email: profesor.institutionalEmail,
        password: cachedPassword,
      );
    }

    await result.fold(
      (error) async {
        Logger.error('Error en re-login: $error');
        if (!_apiService.lastLoginCredentialsRejected) {
          state = state.copyWith(
            status: ProfesorAuthStatus.authenticated,
            token: _authStorage.getToken(),
            errorMessage:
                'No pudimos actualizar la información; puedes seguir usando los datos disponibles.',
          );
          return;
        }
        await _authStorage.clearToken();
        state = state.copyWith(
          status: ProfesorAuthStatus.sessionExpired,
          token: null,
          errorMessage:
              'La contraseña no es válida. Si la cambiaste, ingresa la nueva.',
        );
      },
      (loginResponse) async {
        Logger.info(
          'Re-login exitoso para: ${loginResponse.profesor.nombreCompleto}',
        );
        await _authStorage.saveSession(
          token: loginResponse.token,
          profesor: loginResponse.profesor,
        );
        // Sustituir la credencial cifrada después de un re-login correcto.
        if (plainPassword != null && plainPassword.isNotEmpty) {
          await _authStorage.cacheUatPasswordForProcess(plainPassword);
        }
        state = state.copyWith(
          status: ProfesorAuthStatus.authenticated,
          profesor: loginResponse.profesor,
          token: loginResponse.token,
          errorMessage: null,
        );
        // Renovar el token no invalida las listas guardadas. El servidor
        // confirma el ciclo antes de reutilizar una lista parcial de la caché.
        await _loadGrupos(forceRefresh: true);
      },
    );
  }

  /// Limpiar error
  void clearError() {
    if (state.hasError) {
      state = state.copyWith(
        status: state.profesor != null
            ? ProfesorAuthStatus.authenticated
            : ProfesorAuthStatus.unauthenticated,
        errorMessage: null,
      );
    }
  }
}

/// Provider del estado de autenticación del profesor
final profesorAuthProvider =
    StateNotifierProvider<ProfesorAuthNotifier, ProfesorAuthState>((ref) {
      final apiService = ref.watch(apiServiceProvider);
      final authStorage = ref.watch(authStorageServiceProvider);
      final notifier = ProfesorAuthNotifier(apiService, authStorage);
      // Registrar callback de 401 en ApiService sin dependencia circular.
      // markSessionExpired() tiene su propio guard interno.
      apiService.onSessionExpired = notifier.markSessionExpired;
      return notifier;
    });

/// Provider para verificar si el profesor está autenticado
final isProfesorAuthenticatedProvider = Provider<bool>((ref) {
  final state = ref.watch(profesorAuthProvider);
  return state.isAuthenticated;
});

/// Provider para obtener el profesor actual
final currentProfesorProvider = Provider<Profesor?>((ref) {
  final state = ref.watch(profesorAuthProvider);
  return state.profesor;
});

/// Provider para obtener los grupos del profesor actual
final profesorGruposProvider = Provider<List<Grupo>>((ref) {
  final state = ref.watch(profesorAuthProvider);
  return state.grupos;
});

/// Provider para obtener el estado de carga
final profesorAuthLoadingProvider = Provider<bool>((ref) {
  final state = ref.watch(profesorAuthProvider);
  return state.isLoading;
});

/// Provider para saber si las clases estan descargandose del backend.
final profesorGroupsLoadingProvider = Provider<bool>((ref) {
  final state = ref.watch(profesorAuthProvider);
  return state.isLoadingGroups;
});

/// Aviso contextual sobre disponibilidad o vigencia de las listas.
final profesorGroupsNoticeProvider = Provider<String?>((ref) {
  return ref.watch(profesorAuthProvider).groupsNotice;
});

/// Provider para obtener el error actual
final profesorAuthErrorProvider = Provider<String?>((ref) {
  final state = ref.watch(profesorAuthProvider);
  return state.errorMessage;
});
