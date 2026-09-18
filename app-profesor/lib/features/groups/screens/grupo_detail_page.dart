import 'dart:ui';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/models/grupo.dart';
import '../../../shared/models/alumno.dart';
import '../../../shared/models/asistencia_registro.dart';
import '../../../services/asistencia_local_service.dart';
import '../../../services/api_service.dart';
import '../../../services/ble_beacon_verification_service.dart';
import '../../../services/native_altbeacon_channel.dart';
import '../../../services/student_attendance_ble_service.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/theme/uat_colors.dart';
import '../../../core/permissions/permission_service.dart';
import '../../../core/utils/attendance_window.dart';
import '../../../core/utils/utils.dart';
import 'student_scanner_page.dart';

import '../../../services/auth_storage_service.dart';

class GrupoDetailPage extends StatefulWidget {
  final Grupo grupo;
  final List<Color> gradientColors;
  final Color accentColor;
  final String horario;
  final String dias;
  final List<Grupo>? todosLosGrupos;
  final ApiService? apiService;

  /// Fecha inicial para mostrar (si viene de "Mostrar en pantalla")
  final DateTime? initialDate;

  /// Si true, muestra un efecto neón parpadeante en el botón de fecha
  final bool highlightDateSelector;

  /// Color del efecto neón (normalmente el color del gradiente de la materia)
  final Color? highlightColor;

  const GrupoDetailPage({
    super.key,
    required this.grupo,
    required this.gradientColors,
    required this.accentColor,
    required this.horario,
    required this.dias,
    this.todosLosGrupos,
    this.apiService,
    this.initialDate,
    this.highlightDateSelector = false,
    this.highlightColor,
  });

  @override
  State<GrupoDetailPage> createState() => _GrupoDetailPageState();
}

class _GrupoDetailPageState extends State<GrupoDetailPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Mapa para controlar el estado de asistencia de cada estudiante
  final Map<String, bool> _asistencias = {};
  final AuthStorageService _authStorage = AuthStorageService();
  late AnimationController _buttonAnimationController;
  late AnimationController _studentsAnimationController;
  late Animation<double> _studentsOpacity;
  late Animation<Offset> _studentsSlide;
  // Control del tab seleccionado (0 = Mi asistencia, 1 = Alumnos)
  int _selectedTab = 0;
  DateTime? _entradaProfesor;
  DateTime? _salidaProfesor;
  DateTime _selectedDateTime = DateTime.now();
  late String _selectedClassroom;

  // Controlador para el efecto neón parpadeante en el botón de fecha
  AnimationController? _neonAnimationController;
  Animation<double>? _neonAnimation;

  // Estado de verificación BLE
  bool _entradaVerificada = true;
  String? _motivoEntrada;

  // Servicio de almacenamiento local
  final AsistenciaLocalService _asistenciaService = AsistenciaLocalService();
  late final ApiService _apiService;

  // Servicio de verificación BLE beacon
  final BleBeaconVerificationService _bleBeaconService =
      BleBeaconVerificationService();
  final StudentAttendanceBleService _studentBeaconService =
      StudentAttendanceBleService();
  StreamSubscription<List<StudentAttendanceDetection>>?
  _studentBeaconSubscription;
  Future<void> _studentDetectionQueue = Future<void>.value();
  int _studentScanGeneration = 0;
  bool _isStudentBeaconScanning = false;
  bool _isLoadingStudentBeaconBindings = false;
  bool _isCheckingStudentScanRequirements = false;
  bool _isLoadingStudentBindingStatus = false;
  bool _studentBindingStatusLoaded = false;
  bool _hasResolvedStudentBindings = false;
  bool _studentBindingsInForeground = true;
  Future<void>? _studentBindingRefresh;
  Timer? _studentBindingRefreshTimer;
  final ValueNotifier<int> _availableStudentCount = ValueNotifier(0);
  String? _studentBindingStatusError;
  final Set<String> _linkedStudentMatriculas = {};
  final Map<String, Map<String, dynamic>> _cachedStudentBindings = {};
  Map<String, String> _studentKeyByBeaconUuid = {};
  final Set<String> _detectedStudentBeaconUuids = {};
  final Set<String> _automaticallyDetectedStudentKeys = {};
  final ValueNotifier<List<String>> _studentDetectionOrder = ValueNotifier(
    const [],
  );
  final ValueNotifier<String?> _studentScanError = ValueNotifier(null);

  // Timer para actualizar la hora
  Timer? _timer;

  // Para detectar pull-to-dismiss
  final ScrollController _scrollController = ScrollController();

  // Control del botón flotante para volver arriba
  bool _showScrollToTopButton = false;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _loadCachedStudentBindings();
    _linkedStudentMatriculas.addAll(
      widget.grupo.students
          .where((student) => student.beaconUuid?.trim().isNotEmpty ?? false)
          .map((student) => student.matricula?.trim().toUpperCase())
          .whereType<String>()
          .where((matricula) => matricula.isNotEmpty),
    );
    _availableStudentCount.value = _linkedStudentMatriculas.length;
    _startStudentBindingRefreshTimer();
    _selectedClassroom = widget.grupo.classroom.trim().toUpperCase();
    WidgetsBinding.instance.addObserver(this);
    // Configurar status bar transparente
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
    );

    // Si se recibió una fecha inicial, usarla
    if (widget.initialDate != null) {
      _selectedDateTime = DateTime(
        widget.initialDate!.year,
        widget.initialDate!.month,
        widget.initialDate!.day,
        DateTime.now().hour,
        DateTime.now().minute,
      );
    }

    // Cargar asistencia existente
    _cargarAsistencia();
    unawaited(_loadAvailableClassrooms());

    // Efecto neón parpadeante si se solicitó
    if (widget.highlightDateSelector) {
      _neonAnimationController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      );
      _neonAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: _neonAnimationController!,
          curve: Curves.easeInOut,
        ),
      );
      // Iniciar después de que termine la animación Hero
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && _neonAnimationController != null) {
          _neonAnimationController!.repeat(reverse: true);
          // Auto-detener después de ~3.5 segundos
          Future.delayed(const Duration(milliseconds: 3500), () {
            if (mounted && _neonAnimationController != null) {
              _neonAnimationController!.forward().then((_) {
                if (mounted) {
                  _neonAnimationController!.stop();
                  _neonAnimationController!.dispose();
                  _neonAnimationController = null;
                  setState(() {});
                }
              });
            }
          });
        }
      });
    }

    // Listener para detectar scroll y mostrar/ocultar botón flotante
    _scrollController.addListener(_scrollListener);

    // Timer para actualizar la hora cada minuto
    _timer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (mounted) {
        setState(() {
          // Esto forzará la actualización del widget con la nueva hora
        });
      }
    });

    _buttonAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    // Animación para estudiantes con delay
    _studentsAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _studentsOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _studentsAnimationController,
        curve: Curves.easeOut,
      ),
    );

    _studentsSlide =
        Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _studentsAnimationController,
            curve: Curves.easeOutCubic,
          ),
        );

    // Se eliminó la inicialización de _buttonAnimation porque no se usa
    // Esperar a que termine la animación del Hero
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) {
        _buttonAnimationController.forward();
      }
    });

    // Delay de 400ms antes de animar estudiantes
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        _studentsAnimationController.forward();
      }
    });
  }

  void _loadCachedStudentBindings() {
    final matriculas = widget.grupo.students
        .map((student) => student.matricula?.trim().toUpperCase())
        .whereType<String>()
        .where((matricula) => matricula.isNotEmpty)
        .toSet();
    _cachedStudentBindings
      ..clear()
      ..addEntries(
        _authStorage
            .getStudentDeviceBindings(matriculas: matriculas)
            .where((binding) {
              final deviceBindingId = binding['deviceBindingId']
                  ?.toString()
                  .trim();
              return deviceBindingId != null && deviceBindingId.isNotEmpty;
            })
            .map((binding) {
              final matricula = binding['matricula']
                  ?.toString()
                  .trim()
                  .toUpperCase();
              return MapEntry(matricula ?? '', binding);
            })
            .where((entry) => entry.key.isNotEmpty),
      );
    _linkedStudentMatriculas.addAll(_cachedStudentBindings.keys);
  }

  void _scrollListener() {
    if (_scrollController.hasClients) {
      // Mostrar botón si scrolleamos más de 200 píxeles
      final shouldShow = _scrollController.offset > 200;
      if (shouldShow != _showScrollToTopButton) {
        setState(() {
          _showScrollToTopButton = shouldShow;
        });
      }
    }
  }

  void _scrollToTop() {
    HapticFeedback.mediumImpact();
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _studentBindingRefreshTimer?.cancel();
    _availableStudentCount.dispose();
    _scrollController.removeListener(_scrollListener);
    _buttonAnimationController.dispose();
    _studentsAnimationController.dispose();
    _neonAnimationController?.dispose();
    _scrollController.dispose();
    _bleBeaconService.dispose();
    _studentBeaconSubscription?.cancel();
    _studentScanGeneration++;
    _studentDetectionOrder.dispose();
    _studentScanError.dispose();
    _studentBeaconService.stopScanning();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _studentBindingsInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _startStudentBindingRefreshTimer();
      if (_studentBindingStatusLoaded) {
        unawaited(_refreshStudentBindingStatuses(force: true, silent: true));
      }
    } else {
      _studentBindingRefreshTimer?.cancel();
      _bleBeaconService.cancelScan();
      _stopStudentBeaconScan();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;

    return Scaffold(
      backgroundColor: palette.appBackground,
      body: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) {
          if (notification is ScrollUpdateNotification) {
            // Verificar si estamos en el top
            final isAtTop = notification.metrics.pixels <= 0;

            if (isAtTop && notification.metrics.pixels < 0) {
              // Hay overscroll negativo (estamos jalando hacia abajo desde el top)
              final distance = notification.metrics.pixels.abs();

              // Si supera el threshold, cerrar
              if (distance > 100) {
                HapticFeedback.mediumImpact();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                });
                return true; // Consumir la notificación
              }
            }
          }
          return false;
        },
        child: Stack(
          children: [
            CustomScrollView(
              controller: _scrollController,
              // AlwaysScrollableScrollPhysics asegura que siempre se pueda hacer scroll
              // incluso cuando el contenido es pequeño, permitiendo el pull-to-dismiss
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 60,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12.0,
                      vertical: 16.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Hero Card
                        RepaintBoundary(
                          child: Hero(
                            tag:
                                'grupo_${widget.grupo.group}_${widget.grupo.subject}',
                            child: Material(
                              color: Colors.transparent,
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 200,
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: widget.gradientColors,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: widget.gradientColors[0]
                                          .withValues(alpha: 0.3),
                                      blurRadius: 20,
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
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: widget.accentColor
                                                    .withValues(alpha: 0.2),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                border: Border.all(
                                                  color: widget.accentColor
                                                      .withValues(alpha: 0.3),
                                                ),
                                              ),
                                              child: Text(
                                                widget.grupo.aula,
                                                style: TextStyle(
                                                  color: widget.accentColor,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  letterSpacing: 1.2,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              widget.horario,
                                              style: TextStyle(
                                                color: widget.accentColor
                                                    .withValues(alpha: 0.8),
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                        // Días flotando abajo a la derecha
                                        Positioned(
                                          right: 0,
                                          top: 22,
                                          child: Text(
                                            widget.dias,
                                            style: TextStyle(
                                              color: widget.accentColor
                                                  .withValues(alpha: 0.6),
                                              fontSize: 10,
                                              fontWeight: FontWeight.w500,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    // Nombre de la materia con altura mínima fija para consistencia
                                    SizedBox(
                                      height: 56, // Espacio para 2 líneas
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          widget.grupo.materia
                                              .replaceAll(
                                                RegExp(r'\([^)]*\)\s*'),
                                                '',
                                              )
                                              .trim(),
                                          style: TextStyle(
                                            color: widget.accentColor,
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
                                    // Info adicional - posición fija
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'GRUPO',
                                              style: TextStyle(
                                                color: widget.accentColor
                                                    .withValues(alpha: 0.7),
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                letterSpacing: 1,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              widget.grupo.grupoLetra,
                                              style: TextStyle(
                                                color: widget.accentColor,
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              'ESTUDIANTES',
                                              style: TextStyle(
                                                color: widget.accentColor
                                                    .withValues(alpha: 0.7),
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
                                                  color: widget.accentColor,
                                                  size: 18,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  '${widget.grupo.totalAlumnos}',
                                                  style: TextStyle(
                                                    color: widget.accentColor,
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
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        // Tab menu y contenido con animación
                        FadeTransition(
                          opacity: _studentsOpacity,
                          child: SlideTransition(
                            position: _studentsSlide,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Tab Menu
                                _buildTabMenu(),
                                const SizedBox(height: 16),
                                // Contenido basado en el tab seleccionado
                                _selectedTab == 0
                                    ? _buildMiAsistenciaContent()
                                    : _buildAlumnosContent(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ], // Cierre de slivers
            ), // Cierre CustomScrollView
            // Botón flotante izquierda (X)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 12,
              child: // Botón X
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
                        Icons.close,
                        color: palette.controlIcon,
                        size: 24,
                      ),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  ),
                ),
              ),
            ),
            // Botón flotante derecha (fecha)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _showDateTimePicker();
                },
                child:
                    _neonAnimationController != null && _neonAnimation != null
                    ? AnimatedBuilder(
                        animation: _neonAnimation!,
                        builder: (context, child) {
                          final neonColor =
                              widget.highlightColor ?? widget.gradientColors[0];
                          final glowIntensity = _neonAnimation!.value;
                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              boxShadow: [
                                BoxShadow(
                                  color: neonColor.withValues(
                                    alpha: 0.7 * glowIntensity,
                                  ),
                                  blurRadius: 16 * glowIntensity,
                                  spreadRadius: 2 * glowIntensity,
                                ),
                                BoxShadow(
                                  color: neonColor.withValues(
                                    alpha: 0.4 * glowIntensity,
                                  ),
                                  blurRadius: 30 * glowIntensity,
                                  spreadRadius: 4 * glowIntensity,
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 20,
                                  sigmaY: 20,
                                ),
                                child: Container(
                                  height: 44,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.controlBackground,
                                    borderRadius: BorderRadius.circular(22),
                                    border: Border.all(
                                      color: neonColor.withValues(
                                        alpha: 0.3 + 0.5 * glowIntensity,
                                      ),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _getFormattedDateTime(),
                                        style: TextStyle(
                                          color: palette.controlIcon,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.edit,
                                        size: 16,
                                        color: palette.controlIcon,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                                Text(
                                  _getFormattedDateTime(),
                                  style: TextStyle(
                                    color: palette.controlIcon,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.edit,
                                  size: 16,
                                  color: palette.controlIcon,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ),

            // Botón flotante para volver arriba
            if (_showScrollToTopButton)
              Positioned(
                bottom: 24,
                right: 16,
                child: TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 200),
                  tween: Tween<double>(begin: 0, end: 1),
                  builder: (context, value, child) {
                    return Transform.scale(
                      scale: value,
                      child: Opacity(opacity: value, child: child),
                    );
                  },
                  child: GestureDetector(
                    onTap: _scrollToTop,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                        child: Container(
                          height: 44,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF2C2C2E,
                            ).withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.1),
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.arrow_upward_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'Arriba',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ], // Cierre Stack children
        ), // Cierre Stack
      ), // Cierre NotificationListener
    ); // Cierre Scaffold
  }

  Widget _buildTabMenu() {
    return Row(
      children: [
        _buildTabButton(
          label: 'Mi asistencia',
          isSelected: _selectedTab == 0,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _selectedTab = 0);
          },
        ),
        const SizedBox(width: 24),
        _buildTabButton(
          label: 'Alumnos',
          isSelected: _selectedTab == 1,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _selectedTab = 1);
            unawaited(_refreshStudentBindingStatuses());
          },
        ),
      ],
    );
  }

  Widget _buildTabButton({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final palette = context.uatPalette;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isSelected ? palette.textPrimary : palette.textSecondary,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            height: 3,
            width: isSelected ? 40 : 0,
            decoration: BoxDecoration(
              color: widget.gradientColors[0],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiAsistenciaContent() {
    final palette = context.uatPalette;

    return Column(
      children: [
        // Mensaje de advertencia si no es día de clase
        if (_esFechaHoy() && !_esDiaDeClase()) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.orange.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Hoy no hay clase de este grupo según el horario',
                    style: TextStyle(
                      color: Colors.orange.shade300,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        // Botón de Entrada
        Container(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.shadow,
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _entradaProfesor == null && _puedeMarcarAsistenciaHoy()
                  ? () {
                      HapticFeedback.mediumImpact();
                      if (_puedeMarcarEntrada()) {
                        _verificarBeaconYMarcarEntrada();
                      } else {
                        _mostrarMensajeHorario(_getMensajeVentanaEntrada());
                      }
                    }
                  : null,
              borderRadius: BorderRadius.circular(12),
              splashColor: widget.gradientColors[0].withValues(alpha: 0.2),
              highlightColor: widget.gradientColors[0].withValues(alpha: 0.1),
              child: Opacity(
                opacity: _entradaProfesor == null && _puedeMarcarAsistenciaHoy()
                    ? 1.0
                    : 0.6,
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Row(
                    children: [
                      // Icono de entrada
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: widget.gradientColors[0].withValues(
                            alpha: 0.2,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: widget.gradientColors[0].withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Icon(
                          Icons.login_rounded,
                          color: widget.gradientColors[0],
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Texto
                      Expanded(
                        child: Text(
                          _entradaProfesor == null
                              ? 'Marcar entrada'
                              : '${_entradaEsTardia(_entradaProfesor!) ? 'Entrada tardía' : 'Entrada'}: ${_getFormattedDate(_entradaProfesor!)} ${_formatTime(_entradaProfesor!)}',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // Indicador de estado
                      if (_entradaProfesor != null)
                        Icon(
                          Icons.check_circle,
                          color: widget.gradientColors[0],
                          size: 28,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Botón de Salida
        Container(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.shadow,
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap:
                  _entradaProfesor != null &&
                      _salidaProfesor == null &&
                      _puedeMarcarAsistenciaHoy()
                  ? () {
                      HapticFeedback.mediumImpact();
                      if (_puedeMarcarSalida()) {
                        _verificarBeaconYMarcarSalida();
                      } else {
                        _mostrarMensajeHorario(_getMensajeVentanaSalida());
                      }
                    }
                  : null,
              borderRadius: BorderRadius.circular(12),
              splashColor: widget.gradientColors[0].withValues(alpha: 0.2),
              highlightColor: widget.gradientColors[0].withValues(alpha: 0.1),
              child: Opacity(
                opacity:
                    _entradaProfesor != null &&
                        _salidaProfesor == null &&
                        _puedeMarcarAsistenciaHoy()
                    ? 1.0
                    : 0.6,
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Row(
                    children: [
                      // Icono de salida
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: widget.gradientColors[0].withValues(
                            alpha: 0.2,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: widget.gradientColors[0].withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Icon(
                          Icons.logout_rounded,
                          color: widget.gradientColors[0],
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Texto
                      Expanded(
                        child: Text(
                          _salidaProfesor == null
                              ? 'Marcar salida'
                              : 'Salida: ${_getFormattedDate(_salidaProfesor!)} ${_formatTime(_salidaProfesor!)}',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // Indicador de estado
                      if (_salidaProfesor != null)
                        Icon(
                          Icons.check_circle,
                          color: widget.gradientColors[0],
                          size: 28,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Botón de Subir Asistencia
        Container(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.shadow,
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _puedeSubirAsistencia()
                  ? () {
                      HapticFeedback.mediumImpact();
                      _intentarSincronizarAsistencia();
                    }
                  : null,
              borderRadius: BorderRadius.circular(12),
              splashColor: widget.gradientColors[0].withValues(alpha: 0.2),
              highlightColor: widget.gradientColors[0].withValues(alpha: 0.1),
              child: Opacity(
                opacity: _puedeSubirAsistencia() ? 1.0 : 0.6,
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Row(
                    children: [
                      // Icono de subir
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: widget.gradientColors[0].withValues(
                            alpha: 0.2,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: widget.gradientColors[0].withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Icon(
                          Icons.cloud_upload_rounded,
                          color: widget.gradientColors[0],
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Texto
                      Expanded(
                        child: Text(
                          'Enviar asistencia',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // Icono de flecha
                      if (_puedeSubirAsistencia())
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: widget.gradientColors[0],
                          size: 24,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _loadAvailableClassrooms() async {
    final result = await _apiService.listAvailableClassroomBeacons();
    await result.fold((_) async {}, (beacons) async {
      await _authStorage.saveBeacons(beacons);
    });
  }

  // ── Verificación BLE Beacon para entrada y salida ─────────────

  Future<void> _verificarBeaconYMarcarEntrada() async {
    final resultado = await _verificarBeaconDelSalon(permitirMotivo: true);
    if (!mounted || resultado == null || !resultado.debeMarcarAsistencia) {
      return;
    }

    HapticFeedback.heavyImpact();
    final entrada = DateTime.now();
    setState(() {
      _entradaProfesor = entrada;
      _entradaVerificada = resultado.verificada;
      _motivoEntrada = resultado.motivo;
    });
    await _guardarAsistencia();
    if (mounted && _entradaEsTardia(entrada)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Entrada registrada como asistencia tardía.'),
          backgroundColor: Colors.orange[700],
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    if (resultado.verificada && resultado.beaconUuid != null) {
      await _sincronizarEntradaProfesor(resultado);
    }
  }

  Future<void> _verificarBeaconYMarcarSalida() async {
    final resultado = await _verificarBeaconDelSalon(permitirMotivo: false);
    if (!mounted || resultado == null || !resultado.verificada) return;

    HapticFeedback.heavyImpact();
    setState(() {
      _salidaProfesor = DateTime.now();
    });
    await _guardarAsistencia();
    await _sincronizarSalidaProfesor();
  }

  Future<_BleDialogResult?> _verificarBeaconDelSalon({
    required bool permitirMotivo,
  }) async {
    // Cada acción en línea vuelve a descargar el catálogo completo. Si no hay
    // conexión se conserva la última lista local para poder seguir operando.
    await _loadAvailableClassrooms();
    if (!mounted) return null;

    final references = _classroomBeaconReferences();
    if (references.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No hay salones con beacon configurado. Solicita ayuda a administración.',
          ),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 4),
        ),
      );
      return null;
    }

    if (!await _ensureScanRequirements(classroomBeacon: true)) {
      return null;
    }
    if (!mounted) return null;

    final primaryClassroom = widget.grupo.classroom.trim().toUpperCase();
    var resultado = await _scanClassroomBeacons(
      references,
      primaryClassroom: primaryClassroom,
      permitirMotivo: permitirMotivo,
    );

    while (mounted && resultado != null && resultado.verificada) {
      final detectedClassroom = resultado.classroom;
      if (detectedClassroom == null ||
          _sameClassroom(detectedClassroom, primaryClassroom)) {
        _useDetectedClassroom(detectedClassroom ?? primaryClassroom);
        return resultado;
      }

      final action = await _showAlternateClassroomWarning(detectedClassroom);
      if (!mounted || action == null) return null;
      if (action == _AlternateClassroomAction.accept) {
        _useDetectedClassroom(detectedClassroom);
        return resultado;
      }

      final selected = await _showClassroomCorrectionPicker(references);
      if (!mounted || selected == null) return null;
      resultado = await _scanClassroomBeacons(
        [selected],
        primaryClassroom: primaryClassroom,
        permitirMotivo: false,
      );
    }

    return resultado;
  }

  List<ClassroomBeaconReference> _classroomBeaconReferences() {
    final byUuid = <String, ClassroomBeaconReference>{};
    for (final beacon in _authStorage.getBeacons() ?? const []) {
      final classroom = beacon['classroom']?.toString().trim().toUpperCase();
      final uuid = beacon['uuid']?.toString().trim().toLowerCase();
      if (classroom == null ||
          classroom.isEmpty ||
          uuid == null ||
          uuid.isEmpty) {
        continue;
      }
      byUuid[uuid] = ClassroomBeaconReference(classroom: classroom, uuid: uuid);
    }
    final references = byUuid.values.toList()
      ..sort((left, right) => left.classroom.compareTo(right.classroom));
    return references;
  }

  Future<_BleDialogResult?> _scanClassroomBeacons(
    List<ClassroomBeaconReference> references, {
    required String primaryClassroom,
    required bool permitirMotivo,
  }) {
    return showDialog<_BleDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _BleBeaconScanDialog(
        bleService: _bleBeaconService,
        beacons: references,
        primaryClassroom: primaryClassroom,
        gradientColors: widget.gradientColors,
        permitirMotivo: permitirMotivo,
      ),
    );
  }

  bool _sameClassroom(String left, String right) {
    final leftKey = AuthStorageService.classroomKey(left);
    return leftKey.isNotEmpty &&
        leftKey == AuthStorageService.classroomKey(right);
  }

  void _useDetectedClassroom(String classroom) {
    final normalized = classroom.trim().toUpperCase();
    if (!mounted || normalized.isEmpty) return;
    setState(() {
      _selectedClassroom = normalized;
    });
  }

  Future<_AlternateClassroomAction?> _showAlternateClassroomWarning(
    String classroom,
  ) {
    return showDialog<_AlternateClassroomAction>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final palette = dialogContext.uatPalette;
        return AlertDialog(
          backgroundColor: palette.surfaceElevated,
          icon: const Icon(
            Icons.notification_important_outlined,
            color: Colors.orange,
            size: 36,
          ),
          title: const Text('Se detectó otro salón'),
          content: Text(
            'Se le notificará a coordinación que la asistencia se tomó en '
            '$classroom.',
            textAlign: TextAlign.center,
          ),
          actions: [
            FilledButton.icon(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_AlternateClassroomAction.accept),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Aceptar y tomar asistencia'),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_AlternateClassroomAction.correct),
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: const Text('Ese no es el salón en el que estoy'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
          ],
        );
      },
    );
  }

  Future<ClassroomBeaconReference?> _showClassroomCorrectionPicker(
    List<ClassroomBeaconReference> references,
  ) async {
    ClassroomBeaconReference? selected;
    return showDialog<ClassroomBeaconReference>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final palette = dialogContext.uatPalette;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: palette.surfaceElevated,
            title: const Text('Selecciona el salón correcto'),
            content: DropdownButtonFormField<ClassroomBeaconReference>(
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Salón',
                prefixIcon: Icon(Icons.meeting_room_outlined),
              ),
              items: references
                  .map(
                    (reference) => DropdownMenuItem(
                      value: reference,
                      child: Text(reference.classroom),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setDialogState(() => selected = value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: selected == null
                    ? null
                    : () => Navigator.of(dialogContext).pop(selected),
                icon: const Icon(Icons.radar_rounded),
                label: const Text('Detectar salón'),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _alumnoKey(Alumno alumno) {
    final matricula = alumno.matricula?.trim().toUpperCase();
    if (matricula != null && matricula.isNotEmpty) return matricula;
    final id = alumno.id?.trim();
    return id != null && id.isNotEmpty ? id : alumno.number.toString();
  }

  Map<String, bool> _normalizarAsistencias(Map<String, bool> asistencias) {
    final aliasesToStudentKey = <String, String>{};
    for (final alumno in widget.grupo.students) {
      final studentKey = _alumnoKey(alumno);
      aliasesToStudentKey[studentKey] = studentKey;
      aliasesToStudentKey[alumno.number.toString()] = studentKey;
      final id = alumno.id?.trim();
      if (id != null && id.isNotEmpty) aliasesToStudentKey[id] = studentKey;
      final matricula = alumno.matricula?.trim().toUpperCase();
      if (matricula != null && matricula.isNotEmpty) {
        aliasesToStudentKey[matricula] = studentKey;
      }
    }

    final normalized = <String, bool>{};
    asistencias.forEach((key, value) {
      final normalizedKey =
          aliasesToStudentKey[key] ??
          aliasesToStudentKey[key.trim().toUpperCase()] ??
          key;
      normalized[normalizedKey] = value;
    });

    return normalized;
  }

  List<String> _normalizarAlumnosDetectados(
    Iterable<String> detectedKeys,
    Map<String, bool> normalizedAttendance,
  ) {
    final currentStudentKeys = widget.grupo.students.map(_alumnoKey).toSet();
    final normalizedKeys = _normalizarAsistencias({
      for (final key in detectedKeys) key: true,
    }).keys;

    final uniqueKeys = <String>{};
    return [
      for (final key in normalizedKeys)
        if (currentStudentKeys.contains(key) &&
            normalizedAttendance[key] == true &&
            uniqueKeys.add(key))
          key,
    ];
  }

  List<String> _ordenPersistenteDeAlumnosDetectados() {
    final automaticKeys = _automaticallyDetectedStudentKeys;
    final persistedOrder = <String>[];
    final includedKeys = <String>{};

    for (final key in _studentDetectionOrder.value) {
      if (automaticKeys.contains(key) &&
          _asistencias[key] == true &&
          includedKeys.add(key)) {
        persistedOrder.add(key);
      }
    }
    for (final key in automaticKeys) {
      if (_asistencias[key] == true && includedKeys.add(key)) {
        persistedOrder.add(key);
      }
    }

    return persistedOrder;
  }

  // Cargar asistencia existente para la fecha seleccionada
  void _cargarAsistencia() {
    final registroActual = _asistenciaService.obtenerAsistenciaPorGrupoYFecha(
      widget.grupo.id,
      _selectedDateTime,
    );
    final registroLegado = registroActual == null
        ? _asistenciaService.obtenerAsistenciaPorGrupoYFecha(
            widget.grupo.identificadorUnico,
            _selectedDateTime,
          )
        : null;
    final registro = registroActual ?? registroLegado;

    if (registro != null) {
      final normalizedAttendance = _normalizarAsistencias(
        registro.asistenciasAlumnos,
      );
      final detectedStudentKeys = _normalizarAlumnosDetectados(
        registro.alumnosDetectadosAutomaticamente,
        normalizedAttendance,
      );
      setState(() {
        _entradaProfesor = registro.horaEntrada;
        _salidaProfesor = registro.horaSalida;
        _entradaVerificada = registro.entradaVerificada;
        _motivoEntrada = registro.motivoEntrada;
        _selectedClassroom =
            registro.salonUtilizado?.trim().toUpperCase() ??
            widget.grupo.classroom.trim().toUpperCase();
        _asistencias.clear();
        _asistencias.addAll(normalizedAttendance);
        _automaticallyDetectedStudentKeys
          ..clear()
          ..addAll(detectedStudentKeys);
        _detectedStudentBeaconUuids.clear();
        _studentDetectionOrder.value = detectedStudentKeys;
      });

      // Actualizar el nombre de la clase si está vacío (asistencias antiguas)
      if (registro.nombreClase == null || registro.nombreClase!.isEmpty) {
        final registroActualizado = registro.copyWith(
          nombreClase: widget.grupo.subject,
        );
        _asistenciaService.guardarAsistencia(registroActualizado);
      }
    } else {
      setState(() {
        _entradaProfesor = null;
        _salidaProfesor = null;
        _selectedClassroom = widget.grupo.classroom.trim().toUpperCase();
        _asistencias.clear();
        _automaticallyDetectedStudentKeys.clear();
        _detectedStudentBeaconUuids.clear();
        _studentDetectionOrder.value = const [];
      });
    }
  }

  // Guardar asistencia localmente
  String _registroAsistenciaId() {
    return '${widget.grupo.id}_${_selectedDateTime.year}-${_selectedDateTime.month}-${_selectedDateTime.day}';
  }

  Map<String, bool> _snapshotCompletoDeAsistencia() {
    if (_asistencias.isEmpty) return const {};
    final snapshot = <String, bool>{};
    for (final alumno in widget.grupo.students) {
      final key = _alumnoKey(alumno);
      snapshot[key] = _asistencias[key] ?? false;
    }
    // Conserva entradas heredadas aunque la lista local haya cambiado.
    for (final entry in _asistencias.entries) {
      snapshot.putIfAbsent(entry.key, () => entry.value);
    }
    return snapshot;
  }

  List<Map<String, dynamic>> _buildAttendancesForUpload() {
    if (_asistencias.isEmpty) return const [];
    final snapshot = _snapshotCompletoDeAsistencia();
    final attendances = <Map<String, dynamic>>[];
    for (final student in widget.grupo.students) {
      final studentId = student.id;
      if (studentId == null || studentId.isEmpty) continue;
      final present = snapshot[_alumnoKey(student)] ?? false;

      attendances.add({
        'studentId': studentId,
        // The current UI captures the first pass of the selected day.
        'num_pase_lista': 1,
        'num_dia': _selectedDateTime.weekday,
        'sn_asistencia': present,
      });
    }

    return attendances;
  }

  Future<void> _guardarAsistencia() async {
    final registroId = _registroAsistenciaId();

    final profesorId = _authStorage.getProfesor()?.id ?? 'unknown_professor';

    // Preserve the synced snapshot from the existing record so that
    // post-upload modifications are properly detected as "pending".
    final existente = _asistenciaService.obtenerAsistencia(registroId);

    final registro = AsistenciaRegistro(
      id: registroId,
      grupoId: widget.grupo.id,
      profesorId: profesorId,
      fecha: _selectedDateTime,
      horaEntrada: _entradaProfesor,
      horaSalida: _salidaProfesor,
      asistenciasAlumnos: _snapshotCompletoDeAsistencia(),
      sincronizado: false,
      fechaCreacion: existente?.fechaCreacion ?? DateTime.now(),
      fechaActualizacion: DateTime.now(),
      nombreClase: widget.grupo.subject,
      asistenciasSincronizadas: existente?.asistenciasSincronizadas,
      entradaVerificada: _entradaVerificada,
      motivoEntrada: _motivoEntrada,
      grupoCode: widget.grupo.code,
      grupoGroupLetter: widget.grupo.groupLetter,
      grupoPeriod: widget.grupo.period,
      salonUtilizado: _selectedClassroom,
      alumnosDetectadosAutomaticamente: _ordenPersistenteDeAlumnosDetectados(),
    );

    await _asistenciaService.guardarAsistencia(registro);
  }

  Future<void> _sincronizarSalidaProfesor() async {
    final token = _authStorage.getToken();
    if (token == null || token.isEmpty) return;

    final salida = _salidaProfesor;
    if (salida == null) return;

    final result = await _apiService.recordProfessorExit(
      token: token,
      externalGroupId: widget.grupo.id,
      detectedAt: salida,
    );

    result.fold(
      (error) => Logger.error(
        'No se pudo registrar salida del profesor en backend: $error',
      ),
      (_) => Logger.info('Salida del profesor registrada en backend.'),
    );
  }

  Future<void> _sincronizarEntradaProfesor(
    _BleDialogResult verification,
  ) async {
    final token = _authStorage.getToken();
    final entrada = _entradaProfesor;
    final beaconUuid = verification.beaconUuid;
    if (token == null ||
        token.isEmpty ||
        entrada == null ||
        beaconUuid == null) {
      return;
    }

    final result = await _apiService.recordProfessorBeaconEntry(
      token: token,
      externalGroupId: widget.grupo.id,
      detectedAt: entrada,
      beaconUuid: beaconUuid,
      rssi: verification.detection?.rssi,
      distance: verification.detection?.distance,
      bluetoothAddress: verification.detection?.bluetoothAddress,
    );

    result.fold(
      (error) => Logger.error(
        'No se pudo registrar entrada verificada del profesor en backend: $error',
      ),
      (_) =>
          Logger.info('Entrada verificada del profesor registrada en backend.'),
    );
  }

  // Intentar sincronizar asistencia a la nube
  Future<void> _intentarSincronizarAsistencia() async {
    // Mostrar diálogo de progreso
    if (!mounted) return;

    await _guardarAsistencia();
    if (!mounted) return;

    final token = _authStorage.getToken();
    final attendances = _buildAttendancesForUpload();

    if (token == null || token.isEmpty || attendances.isEmpty) {
      if (mounted) {
        _mostrarDialogoErrorSincronizacion();
      }
      return;
    }

    // La presencia del profesor se envía únicamente cuando se verifica la
    // entrada o la salida. Repetirla al subir alumnos usaría la hora actual del
    // servidor y podría crear una marca distinta a la que ya fue tomada.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
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
                // Icono de nube
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      Icons.cloud,
                      color: widget.gradientColors[1],
                      size: 60,
                    ),
                    Icon(
                      Icons.arrow_upward_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Indicador de progreso
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      widget.gradientColors[1],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Enviando asistencia',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Estamos guardando la asistencia...',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.textSecondary, fontSize: 14),
                ),
              ],
            ),
          ),
        );
      },
    );

    final result = await _apiService.uploadAttendance(
      token: token,
      clientRecordId: _registroAsistenciaId(),
      groupId: widget.grupo.id,
      code: widget.grupo.code ?? '',
      groupLetter: widget.grupo.groupLetter ?? widget.grupo.grupoLetra,
      period: widget.grupo.period ?? '',
      date: _selectedDateTime,
      attendances: attendances,
      groupName: widget.grupo.name,
      classroom: _selectedClassroom,
      level: widget.grupo.level,
      schedule: widget.grupo.schedule,
    );

    // Cerrar diálogo
    if (mounted) {
      Navigator.of(context).pop();
    }

    await result.fold(
      (_) async {
        if (mounted) {
          _mostrarDialogoErrorSincronizacion();
        }
      },
      (response) async {
        await _asistenciaService.guardarSnapshotEnviado(
          _registroAsistenciaId(),
        );
        if (mounted) {
          _mostrarDialogoExito(
            debugUpload: response['skippedApiRestUpload'] == true,
          );
        }
      },
    );
  }

  // Mostrar diálogo de éxito
  void _mostrarDialogoExito({bool debugUpload = false}) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
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
                // Icono de éxito
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.check_circle,
                    color: Colors.green,
                    size: 50,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  debugUpload ? 'Modo de prueba' : '¡Asistencia guardada!',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  debugUpload
                      ? 'La asistencia quedó disponible en los reportes de prueba.'
                      : 'La asistencia del profesor y los alumnos\nse guardó correctamente.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Entendido',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Mostrar diálogo de error de sincronización
  void _mostrarDialogoErrorSincronizacion() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
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
                // Icono de advertencia
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.cloud_off, color: Colors.orange, size: 50),
                ),
                const SizedBox(height: 20),
                Text(
                  'No pudimos enviar la asistencia',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'La asistencia se guardó en este equipo,\npero no pudimos enviarla.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Puede intentarlo más tarde usando el botón "Pendientes" en la esquina superior derecha.',
                          style: TextStyle(
                            color: Colors.orange.shade300,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Entendido',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Verificar si la fecha seleccionada es hoy
  bool _esFechaHoy() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selected = DateTime(
      _selectedDateTime.year,
      _selectedDateTime.month,
      _selectedDateTime.day,
    );
    return selected == today;
  }

  // Verificar si la fecha seleccionada es un día de clase válido
  bool _esDiaDeClase() {
    final weekdaysConClase = widget.grupo.weekdaysConHorarioValido;
    if (weekdaysConClase.isEmpty) {
      return true; // Si no hay horario, permitir cualquier día
    }

    // weekday: 1=Monday, 2=Tuesday, ..., 7=Sunday
    return weekdaysConClase.contains(_selectedDateTime.weekday);
  }

  // Verificar si se puede marcar asistencia (es hoy Y es día de clase)
  bool _puedeMarcarAsistenciaHoy() {
    return _esFechaHoy() && _esDiaDeClase();
  }

  // La asistencia de alumnos es independiente de que el profesor haya marcado
  // entrada o salida. Solo se restringen fechas futuras y días sin clase.
  bool _puedeMarcarAsistenciaAlumnos() {
    return AttendanceWindow.canTakeStudentAttendanceForDate(
      selectedDate: _selectedDateTime,
      now: DateTime.now(),
      isClassDay: _esDiaDeClase(),
    );
  }

  bool _puedeEscanearAlumnos() {
    return _puedeMarcarAsistenciaAlumnos();
  }

  String _mensajeEscaneoNoDisponible() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selectedDay = DateTime(
      _selectedDateTime.year,
      _selectedDateTime.month,
      _selectedDateTime.day,
    );
    if (selectedDay.isAfter(today)) {
      return 'No se puede tomar asistencia para una fecha futura.';
    }
    if (!_esDiaDeClase()) {
      return 'La fecha seleccionada no corresponde a un día de clase de esta materia.';
    }
    return 'No se puede tomar asistencia para la fecha seleccionada.';
  }

  bool _puedeSubirAsistencia() {
    final tieneAsistenciaProfesor =
        _entradaProfesor != null && _salidaProfesor != null;
    final tieneAsistenciaAlumnos =
        _puedeMarcarAsistenciaAlumnos() && _asistencias.isNotEmpty;

    return tieneAsistenciaProfesor || tieneAsistenciaAlumnos;
  }

  String _normalizeBeaconUuid(String uuid) {
    return uuid.replaceAll('-', '').trim().toLowerCase();
  }

  void _startStudentBindingRefreshTimer() {
    _studentBindingRefreshTimer?.cancel();
    final seconds = ApiConstants.studentBindingsRefreshSeconds;
    _studentBindingRefreshTimer = Timer.periodic(
      Duration(seconds: seconds > 0 ? seconds : 30),
      (_) {
        if (!mounted ||
            !_studentBindingStatusLoaded ||
            _isLoadingStudentBeaconBindings) {
          return;
        }
        unawaited(_refreshStudentBindingStatuses(force: true, silent: true));
      },
    );
  }

  Future<void> _refreshStudentBindingStatuses({
    bool force = false,
    bool silent = false,
  }) {
    // El inicio del escáner y el temporizador comparten la misma consulta.
    final pending = _studentBindingRefresh;
    if (pending != null) return pending;
    if (!mounted || (_studentBindingStatusLoaded && !force)) {
      return Future<void>.value();
    }
    final refresh = _fetchStudentBindingStatuses(silent: silent);
    _studentBindingRefresh = refresh;
    return refresh.whenComplete(() => _studentBindingRefresh = null);
  }

  Future<void> _fetchStudentBindingStatuses({required bool silent}) async {
    final matriculas = widget.grupo.students
        .map((student) => student.matricula?.trim().toUpperCase())
        .whereType<String>()
        .where((matricula) => matricula.isNotEmpty)
        .toSet();
    setState(() {
      _isLoadingStudentBindingStatus = !silent;
      _studentBindingStatusLoaded = true;
      if (!silent) _studentBindingStatusError = null;
    });
    try {
      if (matriculas.isEmpty) return;
      // La respuesta del servidor confirma que hay acceso a internet. Una
      // caída de red conserva los vínculos y se reintenta en el siguiente tick.
      final result = await _apiService.resolveStudentDeviceBindings(
        matriculas: matriculas.toList(),
      );
      if (!mounted) return;
      await result.fold(
        (error) async {
          if (!silent) setState(() => _studentBindingStatusError = error);
        },
        (bindings) async {
          final resolved = <String, Map<String, dynamic>>{};
          for (final binding in bindings) {
            final matricula = binding['matricula']
                ?.toString()
                .trim()
                .toUpperCase();
            final uuid = binding['attendanceUuid']?.toString().trim();
            final bindingId = binding['deviceBindingId']?.toString().trim();
            if (!matriculas.contains(matricula) ||
                uuid == null ||
                uuid.isEmpty ||
                bindingId == null ||
                bindingId.isEmpty) {
              continue;
            }
            resolved[matricula!] = binding;
          }
          // Aplicar la respuesta también en memoria: el escáner no depende de
          // que el almacenamiento local termine para reconocer alumnos nuevos.
          setState(() {
            _cachedStudentBindings
              ..clear()
              ..addAll(resolved);
            _linkedStudentMatriculas
              ..clear()
              ..addAll(resolved.keys);
            _hasResolvedStudentBindings = true;
            _studentBindingStatusError = null;
          });
          _availableStudentCount.value = _linkedStudentMatriculas.length;
          await _updateActiveStudentScanBindings();
          await _authStorage.cacheResolvedStudentDeviceBindings(
            resolved.values.toList(),
            requestedMatriculas: matriculas,
          );
        },
      );
    } catch (error, stackTrace) {
      Logger.error(
        'No se pudieron actualizar los vínculos de alumnos',
        error,
        stackTrace,
      );
      if (mounted && !silent) {
        setState(() => _studentBindingStatusError = error.toString());
      }
    } finally {
      if (mounted) setState(() => _isLoadingStudentBindingStatus = false);
    }
  }

  Map<String, String> _studentBeaconBindings() {
    final byMatricula = <String, String>{};
    if (!_hasResolvedStudentBindings) {
      for (final student in widget.grupo.students) {
        final matricula = student.matricula?.trim().toUpperCase();
        final uuid = student.beaconUuid?.trim();
        if (matricula != null &&
            matricula.isNotEmpty &&
            uuid != null &&
            uuid.isNotEmpty) {
          byMatricula[matricula] = uuid;
        }
      }
    }
    for (final entry in _cachedStudentBindings.entries) {
      final uuid = entry.value['attendanceUuid']?.toString().trim();
      if (uuid != null && uuid.isNotEmpty) byMatricula[entry.key] = uuid;
    }
    return {
      for (final student in widget.grupo.students)
        if (byMatricula.containsKey(student.matricula?.trim().toUpperCase()))
          _normalizeBeaconUuid(
            byMatricula[student.matricula!.trim().toUpperCase()]!,
          ): _alumnoKey(
            student,
          ),
    };
  }

  Map<String, StudentAttendanceGattConfirmation> _studentScanConfirmations(
    Map<String, String> bindings,
  ) {
    final studentsByKey = {
      for (final student in widget.grupo.students) _alumnoKey(student): student,
    };
    return {
      for (final binding in bindings.entries)
        binding.key: StudentAttendanceGattConfirmation(
          matricula: studentsByKey[binding.value]!.matricula!,
          materia: widget.grupo.subject,
          dia: _selectedDateTime,
        ),
    };
  }

  Future<void> _updateActiveStudentScanBindings() async {
    if (!mounted ||
        !_studentBindingsInForeground ||
        !_isStudentBeaconScanning ||
        _isLoadingStudentBeaconBindings) {
      return;
    }
    final bindings = _studentBeaconBindings();
    if (mapEquals(bindings, _studentKeyByBeaconUuid)) return;
    final generation = _studentScanGeneration;
    final previous = _studentKeyByBeaconUuid;
    // Registrar el mapa antes de que el canal nativo pueda emitir detecciones.
    _studentKeyByBeaconUuid = bindings;
    try {
      final updated = await _studentBeaconService.updateBindings(
        confirmationsByUuid: _studentScanConfirmations(bindings),
      );
      if (!updated) {
        throw StateError('El escáner no aceptó los vínculos actualizados');
      }
    } catch (error, stackTrace) {
      if (mounted && generation == _studentScanGeneration) {
        _studentKeyByBeaconUuid = previous;
      }
      Logger.error(
        'No se pudieron actualizar los UUIDs del escáner',
        error,
        stackTrace,
      );
    }
  }

  Future<Map<String, String>> _loadStudentBeaconBindingsForScan() async {
    await _refreshStudentBindingStatuses(force: true, silent: true);
    return _studentBeaconBindings();
  }

  Future<bool> _startStudentBeaconScan() async {
    if (_isStudentBeaconScanning || _isLoadingStudentBeaconBindings) {
      return _isStudentBeaconScanning;
    }
    final scanGeneration = ++_studentScanGeneration;
    _studentScanError.value = null;

    if (!_puedeEscanearAlumnos()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_mensajeEscaneoNoDisponible()),
          backgroundColor: Colors.orange,
        ),
      );
      return false;
    }

    setState(() {
      _isLoadingStudentBeaconBindings = true;
    });

    final bindings = await _loadStudentBeaconBindingsForScan();
    if (!mounted || scanGeneration != _studentScanGeneration) return false;

    if (bindings.isEmpty) {
      setState(() {
        _isLoadingStudentBeaconBindings = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No hay alumnos listos para la detección automática en este grupo.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return false;
    }

    final confirmationsByUuid = _studentScanConfirmations(bindings);
    final scannableBindings = bindings;

    if (confirmationsByUuid.isEmpty) {
      setState(() {
        _isLoadingStudentBeaconBindings = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No pudimos preparar la detección automática de este grupo.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return false;
    }

    final requirement = await PermissionService.checkStudentAttendanceScan();
    if (!mounted || scanGeneration != _studentScanGeneration) return false;

    if (!requirement.isReady) {
      setState(() {
        _isLoadingStudentBeaconBindings = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'El teléfono ya no cumple los requisitos. Cierra el escáner e inténtalo de nuevo.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return false;
    }

    await _studentBeaconSubscription?.cancel();
    _studentKeyByBeaconUuid = scannableBindings;
    _studentBeaconSubscription = _studentBeaconService.detectionsStream.listen(
      _enqueueStudentBeaconDetections,
      onError: (Object error, StackTrace stackTrace) {
        Logger.error(
          'El sistema detuvo el escaneo BLE de alumnos.',
          error,
          stackTrace,
        );
        _studentScanError.value = error.toString();
        if (mounted) {
          setState(() => _isStudentBeaconScanning = false);
        } else {
          _isStudentBeaconScanning = false;
        }
      },
    );

    _bleBeaconService.cancelScan();
    var started = false;
    PlatformException? startError;

    try {
      started = await _studentBeaconService.startScanning(
        confirmationsByUuid: confirmationsByUuid,
      );
    } on PlatformException catch (error) {
      startError = error;
      Logger.info(
        '[StudentBeaconScan] GATT no disponible: ${error.code} ${error.message}',
      );
    }

    if (!mounted || scanGeneration != _studentScanGeneration) {
      await _studentBeaconSubscription?.cancel();
      _studentBeaconSubscription = null;
      await _studentBeaconService.stopScanning();
      return false;
    }

    if (!started && startError != null) {
      final error = startError;
      Logger.info(
        '[StudentBeaconScan] No se pudo iniciar BLE: ${error.code} ${error.message}',
      );
      if (mounted) {
        setState(() {
          _isLoadingStudentBeaconBindings = false;
          _isStudentBeaconScanning = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.code == 'BLUETOOTH_OFF'
                  ? 'Activa Bluetooth para iniciar la detección.'
                  : 'Permite dispositivos cercanos y ubicación desde Configuración.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      await _studentBeaconSubscription?.cancel();
      _studentBeaconSubscription = null;
      return false;
    }
    if (!mounted) return false;

    setState(() {
      _isLoadingStudentBeaconBindings = false;
      _isStudentBeaconScanning = started;
    });

    if (!started) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo iniciar la detección automática.'),
          backgroundColor: Colors.red,
        ),
      );
      await _studentBeaconSubscription?.cancel();
      _studentBeaconSubscription = null;
    }
    return started;
  }

  Future<void> _stopStudentBeaconScan() async {
    _studentScanGeneration++;
    // Bloquear actualizaciones del temporizador desde el inicio del cierre.
    _isStudentBeaconScanning = false;
    _isLoadingStudentBeaconBindings = false;
    await _studentBeaconSubscription?.cancel();
    _studentBeaconSubscription = null;
    await _studentDetectionQueue;
    await _studentBeaconService.stopScanning();
    _studentKeyByBeaconUuid = {};
    if (mounted) {
      setState(() {
        _isStudentBeaconScanning = false;
        _isLoadingStudentBeaconBindings = false;
      });
    } else {
      _isStudentBeaconScanning = false;
      _isLoadingStudentBeaconBindings = false;
    }
  }

  Future<void> _handleStudentBeaconDetections(
    List<StudentAttendanceDetection> detections,
  ) async {
    if ((!_isStudentBeaconScanning && !_isLoadingStudentBeaconBindings) ||
        detections.isEmpty) {
      return;
    }

    final studentsByUuid = <String, String>{};
    final previousAttendance = <String, ({bool existed, bool? wasPresent})>{};
    final newlyDetectedUuids = <String>{};
    final newlyAutomaticStudentKeys = <String>{};

    for (final detection in detections) {
      final normalized = _normalizeBeaconUuid(detection.uuid);
      final studentKey = _studentKeyByBeaconUuid[normalized];
      if (studentKey == null) continue;
      studentsByUuid[normalized] = studentKey;
      if (_detectedStudentBeaconUuids.contains(normalized)) continue;

      previousAttendance.putIfAbsent(
        studentKey,
        () => (
          existed: _asistencias.containsKey(studentKey),
          wasPresent: _asistencias[studentKey],
        ),
      );
      newlyDetectedUuids.add(normalized);
      if (!_automaticallyDetectedStudentKeys.contains(studentKey)) {
        newlyAutomaticStudentKeys.add(studentKey);
      }
    }

    if (newlyDetectedUuids.isNotEmpty) {
      void acceptDetections() {
        for (final studentKey in previousAttendance.keys) {
          _asistencias[studentKey] = true;
        }
        _detectedStudentBeaconUuids.addAll(newlyDetectedUuids);
        _automaticallyDetectedStudentKeys.addAll(newlyAutomaticStudentKeys);
        if (mounted && newlyAutomaticStudentKeys.isNotEmpty) {
          final nextOrder = List<String>.from(_studentDetectionOrder.value);
          for (final studentKey in newlyAutomaticStudentKeys) {
            nextOrder
              ..remove(studentKey)
              ..insert(0, studentKey);
          }
          _studentDetectionOrder.value = nextOrder;
        }
      }

      if (mounted) {
        setState(acceptDetections);
      } else {
        acceptDetections();
      }

      try {
        await _guardarAsistencia();
      } catch (error, stackTrace) {
        Logger.error(
          'No se pudo guardar una detección de asistencia; no se confirmó al alumno.',
          error,
          stackTrace,
        );

        void rollbackDetections() {
          for (final entry in previousAttendance.entries) {
            if (entry.value.existed) {
              _asistencias[entry.key] = entry.value.wasPresent ?? false;
            } else {
              _asistencias.remove(entry.key);
            }
          }
          _detectedStudentBeaconUuids.removeAll(newlyDetectedUuids);
          _automaticallyDetectedStudentKeys.removeAll(
            newlyAutomaticStudentKeys,
          );
          if (mounted && newlyAutomaticStudentKeys.isNotEmpty) {
            _studentDetectionOrder.value = _studentDetectionOrder.value
                .where((key) => !newlyAutomaticStudentKeys.contains(key))
                .toList(growable: false);
          }
        }

        if (mounted) {
          setState(rollbackDetections);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No se pudo guardar la asistencia. El alumno no recibió confirmación.',
              ),
              backgroundColor: Colors.red,
            ),
          );
        } else {
          rollbackDetections();
        }
        return;
      }

      if (mounted && newlyAutomaticStudentKeys.isNotEmpty) {
        HapticFeedback.lightImpact();
      }

      if (mounted) {
        await WidgetsBinding.instance.endOfFrame;
      }
    }

    for (final entry in studentsByUuid.entries) {
      if (_asistencias[entry.value] != true) continue;
      try {
        final confirmationStarted = await _studentBeaconService
            .confirmAttendance(entry.key);
        if (!confirmationStarted) {
          Logger.info(
            '[StudentBeaconScan] La conexión de ${entry.key} terminó antes de confirmar; se reintentará al detectarlo de nuevo.',
          );
        }
      } on PlatformException catch (error, stackTrace) {
        Logger.error(
          'No se pudo confirmar la asistencia al teléfono del alumno.',
          error,
          stackTrace,
        );
      }
    }
  }

  void _enqueueStudentBeaconDetections(
    List<StudentAttendanceDetection> detections,
  ) {
    final previous = _studentDetectionQueue;
    _studentDetectionQueue = _processQueuedStudentDetections(
      previous,
      detections,
    );
  }

  Future<void> _processQueuedStudentDetections(
    Future<void> previous,
    List<StudentAttendanceDetection> detections,
  ) async {
    try {
      await previous;
    } catch (_) {
      // A failed batch must not prevent later students from being processed.
    }

    try {
      await _handleStudentBeaconDetections(detections);
    } catch (error, stackTrace) {
      Logger.error(
        'Error procesando una detección BLE de alumno.',
        error,
        stackTrace,
      );
    }
  }

  String _getFormattedDate(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dayBeforeYesterday = today.subtract(const Duration(days: 2));
    final targetDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (targetDate == today) {
      return 'Hoy';
    } else if (targetDate == yesterday) {
      return 'Ayer';
    } else if (targetDate == dayBeforeYesterday) {
      return 'Antier';
    } else {
      final day = dateTime.day.toString().padLeft(2, '0');
      final months = [
        'ene',
        'feb',
        'mar',
        'abr',
        'may',
        'jun',
        'jul',
        'ago',
        'sep',
        'oct',
        'nov',
        'dic',
      ];
      final month = months[dateTime.month - 1];
      return '$day-$month';
    }
  }

  String _getFormattedDateTime() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dayBeforeYesterday = today.subtract(const Duration(days: 2));

    final currentDate = DateTime(
      _selectedDateTime.year,
      _selectedDateTime.month,
      _selectedDateTime.day,
    );
    final hour = _selectedDateTime.hour.toString().padLeft(2, '0');
    final minute = _selectedDateTime.minute.toString().padLeft(2, '0');
    final time = '$hour:$minute';

    if (currentDate == today) {
      return 'Hoy $time';
    } else if (currentDate == yesterday) {
      return 'Ayer $time';
    } else if (currentDate == dayBeforeYesterday) {
      return 'Antier $time';
    } else {
      final day = _selectedDateTime.day.toString().padLeft(2, '0');
      final months = [
        'ene',
        'feb',
        'mar',
        'abr',
        'may',
        'jun',
        'jul',
        'ago',
        'sep',
        'oct',
        'nov',
        'dic',
      ];
      final month = months[_selectedDateTime.month - 1];
      return '$day-$month $time';
    }
  }

  // Parsear el horario (ej: "20:00-21:00" -> DateTime de hoy con esas horas)
  DateTime? _parseHorarioInicio() {
    return AttendanceWindow.classStart(widget.horario, DateTime.now());
  }

  DateTime? _parseHorarioFin() {
    return AttendanceWindow.classEnd(widget.horario, DateTime.now());
  }

  bool _puedeMarcarEntrada() {
    return AttendanceWindow.canMarkEntry(
      widget.horario,
      DateTime.now(),
      toleranceMinutes: ApiConstants.teacherAttendanceToleranceMinutes,
    );
  }

  bool _entradaEsTardia(DateTime entrada) {
    return AttendanceWindow.arrivalStatus(
          widget.horario,
          entrada,
          toleranceMinutes: ApiConstants.teacherAttendanceToleranceMinutes,
        ) ==
        ProfessorArrivalStatus.late;
  }

  bool _puedeMarcarSalida() {
    return AttendanceWindow.canMarkExit(
      widget.horario,
      DateTime.now(),
      toleranceMinutes: ApiConstants.teacherAttendanceToleranceMinutes,
    );
  }

  String _getMensajeVentanaEntrada() {
    final inicioClase = _parseHorarioInicio();
    final finClase = _parseHorarioFin();
    if (inicioClase == null || finClase == null) return '';

    final tolerance = ApiConstants.teacherAttendanceToleranceMinutes;
    final ventanaInicio = inicioClase.subtract(Duration(minutes: tolerance));
    final ventanaFin = finClase.add(Duration(minutes: tolerance));
    final finPuntual = inicioClase.add(Duration(minutes: tolerance));
    final inicioTardio = finPuntual.add(const Duration(minutes: 1));

    final horaInicio = _formatTime(ventanaInicio);
    final horaFin = _formatTime(ventanaFin);
    final horaFinPuntual = _formatTime(finPuntual);
    final horaInicioTardio = _formatTime(inicioTardio);

    return 'Puedes marcar entrada entre $horaInicio y $horaFin. '
        'Será puntual hasta $horaFinPuntual y tardía desde $horaInicioTardio.';
  }

  String _getMensajeVentanaSalida() {
    final inicioClase = _parseHorarioInicio();
    final finClase = _parseHorarioFin();
    if (inicioClase == null || finClase == null) return '';

    final tolerance = ApiConstants.teacherAttendanceToleranceMinutes;
    final ventanaInicio = inicioClase.subtract(Duration(minutes: tolerance));
    final ventanaFin = finClase.add(Duration(minutes: tolerance));

    final horaInicio = _formatTime(ventanaInicio);
    final horaFin = _formatTime(ventanaFin);

    return 'Puedes marcar salida entre $horaInicio y $horaFin';
  }

  void _mostrarMensajeHorario(String mensaje) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensaje),
        backgroundColor: Colors.orange[700],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  bool _esFechaSeleccionable(DateTime date) {
    final weekdays = widget.grupo.weekdaysConHorarioValido;
    if (weekdays.isEmpty) return true;
    return weekdays.contains(date.weekday);
  }

  DateTime _fechaInicialSeleccionable(DateTime candidate, DateTime lastDate) {
    if (_esFechaSeleccionable(candidate) && !candidate.isAfter(lastDate)) {
      return candidate;
    }

    var cursor = candidate.isAfter(lastDate) ? lastDate : candidate;
    for (var i = 0; i < 14; i++) {
      if (_esFechaSeleccionable(cursor)) return cursor;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    cursor = candidate;
    for (var i = 0; i < 14; i++) {
      if (!cursor.isAfter(lastDate) && _esFechaSeleccionable(cursor)) {
        return cursor;
      }
      cursor = cursor.add(const Duration(days: 1));
    }

    return lastDate;
  }

  Future<void> _showDateTimePicker() async {
    // Obtener la hora actual para mantenerla cuando se cambie la fecha
    final now = DateTime.now();
    final initialDate = _fechaInicialSeleccionable(_selectedDateTime, now);
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: now, // No permitir fechas futuras
      locale: const Locale('es', 'MX'),
      selectableDayPredicate: _esFechaSeleccionable,
      builder: (context, child) {
        final palette = context.uatPalette;
        final baseTheme = Theme.of(context);

        return Theme(
          data: baseTheme.copyWith(
            colorScheme: baseTheme.colorScheme.copyWith(
              primary: widget.accentColor,
              onPrimary: Colors.white,
              surface: palette.surfaceElevated,
              onSurface: palette.textPrimary,
              onSurfaceVariant: palette.textSecondary,
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: widget.accentColor),
            ),
            datePickerTheme: DatePickerThemeData(
              backgroundColor: palette.surfaceElevated,
              headerBackgroundColor: palette.surfaceElevated,
              headerForegroundColor: palette.textPrimary,
              dividerColor: palette.border,
              dayForegroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.disabled)) {
                  return palette.textTertiary.withValues(alpha: 0.35);
                }
                if (states.contains(WidgetState.selected)) return Colors.white;
                return palette.textPrimary;
              }),
              dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return widget.accentColor;
                }
                if (states.contains(WidgetState.hovered)) {
                  return widget.accentColor.withValues(alpha: 0.12);
                }
                return null;
              }),
              todayForegroundColor: WidgetStateProperty.all(widget.accentColor),
              todayBorder: BorderSide(color: widget.accentColor),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: palette.surfaceElevated,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    if (pickedDate != null) {
      if (_isStudentBeaconScanning) {
        await _stopStudentBeaconScan();
        if (!mounted) return;
      }
      // Solo actualizar la fecha, mantener la hora actual
      setState(() {
        _selectedDateTime = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          now.hour,
          now.minute,
        );
      });
      // Cargar la asistencia de la nueva fecha seleccionada
      _cargarAsistencia();
    }
  }

  Future<void> _openStudentScanner() async {
    if (!_puedeEscanearAlumnos()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_mensajeEscaneoNoDisponible()),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_isCheckingStudentScanRequirements) return;
    setState(() => _isCheckingStudentScanRequirements = true);
    var requirementsReady = false;
    try {
      requirementsReady = await _ensureScanRequirements(classroomBeacon: false);
    } finally {
      if (mounted) {
        setState(() => _isCheckingStudentScanRequirements = false);
      }
    }
    if (!mounted || !requirementsReady) return;

    final currentOrder = List<String>.from(_studentDetectionOrder.value);
    for (final studentKey in _automaticallyDetectedStudentKeys) {
      if (!currentOrder.contains(studentKey)) currentOrder.add(studentKey);
    }
    if (currentOrder.length != _studentDetectionOrder.value.length) {
      _studentDetectionOrder.value = currentOrder;
    }

    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        fullscreenDialog: true,
        transitionDuration: const Duration(milliseconds: 360),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (context, animation, secondaryAnimation) =>
            StudentScannerPage(
              students: widget.grupo.students,
              detectedStudentKeys: _studentDetectionOrder,
              scanError: _studentScanError,
              gradientColors: widget.gradientColors,
              subject: widget.grupo.subject,
              groupLabel: widget.grupo.grupoLetra,
              availableStudentCount: _availableStudentCount.value,
              availableStudentCountListenable: _availableStudentCount,
              onStart: _startStudentBeaconScan,
              onStop: _stopStudentBeaconScan,
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.035),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );

    if (mounted &&
        (_isStudentBeaconScanning || _isLoadingStudentBeaconBindings)) {
      await _stopStudentBeaconScan();
    }
  }

  Future<bool> _ensureScanRequirements({required bool classroomBeacon}) async {
    Future<ScanRequirementResult> check({bool request = false}) {
      return classroomBeacon
          ? PermissionService.checkClassroomBeaconScan(
              requestPermissions: request,
            )
          : PermissionService.checkStudentAttendanceScan(
              requestPermissions: request,
            );
    }

    var result = await check();
    if (!mounted || result.isReady) return result.isReady;

    final accepted = await _showScanRequirementDialog(
      result,
      classroomBeacon: classroomBeacon,
    );
    if (!mounted || !accepted) return false;

    if (result.requirement == ScanRequirement.permissionRequired) {
      result = await check(request: true);
      if (!mounted || result.isReady) return result.isReady;
      await _showScanRequirementDialog(
        result,
        classroomBeacon: classroomBeacon,
      );
      return false;
    }

    final target = result.settingsTarget;
    if (target != null) {
      await PermissionService.openSettings(target);
    }
    return false;
  }

  Future<bool> _showScanRequirementDialog(
    ScanRequirementResult result, {
    required bool classroomBeacon,
  }) async {
    final operation = classroomBeacon
        ? 'detectar el sensor del salón'
        : 'escanear alumnos cercanos';
    final (title, message, icon) = switch (result.requirement) {
      ScanRequirement.permissionRequired => (
        'Permisos necesarios',
        'Para $operation, permite el acceso a dispositivos cercanos y a tu ubicación.',
        Icons.admin_panel_settings_outlined,
      ),
      ScanRequirement.permissionDenied => (
        'Permiso bloqueado',
        'El permiso necesario está desactivado. Actívalo en la configuración de la app para continuar.',
        Icons.lock_outline_rounded,
      ),
      ScanRequirement.bluetoothOff => (
        'Bluetooth está apagado',
        'Enciende Bluetooth antes de $operation. El escaneo no comenzará mientras siga apagado.',
        Icons.bluetooth_disabled_rounded,
      ),
      ScanRequirement.locationServicesOff => (
        'Ubicación desactivada',
        'Enciende la ubicación del teléfono para $operation. El escaneo no comenzará mientras siga apagada.',
        Icons.location_off_rounded,
      ),
      ScanRequirement.unsupported => (
        'Función no disponible',
        'Este teléfono no es compatible con el escaneo Bluetooth requerido.',
        Icons.phonelink_erase_rounded,
      ),
      ScanRequirement.unavailable => (
        'No se pudo verificar el teléfono',
        'No pudimos comprobar el estado de Bluetooth. Inténtalo de nuevo.',
        Icons.error_outline_rounded,
      ),
      ScanRequirement.ready => (
        'Todo listo',
        'El teléfono está listo para escanear.',
        Icons.check_circle_outline_rounded,
      ),
    };
    final actionLabel = result.requirement == ScanRequirement.permissionRequired
        ? 'Permitir'
        : switch (result.settingsTarget) {
            ScanSettingsTarget.app => 'Abrir configuración',
            ScanSettingsTarget.bluetooth => 'Abrir Bluetooth',
            ScanSettingsTarget.location => 'Abrir ubicación',
            null => 'Entendido',
          };

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            icon: Icon(icon, color: Colors.orange, size: 38),
            title: Text(title, textAlign: TextAlign.center),
            content: Text(message, textAlign: TextAlign.center),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                key: const ValueKey('scan-requirement-action'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(actionLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Widget _buildStudentBeaconScanControls() {
    final palette = context.uatPalette;
    final canScan = _puedeEscanearAlumnos();

    return SizedBox(
      width: double.infinity,
      height: 68,
      child: FilledButton.icon(
        key: const ValueKey('open-student-scanner'),
        onPressed:
            canScan &&
                !_isLoadingStudentBeaconBindings &&
                !_isCheckingStudentScanRequirements
            ? _openStudentScanner
            : null,
        icon:
            _isLoadingStudentBeaconBindings ||
                _isCheckingStudentScanRequirements
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.person_search_rounded, size: 27),
        label: Text(
          _isLoadingStudentBeaconBindings
              ? 'Preparando escaneo…'
              : _isCheckingStudentScanRequirements
              ? 'Verificando teléfono…'
              : 'Escanear alumnos',
        ),
        style: FilledButton.styleFrom(
          backgroundColor: widget.gradientColors.first,
          disabledBackgroundColor: palette.surfaceMuted,
          foregroundColor: Colors.white,
          disabledForegroundColor: palette.textTertiary,
          elevation: 0,
          shadowColor: widget.gradientColors.first.withValues(alpha: 0.28),
          textStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.15,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
    );
  }

  Widget _buildAlumnosContent() {
    final palette = context.uatPalette;
    final automaticallyDetectedStudents = widget.grupo.students
        .where(
          (student) =>
              _automaticallyDetectedStudentKeys.contains(_alumnoKey(student)),
        )
        .toList(growable: false);
    final mainStudents = widget.grupo.students
        .where(
          (student) =>
              !_automaticallyDetectedStudentKeys.contains(_alumnoKey(student)),
        )
        .toList(growable: false);

    return Column(
      children: [
        // Mensaje de advertencia si no es día de clase
        if (!_esDiaDeClase()) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.orange.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Este día no hay clase de este grupo según el horario',
                    style: TextStyle(
                      color: Colors.orange.shade300,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_isLoadingStudentBindingStatus) ...[
          LinearProgressIndicator(
            minHeight: 3,
            color: widget.gradientColors[0],
            backgroundColor: palette.border,
          ),
          const SizedBox(height: 12),
        ],
        if (_studentBindingStatusError != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.sync_problem_rounded, color: Colors.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No pudimos consultar qué alumnos están listos para la detección.',
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      unawaited(_refreshStudentBindingStatuses(force: true)),
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        // Botón de pasar lista con Bluetooth
        _buildStudentBeaconScanControls(),
        const SizedBox(height: 12),
        // Lista de alumnos
        Container(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.shadow,
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(
              children: [
                if (_puedeMarcarAsistenciaAlumnos()) ...[
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () async {
                        HapticFeedback.lightImpact();
                        setState(() {
                          for (final alumno in mainStudents) {
                            final key = _alumnoKey(alumno);
                            _asistencias[key] = !(_asistencias[key] ?? false);
                          }
                        });
                        await _guardarAsistencia();
                      },
                      splashColor: widget.gradientColors[0].withValues(
                        alpha: 0.15,
                      ),
                      highlightColor: widget.gradientColors[0].withValues(
                        alpha: 0.08,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              'Invertir',
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const SizedBox(width: 32),
                            // Mismo ancho que el AnimatedContainer del checkbox (8+28+8)
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: Center(
                                child: Icon(
                                  Icons.check_box_rounded,
                                  color: palette.textSecondary,
                                  size: 32,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Divider(height: 1, thickness: 1, color: palette.border),
                ],
                if (mainStudents.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Todos los alumnos disponibles fueron detectados automáticamente.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  )
                else
                  ...List.generate(
                    mainStudents.length,
                    (index) => _buildStudentCard(
                      mainStudents[index],
                      isLast: index == mainStudents.length - 1,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (automaticallyDetectedStudents.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildAutomaticallyDetectedStudents(
            automaticallyDetectedStudents,
            palette,
          ),
        ],
        // Espacio adicional al final para mejor visualización del último alumno
        const SizedBox(height: 100),
      ],
    );
  }

  Widget _buildAutomaticallyDetectedStudents(
    List<Alumno> students,
    UATPalette palette,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.gradientColors[0].withValues(alpha: 0.35),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: ExpansionTile(
            initiallyExpanded: false,
            maintainState: true,
            iconColor: widget.gradientColors[0],
            collapsedIconColor: palette.textSecondary,
            leading: Icon(
              Icons.bluetooth_connected_rounded,
              color: widget.gradientColors[0],
            ),
            title: Text(
              'Alumnos detectados automáticamente',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              '${students.length} confirmados automáticamente',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
            children: List.generate(
              students.length,
              (index) => _buildStudentCard(
                students[index],
                isLast: index == students.length - 1,
                automaticallyDetected: true,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStudentCard(
    Alumno alumno, {
    bool isLast = false,
    bool automaticallyDetected = false,
  }) {
    final puedeMarcar = _puedeMarcarAsistenciaAlumnos();
    final canToggle = puedeMarcar && !automaticallyDetected;
    final palette = context.uatPalette;
    final matricula = alumno.matricula?.trim().toUpperCase();
    final hasMatricula = matricula != null && matricula.isNotEmpty;
    final hasBinding =
        hasMatricula && _linkedStudentMatriculas.contains(matricula);

    return Container(
      key: ValueKey(
        '${automaticallyDetected ? 'automatic' : 'regular'}-student-${_alumnoKey(alumno)}',
      ),
      color: palette.surface,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canToggle
              ? () async {
                  HapticFeedback.mediumImpact();
                  setState(() {
                    final currentValue =
                        _asistencias[_alumnoKey(alumno)] ?? false;
                    _asistencias[_alumnoKey(alumno)] = !currentValue;
                  });
                  // Guardar en almacenamiento local
                  await _guardarAsistencia();
                }
              : null,
          splashColor: canToggle
              ? widget.gradientColors[0].withValues(alpha: 0.2)
              : Colors.transparent,
          highlightColor: canToggle
              ? widget.gradientColors[0].withValues(alpha: 0.1)
              : Colors.transparent,
          child: Column(
            children: [
              Opacity(
                opacity: puedeMarcar || hasBinding ? 1.0 : 0.5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 18,
                  ),
                  child: Row(
                    children: [
                      // Nombre del estudiante
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              alumno.name,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (automaticallyDetected) ...[
                              const SizedBox(height: 3),
                              Text(
                                'Detectado y confirmado automáticamente',
                                style: TextStyle(
                                  color: widget.gradientColors[0],
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            if (hasBinding) ...[
                              const SizedBox(height: 7),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle_outline_rounded,
                                    color: Colors.green.shade600,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    'Listo para detección',
                                    style: TextStyle(
                                      color: Colors.green.shade600,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Checkbox de asistencia con animación
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        decoration: BoxDecoration(
                          color: (_asistencias[_alumnoKey(alumno)] ?? false)
                              ? widget.gradientColors[0].withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: (_asistencias[_alumnoKey(alumno)] ?? false)
                                  ? widget.gradientColors[0]
                                  : Colors.transparent,
                              border: Border.all(
                                color:
                                    (_asistencias[_alumnoKey(alumno)] ?? false)
                                    ? widget.gradientColors[0]
                                    : palette.border,
                                width: 2.5,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: (_asistencias[_alumnoKey(alumno)] ?? false)
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 20,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Línea separadora alineada con el contenido (excepto para el último elemento)
              if (!isLast)
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16),
                  child: Container(height: 0.5, color: palette.border),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Esta función _verificarAsistenciaProfesor fue eliminada porque no se usa
}

// ══════════════════════════════════════════════════════════════════
// Resultado del diálogo BLE
// ══════════════════════════════════════════════════════════════════

class _BleDialogResult {
  final bool debeMarcarAsistencia;
  final bool verificada;
  final String? motivo;
  final String? beaconUuid;
  final String? classroom;
  final AltBeaconDetection? detection;

  const _BleDialogResult({
    required this.debeMarcarAsistencia,
    required this.verificada,
    this.motivo,
    this.beaconUuid,
    this.classroom,
    this.detection,
  });

  /// Beacon detectado — asistencia verificada
  factory _BleDialogResult.verified(ClassroomBeaconMatch match) =>
      _BleDialogResult(
        debeMarcarAsistencia: true,
        verificada: true,
        beaconUuid: match.reference.uuid,
        classroom: match.reference.classroom,
        detection: match.detection,
      );

  /// Beacon no detectado — entrada parcial con motivo
  factory _BleDialogResult.withMotivo(String motivo) => _BleDialogResult(
    debeMarcarAsistencia: true,
    verificada: false,
    motivo: motivo,
  );
}

enum _AlternateClassroomAction { accept, correct }

// ══════════════════════════════════════════════════════════════════
// Motivos predefinidos
// ══════════════════════════════════════════════════════════════════

const List<String> _motivosPredefinidos = [
  'Estoy en el salón pero no detecta el sensor',
  'No estoy en el salón pero sí asistí',
  'Estoy con mis alumnos en otro salón',
];

// ══════════════════════════════════════════════════════════════════
// Widget: BLE Beacon Scan Dialog
// ══════════════════════════════════════════════════════════════════

class _BleBeaconScanDialog extends StatefulWidget {
  final BleBeaconVerificationService bleService;
  final List<ClassroomBeaconReference> beacons;
  final String primaryClassroom;
  final List<Color> gradientColors;
  final bool permitirMotivo;

  const _BleBeaconScanDialog({
    required this.bleService,
    required this.beacons,
    required this.primaryClassroom,
    required this.gradientColors,
    required this.permitirMotivo,
  });

  @override
  State<_BleBeaconScanDialog> createState() => _BleBeaconScanDialogState();
}

class _BleBeaconScanDialogState extends State<_BleBeaconScanDialog>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  _ScanPhase _phase = _ScanPhase.scanning;
  String _statusText = 'Comprobando tu ubicación...';
  String? _lastDeviceFound;
  StreamSubscription<String>? _progressSub;

  // Para la fase de motivo
  final TextEditingController _otroMotivoController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _progressSub = widget.bleService.progressStream.listen((deviceName) {
      if (mounted) {
        setState(() => _lastDeviceFound = deviceName);
      }
    });

    _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _phase = _ScanPhase.scanning;
      _statusText = 'Comprobando tu ubicación...';
      _lastDeviceFound = null;
    });

    debugPrint(
      '[BLE-Dialog] Buscando ${widget.beacons.length} salones configurados',
    );
    final result = await widget.bleService.detectNearestClassroom(
      beacons: widget.beacons,
      primaryClassroom: widget.primaryClassroom,
    );
    debugPrint('[BLE-Dialog] Resultado: ${result.status}');
    if (!mounted) return;

    switch (result.status) {
      case BeaconVerificationResult.detected:
        final match = result.match;
        if (match == null) {
          setState(() {
            _phase = _ScanPhase.failed;
            _statusText = 'No pudimos comprobar tu ubicación';
          });
          _pulseController.stop();
          return;
        }
        setState(() {
          _phase = _ScanPhase.success;
          _statusText = 'Salón detectado: ${match.reference.classroom}';
        });
        _pulseController.stop();
        HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) {
          Navigator.of(context).pop(_BleDialogResult.verified(match));
        }
        break;

      case BeaconVerificationResult.timeout:
        setState(() {
          _phase = _ScanPhase.failed;
          _statusText = 'No pudimos confirmar tu ubicación';
        });
        _pulseController.stop();
        HapticFeedback.mediumImpact();
        break;

      case BeaconVerificationResult.bluetoothUnavailable:
        setState(() {
          _phase = _ScanPhase.failed;
          _statusText = 'Activa Bluetooth para continuar';
        });
        _pulseController.stop();
        break;

      case BeaconVerificationResult.error:
        setState(() {
          _phase = _ScanPhase.failed;
          _statusText = 'No pudimos comprobar tu ubicación';
        });
        _pulseController.stop();
        break;
    }
  }

  void _seleccionarMotivo(String motivo) {
    Navigator.of(context).pop(_BleDialogResult.withMotivo(motivo));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.bleService.cancelScan();
    _pulseController.dispose();
    _progressSub?.cancel();
    _otroMotivoController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      widget.bleService.cancelScan();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.uatPalette;

    return Dialog(
      backgroundColor: palette.surfaceElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(28.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIcon(),
              const SizedBox(height: 24),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              _buildContent(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Ícono central ──
  Widget _buildIcon() {
    switch (_phase) {
      case _ScanPhase.scanning:
        return ScaleTransition(
          scale: _pulseAnimation,
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: widget.gradientColors[0].withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.location_searching_rounded,
              color: widget.gradientColors[0],
              size: 44,
            ),
          ),
        );
      case _ScanPhase.success:
        return Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_circle_rounded,
            color: Colors.green,
            size: 50,
          ),
        );
      case _ScanPhase.failed:
        return Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.location_off_rounded,
            color: Colors.orange,
            size: 44,
          ),
        );
      case _ScanPhase.motivo:
        return Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: widget.gradientColors[0].withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.edit_note_rounded,
            color: widget.gradientColors[0],
            size: 44,
          ),
        );
    }
  }

  // ── Contenido por fase ──
  Widget _buildContent() {
    switch (_phase) {
      case _ScanPhase.scanning:
        return _buildScanningContent();
      case _ScanPhase.success:
        return const Text(
          'Presencia confirmada ✓',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.green, fontSize: 14),
        );
      case _ScanPhase.failed:
        return _buildFailedContent();
      case _ScanPhase.motivo:
        return _buildMotivoContent();
    }
  }

  Widget _buildScanningContent() {
    final palette = context.uatPalette;

    return Column(
      children: [
        Text(
          'Verificando tu ubicación en el salón...',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.textSecondary, fontSize: 14),
        ),
        if (_lastDeviceFound != null) ...[
          const SizedBox(height: 8),
          Text(
            'Se encontró una señal cercana',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.textTertiary, fontSize: 12),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(widget.gradientColors[0]),
          ),
        ),
        const SizedBox(height: 20),
        TextButton(
          onPressed: () {
            widget.bleService.cancelScan();
            Navigator.of(context).pop();
          },
          child: Text(
            'Cancelar',
            style: TextStyle(color: palette.textSecondary, fontSize: 16),
          ),
        ),
      ],
    );
  }

  Widget _buildFailedContent() {
    final palette = context.uatPalette;

    return Column(
      children: [
        Text(
          widget.permitirMotivo
              ? 'No pudimos verificar tu ubicación.\nPuedes reintentar o indicar un motivo.'
              : 'No pudimos verificar tu ubicación.\nPermanece dentro del salón e inténtalo de nuevo.',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.textSecondary, fontSize: 14),
        ),
        const SizedBox(height: 20),
        // Reintentar
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () {
              _pulseController.repeat(reverse: true);
              _startScan();
            },
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text(
              'Reintentar',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.gradientColors[0],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        if (widget.permitirMotivo) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _phase = _ScanPhase.motivo;
                  _statusText = 'Indica el motivo';
                });
              },
              icon: const Icon(Icons.edit_note_rounded, size: 20),
              label: const Text(
                'Marcar con motivo',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.textSecondary,
                side: BorderSide(color: palette.border),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancelar',
            style: TextStyle(color: palette.textTertiary, fontSize: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildMotivoContent() {
    final palette = context.uatPalette;

    return Column(
      children: [
        Text(
          'Selecciona el motivo por el cual\nno se detectó el sensor:',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.textSecondary, fontSize: 14),
        ),
        const SizedBox(height: 16),
        // Motivos predefinidos
        ..._motivosPredefinidos.map(
          (motivo) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _seleccionarMotivo(motivo),
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.textPrimary,
                  side: BorderSide(color: palette.border),
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  backgroundColor: palette.surfaceMuted,
                ),
                child: Text(
                  motivo,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
        // Campo "Otro"
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: palette.surfaceMuted,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _otroMotivoController,
                  style: TextStyle(color: palette.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Otro motivo...',
                    hintStyle: TextStyle(color: palette.textTertiary),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: () {
                  final texto = _otroMotivoController.text.trim();
                  if (texto.isNotEmpty) {
                    _seleccionarMotivo(texto);
                  }
                },
                icon: Icon(
                  Icons.send_rounded,
                  color: widget.gradientColors[0],
                  size: 22,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () {
            setState(() {
              _phase = _ScanPhase.failed;
              _statusText = 'No pudimos confirmar tu ubicación';
            });
          },
          child: Text(
            'Volver',
            style: TextStyle(color: palette.textTertiary, fontSize: 14),
          ),
        ),
      ],
    );
  }
}

enum _ScanPhase { scanning, success, failed, motivo }
