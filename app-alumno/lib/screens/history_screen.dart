import 'package:flutter/material.dart';

import '../models/attendance_history_entry.dart';
import '../services/local_storage_service.dart';
import '../theme/app_theme.dart';
import '../utils/subject_name.dart';
import '../widgets/app_page_header.dart';

class HistoryScreen extends StatefulWidget {
  final LocalStorageService storage;
  final bool embedded;

  const HistoryScreen({
    super.key,
    required this.storage,
    this.embedded = false,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  Future<void> _refresh() async => setState(() {});

  @override
  Widget build(BuildContext context) {
    final entries = widget.storage.attendanceHistory;
    final palette = AppPalette.of(context);
    final content = ColoredBox(
      color: palette.background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppPageHeader(
              eyebrow: 'Tu actividad',
              title: 'Historial',
              subtitle: entries.isEmpty
                  ? 'Tus asistencias aparecerán aquí'
                  : '${entries.length} ${entries.length == 1 ? 'asistencia registrada' : 'asistencias registradas'}',
            ),
            const SizedBox(height: 24),
            Expanded(
              child: RefreshIndicator(
                color: palette.accent,
                onRefresh: _refresh,
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: entries.isEmpty ? 1 : entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, index) => entries.isEmpty
                      ? const _EmptyHistory()
                      : _HistoryEntryCard(entry: entries[index]),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.background,
        foregroundColor: palette.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(child: content),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.successSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.history_rounded,
              color: palette.success,
              size: 24,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Aún no hay pases de lista',
            style: TextStyle(
              color: palette.ink,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Aquí verás tus asistencias confirmadas.',
            style: TextStyle(color: palette.muted, fontSize: 14, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _HistoryEntryCard extends StatelessWidget {
  final AttendanceHistoryEntry entry;

  const _HistoryEntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.successSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.check_rounded, color: palette.success, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subjectDisplayName(
                    entry.className,
                    fallback: 'Pase de lista confirmado',
                  ),
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Asistencia registrada',
                  style: TextStyle(
                    color: palette.success,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (groupDisplayName(entry.group) != null ||
                    entry.classroom != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (groupDisplayName(entry.group) != null)
                        'Grupo ${groupDisplayName(entry.group)}',
                      if (entry.classroom != null) 'Aula ${entry.classroom}',
                    ].join(' · '),
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  _formatDateTime(entry.recordedAt),
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

String _formatDateTime(DateTime value) {
  const months = [
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
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${value.day} de ${months[value.month - 1]} de ${value.year} · $hour:$minute';
}
