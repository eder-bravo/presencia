import 'dart:io';

import 'package:appprofesoresuniversidad/services/auth_storage_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reemplaza vínculos consultados y conserva los de otros grupos',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'student_binding_cache_',
      );
      Hive.init(directory.path);
      FlutterSecureStorage.setMockInitialValues({});
      final storage = AuthStorageService();
      try {
        await storage.init();
        await storage.cacheResolvedStudentDeviceBindings([
          {'matricula': '1001', 'attendanceUuid': 'old-uuid'},
          {'matricula': '1002', 'attendanceUuid': 'revoked-uuid'},
          {'matricula': '2001', 'attendanceUuid': 'other-group-uuid'},
        ]);
        await storage.cacheResolvedStudentDeviceBindings(
          [
            {'matricula': ' 1001 ', 'attendanceUuid': 'NEW-UUID'},
            {'matricula': '9999', 'attendanceUuid': 'outside-roster-uuid'},
          ],
          requestedMatriculas: ['1001', '1002'],
        );
        final cached = {
          for (final b in storage.getStudentDeviceBindings())
            b['matricula']: b['attendanceUuid'],
        };
        expect(cached, {'1001': 'new-uuid', '2001': 'other-group-uuid'});
        await storage.cacheResolvedStudentDeviceBindings(
          [],
          requestedMatriculas: ['1001', '1002'],
        );
        expect(storage.getStudentDeviceBindings().single['matricula'], '2001');
      } finally {
        await Hive.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
