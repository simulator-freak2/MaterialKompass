import 'package:flutter/material.dart';

class MailCountBadge extends StatelessWidget {
  final int count;
  final String areaLabel;
  final Widget child;

  const MailCountBadge({
    required this.count,
    required this.areaLabel,
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;

    final visibleCount = count > 99 ? '99+' : '$count';
    final mailLabel = count == 1
        ? 'eine unbearbeitete E-Mail'
        : '$count unbearbeitete E-Mails';
    return Semantics(
      label: '$areaLabel, $mailLabel',
      container: true,
      child: Badge(
        backgroundColor: Theme.of(context).colorScheme.error,
        textColor: Theme.of(context).colorScheme.onError,
        label: Text(visibleCount),
        child: child,
      ),
    );
  }
}
