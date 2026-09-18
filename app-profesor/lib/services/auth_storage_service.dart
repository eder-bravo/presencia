import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants/api_constants.dart';
import '../core/utils/utils.dart';
import '../shared/models/grupo.dart';
import '../shared/models/profesor.dart';

class AuthStorageService {
  static final AuthStorageService _instance = AuthStorageService._internal();
  factory AuthStorageService() => _instance;
  AuthStorageService._internal();

  static const String _authBox = 'auth';
  static const String _legacyTokenKey = 'jwt_token';
  static const String _legacyMainBackendTokenKey = 'main_backend_jwt_token';
  static const String _secureTokenKey = 'professor_session_token';
  static const String _secureMainBackendTokenKey =
      'professor_main_backend_token';
  static const String _secureUatPasswordKey = 'professor_uat_password';
  static const String _profesorKey = 'profesor_data';
  static const String _gruposKey = 'grupos_data';
  static const String _gruposAcademicCycleKey = 'grupos_academic_cycle_id';
  static const String _syncInProgressKey = 'sync_in_progress';
  static const String _legacyPasswordKey = 'encrypted_password';
  static const String _beaconsKey = 'beacons_data';
  static const String _studentDeviceBindingsKey =
      'student_device_bindings_data';
  static const String _attendanceToleranceKey =
      'teacher_attendance_tolerance_minutes';
  static const String _professorDeviceBindingIdKey =
      'professor_device_binding_id';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  Box? _box;
  String? _cachedToken;
  String? _cachedUatPassword;
  int _sessionGeneration = 0;

  /// Cambia cada vez que la sesión local se invalida. Permite que una
  /// renovación que ya estaba en vuelo no vuelva a guardar una sesión después
  /// de que la persona cerró sesión.
  int get sessionGeneration => _sessionGeneration;

  Future<void> init() async {
    try {
      if (!Hive.isBoxOpen(_authBox)) {
        _box = await Hive.openBox(_authBox);
      } else {
        _box = Hive.box(_authBox);
      }
      // Versiones anteriores escribían la contraseña UAT en Hive. Se elimina
      // antes de migrar al almacén cifrado de Keychain/Keystore.
      if (_box?.containsKey(_legacyPasswordKey) == true) {
        await _box?.delete(_legacyPasswordKey);
        Logger.info('Credencial UAT heredada eliminada del almacenamiento');
      }
      await _loadAndMigrateSecureSession();
      _cachedUatPassword = await _secureStorage.read(
        key: _secureUatPasswordKey,
      );
      ApiConstants.configureAttendanceTolerance(getAttendanceTolerance());
      Logger.info('AuthStorageService inicializado correctamente');
    } catch (e, stackTrace) {
      Logger.error('Error al inicializar AuthStorageService', e, stackTrace);
    }
  }

  Future<void> saveToken(String token) async {
    try {
      _cachedToken = token;
      await _secureStorage.write(key: _secureTokenKey, value: token);
      await _box?.delete(_legacyTokenKey);
      Logger.info('Identificador de sesion guardado correctamente');
    } catch (e, stackTrace) {
      Logger.error('Error al guardar token', e, stackTrace);
    }
  }

  String? getToken() {
    if (_cachedToken != null) {
      Logger.debug('Identificador de sesion recuperado');
    }
    return _cachedToken;
  }

  Future<void> saveProfesor(Profesor profesor) async {
    try {
      final profesorJson = jsonEncode(profesor.toJson());
      await _box?.put(_profesorKey, profesorJson);
      Logger.info('Datos del profesor guardados correctamente');
    } catch (e, stackTrace) {
      Logger.error('Error al guardar datos del profesor', e, stackTrace);
    }
  }

  Profesor? getProfesor() {
    try {
      final profesorJson = _box?.get(_profesorKey) as String?;
      if (profesorJson != null) {
        final json = jsonDecode(profesorJson) as Map<String, dynamic>;
        Logger.debug('Datos del profesor recuperados');
        return Profesor.fromJson(json);
      }
      return null;
    } catch (e, stackTrace) {
      Logger.error('Error al obtener datos del profesor', e, stackTrace);
      return null;
    }
  }

  Future<void> saveGrupos(List<Grupo> grupos, {int? academicCycleId}) async {
    try {
      final gruposJson = jsonEncode(grupos.map((g) => g.toJson()).toList());
      await _box?.putAll({
        _gruposKey: gruposJson,
        _gruposAcademicCycleKey: academicCycleId,
      });
      Logger.info('${grupos.length} grupos guardados correctamente');
    } catch (e, stackTrace) {
      Logger.error('Error al guardar grupos', e, stackTrace);
    }
  }

  List<Grupo>? getGrupos() {
    try {
      final gruposJson = _box?.get(_gruposKey) as String?;
      if (gruposJson != null) {
        final jsonList = jsonDecode(gruposJson) as List<dynamic>;
        final grupos = jsonList
            .map((json) => Grupo.fromJson(json as Map<String, dynamic>))
            .toList();
        Logger.debug('${grupos.length} grupos recuperados del storage');
        return grupos;
      }
      return null;
    } catch (e, stackTrace) {
      Logger.error('Error al obtener grupos', e, stackTrace);
      return null;
    }
  }

  Future<void> clearGrupos() async {
    try {
      await _box?.deleteAll([_gruposKey, _gruposAcademicCycleKey]);
      Logger.info('Grupos eliminados del storage');
    } catch (e, stackTrace) {
      Logger.error('Error al limpiar grupos', e, stackTrace);
    }
  }

  int? getGruposAcademicCycleId() => _box?.get(_gruposAcademicCycleKey) as int?;

  Future<void> saveSession({
    required String token,
    required Profesor profesor,
    List<Grupo>? grupos,
  }) async {
    await saveToken(token);
    await saveProfesor(profesor);
    if (grupos != null) {
      await saveGrupos(grupos);
    }
    Logger.info('Sesion guardada correctamente');
  }

  bool hasActiveSession() {
    final token = getToken();
    final profesor = getProfesor();
    return token != null && token.isNotEmpty && profesor != null;
  }

  Future<void> clearSession() async {
    _sessionGeneration++;
    _cachedToken = null;
    _cachedUatPassword = null;

    // Cada almacén se limpia de forma independiente. Así, un fallo puntual de
    // Keychain/Keystore no impide borrar la identidad y los datos de sesión de
    // Hive (y viceversa).
    for (final key in const [
      _secureTokenKey,
      _secureMainBackendTokenKey,
      _secureUatPasswordKey,
    ]) {
      try {
        await _secureStorage.delete(key: key);
      } catch (e, stackTrace) {
        Logger.error(
          'Error al eliminar la clave segura de sesión: $key',
          e,
          stackTrace,
        );
      }
    }

    try {
      await _box?.deleteAll(const [
        _legacyTokenKey,
        _legacyMainBackendTokenKey,
        _profesorKey,
        _gruposKey,
        _gruposAcademicCycleKey,
        _syncInProgressKey,
        _legacyPasswordKey,
        _beaconsKey,
        _studentDeviceBindingsKey,
      ]);
    } catch (e, stackTrace) {
      Logger.error(
        'Error al limpiar los datos locales de sesión',
        e,
        stackTrace,
      );
    }

    Logger.info('Sesion local eliminada completamente');
  }

  /// Invalida únicamente el identificador de sesión. La identidad y los datos
  /// locales se conservan para solicitar una contraseña nueva sólo cuando el
  /// backend rechazó la credencial guardada.
  Future<void> clearToken() async {
    _sessionGeneration++;
    _cachedToken = null;
    try {
      await _secureStorage.delete(key: _secureTokenKey);
    } catch (e, stackTrace) {
      Logger.error(
        'Error al eliminar el identificador de sesión',
        e,
        stackTrace,
      );
    }
    try {
      await _box?.delete(_legacyTokenKey);
    } catch (e, stackTrace) {
      Logger.error(
        'Error al eliminar el identificador heredado',
        e,
        stackTrace,
      );
    }
  }

  Future<void> _loadAndMigrateSecureSession() async {
    _cachedToken = await _secureStorage.read(key: _secureTokenKey);

    final legacyToken = _box?.get(_legacyTokenKey) as String?;
    if ((_cachedToken == null || _cachedToken!.isEmpty) &&
        legacyToken != null &&
        legacyToken.isNotEmpty) {
      await saveToken(legacyToken);
    }

    // El token paralelo del backend monolitico dejo de ser valido con el
    // corte a Identity/UAT Integration. Se elimina en vez de migrarlo.
    await _secureStorage.delete(key: _secureMainBackendTokenKey);
    await _box?.delete(_legacyTokenKey);
    await _box?.delete(_legacyMainBackendTokenKey);
  }

  bool isTokenValid() {
    final token = getToken();
    if (token == null || token.isEmpty) return false;

    try {
      final parts = token.split('.');
      if (parts.length != 3) {
        Logger.debug('Sesion REST detectada');
        return true;
      }

      final payload = parts[1];
      final normalizedPayload = base64Url.normalize(payload);
      final decodedPayload = utf8.decode(base64Url.decode(normalizedPayload));
      final payloadMap = jsonDecode(decodedPayload) as Map<String, dynamic>;

      if (payloadMap.containsKey('exp')) {
        final exp = payloadMap['exp'] as int;
        final expirationDate = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
        final isExpired = DateTime.now().isAfter(expirationDate);

        if (isExpired) {
          Logger.info('Token JWT expirado');
          return false;
        }
      }

      return true;
    } catch (e) {
      Logger.debug('Token no JWT; se validara contra backend en la red', e);
      return true;
    }
  }

  Future<void> setSyncInProgress(bool value) async {
    try {
      await _box?.put(_syncInProgressKey, value);
      Logger.info('Sync in progress flag set to: $value');
    } catch (e, stackTrace) {
      Logger.error('Error setting sync in progress flag', e, stackTrace);
    }
  }

  bool isSyncInProgress() {
    try {
      return _box?.get(_syncInProgressKey, defaultValue: false) as bool? ??
          false;
    } catch (e) {
      Logger.error('Error getting sync in progress flag', e);
      return false;
    }
  }

  Future<void> saveAttendanceTolerance(int value) async {
    final normalized = value.clamp(0, 120).toInt();
    await _box?.put(_attendanceToleranceKey, normalized);
    ApiConstants.configureAttendanceTolerance(normalized);
  }

  int getAttendanceTolerance() {
    final stored = _box?.get(_attendanceToleranceKey);
    return stored is int
        ? stored.clamp(0, 120).toInt()
        : ApiConstants.defaultTeacherAttendanceToleranceMinutes;
  }

  String getProfessorDeviceBindingId() {
    return _box?.get(_professorDeviceBindingIdKey, defaultValue: '')
            as String? ??
        '';
  }

  Future<String> ensureProfessorDeviceIdentity() async {
    final current = getProfessorDeviceBindingId();
    if (current.isNotEmpty) return current;

    final bindingId = _uuidV4();
    await _box?.put(_professorDeviceBindingIdKey, bindingId);
    return bindingId;
  }

  Future<void> cacheUatPasswordForProcess(String password) async {
    _cachedUatPassword = password;
    await _secureStorage.write(key: _secureUatPasswordKey, value: password);
    // Defensa adicional para instalaciones actualizadas desde una versión
    // que persistía esta credencial sin protección en Hive.
    try {
      await _box?.delete(_legacyPasswordKey);
    } catch (error, stackTrace) {
      Logger.error(
        'No se pudo limpiar la credencial UAT heredada',
        error,
        stackTrace,
      );
    }
    Logger.info('Credencial UAT protegida por Keychain/Keystore');
  }

  String? getCachedUatPassword() => _cachedUatPassword;

  Future<void> clearCachedUatPassword() async {
    _cachedUatPassword = null;
    await _secureStorage.delete(key: _secureUatPasswordKey);
    try {
      await _box?.delete(_legacyPasswordKey);
    } catch (error, stackTrace) {
      Logger.error(
        'No se pudo limpiar la credencial UAT heredada',
        error,
        stackTrace,
      );
    }
    Logger.info('Credencial UAT eliminada del almacenamiento seguro');
  }

  Future<void> saveLastEmail(String email) async {
    try {
      await _box?.put('last_email', email);
    } catch (e) {
      Logger.error('Error al guardar ultimo email', e);
    }
  }

  String? getLastEmail() {
    try {
      return _box?.get('last_email') as String?;
    } catch (e) {
      return null;
    }
  }

  String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int value) => value.toRadixString(16).padLeft(2, '0');
    final chars = bytes.map(hex).join();
    return '${chars.substring(0, 8)}-'
        '${chars.substring(8, 12)}-'
        '${chars.substring(12, 16)}-'
        '${chars.substring(16, 20)}-'
        '${chars.substring(20)}';
  }

  /// Incorpora los vínculos GATT confirmados por el servidor.
  Future<void> cacheResolvedStudentDeviceBindings(
    List<Map<String, dynamic>> resolvedBindings, {
    Iterable<String>? requestedMatriculas,
  }) async {
    final bindings = _studentBindingsByMatricula();
    // Una respuesta completa reemplaza solo los vínculos del grupo consultado.
    // Los errores de red nunca deben pasar por aquí ni vaciar la copia local.
    final requested = requestedMatriculas
        ?.map((value) => value.trim().toUpperCase())
        .toSet();
    if (requested != null) {
      bindings.removeWhere((matricula, _) => requested.contains(matricula));
    }
    for (final raw in resolvedBindings) {
      final matricula = raw['matricula']?.toString().trim().toUpperCase() ?? '';
      final uuid = raw['attendanceUuid']?.toString().trim().toLowerCase() ?? '';
      if (matricula.isEmpty || uuid.isEmpty) continue;
      if (requested != null && !requested.contains(matricula)) continue;

      bindings[matricula] = {
        ...raw,
        'matricula': matricula,
        'attendanceUuid': uuid,
        'pendingSync': false,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      };
    }
    await _saveStudentBindings(bindings);
  }

  List<Map<String, dynamic>> getStudentDeviceBindings({
    Iterable<String>? matriculas,
  }) {
    final allowed = matriculas
        ?.map((value) => value.trim().toUpperCase())
        .where((value) => value.isNotEmpty)
        .toSet();
    return _studentBindingsByMatricula().entries
        .where((entry) => allowed == null || allowed.contains(entry.key))
        .map((entry) => Map<String, dynamic>.from(entry.value))
        .toList(growable: false);
  }

  Map<String, Map<String, dynamic>> _studentBindingsByMatricula() {
    try {
      final rawJson = _box?.get(_studentDeviceBindingsKey) as String?;
      if (rawJson == null || rawJson.isEmpty) return {};
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return {};
      return decoded.map((key, value) {
        final binding = value is Map
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{};
        return MapEntry(key.toString().trim().toUpperCase(), binding);
      });
    } catch (e, stackTrace) {
      Logger.error('Error al obtener UUIDs locales de alumnos', e, stackTrace);
      return {};
    }
  }

  Future<void> _saveStudentBindings(
    Map<String, Map<String, dynamic>> bindings,
  ) async {
    try {
      await _box?.put(_studentDeviceBindingsKey, jsonEncode(bindings));
    } catch (e, stackTrace) {
      Logger.error('Error al guardar UUIDs locales de alumnos', e, stackTrace);
      rethrow;
    }
  }

  static String classroomKey(String? classroom) {
    if (classroom == null) return '';
    return classroom.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  Map<String, dynamic> _normalizeBeacon(Map<String, dynamic> beacon) {
    final normalized = Map<String, dynamic>.from(beacon);
    final classroom = normalized['classroom']?.toString();
    final key = classroomKey(
      normalized['classroomKey']?.toString() ?? classroom,
    );
    if (classroom != null) {
      normalized['classroom'] = classroom.trim().toUpperCase();
    }
    if (key.isNotEmpty) {
      normalized['classroomKey'] = key;
    }
    return normalized;
  }

  Future<void> saveBeacons(List<Map<String, dynamic>> beacons) async {
    try {
      final byClassroom = <String, Map<String, dynamic>>{};
      final withoutClassroom = <Map<String, dynamic>>[];

      for (final beacon in beacons) {
        final normalized = _normalizeBeacon(beacon);
        final key = classroomKey(
          normalized['classroomKey']?.toString() ??
              normalized['classroom']?.toString(),
        );
        if (key.isEmpty) {
          withoutClassroom.add(normalized);
          continue;
        }
        byClassroom[key] = normalized;
      }

      final normalizedBeacons = [...byClassroom.values, ...withoutClassroom];
      final beaconsJson = jsonEncode(normalizedBeacons);
      await _box?.put(_beaconsKey, beaconsJson);
      Logger.info(
        '${normalizedBeacons.length} configuraciones de aulas guardadas',
      );
    } catch (e, stackTrace) {
      Logger.error('Error al guardar beacons', e, stackTrace);
    }
  }

  List<Map<String, dynamic>>? getBeacons() {
    try {
      final beaconsJson = _box?.get(_beaconsKey) as String?;
      if (beaconsJson != null) {
        final jsonList = jsonDecode(beaconsJson) as List<dynamic>;
        return jsonList.map((item) => Map<String, dynamic>.from(item)).toList();
      }
      return null;
    } catch (e, stackTrace) {
      Logger.error('Error al obtener beacons', e, stackTrace);
      return null;
    }
  }

  String? getBeaconUuidForClassroom(String classroom) {
    return getBeaconForClassroom(classroom)?['uuid'] as String?;
  }

  Map<String, dynamic>? getBeaconForClassroom(String classroom) {
    try {
      final beacons = getBeacons();
      if (beacons == null) return null;
      final targetKey = classroomKey(classroom);
      if (targetKey.isEmpty) return null;

      for (final beacon in beacons) {
        final beaconKey = classroomKey(
          beacon['classroomKey']?.toString() ?? beacon['classroom']?.toString(),
        );
        if (beaconKey == targetKey) {
          return beacon;
        }
      }
      return null;
    } catch (e, stackTrace) {
      Logger.error(
        'Error al buscar beacon para salon $classroom',
        e,
        stackTrace,
      );
      return null;
    }
  }
}
