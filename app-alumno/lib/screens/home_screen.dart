import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/attendance_confirmation.dart';
import '../models/attendance_history_entry.dart';
import '../models/student_academic_profile.dart';
import '../models/student_schedule_entry.dart';
import '../services/attendance_session_service.dart';
import '../services/ble_advertiser_service.dart';
import '../services/local_storage_service.dart';
import '../services/student_auth_service.dart';
import '../services/student_device_binding_service.dart';
import '../theme/app_theme.dart';
import '../utils/subject_name.dart';
import '../widgets/app_page_header.dart';
import 'attendance_bottom_sheet.dart';
import 'history_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.storage,
    required this.bleService,
    required this.attendanceSession,
    required this.deviceBindingService,
    required this.profile,
    required this.initialUatSessionId,
    required this.demoMode,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onLogout,
    this.studentAuth,
  });

  final LocalStorageService storage;
  final BleAdvertiserService bleService;
  final AttendanceSessionService attendanceSession;
  final StudentDeviceBindingService deviceBindingService;
  final StudentAcademicProfile profile;
  final String? initialUatSessionId;
  final bool demoMode;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final Future<void> Function() onLogout;
  final StudentAuthService? studentAuth;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  AdvertiserState _advertiserState = AdvertiserState.idle;
  AttendanceSessionState _attendanceState = AttendanceSessionState.idle;
  StreamSubscription<AdvertiserState>? _advertiserSubscription;
  StreamSubscription<AttendanceConfirmation>? _confirmationSubscription;
  StreamSubscription<AttendanceSessionSnapshot>? _attendanceSubscription;
  Timer? _scheduleClock;
  int _selectedTab = 0;
  int _selectedClass = 0;
  bool _isSyncingDeviceBinding = false;
  bool _isSyncingAcademicInfo = false;
  bool _isManualSyncing = false;
  bool _isCheckingServer = false;
  List<StudentScheduleEntry> _schedule = const [];
  String? _academicSyncError;
  bool _passwordDialogOpen = false;
  bool _isLoggingOut = false;
  Completer<void>? _academicSyncCompletion;
  String? _pendingUatSessionId;
  String? _confirmationId;
  AttendanceConfirmation? _confirmation;
  DateTime? _lastSuccessfulSync;
  late StudentAcademicProfile _profile;
  late final StudentAuthService _studentAuth;

  bool get _isActive => _advertiserState == AdvertiserState.advertising;
  bool get _isChecking =>
      _attendanceState == AttendanceSessionState.checkingRoom;
  bool get _confirmed => _confirmationId != null;
  bool get _hasError =>
      _advertiserState == AdvertiserState.error ||
      _advertiserState == AdvertiserState.bluetoothOff ||
      _attendanceState == AttendanceSessionState.error ||
      _attendanceState == AttendanceSessionState.bluetoothOff ||
      _attendanceState == AttendanceSessionState.roomNotFound ||
      _attendanceState == AttendanceSessionState.missingRoomBeacon;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _profile = widget.profile;
    _studentAuth = widget.studentAuth ?? StudentAuthService();
    _schedule = widget.storage.studentSchedule;
    _selectedClass = _preferredClassIndex(_schedule, DateTime.now());
    _pendingUatSessionId = widget.initialUatSessionId;
    _advertiserState = widget.bleService.currentState;
    _attendanceState = widget.attendanceSession.currentState;
    _advertiserSubscription = widget.bleService.stateStream.listen((value) {
      if (mounted) {
        setState(() => _advertiserState = value);
      }
    });
    _attendanceSubscription = widget.attendanceSession.stateStream.listen((
      snapshot,
    ) {
      if (mounted) {
        setState(() => _attendanceState = snapshot.state);
      }
    });
    _confirmationSubscription = widget.bleService.confirmationStream.listen((
      confirmation,
    ) {
      if (!confirmation.isConfirmed ||
          !confirmation.belongsToMatricula(widget.storage.matricula)) {
        return;
      }
      if (!mounted) return;
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      setState(() {
        _confirmationId = id;
        _confirmation = confirmation;
      });
      unawaited(_saveAttendance(confirmation));
      unawaited(widget.attendanceSession.stop());
      Future<void>.delayed(const Duration(seconds: 5), () {
        if (mounted && _confirmationId == id) {
          setState(() {
            _confirmationId = null;
            _confirmation = null;
          });
        }
      });
    });
    _startScheduleClock();
    unawaited(_syncDeviceBinding());
    unawaited(_syncAcademicInfo());
  }

  void _startScheduleClock() {
    final now = DateTime.now();
    final millisecondsToNextMinute =
        const Duration(minutes: 1).inMilliseconds -
        (now.second * 1000 + now.millisecond);
    _scheduleClock = Timer(
      Duration(milliseconds: millisecondsToNextMinute),
      () {
        if (!mounted) return;
        if (_selectedTab == 0) setState(() {});
        _scheduleClock = Timer.periodic(const Duration(minutes: 1), (_) {
          if (mounted && _selectedTab == 0) setState(() {});
        });
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && (_isActive || _isChecking)) {
      unawaited(widget.attendanceSession.stop());
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncDeviceBinding());
      unawaited(_syncAcademicInfo());
    }
  }

  Future<void> _syncDeviceBinding() async {
    if (widget.demoMode ||
        widget.storage.isDemoMode ||
        _isSyncingDeviceBinding ||
        !widget.storage.isProfileSet) {
      return;
    }
    _isSyncingDeviceBinding = true;
    try {
      final synced = await widget.deviceBindingService.sync(widget.storage);
      await widget.storage.setDeviceBindingSyncPending(!synced);
    } finally {
      _isSyncingDeviceBinding = false;
    }
  }

  Future<void> _syncAcademicInfo() async {
    if (_isLoggingOut ||
        _isSyncingAcademicInfo ||
        !widget.storage.isProfileSet) {
      return;
    }
    _isSyncingAcademicInfo = true;
    final completion = Completer<void>();
    _academicSyncCompletion = completion;
    if (mounted) setState(() => _academicSyncError = null);
    var requestPassword = false;
    try {
      final sessionId = _pendingUatSessionId;
      _pendingUatSessionId = null;
      final result = await _studentAuth.syncAcademicInfo(
        widget.storage,
        sessionId: sessionId,
      );
      if (!mounted) return;
      setState(() {
        _schedule = result.schedule;
        _selectedClass = _preferredClassIndex(result.schedule, DateTime.now());
        _lastSuccessfulSync = result.syncedAt;
        if (result.profile != null) _profile = result.profile!;
      });
    } on StudentAuthException catch (error) {
      requestPassword = error.authenticationFailed;
      if (mounted) setState(() => _academicSyncError = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _academicSyncError =
              'No pudimos actualizar tu horario. Inténtalo de nuevo.',
        );
      }
    } finally {
      _isSyncingAcademicInfo = false;
      completion.complete();
      if (identical(_academicSyncCompletion, completion)) {
        _academicSyncCompletion = null;
      }
      if (mounted) setState(() {});
    }
    if (requestPassword && mounted && !_isLoggingOut) {
      unawaited(_requestUatPassword());
    }
  }

  Future<void> _requestUatPassword() async {
    if (_passwordDialogOpen || !mounted) return;
    _passwordDialogOpen = true;
    final passwordController = TextEditingController();
    String? dialogError;
    var loading = false;

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final password = passwordController.text;
              if (password.isEmpty || loading) return;
              setDialogState(() {
                loading = true;
                dialogError = null;
              });
              try {
                final email = widget.storage.institutionalEmail.isNotEmpty
                    ? widget.storage.institutionalEmail
                    : _profile.institutionalEmail;
                final result = await _studentAuth.loginAndBind(
                  username: email,
                  password: password,
                  storage: widget.storage,
                );
                await widget.storage.saveInstitutionalCredentials(
                  username: email,
                  password: password,
                );
                await widget.storage.saveDemoMode(result.demoMode);
                if (result.reviewAttendanceUuid != null) {
                  await widget.storage.saveAppReviewAttendanceUuid(
                    result.reviewAttendanceUuid!,
                  );
                }
                if (result.deviceBindingToken.isNotEmpty) {
                  await widget.storage.saveDeviceBindingToken(
                    result.deviceBindingToken,
                  );
                }
                await widget.storage.saveAcademicProfile(result.profile);
                _pendingUatSessionId = result.sessionId;
                _profile = result.profile;
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              } on StudentAuthException catch (error) {
                if (dialogContext.mounted) {
                  setDialogState(() {
                    loading = false;
                    dialogError = error.message;
                  });
                }
              }
            }

            return AlertDialog(
              title: const Text('Actualiza tu contraseña institucional'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.storage.institutionalEmail.isNotEmpty
                        ? widget.storage.institutionalEmail
                        : _profile.institutionalEmail,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    autofocus: true,
                    enabled: !loading,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      labelText: 'Contraseña',
                      errorText: dialogError,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: loading
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Ahora no'),
                ),
                FilledButton(
                  onPressed: loading ? null : submit,
                  child: loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continuar'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      passwordController.dispose();
      _passwordDialogOpen = false;
    }

    if (_pendingUatSessionId != null && mounted) {
      await _syncAcademicInfo();
    }
  }

  Future<void> _syncFromServer() async {
    if (_isManualSyncing || _isSyncingAcademicInfo) return;

    setState(() {
      _isManualSyncing = true;
      _isCheckingServer = true;
    });

    try {
      final online = await _studentAuth.isServerOnline();
      if (!mounted) return;
      setState(() => _isCheckingServer = false);

      if (!online) {
        _showSyncFeedback(
          'Sin conexión. Revisa tu internet e inténtalo de nuevo.',
          isError: true,
        );
        return;
      }

      await _syncAcademicInfo();
      if (!mounted) return;
      if (_academicSyncError != null) {
        _showSyncFeedback(_academicSyncError!, isError: true);
        return;
      }

      await _syncDeviceBinding();
      if (!mounted) return;
      _showSyncFeedback('Tu perfil y horario están actualizados.');
    } finally {
      if (mounted) {
        setState(() {
          _isManualSyncing = false;
          _isCheckingServer = false;
        });
      }
    }
  }

  void _showSyncFeedback(String message, {bool isError = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _saveAttendance(AttendanceConfirmation confirmation) async {
    final receivedAt = DateTime.now();
    await widget.storage.addAttendanceHistoryEntry(
      confirmation.recordedAtForHistory(receivedAt),
      classId: confirmation.classId,
      className: confirmation.className,
      group: confirmation.group,
      classroom: confirmation.classroom,
    );
    if (mounted) setState(() {});
  }

  Future<void> _openAttendanceSheet() async {
    HapticFeedback.mediumImpact();
    final todayItems = _dayItems(_schedule, DateTime.now().weekday);
    final safeSelectedClass = todayItems.isEmpty
        ? 0
        : (_selectedClass.clamp(0, todayItems.length - 1));
    final selectedItem = todayItems.isNotEmpty
        ? todayItems[safeSelectedClass]
        : null;
    if (selectedItem != null && _isFreeOccurrence(selectedItem)) return;

    await AttendanceBottomSheet.show(
      context,
      attendanceSession: widget.attendanceSession,
      bleService: widget.bleService,
      storage: widget.storage,
      currentOccurrence: selectedItem,
    );
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HistoryScreen(storage: widget.storage)),
    );
  }

  Future<void> _confirmLogout() async {
    if (_isLoggingOut || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.logout_rounded),
        title: const Text('¿Cerrar sesión?'),
        content: const Text(
          'Se eliminarán de este equipo tus datos de acceso, perfil, horario e historial.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isLoggingOut = true);
    try {
      await _academicSyncCompletion?.future;
      final pendingSessionId = _pendingUatSessionId;
      _pendingUatSessionId = null;
      if (pendingSessionId != null) {
        await _studentAuth.discardSession(pendingSessionId);
      }
      await widget.onLogout();
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoggingOut = false);
      _showSyncFeedback(
        'No pudimos cerrar la sesión. Inténtalo de nuevo.',
        isError: true,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _advertiserSubscription?.cancel();
    _confirmationSubscription?.cancel();
    _attendanceSubscription?.cancel();
    _scheduleClock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _AttendancePage(
        profile: _profile,
        selectedClass: _selectedClass,
        schedule: _schedule,
        scheduleLoading: _isSyncingAcademicInfo,
        isActive: _isActive,
        isChecking: _isChecking,
        confirmed: _confirmed,
        confirmedClassName: _confirmation?.materia ?? _confirmation?.className,
        hasError: _hasError,
        attendanceHistory: widget.storage.attendanceHistory,
        onSelectClass: (index) => setState(() => _selectedClass = index),
        onRegister: _openAttendanceSheet,
        onOpenProfile: () => setState(() => _selectedTab = 3),
        onOpenSchedule: () => setState(() => _selectedTab = 1),
        onOpenHistory: () => setState(() => _selectedTab = 2),
        onRefresh: _syncAcademicInfo,
        errorMessage: _academicSyncError,
      ),
      _SchedulePage(
        schedule: _schedule,
        attendanceHistory: widget.storage.attendanceHistory,
        loading: _isSyncingAcademicInfo,
        errorMessage: _academicSyncError,
        onRetry: _syncAcademicInfo,
      ),
      HistoryScreen(storage: widget.storage, embedded: true),
      _ProfilePage(
        profile: _profile,
        themeMode: widget.themeMode,
        onThemeModeChanged: widget.onThemeModeChanged,
        onOpenHistory: _openHistory,
        onSync: _syncFromServer,
        isSyncing: _isManualSyncing || _isSyncingAcademicInfo,
        isCheckingServer: _isCheckingServer,
        lastSyncedAt: _lastSuccessfulSync,
        onLogout: _confirmLogout,
        isLoggingOut: _isLoggingOut,
      ),
    ];
    return Scaffold(
      backgroundColor: AppPalette.of(context).background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (widget.demoMode)
              Container(
                width: double.infinity,
                color: AppPalette.of(context).warningSurface,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'MODO DE PRUEBA · Información de ejemplo',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppPalette.of(context).warning,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: IndexedStack(index: _selectedTab, children: pages),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: ColoredBox(
        color: AppPalette.of(context).background,
        child: SafeArea(
          top: false,
          child: _PresenciaBottomNav(
            selectedTab: _selectedTab,
            onSelect: (index) => setState(() => _selectedTab = index),
          ),
        ),
      ),
    );
  }
}

class _AttendancePage extends StatefulWidget {
  const _AttendancePage({
    required this.profile,
    required this.selectedClass,
    required this.schedule,
    required this.scheduleLoading,
    required this.isActive,
    required this.isChecking,
    required this.confirmed,
    required this.confirmedClassName,
    required this.hasError,
    required this.attendanceHistory,
    required this.onSelectClass,
    required this.onRegister,
    required this.onOpenProfile,
    required this.onOpenSchedule,
    required this.onOpenHistory,
    required this.onRefresh,
    required this.errorMessage,
  });
  final StudentAcademicProfile profile;
  final int selectedClass;
  final List<StudentScheduleEntry> schedule;
  final bool scheduleLoading;
  final bool isActive, isChecking, confirmed, hasError;
  final List<AttendanceHistoryEntry> attendanceHistory;
  final String? confirmedClassName, errorMessage;
  final ValueChanged<int> onSelectClass;
  final VoidCallback onRegister, onOpenProfile, onOpenSchedule, onOpenHistory;
  final Future<void> Function() onRefresh;

  @override
  State<_AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<_AttendancePage> {
  final _scrollController = ScrollController();
  final _currentSliverKey = GlobalKey();
  late int _anchorIndex;

  @override
  void initState() {
    super.initState();
    _anchorIndex = widget.selectedClass;
  }

  @override
  void didUpdateWidget(covariant _AttendancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.schedule, widget.schedule)) {
      _anchorIndex = widget.selectedClass;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _selectClass(int index) {
    unawaited(HapticFeedback.selectionClick());
    widget.onSelectClass(index);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final palette = AppPalette.of(context);
    final items = _dayItems(widget.schedule, now.weekday);
    final classes = items.where((item) => !_isFreeOccurrence(item)).toList();
    final selectedIndex = items.isEmpty
        ? 0
        : widget.selectedClass.clamp(0, items.length - 1);
    final selected = items.isEmpty ? null : items[selectedIndex];
    final isFree = selected != null && _isFreeOccurrence(selected);
    bool isRegistered(StudentScheduleOccurrence item) =>
        !_isFreeOccurrence(item) &&
        (widget.attendanceHistory.any(
              (entry) => _attendanceMatches(entry, item, now),
            ) ||
            (widget.confirmed &&
                subjectDisplayName(
                      widget.confirmedClassName,
                      fallback: '',
                    ).toLowerCase() ==
                    subjectDisplayName(item.entry.subject).toLowerCase()));
    final registered = selected != null && isRegistered(selected);
    final registeredCount = classes.where(isRegistered).length;
    final dayFinished =
        classes.isNotEmpty &&
        classes.every((item) => scheduleHasEnded(item, now)) &&
        registeredCount < classes.length;

    final textScaler = MediaQuery.textScalerOf(context);
    final buttonHeight = (textScaler.scale(14) * 1.5 + 28).clamp(
      54.0,
      double.infinity,
    );
    final actionClearance =
        buttonHeight +
        48 +
        (selected == null ? 0 : textScaler.scale(11) * 1.5 + 4);
    final anchorIndex = items.isEmpty
        ? 0
        : _anchorIndex.clamp(0, items.length - 1);
    Widget agendaRow(int index) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _AgendaRow(
        key: ValueKey('attendance-class-$index'),
        occurrence: items[index],
        registered: isRegistered(items[index]),
        selected: index == selectedIndex,
        now: now,
        onTap: () => _selectClass(index),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Column(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .44,
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _HomeHeader(
                            profile: widget.profile,
                            date: now,
                            onOpenProfile: widget.onOpenProfile,
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: _DaySummaryCard(
                                  value: '${classes.length}',
                                  label: 'Clases hoy',
                                  icon: Icons.calendar_today_outlined,
                                  color: palette.accent,
                                  surface: palette.accentSurface,
                                  onTap: widget.onOpenSchedule,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _DaySummaryCard(
                                  value:
                                      '$registeredCount de ${classes.length}',
                                  label: 'Asistencias hoy',
                                  icon: Icons.task_alt_rounded,
                                  color: palette.success,
                                  surface: palette.successSurface,
                                  onTap: widget.onOpenHistory,
                                ),
                              ),
                            ],
                          ),
                          if (widget.confirmed) ...[
                            const SizedBox(height: 12),
                            _AttendanceConfirmedBanner(
                              className: widget.confirmedClassName,
                            ),
                          ],
                          const SizedBox(height: 26),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Tu agenda',
                                  style: TextStyle(
                                    color: palette.ink,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -.5,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: widget.onOpenSchedule,
                                child: const Text('Ver semana →'),
                              ),
                            ],
                          ),
                          Text(
                            'Selecciona una clase para registrar tu asistencia.',
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, agendaConstraints) {
                        return RefreshIndicator(
                          onRefresh: widget.onRefresh,
                          color: palette.accent,
                          child: CustomScrollView(
                            key: const Key('attendance-class-list'),
                            controller: _scrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            center: _currentSliverKey,
                            // The previous card peeks into view without pushing the
                            // current class away from the top of the agenda.
                            anchor: items.isNotEmpty && anchorIndex > 0
                                ? (40 / agendaConstraints.maxHeight).clamp(
                                    0.0,
                                    1.0,
                                  )
                                : 0,
                            slivers: [
                              if (anchorIndex > 0)
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                  sliver: SliverList.builder(
                                    itemCount: anchorIndex,
                                    itemBuilder: (_, index) =>
                                        agendaRow(anchorIndex - index - 1),
                                  ),
                                ),
                              SliverPadding(
                                key: _currentSliverKey,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                sliver: SliverList.list(
                                  children: [
                                    if (widget.scheduleLoading &&
                                        widget.schedule.isEmpty)
                                      const _AcademicLoadingCard()
                                    else if (widget.errorMessage != null &&
                                        widget.schedule.isEmpty)
                                      _AcademicErrorCard(
                                        message: widget.errorMessage!,
                                        onRetry: widget.onRefresh,
                                      )
                                    else if (items.isEmpty)
                                      const _NoClassesTodayCard()
                                    else
                                      for (
                                        var index = anchorIndex;
                                        index < items.length;
                                        index++
                                      )
                                        agendaRow(index),
                                    if (dayFinished) const _DayFinishedBanner(),
                                    if (widget.errorMessage != null &&
                                        widget.schedule.isNotEmpty)
                                      _InlineSyncWarning(
                                        message: widget.errorMessage!,
                                        onRetry: widget.onRefresh,
                                      ),
                                    SizedBox(height: actionClearance + 24),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _AttendanceActionBar(
            occurrence: selected,
            registered: registered,
            isFree: isFree,
            busy: widget.isActive || widget.isChecking,
            hasError: widget.hasError,
            loading: widget.scheduleLoading && widget.schedule.isEmpty,
            onRegister: widget.onRegister,
          ),
        ),
      ],
    );
  }
}

class _AttendanceActionBar extends StatelessWidget {
  const _AttendanceActionBar({
    required this.occurrence,
    required this.registered,
    required this.isFree,
    required this.busy,
    required this.hasError,
    required this.loading,
    required this.onRegister,
  });

  final StudentScheduleOccurrence? occurrence;
  final bool registered, isFree, busy, hasError, loading;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = registered ? palette.success : palette.accent;
    final enabled = !registered && !isFree && !busy && !loading;
    final radius = BorderRadius.circular(20);
    final buttonTitle = registered
        ? 'Asistencia registrada'
        : isFree
        ? 'Hora libre'
        : busy
        ? 'Registro en curso'
        : hasError
        ? 'Intentar de nuevo'
        : 'Registrar asistencia';
    return Container(
      key: const Key('attendance-action-bar'),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.background.withValues(alpha: 0),
            palette.background.withValues(alpha: .25),
            palette.background.withValues(alpha: .85),
          ],
          stops: const [0, .35, 1],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .2 : .07),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: dark ? .16 : .7),
                        Colors.white.withValues(alpha: dark ? .06 : .3),
                        accent.withValues(alpha: enabled ? .13 : .06),
                      ],
                      stops: const [0, .52, 1],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: dark ? .3 : .8),
                    ),
                  ),
                  child: FilledButton.icon(
                    onPressed: enabled ? onRegister : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      backgroundColor: Colors.transparent,
                      foregroundColor: palette.ink,
                      disabledBackgroundColor: Colors.transparent,
                      disabledForegroundColor: registered
                          ? palette.success
                          : palette.muted,
                      surfaceTintColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: radius),
                    ),
                    icon: Icon(
                      registered
                          ? Icons.check_circle_outline_rounded
                          : Icons.check_rounded,
                      size: 22,
                    ),
                    label: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          buttonTitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        if (occurrence != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            isFree
                                ? 'Selecciona una clase'
                                : subjectDisplayName(occurrence!.entry.subject),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.ink.withValues(alpha: .8),
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DaySummaryCard extends StatelessWidget {
  const _DaySummaryCard({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
    required this.surface,
    required this.onTap,
  });
  final String value, label;
  final IconData icon;
  final Color color, surface;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: surface,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    style: TextStyle(
                      color: color,
                      fontSize: 23,
                      letterSpacing: -.6,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(icon, size: 19, color: color),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _AgendaRow extends StatelessWidget {
  const _AgendaRow({
    super.key,
    required this.occurrence,
    required this.registered,
    required this.selected,
    required this.now,
    required this.onTap,
  });
  final StudentScheduleOccurrence occurrence;
  final bool registered, selected;
  final DateTime now;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final free = _isFreeOccurrence(occurrence);
    final missed = !free && !registered && scheduleHasEnded(occurrence, now);
    final inProgress = !free && _isOccurrenceInProgress(occurrence, now);
    final color = registered
        ? palette.success
        : missed
        ? palette.warning
        : selected || inProgress
        ? palette.accent
        : palette.muted;
    return Semantics(
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: Padding(
                  padding: const EdgeInsets.only(top: 17),
                  child: Column(
                    children: [
                      Text(
                        occurrence.slot.startTime ?? '—',
                        style: TextStyle(
                          color: palette.ink,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        occurrence.slot.endTime ?? '',
                        style: TextStyle(color: palette.muted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  key: const Key('attendance-card-surface'),
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: registered
                        ? palette.successSurface
                        : missed
                        ? palette.warningSurface
                        : selected
                        ? palette.accentSurface
                        : palette.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: selected
                          ? color.withValues(alpha: .6)
                          : Colors.transparent,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              free
                                  ? 'Hora libre'
                                  : subjectDisplayName(
                                      occurrence.entry.subject,
                                    ),
                              style: TextStyle(
                                color: palette.ink,
                                fontSize: 14,
                                height: 1.35,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            free
                                ? Icons.coffee_outlined
                                : registered
                                ? Icons.check_circle_outline_rounded
                                : selected
                                ? Icons.radio_button_checked_rounded
                                : Icons.chevron_right_rounded,
                            color: color,
                            size: 18,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        free
                            ? 'Un respiro entre clases.'
                            : occurrence.entry.classroom ??
                                  'Aula por confirmar',
                        style: TextStyle(color: palette.muted, fontSize: 11),
                      ),
                      if (registered || missed || inProgress) ...[
                        const SizedBox(height: 7),
                        Text(
                          registered
                              ? 'Asistencia registrada'
                              : inProgress
                              ? 'En curso'
                              : 'Clase terminada · registro disponible',
                          style: TextStyle(
                            color: color,
                            fontSize: 10,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SchedulePage extends StatefulWidget {
  const _SchedulePage({
    required this.schedule,
    required this.attendanceHistory,
    required this.loading,
    required this.errorMessage,
    required this.onRetry,
  });

  final List<StudentScheduleEntry> schedule;
  final List<AttendanceHistoryEntry> attendanceHistory;
  final bool loading;
  final String? errorMessage;
  final Future<void> Function() onRetry;

  @override
  State<_SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<_SchedulePage> {
  int _weekday = DateTime.now().weekday;
  static const _days = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  late final ScrollController _dayScrollController;

  @override
  void initState() {
    super.initState();
    _dayScrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelectedDay());
  }

  @override
  void dispose() {
    _dayScrollController.dispose();
    super.dispose();
  }

  void _selectWeekday(int weekday) {
    if (_weekday == weekday) return;
    setState(() => _weekday = weekday);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelectedDay());
  }

  void _revealSelectedDay() {
    if (!mounted || !_dayScrollController.hasClients) return;
    final target =
        ((_weekday - 1) *
                (44 * MediaQuery.textScalerOf(context).scale(12) / 12 + 6))
            .clamp(0.0, _dayScrollController.position.maxScrollExtent);
    unawaited(
      _dayScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final palette = AppPalette.of(context);
    final weekStart = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - 1));
    final selectedDate = weekStart.add(Duration(days: _weekday - 1));
    final timelineItems = _dayItems(widget.schedule, _weekday);
    final classes = timelineItems
        .where((occurrence) => !_isFreeOccurrence(occurrence))
        .toList();
    final freeMinutes = _totalFreeMinutes(timelineItems, selectedDate);
    final countLabel =
        '${classes.length} ${classes.length == 1 ? 'clase' : 'clases'}';
    final freeLabel = freeMinutes >= 30
        ? ' · ${_freeDurationLabel(freeMinutes)} libre'
        : '';

    return ColoredBox(
      key: const Key('full-schedule-background'),
      color: palette.background,
      child: RefreshIndicator(
        color: palette.accent,
        onRefresh: widget.onRetry,
        child: ListView(
          key: const Key('full-schedule-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            AppPageHeader(
              eyebrow: 'Organiza tu semana',
              title: 'Mi horario',
              subtitle: 'Consulta tus clases y tiempos libres',
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_monthName(selectedDate.month)} ${selectedDate.year}',
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'SEMANA ${_isoWeekNumber(selectedDate)}',
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              key: const Key('full-schedule-day-selector'),
              height: 32 + MediaQuery.textScalerOf(context).scale(32),
              child: ListView.separated(
                controller: _dayScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: _days.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, index) {
                  final date = weekStart.add(Duration(days: index));
                  return _ScheduleDayPill(
                    day: _days[index],
                    date: date.day,
                    selected: _weekday == index + 1,
                    today: _isSameCalendarDay(date, now),
                    onTap: () => _selectWeekday(index + 1),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            Container(height: 1, color: palette.border),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _scheduleDayHeading(selectedDate),
                    key: const Key('full-schedule-section-title'),
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 20,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (classes.isNotEmpty)
                  Text(
                    _scheduleRange(classes).replaceAll(' – ', '–'),
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$countLabel$freeLabel',
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.loading && widget.schedule.isEmpty)
              const _AcademicLoadingCard()
            else if (widget.errorMessage != null && widget.schedule.isEmpty)
              _AcademicErrorCard(
                message: widget.errorMessage!,
                onRetry: widget.onRetry,
              )
            else if (timelineItems.isEmpty)
              const _EmptySchedule()
            else
              ..._buildScheduleTimeline(
                context,
                timelineItems,
                selectedDate,
                now,
                widget.attendanceHistory,
              ),
            if (widget.errorMessage != null && widget.schedule.isNotEmpty) ...[
              const SizedBox(height: 14),
              _InlineSyncWarning(
                message: widget.errorMessage!,
                onRetry: widget.onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScheduleDayPill extends StatelessWidget {
  const _ScheduleDayPill({
    required this.day,
    required this.date,
    required this.selected,
    required this.today,
    required this.onTap,
  });

  final String day;
  final int date;
  final bool selected;
  final bool today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Semantics(
      selected: selected,
      button: true,
      label: '$day $date${today ? ', hoy' : ''}',
      child: Material(
        color: selected ? palette.accent : palette.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 44 * MediaQuery.textScalerOf(context).scale(12) / 12,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: today && !selected
                  ? Border.all(color: palette.accent, width: 1.25)
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  day,
                  style: TextStyle(
                    color: selected
                        ? Theme.of(context).colorScheme.onPrimary
                        : palette.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$date',
                  style: TextStyle(
                    color: selected
                        ? Theme.of(context).colorScheme.onPrimary
                        : palette.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfilePage extends StatelessWidget {
  const _ProfilePage({
    required this.profile,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onOpenHistory,
    required this.onSync,
    required this.isSyncing,
    required this.isCheckingServer,
    required this.lastSyncedAt,
    required this.onLogout,
    required this.isLoggingOut,
  });
  final StudentAcademicProfile profile;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final VoidCallback onOpenHistory;
  final VoidCallback onSync;
  final bool isSyncing;
  final bool isCheckingServer;
  final DateTime? lastSyncedAt;
  final VoidCallback onLogout;
  final bool isLoggingOut;
  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final orange = palette.accent;
    final accent = palette.accent;
    final initials = profile.displayName.trim().isEmpty
        ? 'FI'
        : profile.displayName
              .trim()
              .split(RegExp(r'\s+'))
              .take(2)
              .map((part) => part.substring(0, 1))
              .join()
              .toUpperCase();
    return ColoredBox(
      key: const Key('profile-page-background'),
      color: palette.background,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppPageHeader(
              eyebrow: 'Tu cuenta',
              title: 'Perfil',
              subtitle: 'Tu información estudiantil',
            ),
            const SizedBox(height: 24),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          key: const Key('profile-avatar'),
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            initials,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 22,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile.displayName,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                profile.programName ??
                                    'Programa académico no disponible',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Matrícula ${profile.matricula}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: onOpenHistory,
                        style: TextButton.styleFrom(foregroundColor: accent),
                        icon: const Icon(Icons.history_rounded),
                        label: const Text('Ver historial'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Información académica',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _ProfileField(
                      'CORREO',
                      profile.institutionalEmail.isEmpty
                          ? 'No disponible'
                          : profile.institutionalEmail,
                    ),
                    const Divider(height: 32),
                    _ProfileField(
                      'PROGRAMA',
                      profile.programName ?? 'No disponible',
                    ),
                    const Divider(height: 32),
                    _ProfileField(
                      'CICLO',
                      profile.cycleName ?? 'No disponible',
                    ),
                    const Divider(height: 32),
                    _ProfileField(
                      'PROMEDIO Y CRÉDITOS',
                      _academicSummary(profile),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Card(
              child: ListTile(
                enabled: !isSyncing,
                onTap: isSyncing ? null : onSync,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.cloud_sync_outlined, color: accent),
                ),
                title: const Text('Actualizar información'),
                subtitle: Text(
                  isCheckingServer
                      ? 'Comprobando conexión…'
                      : isSyncing
                      ? 'Actualizando perfil y horario…'
                      : _lastSyncLabel(lastSyncedAt),
                ),
                trailing: isSyncing
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ),
            const SizedBox(height: 18),
            Card(
              child: SwitchListTile.adaptive(
                secondary: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: orange.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.dark_mode_outlined, color: orange),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 4,
                ),
                title: const Text('Tema oscuro'),
                subtitle: const Text('Usar la apariencia oscura'),
                value:
                    themeMode == ThemeMode.dark ||
                    (themeMode == ThemeMode.system &&
                        MediaQuery.platformBrightnessOf(context) ==
                            Brightness.dark),
                onChanged: (enabled) => onThemeModeChanged(
                  enabled ? ThemeMode.dark : ThemeMode.light,
                ),
                activeTrackColor: accent,
              ),
            ),
            const SizedBox(height: 18),
            Card(
              child: ListTile(
                enabled: !isLoggingOut,
                onTap: isLoggingOut ? null : onLogout,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                leading: Icon(
                  Icons.logout_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Cerrar sesión',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                subtitle: const Text(
                  'Salir de esta cuenta en este dispositivo',
                ),
                trailing: isLoggingOut
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.chevron_right_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.profile,
    required this.date,
    required this.onOpenProfile,
  });
  final StudentAcademicProfile profile;
  final DateTime date;
  final VoidCallback onOpenProfile;
  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final name = profile.displayName.trim();
    final firstName = name.isEmpty
        ? 'estudiante'
        : name.split(RegExp(r'\s+')).first;
    return AppPageHeader(
      eyebrow: 'Tu día en el campus',
      title: 'Hola, $firstName.',
      subtitle: _formattedHomeDate(date),
      trailing: Tooltip(
        message: 'Abrir perfil',
        child: Material(
          color: palette.surface,
          shape: CircleBorder(side: BorderSide(color: palette.border)),
          child: InkWell(
            onTap: onOpenProfile,
            customBorder: const CircleBorder(),
            child: SizedBox.square(
              dimension: 44,
              child: Center(
                child: Text(
                  _profileInitials(profile),
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PresenciaBottomNav extends StatelessWidget {
  const _PresenciaBottomNav({
    required this.selectedTab,
    required this.onSelect,
  });
  final int selectedTab;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    const tabs = [
      ('Inicio', Icons.grid_view_rounded),
      ('Horario', Icons.calendar_month_outlined),
      ('Historial', Icons.fact_check_outlined),
      ('Perfil', Icons.person_outline_rounded),
    ];
    return Container(
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          for (var index = 0; index < tabs.length; index++)
            Expanded(
              child: Semantics(
                selected: index == selectedTab,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => onSelect(index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 15,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: index == selectedTab
                                  ? palette.accentSurface
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              tabs[index].$2,
                              size: 21,
                              color: index == selectedTab
                                  ? palette.accent
                                  : palette.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tabs[index].$1,
                            style: TextStyle(
                              color: index == selectedTab
                                  ? palette.ink
                                  : palette.muted,
                              fontSize: 10,
                              fontWeight: index == selectedTab
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttendanceConfirmedBanner extends StatelessWidget {
  const _AttendanceConfirmedBanner({this.className});

  final String? className;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: AppPalette.of(context).successSurface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: AppPalette.of(context).success.withValues(alpha: .28),
      ),
    ),
    child: Row(
      children: [
        Icon(
          Icons.verified_rounded,
          color: AppPalette.of(context).success,
          size: 21,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Asistencia confirmada · ${subjectDisplayName(className, fallback: 'Clase registrada')}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _DayFinishedBanner extends StatelessWidget {
  const _DayFinishedBanner();

  @override
  Widget build(BuildContext context) {
    final orange = AppPalette.of(context).warning;
    return Container(
      key: const Key('day-finished-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: orange.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: orange.withValues(alpha: .28)),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, color: orange, size: 20),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              'Jornada terminada · El registro sigue disponible',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

enum _FullScheduleState { registered, inProgress, ended, upcoming, scheduled }

List<Widget> _buildScheduleTimeline(
  BuildContext context,
  List<StudentScheduleOccurrence> timelineItems,
  DateTime selectedDate,
  DateTime now,
  List<AttendanceHistoryEntry> history,
) {
  final palette = AppPalette.of(context);
  final items = <Widget>[];
  for (var index = 0; index < timelineItems.length; index++) {
    final occurrence = timelineItems[index];
    if (_isFreeOccurrence(occurrence)) {
      items.add(
        _FreeTimeCard(
          start: occurrence.slot.startTime,
          end: occurrence.slot.endTime,
        ),
      );
    } else {
      final start = occurrence.slot.startTime ?? '—';
      final registered = history.any(
        (entry) => _attendanceMatches(entry, occurrence, selectedDate),
      );
      final missed =
          !registered && _occurrenceHasPassed(occurrence, selectedDate, now);
      final statusColor = registered
          ? palette.success
          : missed
          ? palette.warning
          : palette.muted;
      items.add(
        Row(
          key: ValueKey('full-schedule-row-$index'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              height: 128,
              child: Column(
                children: [
                  Text(
                    start,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: Container(width: 1, color: palette.border)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _FullScheduleCard(
                key: ValueKey('full-schedule-card-$index'),
                occurrence: occurrence,
                selectedDate: selectedDate,
                now: now,
                registered: registered,
              ),
            ),
          ],
        ),
      );
    }
    if (index < timelineItems.length - 1) {
      items.add(const SizedBox(height: 12));
    }
  }
  final classes = timelineItems
      .where((occurrence) => !_isFreeOccurrence(occurrence))
      .toList();
  if (classes.isNotEmpty && classes.last.slot.endTime != null) {
    items.add(const SizedBox(height: 12));
    items.add(
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tu última clase termina a las ${classes.last.slot.endTime}',
              style: TextStyle(
                color: palette.ink,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Después, el campus es tuyo.',
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
  return items;
}

class _FreeTimeCard extends StatelessWidget {
  const _FreeTimeCard({required this.start, required this.end});

  final String? start;
  final String? end;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final range = start != null && end != null
        ? '$start–$end · Hora libre'
        : 'Hora libre';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.freeSurface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.spa_outlined, size: 20, color: palette.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  range,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Un respiro entre clases.',
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FullScheduleCard extends StatelessWidget {
  const _FullScheduleCard({
    super.key,
    required this.occurrence,
    required this.selectedDate,
    required this.now,
    required this.registered,
  });

  final StudentScheduleOccurrence occurrence;
  final DateTime selectedDate;
  final DateTime now;
  final bool registered;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final start = _scheduleTimeForDate(occurrence.slot.startTime, selectedDate);
    final end = _scheduleTimeForDate(occurrence.slot.endTime, selectedDate);
    final selectedDay = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    );
    final today = DateTime(now.year, now.month, now.day);
    late final _FullScheduleState state;
    if (registered) {
      state = _FullScheduleState.registered;
    } else if (selectedDay.isBefore(today) ||
        (selectedDay == today && end != null && !now.isBefore(end))) {
      state = _FullScheduleState.ended;
    } else if (selectedDay == today &&
        start != null &&
        end != null &&
        !now.isBefore(start) &&
        now.isBefore(end)) {
      state = _FullScheduleState.inProgress;
    } else if (selectedDay.isAfter(today) ||
        (selectedDay == today && start != null && start.isAfter(now))) {
      state = _FullScheduleState.upcoming;
    } else {
      state = _FullScheduleState.scheduled;
    }
    final missed = state == _FullScheduleState.ended;
    final status = switch (state) {
      _FullScheduleState.registered => 'REGISTRADA',
      _FullScheduleState.ended => 'SIN REGISTRO',
      _FullScheduleState.inProgress => 'EN CURSO',
      _FullScheduleState.upcoming => 'PRÓXIMA',
      _FullScheduleState.scheduled => 'PROGRAMADA',
    };
    final statusColor = registered
        ? palette.success
        : missed
        ? palette.warning
        : palette.muted;
    final detail = switch (state) {
      _FullScheduleState.registered => 'Asistencia registrada',
      _FullScheduleState.inProgress => 'Asistencia pendiente',
      _FullScheduleState.ended => 'Clase terminada · registro disponible',
      _FullScheduleState.upcoming =>
        selectedDay == today &&
                start != null &&
                start.difference(now).inMinutes < 60
            ? 'Comienza en ${start.difference(now).inMinutes + 1} min'
            : 'Próxima clase',
      _FullScheduleState.scheduled => 'Clase programada',
    };
    final time =
        occurrence.slot.startTime != null && occurrence.slot.endTime != null
        ? '${occurrence.slot.startTime}–${occurrence.slot.endTime}'
        : occurrence.slot.displayTime;

    return Container(
      constraints: const BoxConstraints(minHeight: 140),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: registered
            ? palette.successSurface
            : missed
            ? palette.warningSurface
            : palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: registered || missed
              ? statusColor.withValues(alpha: .55)
              : palette.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 9,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                time,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: registered || missed ? statusColor : palette.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                status,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Text(
            subjectDisplayName(occurrence.entry.subject),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.ink,
              fontSize: 14,
              height: 1.43,
              fontWeight: FontWeight.w600,
            ),
          ),
          Row(
            children: [
              Icon(Icons.location_on_outlined, size: 16, color: palette.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  occurrence.entry.classroom ?? 'Aula por confirmar',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: statusColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _AcademicLoadingCard extends StatelessWidget {
  const _AcademicLoadingCard();

  @override
  Widget build(BuildContext context) => const Card(
    child: SizedBox(
      height: 154,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Actualizando horario…'),
          ],
        ),
      ),
    ),
  );
}

class _NoClassesTodayCard extends StatelessWidget {
  const _NoClassesTodayCard();

  @override
  Widget build(BuildContext context) => Card(
    child: SizedBox(
      height: 154,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_available_rounded, color: appMuted(context)),
              const SizedBox(height: 10),
              const Text(
                'No tienes clases programadas para hoy',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AcademicErrorCard extends StatelessWidget {
  const _AcademicErrorCard({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 38),
      child: Column(
        children: [
          Icon(Icons.cloud_off_rounded, size: 36, color: appMuted(context)),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Volver a intentar'),
          ),
        ],
      ),
    ),
  );
}

class _InlineSyncWarning extends StatelessWidget {
  const _InlineSyncWarning({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    borderRadius: BorderRadius.circular(16),
    child: ListTile(
      leading: const Icon(Icons.sync_problem_rounded),
      title: const Text('Mostrando el último horario disponible'),
      subtitle: Text(message),
      trailing: IconButton(
        tooltip: 'Reintentar actualización',
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
      ),
    ),
  );
}

int _isoWeekNumber(DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  final thursday = day.add(Duration(days: DateTime.thursday - day.weekday));
  final firstDayOfIsoYear = DateTime(thursday.year, 1, 1);
  return 1 + thursday.difference(firstDayOfIsoYear).inDays ~/ 7;
}

bool _isFreeOccurrence(StudentScheduleOccurrence occurrence) =>
    subjectDisplayName(occurrence.entry.subject).trim().toLowerCase() ==
    'libre';

bool _isOccurrenceInProgress(
  StudentScheduleOccurrence occurrence,
  DateTime now,
) {
  final start = _scheduleTimeForToday(occurrence.slot.startTime, now);
  final end = _scheduleTimeForToday(occurrence.slot.endTime, now);
  return start != null &&
      end != null &&
      !now.isBefore(start) &&
      now.isBefore(end);
}

List<StudentScheduleOccurrence> _dayItems(
  List<StudentScheduleEntry> schedule,
  int weekday,
) {
  final occurrences = scheduleForWeekday(schedule, weekday);
  // El horario puede traer horas libres explícitas. En ese caso conservamos
  // sus intervalos y evitamos crear tarjetas duplicadas entre clases.
  if (occurrences.any(_isFreeOccurrence)) return occurrences;
  final classes = occurrences;
  final items = <StudentScheduleOccurrence>[];
  for (var index = 0; index < classes.length; index++) {
    items.add(classes[index]);
    if (index == classes.length - 1) continue;
    final end = classes[index].slot.endTime;
    final start = classes[index + 1].slot.startTime;
    final date = DateTime(2024, 1, 1);
    if (end == null ||
        start == null ||
        _freeGapMinutes(classes[index], classes[index + 1], date) < 30) {
      continue;
    }
    items.add(
      StudentScheduleOccurrence(
        entry: StudentScheduleEntry(
          externalGroupId: '',
          subject: 'Libre',
          slots: const [],
        ),
        slot: StudentScheduleSlot(
          weekday: weekday,
          raw: '$end - $start',
          startTime: end,
          endTime: start,
        ),
      ),
    );
  }
  return items;
}

int _preferredClassIndex(List<StudentScheduleEntry> schedule, DateTime now) {
  final items = _dayItems(schedule, now.weekday);
  if (items.isEmpty) return 0;
  for (var index = 0; index < items.length; index++) {
    if (_isOccurrenceInProgress(items[index], now)) return index;
  }
  for (var index = 0; index < items.length; index++) {
    if (_isFreeOccurrence(items[index])) continue;
    final start = _scheduleTimeForToday(items[index].slot.startTime, now);
    if (start != null && start.isAfter(now)) return index;
  }
  if (items.any((occurrence) => occurrence.slot.startTime == null)) {
    return 0;
  }
  final lastClass = items.lastIndexWhere(
    (occurrence) => !_isFreeOccurrence(occurrence),
  );
  return lastClass < 0 ? 0 : lastClass;
}

int _freeGapMinutes(
  StudentScheduleOccurrence left,
  StudentScheduleOccurrence right,
  DateTime date,
) {
  final end = _scheduleTimeForDate(left.slot.endTime, date);
  final start = _scheduleTimeForDate(right.slot.startTime, date);
  if (end == null || start == null) return 0;
  return start.difference(end).inMinutes.clamp(0, 1440);
}

int _totalFreeMinutes(List<StudentScheduleOccurrence> items, DateTime date) {
  var total = 0;
  for (final item in items.where(_isFreeOccurrence)) {
    final start = _scheduleTimeForDate(item.slot.startTime, date);
    final end = _scheduleTimeForDate(item.slot.endTime, date);
    if (start != null && end != null && end.isAfter(start)) {
      total += end.difference(start).inMinutes;
    }
  }
  return total;
}

String _freeDurationLabel(int minutes) {
  final hours = minutes ~/ 60;
  final remaining = minutes % 60;
  if (hours == 0) return '$minutes min';
  final label = '$hours ${hours == 1 ? 'hora' : 'horas'}';
  return remaining == 0 ? label : '$label $remaining min';
}

String _monthName(int month) {
  const months = [
    'Enero',
    'Febrero',
    'Marzo',
    'Abril',
    'Mayo',
    'Junio',
    'Julio',
    'Agosto',
    'Septiembre',
    'Octubre',
    'Noviembre',
    'Diciembre',
  ];
  return months[month.clamp(1, 12) - 1];
}

String _scheduleDayHeading(DateTime date) {
  const days = [
    'Lunes',
    'Martes',
    'Miércoles',
    'Jueves',
    'Viernes',
    'Sábado',
    'Domingo',
  ];
  return '${days[date.weekday - 1]} ${date.day}';
}

String _scheduleRange(List<StudentScheduleOccurrence> classes) {
  final starts =
      classes
          .map((occurrence) => occurrence.slot.startTime)
          .whereType<String>()
          .toList()
        ..sort();
  final ends =
      classes
          .map((occurrence) => occurrence.slot.endTime)
          .whereType<String>()
          .toList()
        ..sort();
  if (starts.isEmpty || ends.isEmpty) return 'Horario por confirmar';
  return '${starts.first} – ${ends.last}';
}

bool _attendanceMatches(
  AttendanceHistoryEntry history,
  StudentScheduleOccurrence occurrence,
  DateTime selectedDate,
) {
  if (!_isSameCalendarDay(history.recordedAt.toLocal(), selectedDate)) {
    return false;
  }

  final historyClassId = history.classId?.trim().toLowerCase();
  final scheduleClassId = occurrence.entry.externalGroupId.trim().toLowerCase();
  if (historyClassId?.isNotEmpty == true && scheduleClassId.isNotEmpty) {
    return historyClassId == scheduleClassId;
  }

  final historyClassName = subjectDisplayName(
    history.className,
    fallback: '',
  ).toLowerCase();
  return historyClassName.isNotEmpty &&
      historyClassName ==
          subjectDisplayName(
            occurrence.entry.subject,
            fallback: '',
          ).toLowerCase();
}

bool _isSameCalendarDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

bool _occurrenceHasPassed(
  StudentScheduleOccurrence occurrence,
  DateTime selectedDate,
  DateTime now,
) {
  final day = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
  final today = DateTime(now.year, now.month, now.day);
  if (day.isBefore(today)) return true;
  if (day.isAfter(today)) return false;
  final end = _scheduleTimeForDate(occurrence.slot.endTime, selectedDate);
  return end != null && !now.isBefore(end);
}

String _formattedHomeDate(DateTime date) {
  const weekdays = [
    'Lunes',
    'Martes',
    'Miércoles',
    'Jueves',
    'Viernes',
    'Sábado',
    'Domingo',
  ];
  return '${weekdays[date.weekday - 1]} ${date.day} · ${_monthName(date.month)}';
}

DateTime? _scheduleTimeForToday(String? value, DateTime now) {
  return _scheduleTimeForDate(value, now);
}

DateTime? _scheduleTimeForDate(String? value, DateTime date) {
  if (value == null) return null;
  final parts = value.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return DateTime(date.year, date.month, date.day, hour, minute);
}

String _profileInitials(StudentAcademicProfile profile) {
  final name = profile.displayName.trim();
  if (name.isEmpty) return 'FI';
  return name
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .take(2)
      .map((part) => part.substring(0, 1))
      .join()
      .toUpperCase();
}

String _academicSummary(StudentAcademicProfile profile) {
  final details = <String>[];
  if (profile.average != null) details.add('Promedio ${profile.average}');
  if (profile.approvedCredits != null) {
    details.add('${profile.approvedCredits} créditos aprobados');
  }
  return details.isEmpty ? 'No disponible' : details.join(' · ');
}

String _lastSyncLabel(DateTime? syncedAt) {
  if (syncedAt == null) {
    return 'Comprueba la conexión y actualiza tu perfil y horario';
  }

  final local = syncedAt.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return 'Última actualización: $hour:$minute';
}

class _EmptySchedule extends StatelessWidget {
  const _EmptySchedule();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 80),
    child: Center(
      child: Column(
        children: [
          Icon(
            Icons.event_available_rounded,
            size: 38,
            color: appMuted(context),
          ),
          const SizedBox(height: 12),
          const Text(
            'No tienes clases programadas para este día',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _ProfileField extends StatelessWidget {
  const _ProfileField(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      const SizedBox(height: 5),
      Text(
        value,
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ],
  );
}
