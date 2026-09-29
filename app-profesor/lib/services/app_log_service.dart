import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:hive_flutter/hive_flutter.dart';

typedef LogUserIdentifierProvider = String? Function();

class AppLogService with WidgetsBindingObserver {
  AppLogService._({AppLogTransport? transport})
    : _transport = transport ?? HttpAppLogTransport();

  static final AppLogService instance = AppLogService._();

  @visibleForTesting
  factory AppLogService.forTesting(AppLogTransport transport) =>
      AppLogService._(transport: transport);

  static const _queueBoxName = 'presencia_app_log_queue_v1';
  static const _metadataBoxName = 'presencia_app_log_metadata_v1';
  static const _installationIdKey = 'installation_id';
  static const _sequenceKey = 'sequence';
  static const _batchSize = 50;
  static const _maxBatchBytes = 800000;
  static const _retryTick = Duration(seconds: 5);
  static const _maxRetryDelay = Duration(seconds: 30);

  final AppLogTransport _transport;
  final Random _random = Random.secure();
  Box<dynamic>? _queue;
  Box<dynamic>? _metadata;
  Timer? _retryTimer;
  bool _flushing = false;
  bool _initialized = false;
  bool _autoFlush = true;
  bool _readingUserIdentifier = false;
  Future<void> _writeTail = Future<void>.value();
  int _failedAttempts = 0;
  DateTime _nextAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);
  late String _baseUrl;
  late String _ingestionKey;
  late String _application;
  late String _appVersion;
  late String _buildNumber;
  late String _installationId;
  final String _appSessionId = _uuidV4Static();
  LogUserIdentifierProvider? _userIdentifierProvider;

  bool get isInitialized => _initialized;
  int get pendingCount => _queue?.length ?? 0;

  Future<void> initialize({
    required String baseUrl,
    required String ingestionKey,
    required String application,
    required String appVersion,
    required String buildNumber,
    LogUserIdentifierProvider? userIdentifierProvider,
    bool scheduleRetries = true,
    bool autoFlush = true,
    Box<dynamic>? queueBox,
    Box<dynamic>? metadataBox,
  }) async {
    if (_initialized) {
      _userIdentifierProvider =
          userIdentifierProvider ?? _userIdentifierProvider;
      return;
    }
    _baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    _ingestionKey = ingestionKey;
    _application = application;
    _appVersion = appVersion;
    _buildNumber = buildNumber;
    _userIdentifierProvider = userIdentifierProvider;
    _autoFlush = autoFlush;
    _queue = queueBox ?? await Hive.openBox<dynamic>(_queueBoxName);
    _metadata = metadataBox ?? await Hive.openBox<dynamic>(_metadataBoxName);
    _installationId = _metadata!.get(_installationIdKey)?.toString() ?? '';
    if (_installationId.isEmpty) {
      _installationId = _uuidV4();
      await _metadata!.put(_installationIdKey, _installationId);
    }
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    if (scheduleRetries) {
      _retryTimer = Timer.periodic(_retryTick, (_) => unawaited(flush()));
    }
    await record(
      level: 'INFO',
      eventName: 'app.started',
      message: 'Aplicación iniciada.',
      context: {'pendingEventsAtStartup': pendingCount},
    );
  }

  void setUserIdentifierProvider(LogUserIdentifierProvider provider) {
    _userIdentifierProvider = provider;
  }

  Future<void> record({
    required String level,
    required String eventName,
    required String message,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
    String? correlationId,
  }) async {
    final queue = _queue;
    final metadata = _metadata;
    // El callback de identidad puede usar servicios que también registran
    // errores. No permitir que un log genere otro al consultar sus metadatos.
    if (!_initialized ||
        queue == null ||
        metadata == null ||
        _readingUserIdentifier) {
      return;
    }
    final previousWrite = _writeTail;
    final currentWrite = Completer<void>();
    _writeTail = currentWrite.future;
    await previousWrite;
    try {
      final storedSequence = metadata.get(_sequenceKey, defaultValue: 0);
      final sequence = storedSequence is int && storedSequence >= 0
          ? storedSequence + 1
          : DateTime.now().microsecondsSinceEpoch;
      final eventId = _uuidV4();
      final now = DateTime.now();
      final userIdentifier = _safeUserIdentifier();
      final redactedMessage = _redactText(message);
      final sanitizedContext = context == null || context.isEmpty
          ? null
          : _sanitizeContext(context);
      final deviceModel = _safePlatformValue(
        () => Platform.localHostname,
        fallback: '',
        maxLength: 160,
      );
      final event = <String, dynamic>{
        'eventId': eventId,
        'sequence': sequence,
        'level': _normalizeLevel(level),
        'application': _application,
        'eventName': _normalizeEventName(eventName),
        'message': _requiredText(
          redactedMessage,
          fallback: _normalizeEventName(eventName),
          maxLength: 8000,
        ),
        'occurredAt': now.toUtc().toIso8601String(),
        'installationId': _installationId,
        'appSessionId': _appSessionId,
        if (userIdentifier != null && userIdentifier.isNotEmpty)
          'userIdentifier': _truncate(_redactText(userIdentifier), 160),
        'appVersion': _requiredText(
          _appVersion,
          fallback: 'unknown',
          maxLength: 40,
        ),
        'buildNumber': _requiredText(
          _buildNumber,
          fallback: 'unknown',
          maxLength: 40,
        ),
        'platform': _safePlatformValue(
          () => Platform.operatingSystem,
          fallback: 'unknown',
          maxLength: 40,
        ),
        'osVersion': _safePlatformValue(
          () => Platform.operatingSystemVersion,
          fallback: 'unknown',
          maxLength: 500,
        ),
        if (deviceModel.isNotEmpty) 'deviceModel': deviceModel,
        'locale': _safePlatformValue(
          () => Platform.localeName,
          fallback: 'unknown',
          maxLength: 40,
        ),
        'timezoneOffset': _timezoneOffset(now.timeZoneOffset),
        if (error != null)
          'errorType': _truncate(error.runtimeType.toString(), 240),
        if (error != null)
          'errorMessage': _truncate(_redactText(error.toString()), 8000),
        if (stackTrace != null)
          'stackTrace': _truncate(_redactText(stackTrace.toString()), 32000),
        if (correlationId != null && correlationId.trim().isNotEmpty)
          'correlationId': _truncate(correlationId.trim(), 128),
        'context': ?sanitizedContext,
      };
      // Commit sequence first. A crash can leave a gap but cannot reuse it.
      await metadata.put(_sequenceKey, sequence);
      await queue.put(eventId, event);
      if (_autoFlush) unawaited(flush());
    } catch (logError, logStack) {
      developer.log(
        'No se pudo persistir un log local.',
        name: 'APP_LOG_QUEUE',
        error: logError,
        stackTrace: logStack,
      );
    } finally {
      currentWrite.complete();
    }
  }

  Future<void> flush({bool force = false}) async {
    final queue = _queue;
    if (!_initialized || queue == null || queue.isEmpty || _flushing) return;
    if (!force && DateTime.now().isBefore(_nextAttemptAt)) return;
    _flushing = true;
    try {
      while (queue.isNotEmpty) {
        final events =
            queue.values
                .whereType<Map>()
                .map((value) => Map<String, dynamic>.from(value))
                .toList(growable: false)
              ..sort(
                (left, right) => (left['sequence'] as int).compareTo(
                  right['sequence'] as int,
                ),
              );
        final batch = _takeBatchWithinByteLimit(events);
        if (batch.isEmpty) return;
        final acknowledged = await _transport.send(
          baseUrl: _baseUrl,
          ingestionKey: _ingestionKey,
          payload: {
            'schemaVersion': 1,
            'batchId': _uuidV4(),
            'sentAt': DateTime.now().toUtc().toIso8601String(),
            'events': batch,
          },
        );
        final attemptedIds = batch
            .map((event) => event['eventId']?.toString())
            .whereType<String>()
            .toSet();
        final safeAcknowledgements = acknowledged
            .where(attemptedIds.contains)
            .toList(growable: false);
        if (safeAcknowledgements.isEmpty) {
          throw const AppLogTransportException(
            'El servidor no confirmó eventos.',
          );
        }
        await queue.deleteAll(safeAcknowledgements);
        _failedAttempts = 0;
        _nextAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);
        if (safeAcknowledgements.length < attemptedIds.length) break;
      }
    } catch (error, stackTrace) {
      _failedAttempts += 1;
      final exponentialSeconds = min(
        1 << min(_failedAttempts, 5),
        _maxRetryDelay.inSeconds,
      );
      _nextAttemptAt = DateTime.now().add(
        Duration(
          seconds: exponentialSeconds,
          milliseconds: _random.nextInt(1000),
        ),
      );
      developer.log(
        'La cola de logs seguirá guardada y se reintentará.',
        name: 'APP_LOG_QUEUE',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _flushing = false;
    }
  }

  List<Map<String, dynamic>> _takeBatchWithinByteLimit(
    List<Map<String, dynamic>> events,
  ) {
    final batch = <Map<String, dynamic>>[];
    var bytes = 2; // JSON array brackets.
    for (final event in events.take(_batchSize)) {
      final eventBytes = utf8.encode(jsonEncode(event)).length;
      final projectedBytes = bytes + eventBytes + (batch.isEmpty ? 0 : 1);
      if (batch.isNotEmpty && projectedBytes > _maxBatchBytes) break;
      batch.add(event);
      bytes = projectedBytes;
    }
    return batch;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _nextAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);
      unawaited(flush(force: true));
    }
  }

  @visibleForTesting
  Future<void> close() async {
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  String? _safeUserIdentifier() {
    _readingUserIdentifier = true;
    try {
      return _userIdentifierProvider?.call()?.trim();
    } catch (_) {
      return null;
    } finally {
      _readingUserIdentifier = false;
    }
  }

  String _uuidV4() => _uuidV4Static();

  static String _uuidV4Static() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int value) => value.toRadixString(16).padLeft(2, '0');
    final chars = bytes.map(hex).join();
    return '${chars.substring(0, 8)}-${chars.substring(8, 12)}-${chars.substring(12, 16)}-${chars.substring(16, 20)}-${chars.substring(20)}';
  }
}

abstract interface class AppLogTransport {
  Future<Set<String>> send({
    required String baseUrl,
    required String ingestionKey,
    required Map<String, dynamic> payload,
  });
}

class HttpAppLogTransport implements AppLogTransport {
  static const _timeout = Duration(seconds: 10);

  @override
  Future<Set<String>> send({
    required String baseUrl,
    required String ingestionKey,
    required Map<String, dynamic> payload,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client
          .postUrl(Uri.parse(baseUrl).resolve('/api/app-logs/batches'))
          .timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('x-app-log-key', ingestionKey);
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(_timeout);
      final body = await utf8.decodeStream(response).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AppLogTransportException(
          'App Log Service respondió ${response.statusCode}.',
        );
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final data = decoded['data'] as Map?;
      final ids = data?['acceptedEventIds'] as List?;
      if (ids == null) {
        throw const AppLogTransportException('Respuesta de logs inválida.');
      }
      return ids.map((value) => value.toString()).toSet();
    } finally {
      client.close(force: true);
    }
  }
}

class AppLogTransportException implements Exception {
  const AppLogTransportException(this.message);
  final String message;
  @override
  String toString() => message;
}

final RegExp _bearerPattern = RegExp(
  r'Bearer\s+[A-Za-z0-9._~+/=-]+',
  caseSensitive: false,
);
final RegExp _sensitiveValuePattern = RegExp(
  r'''((?:password|secret|token|authorization|cookie|credential|session.?id)["']?\s*[:=]\s*)[^,}\s]+''',
  caseSensitive: false,
);
final RegExp _sensitiveKeyPattern = RegExp(
  r'pass(word)?|secret|token|authorization|cookie|credential|session.?id|private.?key',
  caseSensitive: false,
);

String _redactText(String value) => value
    .replaceAll(_bearerPattern, 'Bearer [REDACTED]')
    .replaceAllMapped(
      _sensitiveValuePattern,
      (match) => '${match.group(1)}[REDACTED]',
    );

Object? _sanitizeValue(Object? value, [int depth = 0]) {
  if (depth > 8) return '[TRUNCATED_DEPTH]';
  if (value == null || value is bool) return value;
  if (value is num) return value.isFinite ? value : value.toString();
  if (value is String) return _truncate(_redactText(value), 8000);
  if (value is Iterable) {
    return value
        .take(100)
        .map((item) => _sanitizeValue(item, depth + 1))
        .toList();
  }
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries.take(100)) {
      final key = _truncate(entry.key.toString(), 100);
      result[key] = _sensitiveKeyPattern.hasMatch(key)
          ? '[REDACTED]'
          : _sanitizeValue(entry.value, depth + 1);
    }
    return result;
  }
  return _truncate(_redactText(value.toString()), 8000);
}

Map<String, dynamic> _sanitizeContext(Map<String, dynamic> context) {
  final sanitized = Map<String, dynamic>.from(_sanitizeValue(context) as Map);
  final serialized = jsonEncode(sanitized);
  if (utf8.encode(serialized).length <= 60000) return sanitized;
  return {'_truncated': true, 'preview': _truncate(serialized, 8000)};
}

String _safePlatformValue(
  String Function() reader, {
  required String fallback,
  required int maxLength,
}) {
  try {
    return _requiredText(
      _redactText(reader()),
      fallback: fallback,
      maxLength: maxLength,
    );
  } catch (_) {
    return fallback;
  }
}

String _requiredText(
  String value, {
  required String fallback,
  required int maxLength,
}) {
  final normalized = value.trim();
  return _truncate(normalized.isEmpty ? fallback : normalized, maxLength);
}

String _truncate(String value, int maxLength) =>
    value.substring(0, min(value.length, maxLength));
String _normalizeLevel(String value) {
  final normalized = value.trim().toUpperCase();
  return const {'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'}.contains(normalized)
      ? normalized
      : 'INFO';
}

String _normalizeEventName(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9._-]'),
    '_',
  );
  return _truncate(normalized.isEmpty ? 'app.log' : normalized, 120);
}

String _timezoneOffset(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final absoluteMinutes = offset.inMinutes.abs();
  return '$sign${(absoluteMinutes ~/ 60).toString().padLeft(2, '0')}:${(absoluteMinutes % 60).toString().padLeft(2, '0')}';
}
