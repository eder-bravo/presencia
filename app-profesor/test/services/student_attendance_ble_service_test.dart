import 'dart:convert';

import 'package:appprofesoresuniversidad/services/student_attendance_ble_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.presencia/student_attendance_ble');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('GATT confirmation contains matricula, materia and attendance day', () {
    final confirmation = StudentAttendanceGattConfirmation(
      matricula: ' 2200000001 ',
      materia: 'Redes y telecomunicaciones',
      dia: DateTime(2026, 8, 16, 9, 30),
    );

    final payload =
        jsonDecode(confirmation.toGattPayload()) as Map<String, dynamic>;

    expect(payload, {
      'id': '2200000001',
      'materia': 'Redes y telecomunicaciones',
      'dia': '2026-08-16',
    });
  });

  test('homonymous students receive different GATT identities', () {
    final first = StudentAttendanceGattConfirmation(
      matricula: '2200000001',
      materia: 'Redes',
      dia: DateTime(2026, 8, 16),
    );
    final second = StudentAttendanceGattConfirmation(
      matricula: '2200000002',
      materia: 'Redes',
      dia: DateTime(2026, 8, 16),
    );

    expect(first.toGattPayload(), isNot(second.toGattPayload()));
  });

  test('scans by registered UUID with one payload per student', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return true;
        });

    final started = await StudentAttendanceBleService().startScanning(
      confirmationsByUuid: {
        '11111111-2222-4333-8444-555555555555':
            StudentAttendanceGattConfirmation(
              matricula: '2200000001',
              materia: 'Redes',
              dia: DateTime(2026, 8, 16),
            ),
        'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE':
            StudentAttendanceGattConfirmation(
              matricula: '2200000002',
              materia: 'Redes',
              dia: DateTime(2026, 8, 16),
            ),
      },
    );

    expect(started, isTrue);
    expect(capturedCall?.method, 'startScanning');
    final arguments = capturedCall?.arguments as Map<Object?, Object?>;
    final payloads = arguments['confirmationPayloads'] as Map<Object?, Object?>;
    expect(payloads.keys.toSet(), {
      '11111111222243338444555555555555',
      'aaaaaaaabbbb4ccc8dddeeeeeeeeeeee',
    });
    expect(jsonDecode(payloads['11111111222243338444555555555555'] as String), {
      'id': '2200000001',
      'materia': 'Redes',
      'dia': '2026-08-16',
    });
  });

  test('parses detections emitted by the native GATT scanner', () {
    final detection = StudentAttendanceDetection.fromMap({
      'uuid': '11111111-2222-4333-8444-555555555555',
      'bluetoothAddress': 'AA:BB:CC:DD:EE:FF',
      'rssi': -55,
    });

    expect(detection.uuid, '11111111-2222-4333-8444-555555555555');
    expect(detection.bluetoothAddress, 'AA:BB:CC:DD:EE:FF');
    expect(detection.rssi, -55);
  });

  test(
    'updates and clears scan targets without restarting the scanner',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      final service = StudentAttendanceBleService();
      expect(
        await service.updateBindings(
          confirmationsByUuid: {
            'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE':
                StudentAttendanceGattConfirmation(
                  matricula: '1002',
                  materia: 'Redes',
                  dia: DateTime(2026, 9, 18),
                ),
          },
        ),
        isTrue,
      );
      expect(calls.single.method, 'updateBindings');
      final args = calls.single.arguments as Map;
      final payloads = args['confirmationPayloads'] as Map;
      expect(
        jsonDecode(payloads['aaaaaaaabbbb4ccc8dddeeeeeeeeeeee'] as String),
        {'id': '1002', 'materia': 'Redes', 'dia': '2026-09-18'},
      );
      expect(await service.updateBindings(confirmationsByUuid: {}), isTrue);
      expect(calls.last.arguments, {'confirmationPayloads': {}});
      expect(calls.map((call) => call.method), everyElement('updateBindings'));
    },
  );

  test(
    'confirms a UUID only through an explicit teacher-app acknowledgement',
    () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedCall = call;
            return true;
          });

      final confirmed = await StudentAttendanceBleService().confirmAttendance(
        '11111111-2222-4333-8444-555555555555',
      );

      expect(confirmed, isTrue);
      expect(capturedCall?.method, 'confirmAttendance');
      expect(capturedCall?.arguments, {
        'uuid': '11111111222243338444555555555555',
      });
    },
  );
}
