import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/theme/uat_colors.dart';
import '../../../../core/theme/theme_controller.dart';
import '../../../../shared/models/grupo.dart';
import '../../../../services/asistencia_local_service.dart';
import '../../../../services/api_service.dart';
import '../../../../services/auth_storage_service.dart';
import '../../authentication/providers/profesor_auth_provider.dart';
import 'grupo_detail_page.dart';
import 'upload_management_page.dart';

class GruposPage extends ConsumerStatefulWidget {
  const GruposPage({super.key});

  @override
  ConsumerState<GruposPage> createState() => _GruposPageState();
}

class _GruposPageState extends ConsumerState<GruposPage>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  bool _isExpanded = false; // Control de expansión de tarjetas
  bool _showTitle = true; // Control de visibilidad del título
  late AnimationController _pulseController;
  int? _selectedCardIndex; // Índice de la tarjeta seleccionada para navegación
  Timer? _titleVisibilityTimer; // Controla el retraso para esconder el título
  Timer? _scheduleRefreshTimer;

  static const List<List<Color>> _cardGradients = [
    [Color(0xFF8B5CF6), Color(0xFF7C3AED)],
    [Color(0xFFFF6B9D), Color(0xFFFF5A8F)],
    [Color(0xFF2DD4BF), Color(0xFF14B8A6)],
    [Color(0xFFFF8A65), Color(0xFFFF7043)],
    [Color(0xFF60A5FA), Color(0xFF3B82F6)],
    [Color(0xFFFF6B9D), Color(0xFFFF5A8F)],
  ];

  static const List<Color> _cardAccentColors = [
    Colors.white,
    Colors.white,
    Colors.white,
    Colors.white,
    Colors.white,
    Colors.white,
  ];

  @override
  void initState() {
    super.initState();

    // Animación pulsante para el indicador de clase actual
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    // Listener para animar el título basado en scroll
    _scrollController.addListener(_handleScroll);
    _scheduleRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });

    // Configurar status bar transparente; el brillo se controla desde el tema.
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
    );

    // Check sync status on startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSyncOnStart();
    });
  }

  @override
  void dispose() {
    _titleVisibilityTimer?.cancel();
    _scheduleRefreshTimer?.cancel();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  /// Checks sync status on app start and handles accordingly
  Future<void> _checkSyncOnStart() async {
    final authStorage = AuthStorageService();
    final apiService = ApiService();

    final token = authStorage.getToken();
    if (token == null) return;

    final result = await apiService.getSyncStatus(token);

    result.fold(
      (error) {
        // Ignore errors, just show current state
      },
      (status) {
        if (!mounted) return;

        if (status.isInProgress) {
          // Redirect to sync status screen
          context.push('/sync-status');
        } else if (status.isCompleted) {
          // Check if we have groups locally
          final grupos = ref.read(profesorGruposProvider);
          if (grupos.isEmpty) {
            // Download groups from server
            ref.read(profesorAuthProvider.notifier).refreshGrupos();
          }
        }
      },
    );

    // Check for pending uploads and show notification
    _checkPendingUploads();
  }

  bool _showPendingBanner = false;

  /// Checks for pending uploads and shows/hides the banner accordingly
  void _checkPendingUploads() {
    final asistenciaService = AsistenciaLocalService();
    final hasPending = asistenciaService.hayAsistenciasPendientes();

    if (mounted) {
      setState(() {
        _showPendingBanner = hasPending;
      });
    }
  }

  void _handleScroll() {
    final offset = _scrollController.offset;

    if (offset <= 20) {
      _titleVisibilityTimer?.cancel();
      _titleVisibilityTimer = null;
      if (!_showTitle) {
        setState(() {
          _showTitle = true;
        });
      }
      return;
    }

    if (_showTitle && _titleVisibilityTimer == null) {
      _titleVisibilityTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() {
          _showTitle = false;
        });
        _titleVisibilityTimer = null;
      });
    }
  }

  // Parsear horario de inicio (ej: "20:00-21:00" -> 20:00)
  DateTime? _parseHorarioInicio(String horario) {
    try {
      final horarioParts = horario.split('-');
      if (horarioParts.length != 2) return null;

      final inicioParts = horarioParts[0].trim().split(':');
      if (inicioParts.length != 2) return null;

      final now = DateTime.now();
      return DateTime(
        now.year,
        now.month,
        now.day,
        int.parse(inicioParts[0]),
        int.parse(inicioParts[1]),
      );
    } catch (e) {
      return null;
    }
  }

  // Parsear horario fin (ej: "20:00-21:00" -> 21:00)
  DateTime? _parseHorarioFin(String horario) {
    try {
      final horarioParts = horario.split('-');
      if (horarioParts.length != 2) return null;

      final finParts = horarioParts[1].trim().split(':');
      if (finParts.length != 2) return null;

      final now = DateTime.now();
      return DateTime(
        now.year,
        now.month,
        now.day,
        int.parse(finParts[0]),
        int.parse(finParts[1]),
      );
    } catch (e) {
      return null;
    }
  }

  bool _isCurrentClass(Grupo grupo) {
    final now = DateTime.now();
    final todaySchedule = grupo.horarioParaDia(now.weekday);
    if (todaySchedule == null) return false;
    for (final range in todaySchedule.split('·')) {
      final start = _parseHorarioInicio(range.trim());
      final end = _parseHorarioFin(range.trim());
      if (start == null || end == null) continue;
      final tolerance = ApiConstants.teacherAttendanceToleranceMinutes;
      if (!now.isBefore(start.subtract(Duration(minutes: tolerance))) &&
          !now.isAfter(end.add(Duration(minutes: tolerance)))) {
        return true;
      }
    }
    return false;
  }

  // Obtener el próximo DateTime de inicio para un conjunto de weekdays y horario
  DateTime _getNextStartForSchedule(
    DateTime now,
    List<int> weekdays,
    int inicioHour,
    int inicioMinute,
    int finHour,
    int finMinute,
  ) {
    // Buscar hasta 14 días por seguridad
    for (var add = 0; add < 14; add++) {
      final candidateDay = now.add(Duration(days: add));
      if (weekdays.contains(candidateDay.weekday)) {
        final candidateStart = DateTime(
          candidateDay.year,
          candidateDay.month,
          candidateDay.day,
          inicioHour,
          inicioMinute,
        );
        final candidateEnd = DateTime(
          candidateDay.year,
          candidateDay.month,
          candidateDay.day,
          finHour,
          finMinute,
        );
        final ventanaFin = candidateEnd.add(
          Duration(minutes: ApiConstants.teacherAttendanceToleranceMinutes),
        );

        // Si el inicio está en el futuro, lo retornamos
        if (candidateStart.isAfter(now)) return candidateStart;

        // Si estamos dentro de la ventana (inicio <= now <= ventanaFin), considerar el inicio de hoy
        if (!now.isAfter(ventanaFin)) return candidateStart;
        // Si ya pasó la ventana, continuar buscando la siguiente ocurrencia
      }
    }

    // Fallback: devolver dentro de la próxima semana el primer día coincidente
    for (var add = 1; add <= 7; add++) {
      final candidateDay = now.add(Duration(days: add));
      if (weekdays.contains(candidateDay.weekday)) {
        return DateTime(
          candidateDay.year,
          candidateDay.month,
          candidateDay.day,
          inicioHour,
          inicioMinute,
        );
      }
    }

    // Si no se encuentra, devolver ahora como fallback
    return now;
  }

  // Ordenar grupos por proximidad a la próxima ocurrencia real (considerando días de la semana)
  List<MapEntry<Grupo, int>> _sortGruposByProximity(List<Grupo> grupos) {
    final now = DateTime.now();

    // Crear lista de entradas con grupo y su índice original
    final gruposWithIndex = grupos
        .asMap()
        .entries
        .map((e) => MapEntry(e.value, e.key))
        .toList();

    gruposWithIndex.sort((a, b) {
      final grupoA = a.key;
      final grupoB = b.key;

      // Obtener horarios y días desde el schedule real del grupo
      final horarioA =
          grupoA.horarioParaDia(now.weekday) ??
          grupoA.horarioValido ??
          '00:00-00:00';
      final horarioB =
          grupoB.horarioParaDia(now.weekday) ??
          grupoB.horarioValido ??
          '00:00-00:00';
      final weekdaysA = grupoA.weekdaysConHorarioValido;
      final weekdaysB = grupoB.weekdaysConHorarioValido;

      final inicioA = _parseHorarioInicio(horarioA);
      final finA = _parseHorarioFin(horarioA);
      final inicioB = _parseHorarioInicio(horarioB);
      final finB = _parseHorarioFin(horarioB);

      if (inicioA == null || finA == null || inicioB == null || finB == null) {
        return 0;
      }

      if (weekdaysA.isEmpty || weekdaysB.isEmpty) {
        return 0;
      }

      final nextA = _getNextStartForSchedule(
        now,
        weekdaysA,
        inicioA.hour,
        inicioA.minute,
        finA.hour,
        finA.minute,
      );

      final nextB = _getNextStartForSchedule(
        now,
        weekdaysB,
        inicioB.hour,
        inicioB.minute,
        finB.hour,
        finB.minute,
      );

      final diffA = nextA.difference(now).abs();
      final diffB = nextB.difference(now).abs();

      return diffA.compareTo(diffB);
    });

    // Revertir para que la más próxima esté al final (arriba en el stack)
    return gruposWithIndex.reversed.toList();
  }

  Future<void> _handleRefresh() async {
    HapticFeedback.lightImpact();
    // Refrescar datos desde el servidor
    await ref.read(profesorAuthProvider.notifier).refreshGrupos();
    // Forzar reordenamiento con setState
    if (mounted) setState(() {});
    // Pequeña pausa para animación
    await Future.delayed(const Duration(milliseconds: 300));
  }

  @override
  Widget build(BuildContext context) {
    final grupos = ref.watch(profesorGruposProvider);
    final isLoading =
        ref.watch(profesorAuthLoadingProvider) ||
        ref.watch(profesorGroupsLoadingProvider);
    final groupsNotice = ref.watch(profesorGroupsNoticeProvider);
    final palette = context.uatPalette;
    final isLightMode = context.isUatLightMode;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isLightMode ? Brightness.dark : Brightness.light,
      statusBarBrightness: isLightMode ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: palette.appBackground,
      systemNavigationBarIconBrightness: isLightMode
          ? Brightness.dark
          : Brightness.light,
    );

    // Ordenar grupos por proximidad
    final sortedGruposWithIndex = _sortGruposByProximity(grupos);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: palette.appBackground,
        body: Stack(
          children: [
            // Content sin padding para que ocupe toda la pantalla
            isLoading && sortedGruposWithIndex.isEmpty
                ? _buildLoadingState()
                : sortedGruposWithIndex.isEmpty
                ? _buildEmptyState(groupsNotice)
                : RefreshIndicator(
                    onRefresh: _handleRefresh,
                    color: UATColors.primary,
                    backgroundColor: palette.surfaceElevated,
                    child: _buildWalletCards(sortedGruposWithIndex, grupos),
                  ),
            if (groupsNotice != null && sortedGruposWithIndex.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: MediaQuery.of(context).padding.bottom + 16,
                child: _buildGroupsNotice(groupsNotice),
              ),
            // Floating title
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 12,
              child: AnimatedOpacity(
                opacity: _showTitle ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child: AnimatedSlide(
                  offset: _showTitle ? Offset.zero : const Offset(0, -0.5),
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: Text(
                    'Mis clases',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.4,
                      shadows: [
                        Shadow(
                          offset: const Offset(0, 2),
                          blurRadius: 8,
                          color: palette.shadow,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Floating buttons
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: Row(
                children: [
                  // Botón de expandir/colapsar
                  ClipRRect(
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
                            _isExpanded ? Icons.unfold_less : Icons.unfold_more,
                            color: palette.controlIcon,
                            size: 20,
                          ),
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            setState(() {
                              _isExpanded = !_isExpanded;
                            });
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Contenedor con tema y 3 puntos (como Wallet)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: palette.controlBackground,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: palette.controlBorder,
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Botón de subida de asistencias
                            GestureDetector(
                              onTap: () {
                                HapticFeedback.lightImpact();
                                Navigator.of(context)
                                    .push(
                                      MaterialPageRoute(
                                        builder: (context) =>
                                            const UploadManagementPage(),
                                      ),
                                    )
                                    .then((_) => _checkPendingUploads());
                              },
                              child: Container(
                                width: 44,
                                height: 44,
                                alignment: Alignment.center,
                                color: Colors.transparent,
                                child: Icon(
                                  Icons.upload,
                                  color: palette.controlIcon,
                                  size: 20,
                                ),
                              ),
                            ),
                            // Botón de más opciones
                            GestureDetector(
                              onTap: () {
                                HapticFeedback.lightImpact();
                                _showOptionsMenu(context);
                              },
                              child: Container(
                                width: 44,
                                height: 44,
                                alignment: Alignment.center,
                                color: Colors.transparent,
                                child: Icon(
                                  Icons.more_horiz,
                                  color: palette.controlIcon,
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Pending attendance banner (glassmorphism style)
            if (_showPendingBanner)
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 16,
                left: 20,
                right: 20,
                child: AnimatedSlide(
                  offset: _showPendingBanner ? Offset.zero : const Offset(0, 2),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _showPendingBanner ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 400),
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        setState(() {
                          _showPendingBanner = false;
                        });
                        Navigator.of(context)
                            .push(
                              MaterialPageRoute(
                                builder: (context) =>
                                    const UploadManagementPage(),
                              ),
                            )
                            .then((_) => _checkPendingUploads());
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: palette.surface.withValues(alpha: 0.86),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: palette.border,
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              children: [
                                // Pulsing indicator dot
                                AnimatedBuilder(
                                  animation: _pulseController,
                                  builder: (context, child) {
                                    return Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Color.lerp(
                                          const Color(0xFFFF9500),
                                          const Color(0xFFFFCC00),
                                          _pulseController.value,
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(0xFFFF9500)
                                                .withValues(
                                                  alpha:
                                                      0.4 +
                                                      (_pulseController.value *
                                                          0.3),
                                                ),
                                            blurRadius: 6,
                                            spreadRadius: 1,
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 12),
                                // Cloud icon
                                Icon(
                                  Icons.cloud_upload_outlined,
                                  color: palette.textPrimary.withValues(
                                    alpha: 0.9,
                                  ),
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                // Text
                                Expanded(
                                  child: Text(
                                    'Asistencias pendientes por enviar',
                                    style: TextStyle(
                                      color: palette.textPrimary.withValues(
                                        alpha: 0.92,
                                      ),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                ),
                                // Chevron
                                Icon(
                                  Icons.chevron_right_rounded,
                                  color: palette.textSecondary.withValues(
                                    alpha: 0.7,
                                  ),
                                  size: 22,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Color> _gradientForCard(int index) =>
      _cardGradients[index % _cardGradients.length];

  Color _accentForCard(int index) =>
      _cardAccentColors[index % _cardAccentColors.length];

  Widget _buildLoadingState() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulse = _pulseController.value;

        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: MediaQuery.of(context).padding.top + 81,
              bottom: MediaQuery.of(context).padding.bottom + 200,
            ),
            child: Column(
              children: [
                _buildSkeletonWalletCards(pulse),
                const SizedBox(height: 12),
                Icon(
                  Icons.arrow_upward_rounded,
                  size: 16,
                  color: context.uatPalette.textTertiary,
                ),
                const SizedBox(height: 4),
                _buildSkeletonBlock(
                  width: 112,
                  height: 10,
                  pulse: pulse,
                  opacity: 0.06,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSkeletonWalletCards(double pulse) {
    const cardHeight = 200.0;
    const cardPeekHeight = 50.0;
    const cardCount = 5;
    const totalHeight = cardHeight + ((cardCount - 1) * cardPeekHeight);

    return SizedBox(
      height: totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: List.generate(cardCount, (index) {
          return Positioned(
            top: index * cardPeekHeight,
            left: 0,
            right: 0,
            child: _buildSkeletonCard(index, pulse),
          );
        }),
      ),
    );
  }

  Widget _buildSkeletonCard(int index, double pulse) {
    final palette = context.uatPalette;
    final gradient = _gradientForCard(index);
    final startColor = Color.lerp(
      palette.skeletonBase,
      gradient.first,
      context.isUatLightMode ? 0.16 : 0.26,
    )!;
    final endColor = Color.lerp(
      palette.skeletonBase,
      gradient.last,
      context.isUatLightMode ? 0.12 : 0.20,
    )!;
    final glowOpacity = 0.10 + (pulse * 0.08);

    return Container(
      height: 200,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [startColor, endColor],
        ),
        border: Border.all(color: palette.border, width: 0.7),
        boxShadow: [
          BoxShadow(
            color: gradient.last.withValues(alpha: glowOpacity),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: palette.shadow,
            blurRadius: 18,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            _buildSkeletonSweep(pulse),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _buildSkeletonBlock(
                        width: 106,
                        height: 26,
                        pulse: pulse,
                        opacity: 0.16,
                      ),
                      const Spacer(),
                      _buildSkeletonBlock(
                        width: 70,
                        height: 14,
                        pulse: pulse,
                        opacity: 0.13,
                      ),
                    ],
                  ),
                  const Spacer(),
                  _buildSkeletonBlock(
                    width: double.infinity,
                    height: 18,
                    pulse: pulse,
                    opacity: 0.14,
                  ),
                  const SizedBox(height: 8),
                  _buildSkeletonBlock(
                    width: 220,
                    height: 18,
                    pulse: pulse,
                    opacity: 0.12,
                  ),
                  const Spacer(),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSkeletonBlock(
                            width: 52,
                            height: 9,
                            pulse: pulse,
                            opacity: 0.11,
                          ),
                          const SizedBox(height: 8),
                          _buildSkeletonBlock(
                            width: 28,
                            height: 16,
                            pulse: pulse,
                            opacity: 0.15,
                          ),
                        ],
                      ),
                      const Spacer(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _buildSkeletonBlock(
                            width: 66,
                            height: 9,
                            pulse: pulse,
                            opacity: 0.11,
                          ),
                          const SizedBox(height: 8),
                          _buildSkeletonBlock(
                            width: 48,
                            height: 16,
                            pulse: pulse,
                            opacity: 0.15,
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletonSweep(double pulse) {
    final palette = context.uatPalette;

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final dx = ((width + 180) * pulse) - 140;

          return Transform.translate(
            offset: Offset(dx, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 92,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      palette.skeletonHighlight.withValues(alpha: 0),
                      palette.skeletonHighlight.withValues(alpha: 0.12),
                      palette.skeletonHighlight.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSkeletonBlock({
    required double width,
    required double height,
    required double pulse,
    required double opacity,
  }) {
    final palette = context.uatPalette;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.skeletonHighlight.withValues(
          alpha: opacity + (pulse * 0.08),
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border, width: 0.5),
      ),
    );
  }

  Widget _buildEmptyState(String? groupsNotice) {
    final palette = context.uatPalette;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.school_outlined,
                size: 64,
                color: palette.iconMuted,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              groupsNotice == null
                  ? 'No tienes clases asignadas'
                  : 'No hay clases para mostrar',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: palette.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              groupsNotice ??
                  'Si solicitaste una actualización, revisa el progreso abajo.',
              style: TextStyle(fontSize: 16, color: palette.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // Botón revisar sincronización
            TextButton.icon(
              onPressed: () {
                HapticFeedback.lightImpact();
                context.push('/sync-status');
              },
              icon: const Icon(Icons.cloud_sync, color: Colors.blueAccent),
              label: const Text(
                'Revisar actualización',
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupsNotice(String message) {
    final palette = context.uatPalette;

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: palette.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: UATColors.warning.withValues(alpha: 0.45)),
          boxShadow: [
            BoxShadow(
              color: palette.shadow,
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: UATColors.warning),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWalletCards(
    List<MapEntry<Grupo, int>> gruposWithIndex,
    List<Grupo> todosLosGrupos,
  ) {
    // Altura visible de cada tarjeta empalmada (como en Wallet)
    final cardPeekHeight = _isExpanded
        ? 180.0 // Modo expandido: mostrar hasta los valores de grupo y cantidad de estudiantes
        : 60.0; // Modo normal: suficiente para mostrar horario y días
    const cardHeight = 200.0;

    // Calcular altura total del contenido
    // Si hay una tarjeta seleccionada, agregar espacio extra para el desplazamiento
    final baseHeight =
        cardHeight + (gruposWithIndex.length - 1) * cardPeekHeight;
    final extraHeight = _selectedCardIndex != null
        ? (cardHeight - cardPeekHeight)
        : 0.0;
    final totalHeight = baseHeight + extraHeight;

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: MediaQuery.of(context).padding.top + 81,
          bottom: MediaQuery.of(context).padding.bottom + 200,
        ),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 350),
              curve: Curves.fastOutSlowIn,
              height: totalHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: gruposWithIndex.asMap().entries.map((entry) {
                  final stackIndex = entry.key; // Posición en el stack
                  final grupoEntry = entry.value;
                  final grupo = grupoEntry.key;
                  final originalIndex =
                      grupoEntry.value; // Índice original para horarios
                  final isCurrentClass = _isCurrentClass(grupo);

                  // Calcular posición: si hay una tarjeta seleccionada y esta está debajo,
                  // desplazarla hacia abajo
                  double topPosition = stackIndex * cardPeekHeight;
                  if (_selectedCardIndex != null &&
                      stackIndex > _selectedCardIndex!) {
                    // Desplazar tarjetas debajo hacia abajo (altura completa de la tarjeta)
                    topPosition += 200.0 - cardPeekHeight;
                  }

                  return AnimatedPositioned(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.fastOutSlowIn,
                    top: topPosition,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: false,
                      child: _buildWalletCard(
                        grupo,
                        stackIndex,
                        originalIndex,
                        isCurrentClass,
                        todosLosGrupos,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            // Indicador sutil de próxima clase por atender
            const SizedBox(height: 12),
            Column(
              children: [
                Icon(
                  Icons.arrow_upward_rounded,
                  size: 16,
                  color: context.uatPalette.textTertiary,
                ),
                const SizedBox(height: 4),
                Text(
                  'Próxima por atender',
                  style: TextStyle(
                    color: context.uatPalette.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWalletCard(
    Grupo grupo,
    int stackIndex,
    int originalIndex,
    bool isCurrentClass,
    List<Grupo> todosLosGrupos,
  ) {
    // Obtiene los colores desde la configuración compartida para mantener coherencia visual
    final gradientColors = _gradientForCard(originalIndex);
    final accentColor = _accentForCard(originalIndex);

    return Container(
      height: 200,
      margin: _isExpanded
          ? const EdgeInsets.only(bottom: 5.0)
          : EdgeInsets.zero,
      child: TweenAnimationBuilder<double>(
        duration: Duration(milliseconds: 300 + (stackIndex * 100)),
        curve: Curves.easeOut,
        tween: Tween(begin: 0.0, end: 1.0),
        builder: (context, value, child) {
          // Clamp value to ensure it stays within valid range
          final clampedValue = value.clamp(0.0, 1.0);
          return Transform.scale(
            scale: 0.8 + (clampedValue * 0.2),
            child: Opacity(opacity: clampedValue, child: child),
          );
        },
        child: Stack(
          children: [
            // Tarjeta principal
            RepaintBoundary(
              child: Hero(
                tag: 'grupo_${grupo.group}_${grupo.subject}',
                flightShuttleBuilder:
                    (
                      BuildContext flightContext,
                      Animation<double> animation,
                      HeroFlightDirection flightDirection,
                      BuildContext fromHeroContext,
                      BuildContext toHeroContext,
                    ) {
                      return Material(
                        color: Colors.transparent,
                        elevation: 0,
                        child: toHeroContext.widget,
                      );
                    },
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () async {
                      HapticFeedback.lightImpact();

                      // Establecer la tarjeta seleccionada y animar las demás hacia abajo
                      setState(() {
                        _selectedCardIndex = stackIndex;
                      });

                      // Esperar a que se complete la animación de desplazamiento
                      await Future.delayed(const Duration(milliseconds: 300));
                      if (!mounted) return;

                      // Navegar a la página de detalles
                      await Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (
                                context,
                                animation,
                                secondaryAnimation,
                              ) => GrupoDetailPage(
                                grupo: grupo,
                                gradientColors: gradientColors,
                                accentColor: accentColor,
                                horario:
                                    grupo.horarioParaDia(
                                      DateTime.now().weekday,
                                    ) ??
                                    grupo.horarioValido ??
                                    '00:00-00:00',
                                dias: grupo.diasClaseAgrupados ?? 'Sin horario',
                                todosLosGrupos: todosLosGrupos,
                              ),
                          transitionDuration: const Duration(milliseconds: 400),
                          reverseTransitionDuration: const Duration(
                            milliseconds: 350,
                          ),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                // Curva estilo iOS - suave y natural
                                final curvedAnimation = CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOut,
                                  reverseCurve: Curves.easeIn,
                                );
                                return FadeTransition(
                                  opacity: curvedAnimation,
                                  child: child,
                                );
                              },
                        ),
                      );

                      // IMPORTANTE: Esperar a que el Hero termine de regresar
                      // antes de restaurar las tarjetas de abajo
                      await Future.delayed(const Duration(milliseconds: 350));

                      // Al regresar, limpiar la selección para que las tarjetas vuelvan
                      if (mounted) {
                        setState(() {
                          _selectedCardIndex = null;
                        });
                      }
                    },
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 200),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: gradientColors,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: gradientColors[0].withValues(
                              alpha: isCurrentClass ? 0.3 : 0.2,
                            ),
                            blurRadius: isCurrentClass ? 20 : 15,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Header con badge del grupo y hora
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: accentColor.withValues(
                                                alpha: 0.2,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                color: accentColor.withValues(
                                                  alpha: 0.3,
                                                ),
                                              ),
                                            ),
                                            child: Text(
                                              grupo.aula,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: accentColor,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 1.2,
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (grupo.esCompartida) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: accentColor.withValues(
                                                alpha: 0.12,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.group_add_outlined,
                                                  size: 13,
                                                  color: accentColor,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  'COMPARTIDA',
                                                  style: TextStyle(
                                                    color: accentColor,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 150,
                                    ),
                                    child: Text(
                                      grupo.horarioParaDia(
                                            DateTime.now().weekday,
                                          ) ??
                                          'Sin clase hoy',
                                      textAlign: TextAlign.right,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: accentColor.withValues(
                                          alpha: 0.88,
                                        ),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        height: 1.15,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              // Días flotando abajo a la derecha
                            ],
                          ),

                          const SizedBox(height: 12),

                          // Nombre de la materia con altura mínima fija para consistencia
                          SizedBox(
                            height: 56, // Espacio para 2 líneas
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                grupo.materia
                                    .replaceAll(RegExp(r'\([^)]*\)\s*'), '')
                                    .trim(),
                                style: TextStyle(
                                  color: accentColor,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                  height: 1.2,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Info del grupo - posición fija
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'GRUPO',
                                    style: TextStyle(
                                      color: accentColor.withValues(alpha: 0.7),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    grupo.grupoLetra,
                                    style: TextStyle(
                                      color: accentColor,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    'ESTUDIANTES',
                                    style: TextStyle(
                                      color: accentColor.withValues(alpha: 0.7),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.people_rounded,
                                        color: accentColor,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${grupo.totalAlumnos}',
                                        style: TextStyle(
                                          color: accentColor,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ), // Cierre Container
                  ), // Cierre InkWell
                ), // Cierre Material
              ), // Cierre Hero
            ), // Cierre RepaintBoundary
          ],
        ), // Cierre Stack
      ), // Cierre TweenAnimationBuilder
    ); // Cierre SizedBox
  }

  void _showSyncDialog(BuildContext context) {
    // Block sync if there are pending attendance uploads
    final asistenciaService = AsistenciaLocalService();
    if (asistenciaService.hayAsistenciasPendientes()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Envía las asistencias pendientes antes de actualizar tus clases.',
          ),
          backgroundColor: Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    bool isLoading = false;

    // Reusar la credencial solo si sigue en memoria en esta ejecución.
    final authStorage = AuthStorageService();
    final storedPassword = authStorage.getCachedUatPassword();

    if (storedPassword == null) {
      // Tras reiniciar la app se solicita la contraseña otra vez.
      _showSyncDialogWithPassword(context);
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final palette = context.uatPalette;

          return AlertDialog(
            backgroundColor: palette.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                const Icon(Icons.sync_rounded, color: Colors.blueAccent),
                const SizedBox(width: 12),
                Text(
                  'Actualizar clases',
                  style: TextStyle(color: palette.textPrimary),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Buscaremos la información más reciente de tus clases.',
                    style: TextStyle(
                      fontSize: 14,
                      color: palette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.orange,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Las asistencias ya tomadas se conservarán. Solo se actualizará la información de tus clases.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.orange,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isLoading) ...[
                    const SizedBox(height: 20),
                    const CircularProgressIndicator(color: Colors.blueAccent),
                    const SizedBox(height: 8),
                    Text(
                      'Preparando actualización...',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isLoading ? null : () => Navigator.of(context).pop(),
                child: Text(
                  'Cancelar',
                  style: TextStyle(color: palette.textSecondary),
                ),
              ),
              FilledButton(
                onPressed: isLoading
                    ? null
                    : () async {
                        setState(() => isLoading = true);

                        final result = await ref
                            .read(profesorAuthProvider.notifier)
                            .syncGroups(storedPassword);

                        if (context.mounted) {
                          Navigator.of(context).pop();

                          result.fold(
                            (error) =>
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(error),
                                    backgroundColor: Colors.red,
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                ),
                            (message) {
                              // Navegar a pantalla de estado de sincronización
                              context.push('/sync-status');
                            },
                          );
                        }
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Actualizar'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Solicita la contraseña cuando ya no está disponible en memoria.
  void _showSyncDialogWithPassword(BuildContext context) {
    final passwordController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool obscureText = true;
    bool isLoading = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final palette = context.uatPalette;

          return AlertDialog(
            backgroundColor: palette.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                const Icon(Icons.sync_rounded, color: Colors.blueAccent),
                const SizedBox(width: 12),
                Text(
                  'Actualizar clases',
                  style: TextStyle(color: palette.textPrimary),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Ingresa tu contraseña institucional para actualizar tus clases.',
                    style: TextStyle(
                      fontSize: 14,
                      color: palette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.orange,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Las asistencias ya tomadas se conservarán. Solo se actualizará la información de tus clases.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.orange,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Form(
                    key: formKey,
                    child: TextFormField(
                      controller: passwordController,
                      obscureText: obscureText,
                      style: TextStyle(color: palette.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Contraseña institucional',
                        hintStyle: TextStyle(color: palette.textTertiary),
                        filled: true,
                        fillColor: palette.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: palette.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Colors.blueAccent,
                            width: 2,
                          ),
                        ),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureText
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            color: palette.iconMuted,
                          ),
                          onPressed: () {
                            setState(() => obscureText = !obscureText);
                          },
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Ingresa tu contraseña';
                        }
                        return null;
                      },
                    ),
                  ),
                  if (isLoading) ...[
                    const SizedBox(height: 20),
                    const CircularProgressIndicator(color: Colors.blueAccent),
                    const SizedBox(height: 8),
                    Text(
                      'Preparando actualización...',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isLoading ? null : () => Navigator.of(context).pop(),
                child: Text(
                  'Cancelar',
                  style: TextStyle(color: palette.textSecondary),
                ),
              ),
              FilledButton(
                onPressed: isLoading
                    ? null
                    : () async {
                        FocusScope.of(context).unfocus();
                        if (formKey.currentState!.validate()) {
                          setState(() => isLoading = true);

                          final result = await ref
                              .read(profesorAuthProvider.notifier)
                              .syncGroups(passwordController.text);

                          if (context.mounted) {
                            Navigator.of(context).pop();

                            result.fold(
                              (error) =>
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(error),
                                      backgroundColor: Colors.red,
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  ),
                              (message) {
                                context.push('/sync-status');
                              },
                            );
                          }
                        }
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Actualizar'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showOptionsMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final profesor = ref.read(currentProfesorProvider);
            final palette = context.uatPalette;
            final isLightMode =
                ref.watch(themeControllerProvider) == ThemeMode.light;

            return Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar y nombre
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: UATColors.primary,
                        child: Text(
                          profesor?.email[0].toUpperCase() ?? 'P',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profesor?.name ?? 'Profesor',
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              profesor?.email ?? '',
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

                  const SizedBox(height: 24),
                  Divider(color: palette.border),
                  const SizedBox(height: 8),

                  // Opciones
                  Container(
                    decoration: BoxDecoration(
                      color: palette.surfaceMuted.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: palette.border),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(
                            Icons.sync_rounded,
                            color: Colors.blueAccent,
                          ),
                          title: Text(
                            'Actualizar clases',
                            style: TextStyle(color: palette.textPrimary),
                          ),
                          subtitle: Text(
                            'Consultar la información más reciente',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _showSyncDialog(context);
                          },
                        ),
                        ListTile(
                          leading: const Icon(
                            Icons.delete_sweep,
                            color: Colors.orange,
                          ),
                          title: Text(
                            'Borrar asistencias guardadas',
                            style: TextStyle(color: palette.textPrimary),
                          ),
                          subtitle: Text(
                            'Eliminar asistencias de este equipo',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _showClearCacheDialog(context);
                          },
                        ),
                        ListTile(
                          leading: Icon(
                            isLightMode
                                ? Icons.light_mode_rounded
                                : Icons.dark_mode_rounded,
                            color: UATColors.primary,
                          ),
                          title: Text(
                            isLightMode ? 'Modo claro' : 'Modo oscuro',
                            style: TextStyle(color: palette.textPrimary),
                          ),
                          subtitle: Text(
                            'Cambiar apariencia de la app',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Switch.adaptive(
                            value: isLightMode,
                            activeThumbColor: UATColors.primary,
                            onChanged: (enabled) {
                              HapticFeedback.lightImpact();
                              ref
                                  .read(themeControllerProvider.notifier)
                                  .setLightMode(enabled);
                            },
                          ),
                          onTap: () {
                            HapticFeedback.lightImpact();
                            ref
                                .read(themeControllerProvider.notifier)
                                .setLightMode(!isLightMode);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.logout, color: Colors.red),
                          title: const Text(
                            'Cerrar sesión',
                            style: TextStyle(color: Colors.red),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _showLogoutDialog(context);
                          },
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: MediaQuery.of(context).padding.bottom),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        final palette = context.uatPalette;

        return AlertDialog(
          backgroundColor: palette.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              const Icon(Icons.logout_rounded, color: Colors.red),
              const SizedBox(width: 12),
              Text(
                'Cerrar sesión',
                style: TextStyle(color: palette.textPrimary),
              ),
            ],
          ),
          content: Text(
            '¿Estás seguro de que quieres cerrar sesión?',
            style: TextStyle(fontSize: 16, color: palette.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancelar',
                style: TextStyle(color: palette.textSecondary),
              ),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await ref.read(profesorAuthProvider.notifier).logout();
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Cerrar sesión'),
            ),
          ],
        );
      },
    );
  }

  void _showClearCacheDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        final palette = context.uatPalette;

        return AlertDialog(
          backgroundColor: palette.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              const Icon(Icons.delete_sweep, color: Colors.orange),
              const SizedBox(width: 12),
              Text(
                'Borrar asistencias guardadas',
                style: TextStyle(color: palette.textPrimary),
              ),
            ],
          ),
          content: Text(
            '¿Estás seguro de que quieres eliminar las asistencias guardadas en este equipo?\n\nEsto solo afecta las asistencias que aún no se han enviado.',
            style: TextStyle(fontSize: 16, color: palette.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancelar',
                style: TextStyle(color: palette.textSecondary),
              ),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _clearAsistenciasCache();
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
              child: const Text('Borrar asistencias'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _clearAsistenciasCache() async {
    try {
      final asistenciaService = AsistenciaLocalService();
      await asistenciaService.limpiarTodo();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Se borraron las asistencias guardadas'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No pudimos borrar las asistencias guardadas.'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }
}
