import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/attendance_confirmation.dart';
import '../models/student_schedule_entry.dart';
import '../services/attendance_session_service.dart';
import '../services/ble_advertiser_service.dart';
import '../services/local_storage_service.dart';
import '../theme/app_theme.dart';
import '../utils/subject_name.dart';

enum AttendanceSheetStatus { scanning, requirement, timeout, success }

class AttendanceBottomSheet extends StatefulWidget {
  const AttendanceBottomSheet({
    super.key,
    required this.attendanceSession,
    required this.bleService,
    required this.storage,
    this.currentOccurrence,
    this.onAttendanceConfirmed,
    this.timeoutDuration = const Duration(seconds: 30),
    this.autoCloseDuration = const Duration(milliseconds: 2200),
  });

  final AttendanceSessionService attendanceSession;
  final BleAdvertiserService bleService;
  final LocalStorageService storage;
  final StudentScheduleOccurrence? currentOccurrence;
  final ValueChanged<AttendanceConfirmation>? onAttendanceConfirmed;
  final Duration timeoutDuration;
  final Duration autoCloseDuration;

  static Future<AttendanceConfirmation?> show(
    BuildContext context, {
    required AttendanceSessionService attendanceSession,
    required BleAdvertiserService bleService,
    required LocalStorageService storage,
    StudentScheduleOccurrence? currentOccurrence,
    ValueChanged<AttendanceConfirmation>? onAttendanceConfirmed,
    Duration timeoutDuration = const Duration(seconds: 30),
    Duration autoCloseDuration = const Duration(milliseconds: 2200),
  }) {
    return showModalBottomSheet<AttendanceConfirmation>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (sheetContext) => AttendanceBottomSheet(
        attendanceSession: attendanceSession,
        bleService: bleService,
        storage: storage,
        currentOccurrence: currentOccurrence,
        onAttendanceConfirmed: onAttendanceConfirmed,
        timeoutDuration: timeoutDuration,
        autoCloseDuration: autoCloseDuration,
      ),
    );
  }

  @override
  State<AttendanceBottomSheet> createState() => _AttendanceBottomSheetState();
}

class _AttendanceBottomSheetState extends State<AttendanceBottomSheet>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _pulseController;
  Timer? _countdownTimer;
  Timer? _autoCloseTimer;
  StreamSubscription<AttendanceSessionSnapshot>? _sessionSubscription;
  StreamSubscription<AttendanceConfirmation>? _confirmationSubscription;

  AttendanceSheetStatus _status = AttendanceSheetStatus.scanning;
  late int _remainingSeconds;
  AttendanceSessionSnapshot? _lastSnapshot;
  AttendanceConfirmation? _confirmedData;
  String? _errorMessage;
  AttendanceRequirementAction? _requirementAction;
  bool _waitingForSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.timeoutDuration.inSeconds;
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _listenToStreams();
    _startSession();
  }

  void _listenToStreams() {
    _sessionSubscription = widget.attendanceSession.stateStream.listen((
      snapshot,
    ) {
      if (!mounted || _status != AttendanceSheetStatus.scanning) return;
      final isRequirement =
          snapshot.state == AttendanceSessionState.permissionRequired ||
          snapshot.state == AttendanceSessionState.permissionDenied ||
          snapshot.state == AttendanceSessionState.bluetoothOff ||
          snapshot.state == AttendanceSessionState.bluetoothUnsupported ||
          snapshot.state == AttendanceSessionState.locationServicesOff ||
          snapshot.state == AttendanceSessionState.error;
      final isTimeout =
          snapshot.state == AttendanceSessionState.roomNotFound ||
          snapshot.state == AttendanceSessionState.missingRoomBeacon;

      if (isRequirement || isTimeout) {
        _countdownTimer?.cancel();
        _countdownTimer = null;
        _pulseController.stop();
      }
      setState(() {
        _lastSnapshot = snapshot;
        if (isRequirement) {
          _status = AttendanceSheetStatus.requirement;
          _errorMessage = snapshot.message;
          _requirementAction = snapshot.action;
        } else if (isTimeout) {
          _status = AttendanceSheetStatus.timeout;
          _errorMessage = snapshot.message;
        } else if (snapshot.state == AttendanceSessionState.checkingRoom ||
            snapshot.state == AttendanceSessionState.roomVerified ||
            snapshot.state == AttendanceSessionState.broadcasting) {
          _startCountdownIfNeeded();
        }
      });
    });

    _confirmationSubscription = widget.bleService.confirmationStream.listen((
      confirmation,
    ) {
      if (!confirmation.isConfirmed ||
          !confirmation.belongsToMatricula(widget.storage.matricula)) {
        return;
      }
      _handleConfirmationSuccess(confirmation);
    });
  }

  void _handleConfirmationSuccess(AttendanceConfirmation confirmation) {
    if (!mounted || _status == AttendanceSheetStatus.success) return;

    _countdownTimer?.cancel();
    _countdownTimer = null;
    _pulseController.stop();
    unawaited(HapticFeedback.heavyImpact());

    setState(() {
      _status = AttendanceSheetStatus.success;
      _confirmedData = confirmation;
    });

    widget.onAttendanceConfirmed?.call(confirmation);

    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(widget.autoCloseDuration, () {
      if (mounted) {
        Navigator.of(context).pop(confirmation);
      }
    });
  }

  void _startSession({bool requestPermissions = false}) {
    setState(() {
      _status = AttendanceSheetStatus.scanning;
      _remainingSeconds = widget.timeoutDuration.inSeconds;
      _errorMessage = null;
      _requirementAction = null;
    });

    if (!_pulseController.isAnimating) {
      _pulseController.repeat();
    }

    unawaited(
      widget.attendanceSession.start(requestPermissions: requestPermissions),
    );
  }

  void _startCountdownIfNeeded() {
    if (_countdownTimer != null) return;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_remainingSeconds > 1) {
        setState(() => _remainingSeconds--);
      } else {
        _handleTimeout();
      }
    });
  }

  void _handleTimeout() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _pulseController.stop();
    unawaited(widget.attendanceSession.stop());
    unawaited(HapticFeedback.vibrate());

    if (mounted) {
      setState(() {
        _remainingSeconds = 0;
        _status = AttendanceSheetStatus.timeout;
      });
    }
  }

  void _retry() {
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _status = AttendanceSheetStatus.scanning;
      _remainingSeconds = widget.timeoutDuration.inSeconds;
      _errorMessage = null;
    });
    if (!_pulseController.isAnimating) {
      _pulseController.repeat();
    }
    unawaited(_restartSession());
  }

  Future<void> _restartSession() async {
    await widget.attendanceSession.stop();
    if (!mounted || _status != AttendanceSheetStatus.scanning) return;
    _startSession();
  }

  Future<void> _handleRequirementAction() async {
    final action = _requirementAction;
    if (action == null) {
      _retry();
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    if (action == AttendanceRequirementAction.requestPermissions) {
      _startSession(requestPermissions: true);
      return;
    }

    _waitingForSettings = true;
    await widget.attendanceSession.performRequirementAction(action);
  }

  void _cancel() {
    _countdownTimer?.cancel();
    _autoCloseTimer?.cancel();
    unawaited(widget.attendanceSession.stop());
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _autoCloseTimer?.cancel();
    _sessionSubscription?.cancel();
    _confirmationSubscription?.cancel();
    _pulseController.dispose();
    if (_status == AttendanceSheetStatus.scanning) {
      unawaited(widget.attendanceSession.stop());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForSettings && mounted) {
      _waitingForSettings = false;
      _startSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = AppPalette.of(context).surface;
    final borderColor = AppPalette.of(context).border;

    return Container(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: borderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .5 : .15),
            blurRadius: 28,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Indicador de arrastre superior
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xFF4A4A52)
                        : const Color(0xFFD1D5DB),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Contenido dinámico según el estado
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _buildCurrentState(context, dark),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentState(BuildContext context, bool dark) {
    switch (_status) {
      case AttendanceSheetStatus.scanning:
        return _buildScanningState(context, dark);
      case AttendanceSheetStatus.requirement:
        return _buildRequirementState(context, dark);
      case AttendanceSheetStatus.timeout:
        return _buildTimeoutState(context, dark);
      case AttendanceSheetStatus.success:
        return _buildSuccessState(context, dark);
    }
  }

  Widget _buildRequirementState(BuildContext context, bool dark) {
    final state = _lastSnapshot?.state;
    final isBluetooth =
        state == AttendanceSessionState.bluetoothOff ||
        state == AttendanceSessionState.bluetoothUnsupported;
    final isLocation = state == AttendanceSessionState.locationServicesOff;
    final isPermission =
        state == AttendanceSessionState.permissionRequired ||
        state == AttendanceSessionState.permissionDenied;
    final icon = isBluetooth
        ? Icons.bluetooth_disabled_rounded
        : isLocation
        ? Icons.location_off_rounded
        : isPermission
        ? Icons.admin_panel_settings_outlined
        : Icons.error_outline_rounded;
    final title = isBluetooth
        ? 'Bluetooth no está disponible'
        : isLocation
        ? 'Activa la ubicación'
        : isPermission
        ? 'Se necesita tu permiso'
        : 'No se pudo iniciar el registro';
    final actionLabel = switch (_requirementAction) {
      AttendanceRequirementAction.requestPermissions => 'Permitir',
      AttendanceRequirementAction.openAppSettings => 'Abrir configuración',
      AttendanceRequirementAction.openBluetoothSettings => 'Abrir Bluetooth',
      AttendanceRequirementAction.openLocationSettings => 'Abrir ubicación',
      null => 'Reintentar',
    };

    return Column(
      key: const ValueKey('attendance_state_requirement'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 82,
          height: 82,
          margin: const EdgeInsets.only(top: 8, bottom: 16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppPalette.of(context).warningSurface,
            border: Border.all(
              color: AppPalette.of(context).warning.withValues(alpha: .32),
              width: 2,
            ),
          ),
          child: Icon(icon, color: AppPalette.of(context).warning, size: 40),
        ),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 20,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _errorMessage ??
              'Revisa los requisitos del teléfono e inténtalo de nuevo.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: AppPalette.of(context).muted,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _cancel,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Cancelar'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const Key('attendance_requirement_action'),
                onPressed: _handleRequirementAction,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: AppPalette.of(context).accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(actionLabel, textAlign: TextAlign.center),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // ESTADO: ESCANEANDO / CARGANDO
  // ==========================================
  Widget _buildScanningState(BuildContext context, bool dark) {
    final primaryColor = AppPalette.of(context).accent;
    final subjectName = subjectDisplayName(
      widget.currentOccurrence?.entry.subject,
      fallback: 'Clase actual',
    );
    final classroom = widget.currentOccurrence?.entry.classroom;
    final group = groupDisplayName(widget.currentOccurrence?.entry.group);

    String statusText = 'Buscando aula y registrando asistencia...';
    if (_lastSnapshot?.state == AttendanceSessionState.checkingRoom) {
      statusText = 'Verificando presencia en el aula...';
    } else if (_lastSnapshot?.state == AttendanceSessionState.broadcasting) {
      statusText = 'Enviando señal de asistencia al profesor...';
    } else if (_lastSnapshot?.state == AttendanceSessionState.roomVerified) {
      statusText = 'Aula detectada. Transmitiendo...';
    }

    final progressRatio = (_remainingSeconds / widget.timeoutDuration.inSeconds)
        .clamp(0.0, 1.0);

    return Column(
      key: const ValueKey('attendance_state_scanning'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Animación de radar pulsante con contador
        SizedBox(
          height: 170,
          width: 170,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Ondas expansivas de radar
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) {
                  return CustomPaint(
                    size: const Size(170, 170),
                    painter: _RadarWavesPainter(
                      animationValue: _pulseController.value,
                      waveColor: primaryColor,
                    ),
                  );
                },
              ),

              // Anillo de progreso regresivo
              SizedBox(
                width: 110,
                height: 110,
                child: CircularProgressIndicator(
                  value: progressRatio,
                  strokeWidth: 3.5,
                  strokeCap: StrokeCap.round,
                  backgroundColor: primaryColor.withValues(alpha: .15),
                  valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                ),
              ),

              // Contenido central: Icono + Segundos restantes
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppPalette.of(context).freeSurface,
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withValues(alpha: .2),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.sensors_rounded, color: primaryColor, size: 26),
                    const SizedBox(height: 2),
                    Text(
                      '${_remainingSeconds}s',
                      key: const Key('attendance_countdown_text'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: dark ? Colors.white : const Color(0xFF1F2937),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // Título del estado
        Text(
          'Registrando asistencia',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 20,
          ),
        ),
        const SizedBox(height: 6),

        // Mensaje descriptivo con estado dinámico
        Text(
          statusText,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: AppPalette.of(context).muted,
            fontWeight: FontWeight.w500,
          ),
        ),

        const SizedBox(height: 18),

        // Tarjeta con información de la materia
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppPalette.of(context).freeSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppPalette.of(context).border),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.school_rounded,
                  color: primaryColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subjectName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (classroom != null && classroom.isNotEmpty)
                          classroom,
                        if (group != null && group.isNotEmpty) 'Grupo $group',
                      ].join(' · ').ifEmpty('Horario escolar'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.of(context).muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // Botón Cancelar mientras escanea
        SizedBox(
          width: double.infinity,
          height: 48,
          child: TextButton(
            onPressed: _cancel,
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.of(context).muted,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text(
              'Cancelar',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  // ==========================================
  // ESTADO: TIEMPO AGOTADO / NO SE PUDO
  // ==========================================
  Widget _buildTimeoutState(BuildContext context, bool dark) {
    final errorColor = Theme.of(context).colorScheme.error;
    final retryColor = AppPalette.of(context).accent;

    return Column(
      key: const ValueKey('attendance_state_timeout'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Icono de advertencia / tiempo agotado
        Container(
          width: 80,
          height: 80,
          margin: const EdgeInsets.only(top: 8, bottom: 16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: errorColor.withValues(alpha: .12),
            border: Border.all(
              color: errorColor.withValues(alpha: .3),
              width: 2,
            ),
          ),
          child: Icon(Icons.timer_off_rounded, color: errorColor, size: 40),
        ),

        Text(
          'No se pudo registrar la asistencia',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 20,
          ),
        ),
        const SizedBox(height: 8),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            _errorMessage ??
                'No recibimos respuesta a tiempo. Asegúrate de estar dentro del aula, con Bluetooth encendido y que el profesor tenga activo el pase de lista.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppPalette.of(context).muted,
            ),
          ),
        ),

        const SizedBox(height: 24),

        // 2 Botones: Cancelar y Reintentar
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 50,
                child: OutlinedButton(
                  key: const Key('attendance_timeout_cancel_button'),
                  onPressed: _cancel,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppPalette.of(context).border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'Cancelar',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: dark ? Colors.white : const Color(0xFF374151),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 50,
                child: FilledButton.icon(
                  key: const Key('attendance_timeout_retry_button'),
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  label: const Text(
                    'Reintentar',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: retryColor,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // ESTADO: ÉXITO (CHECK + MATERIA)
  // ==========================================
  Widget _buildSuccessState(BuildContext context, bool dark) {
    final palette = AppPalette.of(context);
    final successColor = palette.success;
    final subjectName = subjectDisplayName(
      _confirmedData?.materia ??
          _confirmedData?.className ??
          widget.currentOccurrence?.entry.subject,
      fallback: 'Clase registrada',
    );

    final group = groupDisplayName(
      _confirmedData?.group ?? widget.currentOccurrence?.entry.group,
    );
    final classroom =
        _confirmedData?.classroom ?? widget.currentOccurrence?.entry.classroom;

    return Column(
      key: const ValueKey('attendance_state_success'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Badge animado con icono de check
        Container(
          width: 86,
          height: 86,
          margin: const EdgeInsets.only(top: 8, bottom: 16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: successColor.withValues(alpha: .14),
            border: Border.all(
              color: successColor.withValues(alpha: .4),
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: successColor.withValues(alpha: .3),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Center(
            child: Icon(
              Icons.check_circle_rounded,
              key: const Key('attendance_success_check_icon'),
              color: successColor,
              size: 52,
            ),
          ),
        ),

        // Mensaje de asistencia tomada correctamente
        Text(
          'Se tomó correctamente la asistencia',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 20,
            color: palette.ink,
          ),
        ),
        const SizedBox(height: 14),

        // Tarjeta destacada con la materia
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: palette.successSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: successColor.withValues(alpha: .35),
              width: 1.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                'Materia',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: successColor,
                  letterSpacing: .5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subjectName,
                key: const Key('attendance_success_subject_name'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: palette.ink,
                ),
              ),
              if ((classroom != null && classroom.isNotEmpty) ||
                  (group != null && group.isNotEmpty)) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    if (classroom != null && classroom.isNotEmpty)
                      'Aula $classroom',
                    if (group != null && group.isNotEmpty) 'Grupo $group',
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: successColor,
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Indicador de cierre automático
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(successColor),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Cerrando automáticamente...',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.of(context).muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// CustomPainter para generar las ondas expansivas de radar
class _RadarWavesPainter extends CustomPainter {
  _RadarWavesPainter({required this.animationValue, required this.waveColor});

  final double animationValue;
  final Color waveColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const waveCount = 3;
    final maxRadius = size.width / 2;

    for (var i = 0; i < waveCount; i++) {
      final waveProgress = (animationValue + (i / waveCount)) % 1.0;
      final radius = 48.0 + (maxRadius - 48.0) * waveProgress;
      final opacity = (1.0 - waveProgress) * 0.35;

      final paint = Paint()
        ..color = waveColor.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 * (1.0 - waveProgress * 0.5);

      canvas.drawCircle(center, radius, paint);

      // Relleno sutil
      final fillPaint = Paint()
        ..color = waveColor.withValues(alpha: opacity * 0.25)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(center, radius, fillPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarWavesPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.waveColor != waveColor;
  }
}

extension on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}
