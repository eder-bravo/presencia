import '../data/models/uat_asistencia_model.dart';
import '../shared/models/alumno.dart';
import '../shared/models/asistencia_registro.dart';
import '../shared/models/grupo.dart';
import 'api_service.dart';
import 'asistencia_local_service.dart';

class PreparedAttendanceBatch {
  final List<Map<String, dynamic>> payload;
  final Map<String, AsistenciaRegistro> recordsById;
  final int skipped;

  const PreparedAttendanceBatch({
    required this.payload,
    required this.recordsById,
    required this.skipped,
  });
}

class DebugAttendanceBatchResult {
  final int accepted;
  final int skipped;
  final int failed;

  const DebugAttendanceBatchResult({
    required this.accepted,
    required this.skipped,
    required this.failed,
  });
}

/// Single responsibility: translate local attendance snapshots into the
/// idempotent batch contract and transfer ownership to the server.
class AttendanceBatchService {
  final ApiService _apiService;
  final AsistenciaLocalService _localService;

  AttendanceBatchService({
    ApiService? apiService,
    AsistenciaLocalService? localService,
  }) : _apiService = apiService ?? ApiService(),
       _localService = localService ?? AsistenciaLocalService();

  PreparedAttendanceBatch prepare(
    List<AsistenciaRegistro> records,
    List<Grupo> groups,
  ) {
    final payload = <Map<String, dynamic>>[];
    final recordsById = <String, AsistenciaRegistro>{};
    var skipped = 0;

    for (final record in records) {
      final group = _resolveGroup(record, groups);
      final idGrupo = group == null
          ? null
          : int.tryParse(group.id) ?? int.tryParse(group.code ?? '');
      if (group == null || idGrupo == null || idGrupo <= 0) {
        skipped++;
        continue;
      }

      final attendances = _buildAttendances(record, group)
          .map(
            (item) => {
              'id_alumno': item['id_alumno'],
              'num_pase_lista': item['num_pase_lista'],
              'num_dia': item['num_dia'],
              'sn_asistencia': item['sn_asistencia'],
            },
          )
          .toList(growable: false);
      if (attendances.isEmpty) {
        skipped++;
        continue;
      }

      recordsById[record.id] = record;
      payload.add({
        'clientRecordId': record.id,
        'Id_Grupo': idGrupo,
        'Fec_Ini': formatUatWeekStart(record.fecha),
        'Asistencia': attendances,
      });
    }

    return PreparedAttendanceBatch(
      payload: payload,
      recordsById: recordsById,
      skipped: skipped,
    );
  }

  Future<DebugAttendanceBatchResult> submitDebugReportOnly({
    required String token,
    required List<AsistenciaRegistro> records,
    required List<Grupo> groups,
  }) async {
    var accepted = 0;
    var skipped = 0;
    var failed = 0;

    for (final record in records) {
      final group = _resolveGroup(record, groups);
      if (group == null) {
        skipped++;
        continue;
      }

      final enviado = record.copyWith(
        asistenciasAlumnos: Map<String, bool>.from(record.asistenciasAlumnos),
      );
      final result = await _apiService.uploadAttendance(
        token: token,
        clientRecordId: record.id,
        groupId: group.id,
        code: group.code ?? record.grupoCode ?? '',
        groupLetter:
            group.groupLetter ?? record.grupoGroupLetter ?? group.group,
        period: group.period ?? record.grupoPeriod ?? '',
        date: record.fecha,
        attendances: _buildAttendances(enviado, group),
        groupName: group.name,
        classroom: record.salonUtilizado ?? group.classroom,
        level: group.level,
        schedule: group.schedule,
      );

      await result.fold(
        (_) async {
          failed++;
        },
        (response) async {
          await registerAcceptedUpload(enviado, response);
          accepted++;
        },
      );
    }

    return DebugAttendanceBatchResult(
      accepted: accepted,
      skipped: skipped,
      failed: failed,
    );
  }

  Future<DebugAttendanceBatchResult> submitDirectToBackend({
    required String token,
    required List<AsistenciaRegistro> records,
    required List<Grupo> groups,
  }) async {
    var accepted = 0;
    var skipped = 0;
    var failed = 0;

    for (final record in records) {
      final group = _resolveGroup(record, groups);
      if (group == null) {
        skipped++;
        continue;
      }

      final enviado = record.copyWith(
        asistenciasAlumnos: Map<String, bool>.from(record.asistenciasAlumnos),
      );
      final attendances = _buildAttendances(enviado, group);
      if (attendances.isEmpty) {
        skipped++;
        continue;
      }

      final result = await _apiService.uploadAttendance(
        token: token,
        clientRecordId: record.id,
        groupId: group.id,
        code: group.code ?? record.grupoCode ?? '',
        groupLetter:
            group.groupLetter ?? record.grupoGroupLetter ?? group.group,
        period: group.period ?? record.grupoPeriod ?? '',
        date: record.fecha,
        attendances: attendances,
        groupName: group.name,
        classroom: record.salonUtilizado ?? group.classroom,
        level: group.level,
        schedule: group.schedule,
      );

      await result.fold(
        (_) async {
          failed++;
        },
        (response) async {
          await registerAcceptedUpload(enviado, response);
          accepted++;
        },
      );
    }

    return DebugAttendanceBatchResult(
      accepted: accepted,
      skipped: skipped,
      failed: failed,
    );
  }

  /// Algunas capturas ya están completas o no requieren publicación externa
  /// (clases compartidas / revisión). En esos casos no habrá un job que consultar.
  Future<void> registerAcceptedUpload(
    AsistenciaRegistro record,
    Map<String, dynamic> response,
  ) async {
    await _localService.guardarSnapshotEnviado(
      record.id,
      asistenciasEnviadas: record.asistenciasAlumnos,
    );
    final data = response['data'];
    final status = data is Map ? data['uploadStatus'] : null;
    if (status == 'COMPLETED' ||
        status == 'SKIPPED' ||
        response['skippedApiRestUpload'] == true) {
      await markCompletedIfUnchanged(record.id);
    }
  }

  /// Completes the local record only when it still matches the snapshot that
  /// was accepted by the server. Later edits remain pending as a new revision.
  Future<bool> markCompletedIfUnchanged(String clientRecordId) async {
    return _localService.marcarComoSincronizada(clientRecordId);
  }

  Grupo? _resolveGroup(AsistenciaRegistro record, List<Grupo> groups) {
    for (final group in groups) {
      if (group.id == record.grupoId) return group;
    }
    for (final group in groups) {
      if (record.grupoCode != null &&
          record.grupoGroupLetter != null &&
          record.grupoPeriod != null &&
          group.code == record.grupoCode &&
          group.groupLetter == record.grupoGroupLetter &&
          group.period == record.grupoPeriod) {
        return group;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _buildAttendances(
    AsistenciaRegistro record,
    Grupo group,
  ) {
    if (record.asistenciasAlumnos.isEmpty) return const [];

    final attendances = <Map<String, dynamic>>[];
    for (final student in group.students) {
      final id = student.id;
      if (id == null || id.isEmpty) continue;
      final parsedId = int.tryParse(id);
      final present = _attendanceForStudent(record, student);
      attendances.add({
        'studentId': id,
        if (parsedId != null && parsedId > 0) 'id_alumno': parsedId,
        // UAT uses this as the pass/class number for the day, not the
        // student's position in the roster. The app captures one daily pass.
        'num_pase_lista': 1,
        'num_dia': record.fecha.weekday,
        'sn_asistencia': present,
        'status': present ? 'PRESENT' : 'ABSENT',
      });
    }
    return attendances;
  }

  bool _attendanceForStudent(AsistenciaRegistro record, Alumno student) {
    final matricula = student.matricula?.toString().trim().toUpperCase();
    final id = student.id?.toString().trim();
    final number = student.number.toString();
    for (final key in [matricula, id, number]) {
      if (key != null &&
          key.isNotEmpty &&
          record.asistenciasAlumnos.containsKey(key)) {
        return record.asistenciasAlumnos[key] ?? false;
      }
    }
    return false;
  }
}
