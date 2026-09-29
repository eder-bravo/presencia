import 'dart:convert';
import 'dart:io';

import 'package:appprofesoresuniversidad/services/asistencia_local_service.dart';
import 'package:appprofesoresuniversidad/services/auth_storage_service.dart';
import 'package:appprofesoresuniversidad/shared/models/alumno.dart';
import 'package:appprofesoresuniversidad/shared/models/asistencia_registro.dart';
import 'package:appprofesoresuniversidad/shared/models/grupo.dart';
import 'package:appprofesoresuniversidad/shared/models/profesor.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('audit: storage inventory with synthetic groups and attendance', () async {
    final directory = await Directory.systemTemp.createTemp(
      'professor-inventory-audit-',
    );
    Hive.init(directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    final auth = AuthStorageService();
    final attendance = AsistenciaLocalService();
    await auth.init();
    await attendance.init();
    await auth.saveProfesor(
      const Profesor(
        id: 'audit',
        name: 'Audit Fixture',
        institutionalEmail: 'audit@example.invalid',
      ),
    );
    final groups = List.generate(
      6,
      (group) => Grupo(
        id: 'group-$group',
        group: 'M',
        classroom: 'A-$group',
        name: 'Synthetic subject $group',
        code: 'AUDIT.$group',
        period: '2026-2',
        students: List.generate(
          50,
          (index) => Alumno(
            id: 'student-${group * 50 + index}',
            matricula: '${2251000000 + group * 50 + index}',
            number: index + 1,
            name: 'Synthetic student ${group * 50 + index}',
            photoUrl: 'https://example.invalid/photo/${group * 50 + index}.jpg',
          ),
        ),
      ),
    );
    await auth.saveGrupos(groups, academicCycleId: 150);
    final bindings = groups
        .expand((group) => group.students)
        .map(
          (student) => <String, dynamic>{
            'matricula': student.matricula,
            'attendanceUuid':
                '11111111-2222-4333-8444-${student.matricula!.padLeft(12, '0')}',
            'deviceBindingId': 'binding-${student.id}',
          },
        )
        .toList();
    final authBox = Hive.box<dynamic>('auth');
    final sizes = <String, int>{};
    for (var update = 1; update <= 62; update++) {
      await auth.cacheResolvedStudentDeviceBindings(
        bindings,
        requestedMatriculas: bindings.map((b) => b['matricula'] as String),
      );
      if ([1, 30, 60, 62].contains(update)) {
        await authBox.flush();
        sizes['after_${update}_binding_updates'] = await File(
          authBox.path!,
        ).length();
      }
    }
    expect(auth.getStudentDeviceBindings(), hasLength(300));
    expect(
      sizes['after_62_binding_updates']!,
      lessThan(sizes['after_60_binding_updates']!),
    );

    for (var day = 0; day < 60; day++) {
      for (var group = 0; group < groups.length; group++) {
        final students = {
          for (final student in groups[group].students)
            student.matricula!: true,
        };
        await attendance.guardarAsistencia(
          AsistenciaRegistro(
            id: '$group-$day',
            grupoId: groups[group].id,
            profesorId: 'audit',
            fecha: DateTime(2026, 7, 1).add(Duration(days: day)),
            asistenciasAlumnos: students,
            sincronizado: day < 30,
            asistenciasSincronizadas: day < 30 ? Map.from(students) : null,
            fechaCreacion: DateTime(2026, 7, 1),
            alumnosDetectadosAutomaticamente: students.keys.toList(),
          ),
        );
      }
    }
    final attendanceBox = Hive.box<AsistenciaRegistro>('asistencias');
    await attendanceBox.flush();
    final attendanceBytes = await File(attendanceBox.path!).length();
    await auth.clearSession();
    final afterLogout = attendanceBox.length;
    expect(afterLogout, 360);
    await attendance.limpiarSincronizadas();
    expect(attendanceBox.length, 180);
    expect(attendance.obtenerAsistenciasPendientes(), hasLength(180));

    final output = {
      'scenario': 'synthetic_inventory_not_phone_measurement',
      'groups': 6,
      'students_per_group': 50,
      'binding_count': 300,
      'auth_hive_bytes': sizes,
      'attendance_records': 360,
      'attendance_hive_bytes': attendanceBytes,
      'attendance_records_after_logout': afterLogout,
      'attendance_records_after_explicit_synced_cleanup': attendanceBox.length,
    };
    print('AUDIT_RESULT ${jsonEncode(output)}');
    await File(
      '/tmp/professor_storage_inventory_result.json',
    ).writeAsString(jsonEncode(output));
    await Hive.close();
    await directory.delete(recursive: true);
  });
}
