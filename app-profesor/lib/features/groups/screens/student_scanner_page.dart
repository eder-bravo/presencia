import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/uat_colors.dart';
import '../../../shared/models/alumno.dart';

const _scannerSuccessAccent = Color(0xFF1F9D63);
const _scannerSuccessTextLight = Color(0xFF12643D);
const _scannerPauseColor = Color(0xFFCB3D3D);

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
    if (!started) _pulseController.stop();
  }

  Future<void> _pauseAndClose() async {
    if (_isStopping) return;
    setState(() => _isStopping = true);
    _pulseController.stop();
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
        if (!didPop) unawaited(_pauseAndClose());
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
                  _buildPauseButton(),
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
                    color: widget.gradientColors.first.withValues(alpha: 0.2),
                    blurRadius: 24,
                    spreadRadius: 2,
                    offset: const Offset(0, 3),
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
          _isStopping
              ? 'Pausando escaneo'
              : _isStarting
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
        if (_scanStarted) ...[
          const SizedBox(height: 14),
          _ScanningDots(
            key: const ValueKey('scanner-activity-dots'),
            animation: _pulseController,
            color: _scannerSuccessAccent,
            reduceMotion: reduceMotion,
          ),
        ],
      ],
    );
  }

  Widget _buildStatusPill(UATPalette palette) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final successColor = isDark
        ? _scannerSuccessAccent
        : _scannerSuccessTextLight;
    final warningColor = isDark
        ? const Color(0xFFFFB74D)
        : const Color(0xFF9A4D00);

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
            Icon(
              Icons.info_outline_rounded,
              color: warningColor,
              size: 16,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                _scanError == null
                    ? 'Revisa Bluetooth y los permisos'
                    : 'Vuelve a intentarlo o reinicia Bluetooth',
                style: TextStyle(
                  color: warningColor,
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
            color: _scannerSuccessAccent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _scannerSuccessAccent.withValues(alpha: 0.28),
            ),
          ),
          child: Text(
            available > 0 && available >= count
                ? '$count de $available detectados'
                : '$count detectados',
            style: TextStyle(
              color: successColor,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
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
              : _DetectedStudentsList(
                  key: const ValueKey('detected-student-list'),
                  students: detectedStudents,
                  accentColor: widget.gradientColors.first,
                  palette: palette,
                ),
        );
      },
    );
  }

  Widget _buildPauseButton() {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: FilledButton.icon(
        key: const ValueKey('cancel-student-scan'),
        onPressed: _isStopping ? null : _pauseAndClose,
        icon: _isStopping
            ? const SizedBox(
                width: 19,
                height: 19,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.4,
                ),
              )
            : const Icon(Icons.pause_rounded, size: 22),
        label: Text(_isStopping ? 'Pausando...' : 'Pausar escaneo'),
        style: FilledButton.styleFrom(
          backgroundColor: _scannerPauseColor,
          disabledBackgroundColor: _scannerPauseColor.withValues(alpha: 0.7),
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

class _ScanningDots extends StatelessWidget {
  final Animation<double> animation;
  final Color color;
  final bool reduceMotion;

  const _ScanningDots({
    super.key,
    required this.animation,
    required this.color,
    required this.reduceMotion,
  });

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: 28,
        height: 12,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(3, (index) {
              final phase = (animation.value - index * 0.18) % 1;
              final pulse = reduceMotion
                  ? 1.0
                  : Curves.easeInOut.transform(1 - (phase - 0.5).abs() * 2);
              return Transform.translate(
                offset: Offset(0, reduceMotion ? 0 : -2 * pulse),
                child: Opacity(
                  opacity: 0.35 + 0.65 * pulse,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
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

class _DetectedStudentsList extends StatefulWidget {
  final List<Alumno> students;
  final Color accentColor;
  final UATPalette palette;

  const _DetectedStudentsList({
    super.key,
    required this.students,
    required this.accentColor,
    required this.palette,
  });

  @override
  State<_DetectedStudentsList> createState() => _DetectedStudentsListState();
}

class _DetectedStudentsListState extends State<_DetectedStudentsList> {
  final _listKey = GlobalKey<AnimatedListState>();
  late final List<Alumno> _students;

  @override
  void initState() {
    super.initState();
    _students = List.of(widget.students);
  }

  @override
  void didUpdateWidget(covariant _DetectedStudentsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final listState = _listKey.currentState;
    if (listState == null) {
      _students
        ..clear()
        ..addAll(widget.students);
      return;
    }

    final nextKeys = widget.students.map(_studentKey).toSet();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 260);

    for (var index = _students.length - 1; index >= 0; index--) {
      if (!nextKeys.contains(_studentKey(_students[index]))) {
        _students.removeAt(index);
        listState.removeItem(
          index,
          (_, _) => const SizedBox.shrink(),
          duration: Duration.zero,
        );
      }
    }

    for (var index = 0; index < widget.students.length; index++) {
      final student = widget.students[index];
      final key = _studentKey(student);
      if (index < _students.length && _studentKey(_students[index]) == key) {
        _students[index] = student;
        continue;
      }

      final previousIndex = _students.indexWhere(
        (current) => _studentKey(current) == key,
      );
      if (previousIndex >= 0) {
        _students.removeAt(previousIndex);
        listState.removeItem(
          previousIndex,
          (_, _) => const SizedBox.shrink(),
          duration: Duration.zero,
        );
      }

      _students.insert(index, student);
      // Animate detections, not existing rows rebuilt while scrolling.
      listState.insertItem(
        index,
        duration: previousIndex < 0 ? duration : Duration.zero,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: AnimatedList(
        key: _listKey,
        initialItemCount: _students.length,
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
        physics: const ClampingScrollPhysics(),
        itemBuilder: (context, index, animation) {
          final student = _students[index];
          final studentKey = _studentKey(student);
          final easedAnimation = animation.drive(
            CurveTween(curve: Curves.easeOutCubic),
          );
          return SizeTransition(
            key: ValueKey('detected-student-row-$studentKey'),
            sizeFactor: easedAnimation,
            alignment: Alignment.topCenter,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(-0.045, 0),
                end: Offset.zero,
              ).animate(easedAnimation),
              child: FadeTransition(
                opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
                child: Padding(
                  // Keep the shadow inside the row's animation clip.
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                  child: _DetectedStudentCard(
                    key: ValueKey('detected-student-$studentKey'),
                    student: student,
                    accentColor: widget.accentColor,
                    palette: widget.palette,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DetectedStudentCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final matricula = student.matricula?.trim().toUpperCase();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final successColor = isDark
        ? _scannerSuccessAccent
        : _scannerSuccessTextLight;

    return Container(
      constraints: const BoxConstraints(minHeight: 116),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: palette.border.withValues(alpha: isDark ? 0.14 : 0.10),
        ),
        boxShadow: [
          BoxShadow(
            color: (isDark ? palette.shadow : palette.textPrimary).withValues(
              alpha: isDark ? 0.18 : 0.06,
            ),
            blurRadius: 8,
            spreadRadius: -2,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _StudentAvatar(student: student, accentColor: accentColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  student.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textPrimary,
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
                      color: palette.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      color: successColor,
                      size: 17,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Asistencia registrada',
                      style: TextStyle(
                        color: successColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
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
              color: _scannerSuccessAccent.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.done_rounded,
              color: successColor,
              size: 22,
            ),
          ),
        ],
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
