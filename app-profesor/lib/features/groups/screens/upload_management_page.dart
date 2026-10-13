import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../../services/asistencia_local_service.dart';
import '../../../shared/models/asistencia_registro.dart';
import '../../../core/theme/uat_colors.dart';
import '../../../core/utils/utils.dart';
import '../../../services/api_service.dart';
import '../../../services/auth_storage_service.dart';
import '../../../services/attendance_batch_service.dart';
import '../../../shared/models/grupo.dart';
import 'grupo_detail_page.dart';

class UploadManagementPage extends StatefulWidget {
  final ApiService? apiService;
  final AuthStorageService? authStorage;

  const UploadManagementPage({super.key, this.apiService, this.authStorage});

  @override
  State<UploadManagementPage> createState() => _UploadManagementPageState();
}

class _UploadManagementPageState extends State<UploadManagementPage> {
  final AsistenciaLocalService _asistenciaService = AsistenciaLocalService();
  late final ApiService _apiService = widget.apiService ?? ApiService();
  late final AuthStorageService _authStorage =
      widget.authStorage ?? AuthStorageService();
  late final AttendanceBatchService _attendanceBatchService =
      AttendanceBatchService(
        apiService: _apiService,
        localService: _asistenciaService,
      );
  List<AsistenciaRegistro> _pendientes = [];
  List<AsistenciaRegistro> _sincronizadas = [];
  // Keys (grupoId_date) of records that are currently syncing on the server
  // but the app wasn't present to see the completion (e.g. professor left & came back).
  Set<String> _syncingOnServer = {};
  bool _isLoading = true;
  bool _isUploading = false;
  bool _isPolling = false;
  int _submissionGeneration = 0;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  // Stepper-based progress tracking
  final ValueNotifier<List<_SyncStepData>> _stepsNotifier = ValueNotifier([]);
  // Guards access to _stepsNotifier and setState after widget is disposed
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _cargarAsistencias();
  }

  @override
  void dispose() {
    _disposed = true;
    _stepsNotifier.dispose();
    super.dispose();
  }

  Future<void> _cargarAsistencias() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      // Mostrar datos locales de inmediato — sin esperar la red
      final pendientes = _asistenciaService.obtenerAsistenciasPendientes();
      final sincronizadas = _asistenciaService
          .obtenerAsistenciasSincronizadas();
      if (mounted) {
        setState(() {
          _pendientes = pendientes;
          _sincronizadas = sincronizadas;
          _isLoading = false;
        });
      }

      // Reconciliar con servidor en background (no bloquea la UI)
      if (pendientes.isNotEmpty) {
        _reconciliarEnBackground();
      }
    } catch (e) {
      Logger.error('Error cargando asistencias', e, StackTrace.current);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Reconcilia con el servidor sin bloquear la UI.
  /// Si algo cambió, actualiza el estado silenciosamente.
  void _reconciliarEnBackground() {
    _reconciliarConServidor()
        .then((_) {
          final pendientesActualizados = _asistenciaService
              .obtenerAsistenciasPendientes();
          final sincronizadasActualizadas = _asistenciaService
              .obtenerAsistenciasSincronizadas();
          if (mounted) {
            setState(() {
              _pendientes = pendientesActualizados;
              _sincronizadas = sincronizadasActualizadas;
              // Clear any server-syncing flags that were resolved
              _syncingOnServer.removeWhere((key) {
                return !pendientesActualizados.any((r) {
                  final dateStr =
                      '${r.fecha.year}-${r.fecha.month.toString().padLeft(2, '0')}-${r.fecha.day.toString().padLeft(2, '0')}';
                  return '${r.grupoId}_$dateStr' == key;
                });
              });
            });
          }
        })
        .catchError((e) {
          Logger.error(
            'Error en reconciliación en background',
            e,
            StackTrace.current,
          );
        });
  }

  /// Check the server for records that were already synced or are syncing
  /// (e.g. app was closed during upload).
  /// Only reconciles completed records if the local data hasn't changed.
  Future<void> _reconciliarConServidor() async {
    final token = _authStorage.getToken();
    if (token == null) return;
    final generation = _submissionGeneration;
    final pendientes = _asistenciaService.obtenerAsistenciasPendientes();

    final records = pendientes.map((r) {
      final dateStr =
          '${r.fecha.year}-${r.fecha.month.toString().padLeft(2, '0')}-${r.fecha.day.toString().padLeft(2, '0')}';
      return {'clientRecordId': r.id, 'groupId': r.grupoId, 'date': dateStr};
    }).toList();

    final statusMap = await _apiService.checkSyncedRecordsStatus(
      token: token,
      records: records,
    );

    // Una consulta iniciada antes de un nuevo envío podría confirmar la
    // revisión anterior. Esperar la consulta que corresponde al nuevo envío.
    if (_disposed || _isUploading || generation != _submissionGeneration) {
      return;
    }
    if (statusMap.isEmpty) return;

    final newSyncingOnServer = <String>{};

    for (final registro in pendientes) {
      final dateStr =
          '${registro.fecha.year}-${registro.fecha.month.toString().padLeft(2, '0')}-${registro.fecha.day.toString().padLeft(2, '0')}';
      final key = '${registro.grupoId}_$dateStr';
      final status = statusMap[key];

      if (status == 'COMPLETED' || status == 'SKIPPED') {
        if (await _attendanceBatchService.markCompletedIfUnchanged(
          registro.id,
        )) {
          Logger.info('Reconciliación: marcando como sincronizada $key');
        } else {
          Logger.info(
            'Reconciliación: $key tiene cambios locales posteriores al envío, mantener como pendiente',
          );
        }
      } else if (status == 'IN_PROGRESS' ||
          status == 'PROCESSING' ||
          status == 'PENDING') {
        // The server is still processing this record (professor left mid-upload).
        Logger.info('Reconciliación: $key está sincronizando en el servidor');
        newSyncingOnServer.add(key);
      }
    }

    if (mounted) {
      setState(() => _syncingOnServer = newSyncingOnServer);
      if (newSyncingOnServer.isNotEmpty && !_isUploading && !_isPolling) {
        // Populate the stepper so the UI isn't empty when re-entering mid-sync
        _stepsNotifier.value = [
          _SyncStepData(
            label: 'Preparando el envío',
            status: _StepStatus.completed,
          ),
          _SyncStepData(
            label: 'Información lista',
            status: _StepStatus.completed,
          ),
          _SyncStepData(
            label: 'Enviando asistencias',
            status: _StepStatus.inProgress,
            subtitle:
                '${newSyncingOnServer.length} registro${newSyncingOnServer.length == 1 ? '' : 's'} en proceso...',
          ),
          _SyncStepData(label: '¡Terminado!', status: _StepStatus.pending),
        ];
        // Start polling so the UI clears once jobs finish
        _pollUntilSyncingClears();
      }
    }
  }

  /// Polls the server every 4 seconds while _syncingOnServer is non-empty.
  /// Stops when all jobs finish or the widget is disposed.
  Future<void> _pollUntilSyncingClears() async {
    if (_isPolling) return;
    _isPolling = true;
    try {
      while (!_disposed && _syncingOnServer.isNotEmpty && !_isUploading) {
        await Future.delayed(const Duration(seconds: 4));
        if (_disposed || _isUploading) break;
        await _reconciliarConServidor();
      }

      // Once clear: reload fresh data so synced records move off the pending list
      if (!_disposed && mounted && _syncingOnServer.isEmpty) {
        await _cargarAsistencias();
      }
    } finally {
      _isPolling = false;
    }
  }

  // Get dates that have pending uploads
  Set<DateTime> get _pendingDates {
    return _pendientes.map((a) {
      return DateTime(a.fecha.year, a.fecha.month, a.fecha.day);
    }).toSet();
  }

  // Get dates that are synced
  Set<DateTime> get _syncedDates {
    return _sincronizadas.map((a) {
      return DateTime(a.fecha.year, a.fecha.month, a.fecha.day);
    }).toSet();
  }

  void _showCalendarModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CalendarModal(
        pendingDates: _pendingDates,
        syncedDates: _syncedDates,
        focusedDay: _focusedDay,
        selectedDay: _selectedDay,
        onDaySelected: (selectedDay, focusedDay) {
          setState(() {
            _selectedDay = selectedDay;
            _focusedDay = focusedDay;
          });
        },
      ),
    );
  }

  Future<void> _subirAsistencias() async {
    if (_pendientes.isEmpty || _isUploading) return;

    final token = _authStorage.getToken();
    final grupos = _authStorage.getGrupos() ?? [];
    if (token == null) return;

    setState(() {
      _isUploading = true;
      _submissionGeneration++;
    });
    HapticFeedback.mediumImpact();
    _stepsNotifier.value = [
      _SyncStepData(
        label: 'Preparando asistencias',
        status: _StepStatus.inProgress,
      ),
      _SyncStepData(label: 'Enviando asistencias', status: _StepStatus.pending),
      _SyncStepData(
        label: 'Guardando información',
        status: _StepStatus.pending,
      ),
      _SyncStepData(label: 'Confirmando envío', status: _StepStatus.pending),
    ];

    _updateStep(0, _StepStatus.completed);

    _updateStep(
      1,
      _StepStatus.inProgress,
      subtitle:
          '${_pendientes.length} lista${_pendientes.length == 1 ? '' : 's'} por enviar',
    );
    try {
      final directResult = await _attendanceBatchService.submitDirectToBackend(
        token: token,
        records: List<AsistenciaRegistro>.from(_pendientes),
        groups: grupos,
      );
      _updateStep(
        1,
        directResult.failed > 0 ? _StepStatus.failed : _StepStatus.completed,
        subtitle:
            '${directResult.accepted} aceptada${directResult.accepted == 1 ? '' : 's'}, '
            '${directResult.skipped} omitida${directResult.skipped == 1 ? '' : 's'}, '
            '${directResult.failed} fallida${directResult.failed == 1 ? '' : 's'}',
      );
      _updateStep(
        2,
        directResult.failed > 0 ? _StepStatus.failed : _StepStatus.pending,
        subtitle: directResult.failed > 0
            ? null
            : 'Las listas se guardarán en unos momentos.',
      );
      _updateStep(
        3,
        directResult.failed > 0 ? _StepStatus.failed : _StepStatus.pending,
        subtitle: directResult.failed > 0
            ? 'Las listas fallidas permanecen pendientes.'
            : 'Las asistencias se marcarán como enviadas al finalizar.',
      );
      HapticFeedback.heavyImpact();
    } catch (e, stackTrace) {
      Logger.error('Error enviando asistencias', e, stackTrace);
      _updateStep(1, _StepStatus.failed, subtitle: 'Intenta enviar de nuevo.');
    } finally {
      if (!_disposed && mounted) {
        // La reconciliación debe poder iniciar el polling, incluso si la
        // primera respuesta de estado llega inmediatamente.
        setState(() => _isUploading = false);
        await _cargarAsistencias();
      }
    }
  }

  void _updateStep(
    int index,
    _StepStatus status, {
    String? subtitle,
    String? label,
  }) {
    if (_disposed) return;
    final steps = List<_SyncStepData>.from(_stepsNotifier.value);
    steps[index] = steps[index].copyWith(
      status: status,
      subtitle: subtitle,
      label: label,
    );
    _stepsNotifier.value = steps;
  }

  Widget _buildUploadingState() {
    return ValueListenableBuilder<List<_SyncStepData>>(
      valueListenable: _stepsNotifier,
      builder: (context, steps, _) {
        final palette = context.uatPalette;
        final allCompleted = steps.every(
          (s) => s.status == _StepStatus.completed,
        );
        final anyFailed = steps.any((s) => s.status == _StepStatus.failed);
        final activeStep = steps.cast<_SyncStepData?>().firstWhere(
          (s) => s!.status == _StepStatus.inProgress,
          orElse: () => null,
        );

        return Column(
          children: [
            // Stepper card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: palette.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Text(
                    allCompleted
                        ? '¡Envío completado!'
                        : anyFailed
                        ? 'No pudimos completar el envío'
                        : 'Enviando asistencias...',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (activeStep?.subtitle != null &&
                      activeStep!.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      activeStep.subtitle!,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  // Steps
                  for (int i = 0; i < steps.length; i++)
                    _buildStepItem(steps[i], i, steps.length),
                ],
              ),
            ),
            const Spacer(),
            // Bottom info bar
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.cloud_done, color: Colors.blue.shade400),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Las listas solo se envían cuando pulsas “Enviar asistencias”. Si falla la conexión, permanecen guardadas en este celular.',
                      style: TextStyle(
                        color: Colors.blue.shade400,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ],
        );
      },
    );
  }

  Widget _buildStepItem(_SyncStepData step, int index, int total) {
    final palette = context.uatPalette;
    final isLast = index == total - 1;
    final isActive = step.status == _StepStatus.inProgress;
    final isPast = step.status == _StepStatus.completed;
    final isFailed = step.status == _StepStatus.failed;

    Color circleColor;
    if (isPast) {
      circleColor = Colors.orange;
    } else if (isActive) {
      circleColor = Colors.orange;
    } else if (isFailed) {
      circleColor = Colors.red;
    } else {
      circleColor = palette.border;
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Circle + line
          SizedBox(
            width: 40,
            child: Column(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isPast || isActive || isFailed
                        ? circleColor
                        : Colors.transparent,
                    border: Border.all(color: circleColor, width: 2),
                  ),
                  child: Center(
                    child: isPast
                        ? const Icon(Icons.check, color: Colors.white, size: 18)
                        : isActive
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : isFailed
                        ? const Icon(Icons.close, color: Colors.white, size: 18)
                        : null,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: isPast ? Colors.orange : palette.border,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Text content with optional highlight for active step
          Expanded(
            child: Container(
              margin: EdgeInsets.only(bottom: isLast ? 0 : 24),
              padding: isActive
                  ? const EdgeInsets.all(12)
                  : const EdgeInsets.only(top: 4),
              decoration: isActive
                  ? BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    )
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.label,
                    style: TextStyle(
                      color: step.status == _StepStatus.pending
                          ? palette.textTertiary
                          : palette.textPrimary,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                      fontSize: isActive ? 16 : 14,
                    ),
                  ),
                  if ((isActive || isFailed) &&
                      step.subtitle != null &&
                      step.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      step.subtitle!,
                      style: TextStyle(
                        color: isFailed
                            ? Colors.red.shade300
                            : palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPendingDetailsModal() {
    // Sort: today first, then most recent
    final sorted = List<AsistenciaRegistro>.from(_pendientes)
      ..sort((a, b) => b.fecha.compareTo(a.fecha));

    final grupos = _authStorage.getGrupos() ?? [];
    // Build student name lookup: studentId -> name
    final studentNames = <String, String>{};
    for (final grupo in grupos) {
      for (final student in grupo.students) {
        if (student.id != null) {
          studentNames[student.id!] = student.name;
        }
      }
    }
    // Build grupo name lookup: grupoId -> Grupo
    final grupoMap = <String, Grupo>{};
    for (final grupo in grupos) {
      grupoMap[grupo.id] = grupo;
      grupoMap[grupo.identificadorUnico] = grupo;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _PendingDetailsModal(
        pendientes: sorted,
        studentNames: studentNames,
        grupoMap: grupoMap,
        todosLosGrupos: grupos,
        onDelete: (registroId) async {
          await _asistenciaService.eliminarAsistencia(registroId);
          await _cargarAsistencias();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;

    return Scaffold(
      backgroundColor: palette.appBackground,
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : _buildContent(),
            ),
          ),
          // Botón de cerrar
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: palette.controlBackground,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: palette.controlBorder,
                      width: 0.5,
                    ),
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.close,
                      color: palette.controlIcon,
                      size: 24,
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      Navigator.of(context).pop();
                    },
                  ),
                ),
              ),
            ),
          ),
          // Botón Ver calendario — glassmorphism, esquina superior derecha
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: palette.controlBackground,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: palette.controlBorder,
                      width: 0.5,
                    ),
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.calendar_month_rounded,
                      color: palette.controlIcon,
                      size: 20,
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      _showCalendarModal();
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final palette = context.uatPalette;

    return Column(
      children: [
        const SizedBox(height: 80),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Envío de asistencias',
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 34,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
            ),
          ),
        ),
        const SizedBox(height: 40),
        Expanded(
          child: _isUploading || _syncingOnServer.isNotEmpty
              ? _buildUploadingState()
              : _pendientes.isEmpty
              ? _buildAllSyncedState()
              : _buildPendingState(),
        ),
      ],
    );
  }

  Widget _buildAllSyncedState() {
    final palette = context.uatPalette;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.cloud_done_rounded,
            size: 64,
            color: Colors.green.shade400,
          ),
        ),
        const SizedBox(height: 32),
        Text(
          '¡Estás al día!',
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Todas tus asistencias están guardadas',
          style: TextStyle(color: palette.textSecondary, fontSize: 16),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildPendingState() {
    final palette = context.uatPalette;

    return Column(
      children: [
        // Banner: records being synced server-side (professor left mid-upload)
        if (_syncingOnServer.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.blue.shade400,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${_syncingOnServer.length} registro${_syncingOnServer.length == 1 ? '' : 's'} en proceso. Se actualizará al terminar.',
                    style: TextStyle(color: Colors.blue.shade300, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
        GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            _showPendingDetailsModal();
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: palette.border, width: 0.5),
            ),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.pending_actions_rounded,
                        size: 24,
                        color: Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Asistencias pendientes',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_pendientes.length} registro${_pendientes.length == 1 ? '' : 's'} por enviar',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.list_alt_rounded,
                        color: palette.textSecondary,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Revisar detalles',
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Botón Subir Asistencias — bloqueado si ya hay algo subiendo o procesando en servidor
        Builder(
          builder: (context) {
            final blocked = _isUploading || _syncingOnServer.isNotEmpty;
            return GestureDetector(
              onTap: blocked ? null : _subirAsistencias,
              child: Opacity(
                opacity: blocked ? 0.4 : 1.0,
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 40),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: palette.border, width: 0.5),
                  ),
                  child: Row(
                    children: [
                      // Ícono teal
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E3A38),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: blocked
                            ? const Center(
                                child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Color(0xFF4DB8A8),
                                    strokeWidth: 2.5,
                                  ),
                                ),
                              )
                            : const Icon(
                                Icons.cloud_upload_rounded,
                                color: Color(0xFF4DB8A8),
                                size: 24,
                              ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        _syncingOnServer.isNotEmpty
                            ? 'Enviando...'
                            : 'Enviar asistencias',
                        style: TextStyle(
                          color: blocked
                              ? palette.textTertiary
                              : palette.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Modal bottom sheet for calendar view
class _CalendarModal extends StatefulWidget {
  final Set<DateTime> pendingDates;
  final Set<DateTime> syncedDates;
  final DateTime focusedDay;
  final DateTime? selectedDay;
  final Function(DateTime, DateTime) onDaySelected;

  const _CalendarModal({
    required this.pendingDates,
    required this.syncedDates,
    required this.focusedDay,
    required this.selectedDay,
    required this.onDaySelected,
  });

  @override
  State<_CalendarModal> createState() => _CalendarModalState();
}

class _CalendarModalState extends State<_CalendarModal> {
  late DateTime _focusedDay;
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _focusedDay = widget.focusedDay;
    _selectedDay = widget.selectedDay;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: palette.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Calendario de asistencias',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // Legend
            _buildLegend(),
            const SizedBox(height: 16),
            // Calendar
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TableCalendar(
                  firstDay: DateTime.now().subtract(const Duration(days: 365)),
                  lastDay: DateTime.now().add(const Duration(days: 30)),
                  focusedDay: _focusedDay,
                  rowHeight: 48,
                  daysOfWeekHeight: 24,
                  selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                  onDaySelected: (selectedDay, focusedDay) {
                    setState(() {
                      _selectedDay = selectedDay;
                      _focusedDay = focusedDay;
                    });
                    widget.onDaySelected(selectedDay, focusedDay);
                    HapticFeedback.selectionClick();
                  },
                  onPageChanged: (focusedDay) {
                    setState(() => _focusedDay = focusedDay);
                  },
                  locale: 'es_ES',
                  startingDayOfWeek: StartingDayOfWeek.monday,
                  headerStyle: HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    titleTextStyle: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    leftChevronIcon: Icon(
                      Icons.chevron_left,
                      color: palette.textPrimary,
                      size: 28,
                    ),
                    rightChevronIcon: Icon(
                      Icons.chevron_right,
                      color: palette.textPrimary,
                      size: 28,
                    ),
                  ),
                  daysOfWeekStyle: DaysOfWeekStyle(
                    weekdayStyle: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    weekendStyle: TextStyle(
                      color: palette.textTertiary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  calendarStyle: CalendarStyle(
                    defaultTextStyle: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 16,
                    ),
                    weekendTextStyle: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 16,
                    ),
                    outsideTextStyle: TextStyle(
                      color: palette.textTertiary,
                      fontSize: 16,
                    ),
                    todayDecoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.3),
                      shape: BoxShape.circle,
                    ),
                    todayTextStyle: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    selectedDecoration: BoxDecoration(
                      color: Colors.blue.shade600,
                      shape: BoxShape.circle,
                    ),
                    selectedTextStyle: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    cellMargin: const EdgeInsets.all(6),
                  ),
                  calendarBuilders: CalendarBuilders(
                    defaultBuilder: (context, day, focusedDay) {
                      final normalizedDay = DateTime(
                        day.year,
                        day.month,
                        day.day,
                      );
                      final isPending = widget.pendingDates.contains(
                        normalizedDay,
                      );
                      final isSynced = widget.syncedDates.contains(
                        normalizedDay,
                      );

                      if (isPending) {
                        return _buildDayWithIndicator(day, Colors.orange);
                      } else if (isSynced) {
                        return _buildDayWithIndicator(day, Colors.green);
                      }
                      return null;
                    },
                    todayBuilder: (context, day, focusedDay) {
                      final normalizedDay = DateTime(
                        day.year,
                        day.month,
                        day.day,
                      );
                      final isPending = widget.pendingDates.contains(
                        normalizedDay,
                      );
                      final isSynced = widget.syncedDates.contains(
                        normalizedDay,
                      );

                      Color? indicatorColor;
                      if (isPending) {
                        indicatorColor = Colors.orange;
                      } else if (isSynced) {
                        indicatorColor = Colors.green;
                      }

                      return Container(
                        margin: const EdgeInsets.all(4),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.3),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${day.day}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                            if (indicatorColor != null)
                              Positioned(
                                bottom: 2,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: indicatorColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                    selectedBuilder: (context, day, focusedDay) {
                      final normalizedDay = DateTime(
                        day.year,
                        day.month,
                        day.day,
                      );
                      final isPending = widget.pendingDates.contains(
                        normalizedDay,
                      );
                      final isSynced = widget.syncedDates.contains(
                        normalizedDay,
                      );
                      final indicatorColor = isPending
                          ? Colors.orange
                          : isSynced
                          ? Colors.green
                          : null;
                      return Container(
                        margin: const EdgeInsets.all(4),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.blue.shade600,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${day.day}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                            if (indicatorColor != null)
                              Positioned(
                                bottom: 2,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: indicatorColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            // Close button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.surfaceMuted,
                    foregroundColor: palette.textPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Cerrar',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDayWithIndicator(DateTime day, Color indicatorColor) {
    final palette = context.uatPalette;

    return Container(
      margin: const EdgeInsets.all(4),
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: Text(
                '${day.day}',
                style: TextStyle(color: palette.textPrimary, fontSize: 16),
              ),
            ),
          ),
          Positioned(
            bottom: 2,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: indicatorColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildLegendItem(Colors.orange, 'Pendiente'),
        const SizedBox(width: 32),
        _buildLegendItem(Colors.green, 'Enviado'),
      ],
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    final palette = context.uatPalette;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(color: palette.textSecondary, fontSize: 14),
        ),
      ],
    );
  }
}

/// Modal bottom sheet showing pending attendance details
class _PendingDetailsModal extends StatefulWidget {
  final List<AsistenciaRegistro> pendientes;
  final Map<String, String> studentNames;
  final Map<String, Grupo> grupoMap;
  final List<Grupo> todosLosGrupos;
  final Future<void> Function(String registroId) onDelete;

  const _PendingDetailsModal({
    required this.pendientes,
    required this.studentNames,
    required this.grupoMap,
    required this.todosLosGrupos,
    required this.onDelete,
  });

  @override
  State<_PendingDetailsModal> createState() => _PendingDetailsModalState();
}

class _PendingDetailsModalState extends State<_PendingDetailsModal> {
  late List<AsistenciaRegistro> _localPendientes;
  StreamSubscription<void>? _attendanceSubscription;

  // Gradientes (igual que en grupos_page)
  static const List<List<Color>> _cardGradients = [
    [Color(0xFF8B5CF6), Color(0xFF7C3AED)],
    [Color(0xFFFF6B9D), Color(0xFFFF5A8F)],
    [Color(0xFF2DD4BF), Color(0xFF14B8A6)],
    [Color(0xFFFF8A65), Color(0xFFFF7043)],
    [Color(0xFF60A5FA), Color(0xFF3B82F6)],
    [Color(0xFFFF6B9D), Color(0xFFFF5A8F)],
  ];

  @override
  void initState() {
    super.initState();
    _localPendientes = List.from(widget.pendientes);
    _attendanceSubscription = AsistenciaLocalService().cambios.listen((_) {
      if (!mounted) return;
      setState(() {
        _localPendientes =
            AsistenciaLocalService().obtenerAsistenciasPendientes()
              ..sort((a, b) => b.fecha.compareTo(a.fecha));
      });
    });
  }

  @override
  void dispose() {
    _attendanceSubscription?.cancel();
    super.dispose();
  }

  /// Obtener colores del gradiente para un grupo específico
  List<Color> _getColoresParaGrupo(String grupoId) {
    final index = widget.todosLosGrupos.indexWhere(
      (g) => g.id == grupoId || g.identificadorUnico == grupoId,
    );
    if (index == -1) return _cardGradients[0];
    return _cardGradients[index % _cardGradients.length];
  }

  String _formatFecha(DateTime fecha) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final fechaNorm = DateTime(fecha.year, fecha.month, fecha.day);
    final diff = today.difference(fechaNorm).inDays;

    final diasSemana = [
      'Lunes',
      'Martes',
      'Miércoles',
      'Jueves',
      'Viernes',
      'Sábado',
      'Domingo',
    ];
    final meses = [
      '',
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

    final diaSemana = diasSemana[fecha.weekday - 1];
    final fechaStr = '${fecha.day} ${meses[fecha.month]}';

    if (diff == 0) return 'Hoy · $diaSemana $fechaStr';
    if (diff == 1) return 'Ayer · $diaSemana $fechaStr';
    if (diff == 2) return 'Antier · $diaSemana $fechaStr';
    return '$diaSemana $fechaStr';
  }

  /// Returns (className, groupMeta) where groupMeta is "Grupo K · Salón 301"
  (String, String?) _resolveGrupoMeta(AsistenciaRegistro registro) {
    final grupo = widget.grupoMap[registro.grupoId];
    if (grupo != null) {
      final className = registro.nombreClase ?? grupo.name;
      final meta = 'Grupo ${grupo.groupLetter} · ${grupo.classroom}';
      return (className, meta);
    }
    final fallback = registro.nombreClase ?? registro.grupoId;
    return (fallback, null);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: palette.textTertiary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              'Asistencias pendientes',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '${_localPendientes.length} registro${_localPendientes.length == 1 ? '' : 's'}',
              style: TextStyle(color: palette.textSecondary, fontSize: 14),
            ),
          ),
          Divider(color: palette.border, height: 1),
          // List
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              itemCount: _localPendientes.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final registro = _localPendientes[index];
                return _buildRegistroTile(registro);
              },
            ),
          ),
          // Close button
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.surfaceMuted,
                  foregroundColor: palette.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Cerrar',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Returns only entries that changed vs the last synced snapshot.
  /// If no snapshot exists, returns all entries (first-time upload).
  Map<String, bool> _changedEntries(AsistenciaRegistro registro) {
    final synced = registro.asistenciasSincronizadas;
    if (synced == null) return registro.asistenciasAlumnos;
    return Map.fromEntries(
      registro.asistenciasAlumnos.entries.where(
        (e) => synced[e.key] != e.value,
      ),
    );
  }

  Widget _buildRegistroTile(AsistenciaRegistro registro) {
    final changed = _changedEntries(registro);
    final total = changed.length;
    final (className, grupoMeta) = _resolveGrupoMeta(registro);
    final palette = context.uatPalette;

    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openRegistroDetail(registro),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                // Orange dot
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Colors.orange,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                // Date + group info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _formatFecha(registro.fecha),
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        className,
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (grupoMeta != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          grupoMeta,
                          style: TextStyle(
                            color: palette.textTertiary,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Changed count chip
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    total == 1 ? '$total cambio' : '$total cambios',
                    style: TextStyle(
                      color: Colors.orange.shade400,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: palette.iconMuted,
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openRegistroDetail(AsistenciaRegistro registro) async {
    HapticFeedback.selectionClick();
    final (className, grupoMeta) = _resolveGrupoMeta(registro);
    final result = await Navigator.of(context).push<_PendingDetailAction>(
      MaterialPageRoute(
        builder: (_) => _PendingRegistroDetailPage(
          registro: registro,
          className: className,
          grupoMeta: grupoMeta,
          changedEntries: _changedEntries(registro),
          studentNames: widget.studentNames,
          accentColor: _getColoresParaGrupo(registro.grupoId).first,
        ),
      ),
    );

    if (!mounted || result == null) return;
    if (result == _PendingDetailAction.show) {
      _navigateToGrupoDetail(registro);
      return;
    }

    await widget.onDelete(registro.id);
    if (!mounted) return;
    setState(() {
      _localPendientes.removeWhere((item) => item.id == registro.id);
    });
    if (_localPendientes.isEmpty && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// Navegar a la pantalla de detalle del grupo con la fecha específica
  void _navigateToGrupoDetail(AsistenciaRegistro registro) {
    final grupo = widget.grupoMap[registro.grupoId];
    if (grupo == null) return;

    final gradientColors = _getColoresParaGrupo(registro.grupoId);

    // Capturar el navigator antes de cerrar el modal (el context se invalida al hacer pop)
    final navigator = Navigator.of(context);

    // Cerrar el modal
    navigator.pop();

    // Cerrar la página de sincronización (UploadManagementPage)
    navigator.pop();

    // Navegar a GrupoDetailPage con la fecha del registro y efecto neón
    navigator.push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            GrupoDetailPage(
              grupo: grupo,
              gradientColors: gradientColors,
              accentColor: Colors.white,
              horario:
                  grupo.horarioParaDia(registro.fecha.weekday) ??
                  grupo.horarioValido ??
                  '00:00-00:00',
              dias: grupo.diasClaseAgrupados ?? 'Sin horario',
              todosLosGrupos: widget.todosLosGrupos,
              initialDate: registro.fecha,
              highlightDateSelector: true,
              highlightColor: gradientColors[0],
            ),
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curvedAnimation = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOut,
            reverseCurve: Curves.easeIn,
          );
          return FadeTransition(opacity: curvedAnimation, child: child);
        },
      ),
    );
  }
}

enum _PendingDetailAction { delete, show }

class _PendingRegistroDetailPage extends StatelessWidget {
  final AsistenciaRegistro registro;
  final String className;
  final String? grupoMeta;
  final Map<String, bool> changedEntries;
  final Map<String, String> studentNames;
  final Color accentColor;

  const _PendingRegistroDetailPage({
    required this.registro,
    required this.className,
    required this.grupoMeta,
    required this.changedEntries,
    required this.studentNames,
    required this.accentColor,
  });

  String _studentName(String id) {
    final name = studentNames[id]?.trim();
    return name == null || name.isEmpty ? id : name;
  }

  String _formatDate(DateTime date) {
    const weekdays = [
      'Lunes',
      'Martes',
      'Miércoles',
      'Jueves',
      'Viernes',
      'Sábado',
      'Domingo',
    ];
    const months = [
      '',
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre',
    ];
    return '${weekdays[date.weekday - 1]} ${date.day} de ${months[date.month]} de ${date.year}';
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final palette = context.uatPalette;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: palette.surfaceElevated,
        title: Text(
          '¿Eliminar registro?',
          style: TextStyle(color: palette.textPrimary),
        ),
        content: Text(
          'Esta acción eliminará el registro pendiente y no se puede deshacer.',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      HapticFeedback.heavyImpact();
      Navigator.of(context).pop(_PendingDetailAction.delete);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;
    final entries = changedEntries.entries.toList()
      ..sort((a, b) {
        if (a.value != b.value) return a.value ? -1 : 1;
        return _studentName(a.key).compareTo(_studentName(b.key));
      });
    final hasSnapshot = registro.asistenciasSincronizadas != null;

    return Scaffold(
      backgroundColor: palette.appBackground,
      appBar: AppBar(
        backgroundColor: palette.appBackground,
        foregroundColor: palette.textPrimary,
        elevation: 0,
        title: const Text('Registro pendiente'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  Text(
                    _formatDate(registro.fecha),
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    className,
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (grupoMeta != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      grupoMeta!,
                      style: TextStyle(
                        color: palette.textTertiary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          hasSnapshot
                              ? 'Cambios desde el último envío'
                              : 'Lista marcada',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        '${entries.length}',
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No hay cambios de asistencia en este registro.',
                        style: TextStyle(color: palette.textSecondary),
                      ),
                    )
                  else
                    ...entries.map(
                      (entry) => _StudentAttendanceChangeRow(
                        name: _studentName(entry.key),
                        present: entry.value,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(color: palette.appBackground),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _confirmDelete(context),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Eliminar'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade400,
                        side: BorderSide(color: Colors.red.shade400),
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(context).pop(_PendingDetailAction.show);
                      },
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Mostrar'),
                      style: FilledButton.styleFrom(
                        backgroundColor: accentColor,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudentAttendanceChangeRow extends StatelessWidget {
  final String name;
  final bool present;

  const _StudentAttendanceChangeRow({
    required this.name,
    required this.present,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;
    final statusColor = present ? Colors.green.shade600 : Colors.red.shade500;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Icon(
            present ? Icons.check_circle_rounded : Icons.cancel_rounded,
            color: statusColor,
            size: 21,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            present ? 'Presente' : 'Ausente',
            style: TextStyle(
              color: statusColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// --- Stepper data models ---

enum _StepStatus { pending, inProgress, completed, failed }

class _SyncStepData {
  final String label;
  final _StepStatus status;
  final String? subtitle;

  const _SyncStepData({
    required this.label,
    required this.status,
    this.subtitle,
  });

  _SyncStepData copyWith({
    String? label,
    _StepStatus? status,
    String? subtitle,
  }) => _SyncStepData(
    label: label ?? this.label,
    status: status ?? this.status,
    subtitle: subtitle ?? this.subtitle,
  );
}
