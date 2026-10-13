import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attendance_history_entry.dart';
import '../models/student_academic_profile.dart';
import '../models/student_schedule_entry.dart';

class StudentStoredCredentials {
  final String username;
  final String password;

  const StudentStoredCredentials({
    required this.username,
    required this.password,
  });
}

/// Local storage for student profile
class LocalStorageService {
  LocalStorageService();

  @visibleForTesting
  LocalStorageService.withProfileBox(Box<dynamic> profileBox)
    : _profile = profileBox;

  static const String _profileBox = 'student_profile';
  static const String _attendanceHistoryKey = 'attendance_history';
  static const String _academicProfileKey = 'academic_profile';
  static const String _scheduleKey = 'student_schedule';
  static const String _attendanceToleranceKey =
      'teacher_attendance_tolerance_minutes';
  static const String _demoModeKey = 'app_review_demo_mode';
  static const int defaultAttendanceToleranceMinutes = 10;
  static const int _maxAttendanceHistoryEntries = 200;
  static const String _secureUsernameKey = 'uat_student_username';
  static const String _securePasswordKey = 'uat_student_password';
  static const String _secureDeviceBindingTokenKey =
      'student_device_binding_token';
  static const String _legacyClassroomBeaconClearedKey =
      'legacy_classroom_beacon_cleared';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  late Box _profile;
  Future<void> _attendanceHistoryWrite = Future<void>.value();

  Future<void> init() async {
    await Hive.initFlutter();
    _profile = await Hive.openBox(_profileBox);
    await _profile.delete('uat_student_session_id');
  }

  // ── Profile ──────────────────────────────────────────────────

  bool get isProfileSet => _profile.get('matricula') != null;

  String get matricula => _profile.get('matricula', defaultValue: '');

  String get attendanceUuid =>
      _profile.get('attendance_uuid', defaultValue: '');

  String get deviceBindingId =>
      _profile.get('device_binding_id', defaultValue: '');

  String get institutionalEmail =>
      _profile.get('institutional_email', defaultValue: '');

  StudentAcademicProfile? get academicProfile {
    final stored = _profile.get(_academicProfileKey);
    if (stored is Map) {
      return StudentAcademicProfile.fromStorage(
        Map<String, dynamic>.from(stored),
      );
    }
    if (!isProfileSet) return null;
    return StudentAcademicProfile(
      matricula: matricula,
      institutionalEmail: institutionalEmail,
      displayName: institutionalEmail.isEmpty ? matricula : institutionalEmail,
    );
  }

  List<StudentScheduleEntry> get studentSchedule {
    dynamic stored;
    try {
      stored = _profile.get(_scheduleKey);
    } catch (_) {
      // Lightweight test doubles and pre-initialization callers have no box.
      return const [];
    }
    if (stored is! List) return const [];
    return stored
        .whereType<Map>()
        .map(
          (entry) => StudentScheduleEntry.fromStorage(
            Map<String, dynamic>.from(entry),
          ),
        )
        .toList(growable: false);
  }

  int get attendanceToleranceMinutes {
    dynamic stored;
    try {
      stored = _profile.get(_attendanceToleranceKey);
    } catch (_) {
      return defaultAttendanceToleranceMinutes;
    }
    if (stored is! int) return defaultAttendanceToleranceMinutes;
    return stored.clamp(0, 120).toInt();
  }

  String get classroomBeaconUuid =>
      _profile.get('classroom_beacon_uuid', defaultValue: '');

  bool get hasPendingDeviceBindingSync =>
      _profile.get('device_binding_sync_pending', defaultValue: false) == true;

  bool get isDemoMode {
    try {
      return _profile.get(_demoModeKey, defaultValue: false) == true;
    } catch (_) {
      // Lightweight widget-test doubles may not initialize Hive.
      return false;
    }
  }

  bool get hasClassroomBeacon => classroomBeaconUuid.trim().isNotEmpty;

  List<AttendanceHistoryEntry> get attendanceHistory {
    dynamic storedEntries;
    try {
      storedEntries = _profile.get(_attendanceHistoryKey);
    } catch (_) {
      // Lightweight test doubles and pre-initialization callers have no box.
      return const [];
    }
    if (storedEntries is! List) return const [];

    final entries =
        storedEntries
            .map(AttendanceHistoryEntry.fromStorage)
            .whereType<AttendanceHistoryEntry>()
            .toList()
          ..sort((left, right) => left.recordedAt.compareTo(right.recordedAt));

    // Keep the first confirmation, including duplicates from older builds.
    final uniqueEntries = <AttendanceHistoryEntry>[];
    for (final entry in entries) {
      if (!uniqueEntries.any(entry.isSameDailyAttendanceAs)) {
        uniqueEntries.add(entry);
      }
    }
    return uniqueEntries.reversed.toList(growable: false);
  }

  int get attendanceHistoryCount => attendanceHistory.length;

  Future<void> addAttendanceHistoryEntry(
    DateTime recordedAt, {
    String? classId,
    String? className,
    String? group,
    String? classroom,
  }) {
    final entry = AttendanceHistoryEntry(
      recordedAt: recordedAt,
      classId: classId,
      className: className,
      group: group,
      classroom: classroom,
    );
    // Serialize confirmations so repeated BLE callbacks cannot race a write.
    final write = _attendanceHistoryWrite.then((_) async {
      final entries = attendanceHistory.toList();
      if (entries.any(entry.isSameDailyAttendanceAs)) return;

      entries.add(entry);
      entries.sort(
        (left, right) => right.recordedAt.compareTo(left.recordedAt),
      );
      await _profile.put(
        _attendanceHistoryKey,
        entries
            .take(_maxAttendanceHistoryEntries)
            .map((entry) => entry.toStorage())
            .toList(growable: false),
      );
    });
    // Report a failed write to its caller without blocking later attempts.
    _attendanceHistoryWrite = write.catchError((Object _) {});
    return write;
  }

  Future<void> ensureDeviceBinding() async {
    if (!isProfileSet) return;

    await ensureDeviceIdentity();
    await _clearLegacyClassroomBeacon();
    await _syncNativeIdentity(
      matricula: matricula,
      attendanceUuid: attendanceUuid,
      deviceBindingId: deviceBindingId,
    );
  }

  Future<void> ensureDeviceIdentity() async {
    final stableUuid = attendanceUuid.isNotEmpty ? attendanceUuid : _uuidV4();
    final bindingId = deviceBindingId.isNotEmpty ? deviceBindingId : _uuidV4();

    await _profile.put('attendance_uuid', stableUuid);
    await _profile.put('device_binding_id', bindingId);
  }

  Future<void> saveProfile(
    String matricula, {
    String? institutionalEmail,
  }) async {
    await ensureDeviceIdentity();

    await _profile.put('matricula', matricula);
    if (institutionalEmail != null) {
      await _profile.put('institutional_email', institutionalEmail);
    }
    await _syncNativeIdentity(
      matricula: matricula,
      attendanceUuid: attendanceUuid,
      deviceBindingId: deviceBindingId,
    );
  }

  Future<void> saveAcademicProfile(StudentAcademicProfile profile) async {
    await _profile.put(_academicProfileKey, profile.toStorage());
    await saveProfile(
      profile.matricula,
      institutionalEmail: profile.institutionalEmail,
    );
  }

  Future<void> saveStudentSchedule(List<StudentScheduleEntry> schedule) async {
    await _profile.put(
      _scheduleKey,
      schedule.map((entry) => entry.toStorage()).toList(growable: false),
    );
  }

  Future<void> saveAttendanceTolerance(int minutes) async {
    await _profile.put(_attendanceToleranceKey, minutes.clamp(0, 120).toInt());
  }

  Future<void> saveDemoMode(bool enabled) async {
    await _profile.put(_demoModeKey, enabled);
  }

  Future<void> saveAppReviewAttendanceUuid(String uuid) async {
    final normalized = uuid.trim().toLowerCase();
    if (normalized.isEmpty) return;
    await _profile.put('attendance_uuid', normalized);
    await _syncNativeIdentity(
      matricula: matricula,
      attendanceUuid: normalized,
      deviceBindingId: deviceBindingId,
    );
  }

  Future<void> saveInstitutionalCredentials({
    required String username,
    required String password,
  }) async {
    await _secureStorage.write(
      key: _secureUsernameKey,
      value: username.trim().toLowerCase(),
    );
    await _secureStorage.write(key: _securePasswordKey, value: password);
  }

  Future<StudentStoredCredentials?> readInstitutionalCredentials() async {
    final username = await _secureStorage.read(key: _secureUsernameKey);
    final password = await _secureStorage.read(key: _securePasswordKey);

    if (username == null ||
        username.trim().isEmpty ||
        password == null ||
        password.isEmpty) {
      return null;
    }

    return StudentStoredCredentials(
      username: username.trim().toLowerCase(),
      password: password,
    );
  }

  Future<void> clearInstitutionalCredentials() async {
    await _secureStorage.delete(key: _secureUsernameKey);
    await _secureStorage.delete(key: _securePasswordKey);
  }

  Future<void> clearStudentSession() async {
    final preserveDeviceIdentity = !isDemoMode;
    final stableAttendanceUuid = preserveDeviceIdentity ? attendanceUuid : '';
    final stableDeviceBindingId = preserveDeviceIdentity ? deviceBindingId : '';

    await Future.wait<void>([
      _secureStorage.delete(key: _secureUsernameKey),
      _secureStorage.delete(key: _securePasswordKey),
      _secureStorage.delete(key: _secureDeviceBindingTokenKey),
    ]);

    final prefs = await SharedPreferences.getInstance();
    await Future.wait<bool>([
      prefs.remove('student_matricula'),
      prefs.remove('student_attendance_uuid'),
      prefs.remove('student_device_binding_id'),
      prefs.remove('classroom_beacon_uuid'),
    ]);

    await _profile.clear();
    if (stableAttendanceUuid.isNotEmpty) {
      await _profile.put('attendance_uuid', stableAttendanceUuid);
    }
    if (stableDeviceBindingId.isNotEmpty) {
      await _profile.put('device_binding_id', stableDeviceBindingId);
    }
  }

  Future<void> saveDeviceBindingToken(String token) async {
    await _secureStorage.write(key: _secureDeviceBindingTokenKey, value: token);
  }

  Future<String?> readDeviceBindingToken() async {
    return _secureStorage.read(key: _secureDeviceBindingTokenKey);
  }

  Future<void> saveClassroomBeaconUuid(String uuid) async {
    await _profile.put('classroom_beacon_uuid', uuid.trim());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('classroom_beacon_uuid', uuid.trim());
  }

  Future<void> setDeviceBindingSyncPending(bool pending) async {
    await _profile.put('device_binding_sync_pending', pending);
  }

  Future<void> _clearLegacyClassroomBeacon() async {
    final alreadyCleared =
        _profile.get(_legacyClassroomBeaconClearedKey, defaultValue: false) ==
        true;
    if (alreadyCleared) return;

    await _profile.delete('classroom_beacon_uuid');
    await _profile.put(_legacyClassroomBeaconClearedKey, true);
  }

  Future<void> _syncNativeIdentity({
    required String matricula,
    required String attendanceUuid,
    required String deviceBindingId,
  }) async {
    // Also sync to SharedPreferences/UserDefaults so native BLE can read it.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('student_matricula', matricula);
    await prefs.setString('student_attendance_uuid', attendanceUuid);
    await prefs.setString('student_device_binding_id', deviceBindingId);
    await prefs.setString('classroom_beacon_uuid', classroomBeaconUuid);
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
}
