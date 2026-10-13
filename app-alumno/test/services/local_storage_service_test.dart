import 'dart:async';

import 'package:app_alumno/models/attendance_confirmation.dart';
import 'package:app_alumno/models/attendance_history_entry.dart';
import 'package:app_alumno/services/local_storage_service.dart';
import 'package:app_alumno/models/student_schedule_entry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryBox extends Fake implements Box<dynamic> {
  final Map<dynamic, dynamic> contents = {};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) {
    return contents.containsKey(key) ? contents[key] : defaultValue;
  }

  @override
  Future<void> put(dynamic key, dynamic value) async {
    contents[key] = value;
  }

  @override
  Future<int> clear() async {
    final count = contents.length;
    contents.clear();
    return count;
  }
}

class _DelayedWriteBox extends _MemoryBox {
  final firstWriteStarted = Completer<void>();
  final releaseFirstWrite = Completer<void>();
  int writeCount = 0;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    writeCount++;
    if (writeCount == 1) {
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
    }
    await super.put(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('stores the first attendance entry when history is empty', () async {
    final box = _MemoryBox();
    final storage = LocalStorageService.withProfileBox(box);
    final recordedAt = DateTime(2026, 8, 4, 8, 30);

    expect(storage.attendanceHistory, isEmpty);

    await storage.addAttendanceHistoryEntry(
      recordedAt,
      classId: 'group-42',
      className: 'Redes',
      group: 'A',
      classroom: 'LC-3',
    );

    expect(storage.attendanceHistoryCount, 1);
    expect(storage.attendanceHistory.single.recordedAt, recordedAt);
    expect(storage.attendanceHistory.single.classId, 'group-42');
    expect(storage.attendanceHistory.single.className, 'Redes');
    expect(storage.attendanceHistory.single.group, 'A');
    expect(storage.attendanceHistory.single.classroom, 'LC-3');
  });

  test(
    'repeated GATT scans keep only the first attendance for the day',
    () async {
      final box = _MemoryBox();
      final storage = LocalStorageService.withProfileBox(box);
      final confirmation = AttendanceConfirmation.fromGattMessage(
        '{"id":"2200000001","materia":"Redes","dia":"2026-08-04"}',
      );
      final firstRecordedAt = confirmation.recordedAtForHistory(
        DateTime(2026, 8, 4, 8, 30),
      );

      await storage.addAttendanceHistoryEntry(
        firstRecordedAt,
        className: confirmation.className,
      );
      await storage.addAttendanceHistoryEntry(
        confirmation.recordedAtForHistory(DateTime(2026, 8, 4, 8, 35)),
        className: confirmation.className,
      );
      // The teacher's attendance day also applies to a later delivery.
      await storage.addAttendanceHistoryEntry(
        confirmation.recordedAtForHistory(DateTime(2026, 8, 5, 9, 15)),
        className: confirmation.className,
      );

      final reopenedStorage = LocalStorageService.withProfileBox(box);
      expect(reopenedStorage.attendanceHistoryCount, 1);
      expect(
        reopenedStorage.attendanceHistory.single.recordedAt,
        firstRecordedAt,
      );
      expect(box.contents['attendance_history'], hasLength(1));
    },
  );

  test(
    'a repeated class ID preserves the first confirmation details',
    () async {
      final storage = LocalStorageService.withProfileBox(_MemoryBox());
      final firstRecordedAt = DateTime(2026, 8, 4, 8, 30);

      await storage.addAttendanceHistoryEntry(
        firstRecordedAt,
        classId: 'group-42',
        className: 'Redes',
        group: 'A',
        classroom: 'LC-3',
      );
      await storage.addAttendanceHistoryEntry(
        DateTime(2026, 8, 4, 9),
        classId: ' GROUP-42 ',
        className: 'Redes de computadoras',
        group: 'Grupo A',
        classroom: 'LC-4',
      );

      expect(storage.attendanceHistoryCount, 1);
      final entry = storage.attendanceHistory.single;
      expect(entry.recordedAt, firstRecordedAt);
      expect(entry.className, 'Redes');
      expect(entry.group, 'A');
      expect(entry.classroom, 'LC-3');
    },
  );

  test('matches subjects with different casing or whitespace', () async {
    final storage = LocalStorageService.withProfileBox(_MemoryBox());
    final firstRecordedAt = DateTime(2026, 8, 4, 8, 30);

    await storage.addAttendanceHistoryEntry(
      firstRecordedAt,
      className: 'Bases de Datos',
    );
    await storage.addAttendanceHistoryEntry(
      DateTime(2026, 8, 4, 8, 35),
      classId: 'group-42',
      className: '  BASES   DE DATOS  ',
      group: 'A',
      classroom: 'LC-3',
    );

    expect(storage.attendanceHistoryCount, 1);
    expect(storage.attendanceHistory.single.recordedAt, firstRecordedAt);
  });

  test('counts other subjects and the same subject on another day', () async {
    final storage = LocalStorageService.withProfileBox(_MemoryBox());
    final firstDay = DateTime(2026, 8, 4, 23, 59);
    final nextDay = DateTime(2026, 8, 5, 0, 1);

    await storage.addAttendanceHistoryEntry(firstDay, className: 'Redes');
    await storage.addAttendanceHistoryEntry(
      DateTime(2026, 8, 4, 10),
      className: 'Bases de Datos',
    );
    await storage.addAttendanceHistoryEntry(nextDay, className: 'Redes');

    expect(storage.attendanceHistoryCount, 3);
    expect(storage.attendanceHistory.map((entry) => entry.recordedAt), [
      nextDay,
      firstDay,
      DateTime(2026, 8, 4, 10),
    ]);
  });

  test('keeps distinct class IDs and groups with the same subject', () async {
    final storage = LocalStorageService.withProfileBox(_MemoryBox());
    final recordedAt = DateTime(2026, 8, 4, 8, 30);

    for (final id in ['group-42', 'group-43']) {
      await storage.addAttendanceHistoryEntry(
        recordedAt,
        classId: id,
        className: 'Redes',
      );
    }
    for (final group in ['A', 'B']) {
      await storage.addAttendanceHistoryEntry(
        recordedAt,
        className: 'Bases de Datos',
        group: group,
      );
    }

    expect(storage.attendanceHistoryCount, 4);
  });

  test('old duplicate history shows and counts only the first attendance', () {
    final box = _MemoryBox();
    final firstRecordedAt = DateTime(2026, 8, 4, 8, 30);
    box.contents['attendance_history'] = [
      AttendanceHistoryEntry(
        recordedAt: DateTime(2026, 8, 5, 8, 30),
        className: 'Redes',
      ).toStorage(),
      AttendanceHistoryEntry(
        recordedAt: DateTime(2026, 8, 4, 10),
        className: 'Bases de Datos',
      ).toStorage(),
      AttendanceHistoryEntry(
        recordedAt: DateTime(2026, 8, 4, 8, 35),
        className: 'Redes',
        classroom: 'LC-4',
      ).toStorage(),
      AttendanceHistoryEntry(
        recordedAt: firstRecordedAt,
        className: 'Redes',
        classroom: 'LC-3',
      ).toStorage(),
      {'recordedAt': 'invalid'},
    ];
    final storage = LocalStorageService.withProfileBox(box);

    expect(storage.attendanceHistoryCount, 3);
    final firstDayEntry = storage.attendanceHistory.last;
    expect(firstDayEntry.recordedAt, firstRecordedAt);
    expect(firstDayEntry.classroom, 'LC-3');
  });

  test('does not merge legacy records without any class identity', () async {
    final storage = LocalStorageService.withProfileBox(_MemoryBox());

    await storage.addAttendanceHistoryEntry(DateTime(2026, 8, 4, 8));
    await storage.addAttendanceHistoryEntry(DateTime(2026, 8, 4, 10));

    expect(storage.attendanceHistoryCount, 2);
  });

  test(
    'simultaneous confirmations keep the first without losing another class',
    () async {
      final box = _DelayedWriteBox();
      final storage = LocalStorageService.withProfileBox(box);
      final firstRecordedAt = DateTime(2026, 8, 4, 8, 30);
      final firstWrite = storage.addAttendanceHistoryEntry(
        firstRecordedAt,
        className: 'Redes',
      );
      await box.firstWriteStarted.future;

      final repeatedWrite = storage.addAttendanceHistoryEntry(
        DateTime(2026, 8, 4, 8, 35),
        className: 'Redes',
      );
      final otherClassWrite = storage.addAttendanceHistoryEntry(
        DateTime(2026, 8, 4, 10),
        className: 'Bases de Datos',
      );
      box.releaseFirstWrite.complete();
      await Future.wait([firstWrite, repeatedWrite, otherClassWrite]);

      expect(storage.attendanceHistoryCount, 2);
      expect(storage.attendanceHistory.last.recordedAt, firstRecordedAt);
      expect(box.contents['attendance_history'], hasLength(2));
      expect(box.writeCount, 2);
    },
  );

  test('keeps the last synchronized schedule for offline startup', () async {
    final box = _MemoryBox();
    final storage = LocalStorageService.withProfileBox(box);
    const schedule = [
      StudentScheduleEntry(
        externalGroupId: 'group-42',
        subject: 'Redes',
        classroom: 'LC-3',
        slots: [
          StudentScheduleSlot(
            weekday: DateTime.monday,
            raw: '08:00-10:00',
            startTime: '08:00',
            endTime: '10:00',
          ),
        ],
      ),
    ];

    await storage.saveStudentSchedule(schedule);

    expect(storage.studentSchedule, hasLength(1));
    expect(storage.studentSchedule.single.subject, 'Redes');
    expect(storage.studentSchedule.single.slots.single.endTime, '10:00');
  });

  test('keeps coordinator tolerance for offline card locking', () async {
    final storage = LocalStorageService.withProfileBox(_MemoryBox());

    expect(
      storage.attendanceToleranceMinutes,
      LocalStorageService.defaultAttendanceToleranceMinutes,
    );

    await storage.saveAttendanceTolerance(25);

    expect(storage.attendanceToleranceMinutes, 25);
  });

  test(
    'logout clears student data but keeps the stable device identity',
    () async {
      SharedPreferences.setMockInitialValues({
        'student_matricula': '123456',
        'student_attendance_uuid': 'attendance-uuid',
        'student_device_binding_id': 'binding-id',
        'classroom_beacon_uuid': 'classroom-uuid',
      });
      final box = _MemoryBox();
      box.contents.addAll({
        'matricula': '123456',
        'attendance_uuid': 'attendance-uuid',
        'device_binding_id': 'binding-id',
        'institutional_email': 'alumno@alumnos.uat.edu.mx',
        'classroom_beacon_uuid': 'classroom-uuid',
        'academic_profile': <String, dynamic>{'matricula': '123456'},
        'student_schedule': <dynamic>[],
        'attendance_history': <dynamic>[],
      });
      final storage = LocalStorageService.withProfileBox(box);

      await storage.clearStudentSession();

      expect(storage.isProfileSet, isFalse);
      expect(storage.academicProfile, isNull);
      expect(storage.studentSchedule, isEmpty);
      expect(storage.attendanceHistory, isEmpty);
      expect(storage.attendanceUuid, 'attendance-uuid');
      expect(storage.deviceBindingId, 'binding-id');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('student_matricula'), isNull);
      expect(prefs.getString('student_attendance_uuid'), isNull);
      expect(prefs.getString('student_device_binding_id'), isNull);
      expect(prefs.getString('classroom_beacon_uuid'), isNull);
    },
  );

  test('logout discards the fixed App Review device identity', () async {
    SharedPreferences.setMockInitialValues({
      'student_matricula': 'APPREVIEW01',
      'student_attendance_uuid': '00000000-0000-4000-8000-000000000903',
      'student_device_binding_id': 'review-binding-id',
    });
    final box = _MemoryBox();
    box.contents.addAll({
      'matricula': 'APPREVIEW01',
      'attendance_uuid': '00000000-0000-4000-8000-000000000903',
      'device_binding_id': 'review-binding-id',
      'app_review_demo_mode': true,
    });
    final storage = LocalStorageService.withProfileBox(box);

    await storage.clearStudentSession();

    expect(storage.isProfileSet, isFalse);
    expect(storage.attendanceUuid, isEmpty);
    expect(storage.deviceBindingId, isEmpty);
  });
}
