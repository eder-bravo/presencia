class AttendanceHistoryEntry {
  final DateTime recordedAt;
  final String? classId;
  final String? className;
  final String? group;
  final String? classroom;

  const AttendanceHistoryEntry({
    required this.recordedAt,
    this.classId,
    this.className,
    this.group,
    this.classroom,
  });

  bool isSameDailyAttendanceAs(AttendanceHistoryEntry other) {
    final day = recordedAt.toLocal();
    final otherDay = other.recordedAt.toLocal();
    if (day.year != otherDay.year ||
        day.month != otherDay.month ||
        day.day != otherDay.day) {
      return false;
    }

    final id = _normalizedClassContext(classId);
    final otherId = _normalizedClassContext(other.classId);
    if (id.isNotEmpty && otherId.isNotEmpty) return id == otherId;

    // Student GATT confirmations may only contain the subject and day.
    final name = _normalizedClassContext(className);
    final otherName = _normalizedClassContext(other.className);
    if (name.isEmpty || name != otherName) return false;

    final groupName = _normalizedClassContext(group);
    final otherGroupName = _normalizedClassContext(other.group);
    return groupName.isEmpty ||
        otherGroupName.isEmpty ||
        groupName == otherGroupName;
  }

  Map<String, String> toStorage() => {
    'recordedAt': recordedAt.toIso8601String(),
    'classId': ?classId,
    'className': ?className,
    'group': ?group,
    'classroom': ?classroom,
  };

  static AttendanceHistoryEntry? fromStorage(Object? value) {
    if (value is! Map) return null;

    final recordedAt = DateTime.tryParse(value['recordedAt']?.toString() ?? '');
    if (recordedAt == null) return null;

    return AttendanceHistoryEntry(
      recordedAt: recordedAt,
      classId: _readOptionalString(value['classId']),
      className: _readOptionalString(value['className']),
      group: _readOptionalString(value['group']),
      classroom: _readOptionalString(value['classroom']),
    );
  }
}

String _normalizedClassContext(String? value) =>
    (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

String? _readOptionalString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
