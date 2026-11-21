import 'package:flutter/material.dart';

/// Formats an ISO timestamp from the server in local time (dd.MM.yyyy HH:mm).
String formatBackupTimestamp(Object? value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (parsed == null) return '–';
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(parsed.day)}.${two(parsed.month)}.${parsed.year} '
      '${two(parsed.hour)}:${two(parsed.minute)}';
}

String backupStatusLabel(String? status) => switch (status) {
  'ok' => 'In Ordnung',
  'warning' => 'Hinweise',
  'error' => 'Fehler',
  _ => 'Noch nicht geprüft',
};

IconData backupStatusIcon(String? status) => switch (status) {
  'ok' => Icons.verified_outlined,
  'warning' => Icons.warning_amber_outlined,
  'error' => Icons.gpp_bad_outlined,
  _ => Icons.help_outline,
};

Color backupStatusColor(BuildContext context, String? status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'ok' => Colors.green.shade700,
    'warning' => Colors.orange.shade800,
    'error' => scheme.error,
    _ => scheme.onSurfaceVariant,
  };
}

/// Dashboard card of the central administration: weekly backup check result,
/// the unacknowledged weekly message and entry points for backup actions.
class BackupStatusCard extends StatelessWidget {
  final Map<String, dynamic> status;
  final VoidCallback? onManage;
  final Future<void> Function(String checkId)? onAcknowledge;
  final bool showItems;

  const BackupStatusCard({
    required this.status,
    this.onManage,
    this.onAcknowledge,
    this.showItems = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final latest = status['latestCheck'] is Map
        ? Map<String, dynamic>.from(status['latestCheck'] as Map)
        : null;
    final weekly = status['weeklyMessage'] is Map
        ? Map<String, dynamic>.from(status['weeklyMessage'] as Map)
        : null;
    final newest = status['newestBackup'] is Map
        ? Map<String, dynamic>.from(status['newestBackup'] as Map)
        : null;
    final configured = status['configured'] == true;
    final String? checkStatus = configured
        ? (latest == null ? null : latest['status']?.toString())
        : 'error';
    final color = backupStatusColor(context, checkStatus);
    final items = (latest?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
    final theme = Theme.of(context);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  backupStatusIcon(checkStatus),
                  color: color,
                  size: 32,
                  semanticLabel: 'Backup-Status',
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Backup-Status: ${backupStatusLabel(checkStatus)}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        !configured
                            ? (status['error']?.toString() ??
                                  'Serverseitige Plattformsicherungen sind nicht konfiguriert.')
                            : latest == null
                            ? 'Es liegt noch kein Prüfergebnis vor.'
                            : latest['summary']?.toString() ?? '',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                _Fact(
                  label: 'Letzte Prüfung',
                  value: formatBackupTimestamp(latest?['completedAt']),
                ),
                _Fact(
                  label: 'Nächste Wochenprüfung',
                  value: formatBackupTimestamp(status['nextScheduledCheckAt']),
                ),
                _Fact(
                  label: 'Neueste Plattformsicherung',
                  value: formatBackupTimestamp(newest?['createdAt']),
                ),
                _Fact(
                  label: 'Gespeicherte Sicherungen',
                  value: '${status['backupCount'] ?? 0}',
                ),
              ],
            ),
            if (weekly != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: backupStatusColor(
                    context,
                    weekly['status']?.toString(),
                  ).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Wöchentliche Statusmeldung vom '
                      '${formatBackupTimestamp(weekly['completedAt'])}',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    for (final item
                        in (weekly['items'] as List? ?? const [])
                            .whereType<Map>())
                      _CheckItem(item: Map<String, dynamic>.from(item)),
                    if (onAcknowledge != null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () =>
                              onAcknowledge!(weekly['id'].toString()),
                          icon: const Icon(Icons.done_all),
                          label: const Text('Zur Kenntnis genommen'),
                        ),
                      ),
                  ],
                ),
              ),
            ] else if (showItems && items.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final item in items) _CheckItem(item: item),
            ],
            if (onManage != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: onManage,
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('Sicherungen verwalten'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      Text(value, style: Theme.of(context).textTheme.bodyMedium),
    ],
  );
}

class _CheckItem extends StatelessWidget {
  final Map<String, dynamic> item;

  const _CheckItem({required this.item});

  @override
  Widget build(BuildContext context) {
    final status = item['status']?.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            backupStatusIcon(status),
            size: 18,
            color: backupStatusColor(context, status),
            semanticLabel: backupStatusLabel(status),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${item['label'] ?? ''}: ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: item['detail']?.toString() ?? ''),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
