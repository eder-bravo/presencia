import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

class StudentAttendanceDetection {
  final String uuid;
  final String? bluetoothAddress;
  final int? rssi;
  final DateTime detectedAt;

  StudentAttendanceDetection({
    required this.uuid,
    this.bluetoothAddress,
    this.rssi,
    DateTime? detectedAt,
  }) : detectedAt = detectedAt ?? DateTime.now();

  factory StudentAttendanceDetection.fromMap(Map<dynamic, dynamic> map) {
    return StudentAttendanceDetection(
      uuid: map['uuid'] as String? ?? '',
      bluetoothAddress: map['bluetoothAddress'] as String?,
      rssi: map['rssi'] as int?,
    );
  }

  Map<String, dynamic> toApiJson() {
    return {
      'beaconUuid': uuid,
      'detectedAt': detectedAt.toIso8601String(),
      if (rssi != null) 'rssi': rssi,
      if (bluetoothAddress != null) 'bluetoothAddress': bluetoothAddress,
    };
  }
}

/// Student-specific confirmation written only after the advertised UUID has
/// been matched to that matricula in the active class roster.
class StudentAttendanceGattConfirmation {
  final String matricula;
  final String materia;
  final DateTime dia;

  const StudentAttendanceGattConfirmation({
    required this.matricula,
    required this.materia,
    required this.dia,
  });

  String toGattPayload() {
    return jsonEncode({
      'id': matricula.trim().toUpperCase(),
      'materia': materia.trim(),
      'dia': _formatGattDay(dia),
    });
  }

  static String _formatGattDay(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}

class StudentAttendanceBleService {
  static const _method = MethodChannel('com.presencia/student_attendance_ble');
  static const _events = EventChannel(
    'com.presencia/student_attendance_ble_events',
  );

  Stream<List<StudentAttendanceDetection>> get detectionsStream {
    return _events.receiveBroadcastStream().map((event) {
      if (event is List) {
        return event
            .whereType<Map<dynamic, dynamic>>()
            .map(StudentAttendanceDetection.fromMap)
            .where((detection) => detection.uuid.isNotEmpty)
            .toList();
      }
      return <StudentAttendanceDetection>[];
    });
  }

  Future<bool> startScanning({
    required Map<String, StudentAttendanceGattConfirmation> confirmationsByUuid,
  }) async {
    final confirmationPayloads = _confirmationPayloads(confirmationsByUuid);
    if (confirmationPayloads.isEmpty) return false;

    final result = await _method.invokeMethod<bool>('startScanning', {
      'confirmationPayloads': confirmationPayloads,
    });
    return result == true;
  }

  /// Reemplaza los objetivos sin reiniciar conexiones ni confirmaciones BLE.
  Future<bool> updateBindings({
    required Map<String, StudentAttendanceGattConfirmation> confirmationsByUuid,
  }) async {
    final result = await _method.invokeMethod<bool>('updateBindings', {
      'confirmationPayloads': _confirmationPayloads(confirmationsByUuid),
    });
    return result == true;
  }

  Map<String, String> _confirmationPayloads(
    Map<String, StudentAttendanceGattConfirmation> confirmationsByUuid,
  ) {
    final confirmationPayloads = <String, String>{};
    for (final entry in confirmationsByUuid.entries) {
      final uuid = _normalizeUuid(entry.key);
      final matricula = entry.value.matricula.trim();
      final materia = entry.value.materia.trim();
      if (uuid.isEmpty || matricula.isEmpty || materia.isEmpty) continue;
      confirmationPayloads[uuid] = entry.value.toGattPayload();
    }
    return confirmationPayloads;
  }

  /// Allows the native layer to send feedback to the student only after the
  /// teacher app has accepted and persisted this UUID as present.
  Future<bool> confirmAttendance(String uuid) async {
    final normalizedUuid = _normalizeUuid(uuid);
    if (normalizedUuid.isEmpty) return false;

    final result = await _method.invokeMethod<bool>('confirmAttendance', {
      'uuid': normalizedUuid,
    });
    return result == true;
  }

  Future<void> stopScanning() async {
    await _method.invokeMethod('stopScanning');
  }

  String _normalizeUuid(String uuid) {
    return uuid.replaceAll('-', '').trim().toLowerCase();
  }
}
