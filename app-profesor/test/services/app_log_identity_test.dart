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
    'identity logs do not grow the queue or suppress independent events',
    () async {
      final directory = await Directory.systemTemp.createTemp('log-identity-');
      Hive.init(directory.path);
      final queue = await Hive.openBox<dynamic>('queue');
      final metadata = await Hive.openBox<dynamic>('metadata');
      final service = AppLogService.forTesting(_NoNetworkTransport());
      addTearDown(() async {
        await service.close();
        await Hive.close();
        await directory.delete(recursive: true);
      });

      var reads = 0;
      var throwFromProvider = false;
      final nestedWrites = <Future<void>>[];
      await service.initialize(
        baseUrl: 'https://example.invalid',
        ingestionKey: 'x' * 32,
        application: 'PROFESSOR',
        appVersion: 'test',
        buildNumber: '1',
        scheduleRetries: false,
        autoFlush: false,
        queueBox: queue,
        metadataBox: metadata,
        userIdentifierProvider: () {
          // Keep a regression from producing an infinite chain in the test.
          if (++reads > 100) return null;
          nestedWrites.add(
            service.record(
              level: 'ERROR',
              eventName: 'test.identity_read',
              message: 'Log emitted from inside the identity provider',
            ),
          );
          if (throwFromProvider) throw StateError('Identity unavailable');
          return 'audit@example.invalid';
        },
      );

      // Await any recursively scheduled writes, including on a regressed build.
      Future<void> drainNestedWrites() async {
        var completed = 0;
        while (completed < nestedWrites.length) {
          final pending = nestedWrites.skip(completed).toList();
          completed += pending.length;
          await Future.wait(pending);
        }
      }

      await drainNestedWrites();
      expect(queue.length, 1);
      expect(reads, 1);
      expect(
        (queue.values.single as Map)['userIdentifier'],
        'audit@example.invalid',
      );

      throwFromProvider = true;
      await service.record(
        level: 'ERROR',
        eventName: 'test.original_error',
        message: 'Keep the original event',
      );
      await drainNestedWrites();
      expect(queue.length, 2);
      expect((queue.values.last as Map).containsKey('userIdentifier'), isFalse);

      throwFromProvider = false;
      await Future.wait(
        List.generate(
          20,
          (index) => service.record(
            level: 'INFO',
            eventName: 'test.independent',
            message: 'Independent event $index',
          ),
        ),
      );
      await drainNestedWrites();
      expect(queue.length, 22);
      expect(reads, 22);
      expect(
        queue.values.where((event) => event['eventName'] == 'test.independent'),
        hasLength(20),
      );
      expect(
        queue.values.any((event) => event['eventName'] == 'test.identity_read'),
        isFalse,
      );
    },
  );

  test(
    'the production identity callback stays bounded, including corrupt auth data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'log-real-identity-',
      );
      Hive.init(directory.path);
      FlutterSecureStorage.setMockInitialValues({});
      final storage = AuthStorageService();
      await storage.init();
      await storage.saveProfesor(
        const Profesor(
          id: 'audit',
          name: 'Audit fixture',
          institutionalEmail: 'audit@example.invalid',
        ),
      );

      final queue = await Hive.openBox<dynamic>('queue');
      final metadata = await Hive.openBox<dynamic>('metadata');
      final service = AppLogService.instance;
      addTearDown(() async {
        service.setUserIdentifierProvider(() => null);
        await service.close();
        await Hive.close();
        await directory.delete(recursive: true);
      });
      var reads = 0;
      await service.initialize(
        baseUrl: 'https://example.invalid',
        ingestionKey: 'x' * 32,
        application: 'PROFESSOR',
        appVersion: 'test',
        buildNumber: '1',
        scheduleRetries: false,
        autoFlush: false,
        queueBox: queue,
        metadataBox: metadata,
        userIdentifierProvider: () {
          // Same production callback, with a test-only fuse on regressions.
          if (++reads > 100) return null;
          return storage.getProfesor()?.institutionalEmail;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(queue.length, 1);
      expect(reads, 1);

      // getProfesor logs errors for invalid stored JSON. It must not start a
      // second chain when called by the diagnostic metadata provider.
      await Hive.box<dynamic>('auth').put('profesor_data', '{invalid json');
      await service.record(
        level: 'ERROR',
        eventName: 'test.original',
        message: 'Original diagnostic',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(queue.length, 2);
      expect(reads, 2);
      expect((queue.values.last as Map)['eventName'], 'test.original');
      expect((queue.values.last as Map).containsKey('userIdentifier'), isFalse);
    },
  );
}

class _NoNetworkTransport implements AppLogTransport {
  @override
  Future<Set<String>> send({
    required String baseUrl,
    required String ingestionKey,
    required Map<String, dynamic> payload,
  }) {
    throw StateError('Identity tests must not use the network');
  }
}
