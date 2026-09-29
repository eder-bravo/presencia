import 'dart:convert';
import 'dart:io';

import 'package:appprofesoresuniversidad/services/app_log_service.dart';
import 'package:appprofesoresuniversidad/services/auth_storage_service.dart';
import 'package:appprofesoresuniversidad/shared/models/profesor.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'audit: fixed identity callback keeps the log queue stable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'professor-storage-audit-',
      );
      Hive.init(directory.path);
      FlutterSecureStorage.setMockInitialValues({});
      final auth = AuthStorageService();
      await auth.init();
      await auth.saveProfesor(
        const Profesor(
          id: 'audit-synthetic',
          name: 'Synthetic audit fixture',
          institutionalEmail: 'storage-audit@example.invalid',
        ),
      );

      final service = AppLogService.instance;
      final queue = await Hive.openBox<dynamic>('audit-log-queue');
      final metadata = await Hive.openBox<dynamic>('audit-log-metadata');
      var identityReads = 0;
      final stopwatch = Stopwatch()..start();
      await service.initialize(
        baseUrl: 'https://example.invalid',
        ingestionKey: 'unused-no-network',
        application: 'PROFESSOR',
        appVersion: 'audit',
        buildNumber: '1',
        scheduleRetries: false,
        autoFlush: false,
        queueBox: queue,
        metadataBox: metadata,
        userIdentifierProvider: () {
          // Test-only fuse to bound writes if the original bug regresses.
          if (++identityReads > 1000) return null;
          return auth.getProfesor()?.institutionalEmail;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      service.setUserIdentifierProvider(() => null);
      await queue.flush();
      stopwatch.stop();
      final events = queue.values
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
      final repeated = events
          .where(
            (event) => event['message'] == 'Datos del profesor recuperados',
          )
          .length;
      final beforeCompact = await File(queue.path!).length();
      await queue.compact();
      await queue.flush();
      final afterCompact = await File(queue.path!).length();
      final output = {
        'scenario': 'fixed_identity_callback_offline_equivalent',
        'external_seed_events': 1,
        'test_only_fuse_identity_reads': 1000,
        'total_events': events.length,
        'self_generated_debug_events': repeated,
        'elapsed_ms_desktop_test_only': stopwatch.elapsedMilliseconds,
        'hive_file_bytes': beforeCompact,
        'hive_file_bytes_after_compact': afterCompact,
        'json_bytes': utf8.encode(jsonEncode(events)).length,
      };
      print('AUDIT_RESULT ${jsonEncode(output)}');
      await File(
        '/tmp/professor_storage_audit_fixed_result.json',
      ).writeAsString(jsonEncode(output));
      expect(events.length, 1);
      expect(repeated, 0);
      expect(afterCompact, beforeCompact);

      await service.close();
      await Hive.close();
      await directory.delete(recursive: true);
    },
  );
}
