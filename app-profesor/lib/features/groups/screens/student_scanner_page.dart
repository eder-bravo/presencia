import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/uat_colors.dart';
import '../../../shared/models/alumno.dart';

class StudentScannerPage extends StatefulWidget {
  final List<Alumno> students;
  final ValueListenable<List<String>> detectedStudentKeys;
  final ValueListenable<String?>? scanError;
  final List<Color> gradientColors;
  final String subject;
  final String groupLabel;
  final int availableStudentCount;
  final ValueListenable<int>? availableStudentCountListenable;
  final Future<bool> Function() onStart;
  final Future<void> Function() onStop;

  const StudentScannerPage({
    super.key,
    required this.students,
    required this.detectedStudentKeys,
    this.scanError,
    required this.gradientColors,
    required this.subject,
    required this.groupLabel,
    required this.availableStudentCount,
    this.availableStudentCountListenable,
    required this.onStart,
    required this.onStop,
  });

  @override
  State<StudentScannerPage> createState() => _StudentScannerPageState();
}

class _StudentScannerPageState extends State<StudentScannerPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _isStarting = true;
  bool _scanStarted = false;
  bool _isStopping = false;
  bool _allowPop = false;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _scanError = widget.scanError?.value;
    widget.scanError?.addListener(_handleScanError);
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginScan());
  }

  void _handleScanError() {
    final error = widget.scanError?.value;
    if (!mounted || error == null || error.isEmpty) return;
    setState(() {
      _scanError = error;
      _isStarting = false;
      _scanStarted = false;
    });
    _pulseController.stop();
  }

  Future<void> _beginScan() async {
    var started = false;
    try {
      started = await widget.onStart();
    } catch (_) {
      started = false;
    }
    if (!mounted) return;
    setState(() {
      _isStarting = false;
      _scanStarted = started;
    });
  }

  Future<void> _cancelAndClose() async {
    if (_isStopping) return;
    setState(() => _isStopping = true);
    try {
      await widget.onStop();
    } catch (_) {
      // The scanner screen should remain closable even if native cleanup fails.
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    widget.scanError?.removeListener(_handleScanError);
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancelAndClose());
      },
      child: Scaffold(
        key: const ValueKey('student-scanner-page'),
        backgroundColor: palette.appBackground,
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                widget.gradientColors.first.withValues(alpha: 0.13),
                palette.appBackground,
                palette.appBackground,
              ],
              stops: const [0, 0.32, 1],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                children: [
                  _buildHeader(palette, reduceMotion),
                  const SizedBox(height: 22),
                  Expanded(child: _buildDetectedStudents(palette)),
                  const SizedBox(height: 18),
                  _buildCancelButton(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(UATPalette palette, bool reduceMotion) {
    return Column(
      children: [
        SizedBox(
          width: 112,
          height: 112,
          child: AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final progress = reduceMotion ? 0.45 : _pulseController.value;
              return Stack(
                alignment: Alignment.center,
                children: [
                  _PulseRing(
                    progress: progress,
                    color: widget.gradientColors.first,
                  ),
                  _PulseRing(
                    progress: (progress + 0.5) % 1,
                    color: widget.gradientColors.first,
                  ),
                  child!,
                ],
              );
            },
            child: Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: widget.gradientColors),
                boxShadow: [
                  BoxShadow(
                    color: widget.gradientColors.first.withValues(alpha: 0.3),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.person_search_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _isStarting
              ? 'Preparando escaneo'
              : _scanStarted
              ? 'Escaneando alumnos'
              : 'El escaneo se detuvo',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          '${widget.subject}  ·  Grupo ${widget.groupLabel}',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _buildStatusPill(palette),
        ),
      ],
    );
  }

  Widget _buildStatusPill(UATPalette palette) {
    if (_isStarting) {
      return Container(
        key: const ValueKey('scanner-starting'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: widget.gradientColors.first,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Conectando con dispositivos cercanos',
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    if (!_scanStarted) {
      return Container(
        key: const ValueKey('scanner-unavailable'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.info_outline_rounded,
              color: Colors.orange,
              size: 16,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                _scanError == null
                    ? 'Revisa Bluetooth y los permisos'
                    : 'Vuelve a intentarlo o reinicia Bluetooth',
                style: const TextStyle(
                  color: Colors.orange,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return AnimatedBuilder(
      key: const ValueKey('scanner-active'),
      animation: Listenable.merge([
        widget.detectedStudentKeys,
        widget.availableStudentCountListenable,
      ]),
      builder: (context, _) {
        final count = widget.detectedStudentKeys.value.toSet().length;
        final available =
            widget.availableStudentCountListenable?.value ??
            widget.availableStudentCount;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1F9D63).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: const Color(0xFF1F9D63).withValues(alpha: 0.28),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF1F9D63),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                available > 0 && available >= count
                    ? '$count de $available detectados'
                    : '$count detectados',
                style: const TextStyle(
                  color: Color(0xFF1F9D63),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetectedStudents(UATPalette palette) {
    final studentsByKey = {
      for (final student in widget.students) _studentKey(student): student,
    };

    return ValueListenableBuilder<List<String>>(
      valueListenable: widget.detectedStudentKeys,
      builder: (context, detectedKeys, _) {
        final detectedStudents = detectedKeys
            .map((key) => studentsByKey[key])
            .whereType<Alumno>()
            .toList(growable: false);

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: detectedStudents.isEmpty
              ? _ScannerEmptyState(
                  key: const ValueKey('scanner-empty'),
                  palette: palette,
                  isUnavailable: !_isStarting && !_scanStarted,
                )
              : Scrollbar(
                  key: const ValueKey('detected-student-list'),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    itemCount: detectedStudents.length,
                    itemBuilder: (context, index) {
                      final student = detectedStudents[index];
                      final studentKey = _studentKey(student);
                      return Padding(
                        key: ValueKey('detected-student-row-$studentKey'),
                        padding: EdgeInsets.only(
                          bottom: index == detectedStudents.length - 1 ? 0 : 12,
                        ),
                        child: _DetectedStudentCard(
                          key: ValueKey('detected-student-$studentKey'),
                          student: student,
                          accentColor: widget.gradientColors.first,
                          palette: palette,
                        ),
                      );
                    },
                  ),
                ),
        );
      },
    );
  }

  Widget _buildCancelButton() {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: FilledButton.icon(
        key: const ValueKey('cancel-student-scan'),
        onPressed: _isStopping ? null : _cancelAndClose,
        icon: _isStopping
            ? const SizedBox(
                width: 19,
                height: 19,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.4,
                ),
              )
            : const Icon(Icons.close_rounded, size: 22),
        label: Text(_isStopping ? 'Cerrando...' : 'Cancelar escaneo'),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFD64545),
          disabledBackgroundColor: const Color(
            0xFFD64545,
          ).withValues(alpha: 0.7),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

class _PulseRing extends StatelessWidget {
  final double progress;
  final Color color;

  const _PulseRing({required this.progress, required this.color});

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 0.65 + (progress * 0.55),
      child: Opacity(
        opacity: (1 - progress).clamp(0, 1) * 0.45,
        child: Container(
          width: 94,
          height: 94,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
        ),
      ),
    );
  }
}

class _ScannerEmptyState extends StatelessWidget {
  final UATPalette palette;
  final bool isUnavailable;

  const _ScannerEmptyState({
    super.key,
    required this.palette,
    required this.isUnavailable,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 30),
        decoration: BoxDecoration(
          color: palette.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: palette.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isUnavailable
                  ? Icons.bluetooth_disabled_rounded
                  : Icons.bluetooth_searching_rounded,
              color: isUnavailable ? Colors.orange : palette.iconMuted,
              size: 34,
            ),
            const SizedBox(height: 14),
            Text(
              isUnavailable
                  ? 'El escaneo no está disponible'
                  : 'Buscando alumnos cercanos…',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isUnavailable
                  ? 'Activa Bluetooth y permite dispositivos cercanos y ubicación.'
                  : 'Las tarjetas aparecerán aquí en cuanto la app los detecte.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetectedStudentCard extends StatefulWidget {
  final Alumno student;
  final Color accentColor;
  final UATPalette palette;

  const _DetectedStudentCard({
    super.key,
    required this.student,
    required this.accentColor,
    required this.palette,
  });

  @override
  State<_DetectedStudentCard> createState() => _DetectedStudentCardState();
}

class _DetectedStudentCardState extends State<_DetectedStudentCard> {
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 480);
    final matricula = widget.student.matricula?.trim().toUpperCase();

    return AnimatedSlide(
      offset: _entered ? Offset.zero : const Offset(-1.15, 0),
      duration: duration,
      curve: Curves.easeOutBack,
      child: AnimatedOpacity(
        opacity: _entered ? 1 : 0,
        duration: duration,
        curve: Curves.easeOut,
        child: Container(
          constraints: const BoxConstraints(minHeight: 116),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: widget.palette.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: widget.accentColor.withValues(alpha: 0.28),
            ),
            boxShadow: [
              BoxShadow(
                color: widget.palette.shadow,
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Row(
            children: [
              _StudentAvatar(
                student: widget.student,
                accentColor: widget.accentColor,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.student.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.palette.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                    if (matricula != null && matricula.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        'Matrícula $matricula',
                        style: TextStyle(
                          color: widget.palette.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    const Row(
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          color: Color(0xFF1F9D63),
                          size: 17,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Asistencia registrada',
                          style: TextStyle(
                            color: Color(0xFF1F9D63),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF1F9D63).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.done_rounded,
                  color: Color(0xFF1F9D63),
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StudentAvatar extends StatelessWidget {
  final Alumno student;
  final Color accentColor;

  const _StudentAvatar({required this.student, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    final photoUrl = student.photoUrl?.trim();
    final fallback = _InitialsAvatar(student: student, color: accentColor);

    if (photoUrl == null || photoUrl.isEmpty) return fallback;

    return Container(
      width: 64,
      height: 64,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: accentColor.withValues(alpha: 0.38)),
      ),
      child: ClipOval(
        child: Image.network(
          photoUrl,
          fit: BoxFit.cover,
          width: 59,
          height: 59,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

class _InitialsAvatar extends StatelessWidget {
  final Alumno student;
  final Color color;

  const _InitialsAvatar({required this.student, required this.color});

  @override
  Widget build(BuildContext context) {
    final words = student.name
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    final initials = words.isEmpty
        ? 'A'
        : words.length == 1
        ? words.first.substring(0, 1).toUpperCase()
        : '${words.first.substring(0, 1)}${words.last.substring(0, 1)}'
              .toUpperCase();

    return Container(
      width: 64,
      height: 64,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.95),
            color.withValues(alpha: 0.68),
          ],
        ),
      ),
      child: Text(
        initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

String _studentKey(Alumno student) {
  final matricula = student.matricula?.trim().toUpperCase();
  if (matricula != null && matricula.isNotEmpty) return matricula;
  final id = student.id?.trim();
  return id != null && id.isNotEmpty ? id : student.number.toString();
}
