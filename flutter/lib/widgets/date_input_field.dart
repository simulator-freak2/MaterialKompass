import 'package:flutter/material.dart';

String _twoDigits(int value) => value.toString().padLeft(2, '0');

DateTime? parseDateInput(String? value) {
  final input = value?.trim() ?? '';
  if (input.isEmpty) return null;

  final german = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(input);
  if (german != null) {
    final day = int.parse(german.group(1)!);
    final month = int.parse(german.group(2)!);
    final year = int.parse(german.group(3)!);
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  return DateTime.tryParse(input);
}

String formatDateForInput(Object? value) {
  final date = parseDateInput(value?.toString());
  if (date == null) return '';
  return '${_twoDigits(date.day)}.${_twoDigits(date.month)}.${date.year}';
}

String? dateInputToIso(String value) {
  if (value.trim().isEmpty) return null;
  final date = parseDateInput(value);
  if (date == null) return null;
  return '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)}';
}

class DateInputField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final double? width;
  final bool required;
  final DateTime? firstDate;
  final DateTime? lastDate;

  const DateInputField({
    required this.controller,
    required this.label,
    this.width,
    this.required = false,
    this.firstDate,
    this.lastDate,
    super.key,
  });

  Future<void> _selectDate(BuildContext context) async {
    final now = DateTime.now();
    final earliest = firstDate ?? DateTime(1900);
    final latest = lastDate ?? DateTime(now.year + 100, 12, 31);
    var initial = parseDateInput(controller.text) ?? now;
    if (initial.isBefore(earliest)) initial = earliest;
    if (initial.isAfter(latest)) initial = latest;

    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: earliest,
      lastDate: latest,
      locale: const Locale('de', 'DE'),
      helpText: label,
      cancelText: 'Abbrechen',
      confirmText: 'Übernehmen',
    );
    if (selected != null) controller.text = formatDateForInput(selected);
  }

  @override
  Widget build(BuildContext context) {
    final field = TextFormField(
      controller: controller,
      readOnly: true,
      onTap: () => _selectDate(context),
      decoration: InputDecoration(
        labelText: '$label (TT.MM.JJJJ)',
        hintText: 'TT.MM.JJJJ',
        border: const OutlineInputBorder(),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!required)
              IconButton(
                tooltip: 'Datum löschen',
                onPressed: controller.clear,
                icon: const Icon(Icons.clear),
              ),
            IconButton(
              tooltip: 'Datum auswählen',
              onPressed: () => _selectDate(context),
              icon: const Icon(Icons.calendar_today_outlined),
            ),
          ],
        ),
      ),
      validator: (value) {
        if (required && (value == null || value.trim().isEmpty)) {
          return 'Pflichtfeld';
        }
        if (value != null &&
            value.trim().isNotEmpty &&
            dateInputToIso(value) == null) {
          return 'Bitte TT.MM.JJJJ eingeben';
        }
        return null;
      },
    );
    return width == null ? field : SizedBox(width: width, child: field);
  }
}
