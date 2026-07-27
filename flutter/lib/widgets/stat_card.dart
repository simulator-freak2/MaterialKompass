import 'package:flutter/material.dart';

class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final double width;
  final bool compact;
  final IconData? icon;
  final bool attention;

  const StatCard({
    required this.title,
    required this.value,
    this.width = 160,
    this.compact = false,
    this.icon,
    this.attention = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = attention ? colors.error : colors.primary;
    return Card(
      margin: EdgeInsets.zero,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: compact ? 19 : 22, color: accent),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: compact ? 13 : 15),
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 4 : 8),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 24 : 28,
                  fontWeight: FontWeight.bold,
                  color: attention ? colors.error : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
