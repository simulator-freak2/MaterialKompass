import 'package:flutter/material.dart';

import '../services/system_message_service.dart';

class SystemMessageCard extends StatelessWidget {
  const SystemMessageCard({required this.message, super.key});

  final SystemMessage message;

  String _date(DateTime value) {
    final local = value.toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year}, '
        '${two(local.hour)}:${two(local.minute)} Uhr';
  }

  @override
  Widget build(BuildContext context) {
    final maintenancePeriod =
        message.isMaintenance &&
            message.startsAt != null &&
            message.endsAt != null
        ? 'Zeitraum: ${_date(message.startsAt!)} bis ${_date(message.endsAt!)}'
        : null;
    return Semantics(
      liveRegion: true,
      child: Card(
        color: message.isMaintenance
            ? Theme.of(context).colorScheme.tertiaryContainer
            : Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                message.isMaintenance
                    ? Icons.construction_outlined
                    : Icons.new_releases_outlined,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (maintenancePeriod != null) ...[
                      const SizedBox(height: 4),
                      Text(maintenancePeriod),
                    ],
                    const SizedBox(height: 8),
                    Text(message.message),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
