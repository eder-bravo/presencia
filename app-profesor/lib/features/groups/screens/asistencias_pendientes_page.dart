import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/asistencia_registro.dart';
import '../../../shared/models/grupo.dart';
import '../../../core/theme/uat_colors.dart';
import '../../../services/asistencia_local_service.dart';
import '../../../services/attendance_batch_service.dart';
import '../../../services/api_service.dart';
import '../../../services/auth_storage_service.dart';
import '../../authentication/providers/profesor_auth_provider.dart';

class AsistenciasPendientesPage extends ConsumerStatefulWidget {
  final String claseActual;
  final String grupoActualId;
  final List<Grupo>? todosLosGrupos;

  const AsistenciasPendientesPage({
    super.key,
    required this.claseActual,
    required this.grupoActualId,
    this.todosLosGrupos,
  });

  @override
  ConsumerState<AsistenciasPendientesPage> createState() =>
      _AsistenciasPendientesPageState();
}

class _AsistenciasPendientesPageState
    extends ConsumerState<AsistenciasPendientesPage> {
  final AsistenciaLocalService _asistenciaService = AsistenciaLocalService();
  // ApiService se obtiene del provider para que el callback 401 esté activo
  ApiService get _apiService => ref.read(apiServiceProvider);
  AuthStorageService get _authStorage => AuthStorageService();
  List<AsistenciaRegistro> _asistenciasPendientes = [];
  bool _isLoading = true;
  bool _isSyncing = false;

  // Gradientes y colores de acentos (igual que en grupos_page)
  static const List<List<Color>> _cardGradients = [
    [Color(0xFF8B5CF6), Color(0xFF7C3AED)],
    [Color(0xFFFF6B9D), Color(0xFFFF5A8F)],
    [Color(0xFF2DD4BF), Color(0xFF14B8A6)],
    [Color(0xFFFF8A65), Color(0xFFFF7043)],
    [Color(0xFF60A5FA), Color(0xFF3B82F6)],
    [Color(0xFFFF6B9D), Color(0xFFFF5A8F)],
  ];

  // Obtener colores para un grupo específico
  List<Color> _getColoresParaGrupo(String grupoId) {
    if (widget.todosLosGrupos == null) return _cardGradients[0];

    // Buscar el índice del grupo en la lista original
    final index = widget.todosLosGrupos!.indexWhere(
      (g) => g.id == grupoId || g.identificadorUnico == grupoId,
    );

    if (index == -1) return _cardGradients[0];
    return _cardGradients[index % _cardGradients.length];
  }

  @override
  void initState() {
    super.initState();
    _actualizarAsistenciasSinNombre();
    _cargarAsistenciasPendientes();
  }

  @override
  void dispose() {
    super.dispose();
  }

  // Actualizar asistencias antiguas que no tienen nombreClase
  Future<void> _actualizarAsistenciasSinNombre() async {
    if (widget.todosLosGrupos == null) return;

    final todasLasAsistencias = _asistenciaService
        .obtenerAsistenciasPendientes();

    for (var asistencia in todasLasAsistencias) {
      if (asistencia.nombreClase == null || asistencia.nombreClase!.isEmpty) {
        // Buscar el grupo correspondiente usando el identificador único
        final grupo = widget.todosLosGrupos!.firstWhere(
          (g) => g.identificadorUnico == asistencia.grupoId,
          orElse: () => widget.todosLosGrupos!.first,
        );

        // Actualizar con el nombre de la clase
        final actualizado = asistencia.copyWith(nombreClase: grupo.subject);

        await _asistenciaService.guardarAsistencia(actualizado);
      }
    }
  }

  void _cargarAsistenciasPendientes() {
    setState(() {
      _isLoading = true;
    });

    final pendientes = _asistenciaService.obtenerAsistenciasPendientes();

    // Ordenar: primero la clase actual, luego el resto por fecha descendente
    pendientes.sort((a, b) {
      // Primero verificar si es de la clase actual
      final aEsClaseActual = (a.nombreClase ?? '') == widget.claseActual;
      final bEsClaseActual = (b.nombreClase ?? '') == widget.claseActual;

      if (aEsClaseActual && !bEsClaseActual) {
        return -1;
      }
      if (bEsClaseActual && !aEsClaseActual) {
        return 1;
      }
      // Si ambos son de la misma categoría (clase actual o no), ordenar por fecha
      return b.fecha.compareTo(a.fecha);
    });

    setState(() {
      _asistenciasPendientes = pendientes;
      _isLoading = false;
    });
  }

  Future<void> _sincronizarAsistencia(AsistenciaRegistro registro) async {
    setState(() {
      _isSyncing = true;
    });

    await _subirRegistro(registro, showSnackbars: true);

    setState(() {
      _isSyncing = false;
    });

    _cargarAsistenciasPendientes();
  }

  Future<void> _sincronizarTodas() async {
    if (_asistenciasPendientes.isEmpty) return;

    setState(() {
      _isSyncing = true;
    });

    // Mostrar diálogo de progreso
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final palette = context.uatPalette;

        return Dialog(
          backgroundColor: palette.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 50,
                  height: 50,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Enviando asistencias...',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    bool allSuccess = true;
    for (final registro in _asistenciasPendientes) {
      final success = await _subirRegistro(registro, showSnackbars: false);
      if (!success) {
        allSuccess = false;
      }
    }

    if (mounted) {
      Navigator.of(context).pop();
    }

    if (allSuccess) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Todas las asistencias fueron enviadas'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );

        // Volver a la pantalla anterior
        Navigator.of(context).pop();
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No pudimos enviar las asistencias. Intenta de nuevo.',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }

    setState(() {
      _isSyncing = false;
    });

    _cargarAsistenciasPendientes();
  }

  Future<bool> _subirRegistro(
    AsistenciaRegistro registro, {
    required bool showSnackbars,
  }) async {
    final token = _authStorage.getToken();
    final profesor = _authStorage.getProfesor();
    if (token == null || profesor == null) {
      if (showSnackbars && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sesión no válida. Inicia sesión de nuevo.'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    final grupo = _resolveGrupo(registro.grupoId);
    if (grupo == null) {
      if (showSnackbars && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se encontró el grupo para esta asistencia.'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    final registroActualizado = await _migrarRegistroSiNecesario(
      registro,
      grupo,
    );

    final registroEnviado = registroActualizado.copyWith(
      asistenciasAlumnos: Map<String, bool>.from(
        registroActualizado.asistenciasAlumnos,
      ),
    );
    final attendances = _buildAttendances(registroEnviado, grupo);
    if (attendances.isEmpty) {
      // No hay alumnos mapeados — probablemente IDs no coinciden.
      // NO marcar como sincronizada: no se subio nada realmente.
      if (showSnackbars && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No encontramos alumnos en esta lista. Revisa la información del grupo.',
            ),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    final result = await _apiService.uploadAttendance(
      token: token,
      clientRecordId: registroActualizado.id,
      groupId: grupo.id,
      code: grupo.code ?? '',
      groupLetter: grupo.groupLetter ?? '',
      period: grupo.period ?? '',
      date: registroActualizado.fecha,
      attendances: attendances,
      groupName: grupo.name,
      classroom: registroActualizado.salonUtilizado ?? grupo.classroom,
      level: grupo.level,
      schedule: grupo.schedule,
    );

    final uploadSuccess = await result.fold(
      (error) async {
        if (showSnackbars && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return false;
      },
      (response) async {
        await AttendanceBatchService(
          apiService: _apiService,
          localService: _asistenciaService,
        ).registerAcceptedUpload(registroEnviado, response);
        if (showSnackbars && mounted) {
          final isDebugUpload = response['skippedApiRestUpload'] == true;
          final message = isDebugUpload
              ? 'Modo de prueba: asistencia disponible en los reportes.'
              : 'Asistencia del ${_formatearFecha(registroActualizado.fecha)} enviada';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return true;
      },
    );

    return uploadSuccess;
  }

  Grupo? _resolveGrupo(String grupoId) {
    final grupos = widget.todosLosGrupos ?? _authStorage.getGrupos();
    if (grupos == null) return null;

    final direct = grupos.firstWhere(
      (g) => g.id == grupoId,
      orElse: () =>
          const Grupo(id: '', group: '', classroom: '', name: '', students: []),
    );

    if (direct.id.isNotEmpty) return direct;

    final byLegacy = grupos.firstWhere(
      (g) => g.identificadorUnico == grupoId,
      orElse: () =>
          const Grupo(id: '', group: '', classroom: '', name: '', students: []),
    );

    return byLegacy.id.isNotEmpty ? byLegacy : null;
  }

  Future<AsistenciaRegistro> _migrarRegistroSiNecesario(
    AsistenciaRegistro registro,
    Grupo grupo,
  ) async {
    if (registro.grupoId == grupo.id) {
      return registro;
    }

    final nuevoId =
        '${grupo.id}_${registro.fecha.year}-${registro.fecha.month}-${registro.fecha.day}';
    final actualizado = registro.copyWith(grupoId: grupo.id, id: nuevoId);
    await _asistenciaService.guardarAsistencia(actualizado);
    await _asistenciaService.eliminarAsistencia(registro.id);
    return actualizado;
  }

  List<Map<String, dynamic>> _buildAttendances(
    AsistenciaRegistro registro,
    Grupo grupo,
  ) {
    final studentIdMap = <String, String>{};
    for (final student in grupo.students) {
      final studentId = student.id;
      if (studentId != null && studentId.isNotEmpty) {
        studentIdMap[studentId] = studentId;
        studentIdMap[student.number.toString()] = studentId;
        if (student.matricula != null) {
          studentIdMap[student.matricula!.trim().toUpperCase()] = studentId;
        }
      }
    }

    final attendances = <Map<String, dynamic>>[];
    registro.asistenciasAlumnos.forEach((key, present) {
      final studentId =
          studentIdMap[key] ?? studentIdMap[key.trim().toUpperCase()];
      if (studentId == null) {
        return;
      }
      attendances.add({
        'studentId': studentId,
        'num_pase_lista': 1,
        'num_dia': registro.fecha.weekday,
        'sn_asistencia': present,
      });
    });

    return attendances;
  }

  String _formatearFecha(DateTime fecha) {
    final dias = ['Dom', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb'];
    final meses = [
      'Ene',
      'Feb',
      'Mar',
      'Abr',
      'May',
      'Jun',
      'Jul',
      'Ago',
      'Sep',
      'Oct',
      'Nov',
      'Dic',
    ];

    final dia = dias[fecha.weekday % 7];
    final mes = meses[fecha.month - 1];

    return '$dia ${fecha.day} $mes';
  }

  String _formatearHora(DateTime? dateTime) {
    if (dateTime == null) return '--:--';
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;
    final isLightMode = context.isUatLightMode;

    return Scaffold(
      backgroundColor: palette.appBackground,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: palette.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Asistencias pendientes',
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isLightMode
              ? Brightness.dark
              : Brightness.light,
          statusBarBrightness: isLightMode ? Brightness.light : Brightness.dark,
          systemNavigationBarColor: palette.appBackground,
          systemNavigationBarIconBrightness: isLightMode
              ? Brightness.dark
              : Brightness.light,
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
              ),
            )
          : _asistenciasPendientes.isEmpty
          ? _buildEmptyState()
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(
                      top: 100,
                      left: 16,
                      right: 16,
                      bottom: 100,
                    ),
                    itemCount: _asistenciasPendientes.length,
                    itemBuilder: (context, index) {
                      final registro = _asistenciasPendientes[index];
                      final esClaseActual =
                          (registro.nombreClase ?? '') == widget.claseActual;

                      // Mostrar encabezado solo para el primer elemento de la clase actual
                      final mostrarEncabezado = index == 0 && esClaseActual;
                      final mostrarEncabezadoOtros =
                          index > 0 &&
                              esClaseActual &&
                              !((_asistenciasPendientes[index - 1]
                                          .nombreClase ??
                                      '') ==
                                  widget.claseActual) ||
                          (index > 0 &&
                              !esClaseActual &&
                              ((_asistenciasPendientes[index - 1].nombreClase ??
                                      '') ==
                                  widget.claseActual));

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (mostrarEncabezado) ...[
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 4,
                                bottom: 12,
                                top: 8,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.star_rounded,
                                    color: _getColoresParaGrupo(
                                      registro.grupoId,
                                    )[0],
                                    size: 20,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'CLASE ACTUAL - ${widget.claseActual.toUpperCase()}',
                                      style: TextStyle(
                                        color: _getColoresParaGrupo(
                                          registro.grupoId,
                                        )[0],
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (mostrarEncabezadoOtros) ...[
                            const Padding(
                              padding: EdgeInsets.only(
                                left: 4,
                                bottom: 12,
                                top: 24,
                              ),
                              child: Text(
                                'OTRAS CLASES',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                          ],
                          _buildAsistenciaCard(registro, esClaseActual),
                          const SizedBox(height: 12),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
      floatingActionButton: _asistenciasPendientes.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _isSyncing ? null : _sincronizarTodas,
              backgroundColor: Colors.orange,
              icon: _isSyncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.cloud_upload, color: Colors.white),
              label: Text(
                _isSyncing ? 'Enviando...' : 'Enviar todas',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildEmptyState() {
    final palette = context.uatPalette;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.cloud_done, size: 60, color: Colors.green),
          ),
          const SizedBox(height: 24),
          Text(
            'Todo enviado',
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'No hay asistencias pendientes de enviar',
            style: TextStyle(color: palette.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildAsistenciaCard(AsistenciaRegistro registro, bool esClaseActual) {
    final palette = context.uatPalette;
    final tieneEntrada = registro.horaEntrada != null;
    final tieneSalida = registro.horaSalida != null;
    final alumnosPresentes = registro.asistenciasAlumnos.values
        .where((asistio) => asistio)
        .length;
    final totalAlumnos = registro.asistenciasAlumnos.length;

    // Buscar el grupo correspondiente para obtener la letra del grupo
    final grupo = widget.todosLosGrupos?.firstWhere(
      (g) => g.identificadorUnico == registro.grupoId,
      orElse: () => widget.todosLosGrupos!.first,
    );
    final letraGrupo = grupo?.group ?? registro.grupoId.split('_').last;

    // Obtener los colores del grupo
    final coloresGrupo = _getColoresParaGrupo(registro.grupoId);
    final colorPrincipal = coloresGrupo[0];

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: esClaseActual
            ? Border.all(
                color: colorPrincipal.withValues(alpha: 0.5),
                width: 1.5,
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: palette.shadow,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Encabezado con clase, grupo y fecha
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: esClaseActual
                  ? colorPrincipal.withValues(alpha: 0.15)
                  : palette.surfaceMuted,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: esClaseActual
                        ? colorPrincipal.withValues(alpha: 0.2)
                        : palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.class_,
                    color: esClaseActual ? colorPrincipal : palette.iconMuted,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        registro.nombreClase ?? 'Sin nombre',
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            'Grupo $letraGrupo',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            ' • ',
                            style: TextStyle(
                              color: palette.textTertiary,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            _formatearFecha(registro.fecha),
                            style: TextStyle(
                              color: palette.textTertiary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _isSyncing
                      ? null
                      : () => _sincronizarAsistencia(registro),
                  icon: _isSyncing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                      : Icon(Icons.cloud_upload, color: colorPrincipal),
                ),
              ],
            ),
          ),

          // Detalles de asistencia
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Mi asistencia
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.person,
                            color: palette.textSecondary,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'MI ASISTENCIA',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildTiempoChip(
                              'Entrada',
                              _formatearHora(registro.horaEntrada),
                              Icons.login,
                              tieneEntrada ? Colors.green : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildTiempoChip(
                              'Salida',
                              _formatearHora(registro.horaSalida),
                              Icons.logout,
                              tieneSalida ? Colors.blue : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Asistencia de alumnos
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.group,
                            color: palette.textSecondary,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'ASISTENCIA DE ALUMNOS',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '$alumnosPresentes presentes',
                                  style: TextStyle(
                                    color: palette.textPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '$alumnosPresentes/$totalAlumnos',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTiempoChip(
    String label,
    String hora,
    IconData icon,
    Color color,
  ) {
    final palette = context.uatPalette;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                hora,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
