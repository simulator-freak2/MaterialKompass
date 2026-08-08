import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scan_support.dart';

class StoragePositionPicker extends StatefulWidget {
  final List<Map<String, dynamic>> positions;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool required;
  final double width;

  const StoragePositionPicker({
    required this.positions,
    required this.value,
    required this.onChanged,
    this.required = true,
    this.width = 470,
    super.key,
  });

  @override
  State<StoragePositionPicker> createState() => _StoragePositionPickerState();
}

class _StoragePositionPickerState extends State<StoragePositionPicker> {
  late final TextEditingController controller;
  String? error;

  Map<String, dynamic>? get selected =>
      widget.positions.cast<Map<String, dynamic>?>().firstWhere(
            (entry) => entry?['id']?.toString() == widget.value,
            orElse: () => null,
          );

  String label(Map<String, dynamic> entry) =>
      '${entry['fullCode'] ?? ''} · ${entry['path'] ?? entry['name'] ?? ''}'
          .trim();

  @override
  void initState() {
    super.initState();
    controller = TextEditingController();
    _sync();
  }

  @override
  void didUpdateWidget(covariant StoragePositionPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value ||
        oldWidget.positions != widget.positions) {
      _sync();
    }
  }

  void _sync() {
    final entry = selected;
    final value = entry == null ? '' : label(entry);
    if (controller.text != value) controller.text = value;
  }

  void _select(Map<String, dynamic> entry) {
    setState(() {
      controller.text = label(entry);
      error = null;
    });
    widget.onChanged(entry['id']?.toString());
  }

  void _match(String raw) {
    final query = raw.trim().toLowerCase();
    final matches = widget.positions
        .where((entry) =>
            entry['fullCode']?.toString().toLowerCase() == query ||
            entry['id']?.toString().toLowerCase() == query)
        .toList();
    if (matches.length == 1) {
      _select(matches.single);
    } else {
      setState(() => error = 'Kein eindeutiger Lagercode gefunden.');
    }
  }

  Future<void> _scan() async {
    if (!isCameraScanningSupported) {
      setState(() => error = 'Am PC bitte einen USB-Handscanner verwenden.');
      return;
    }
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lagercode scannen'),
        content: SizedBox(
          width: 420,
          height: 360,
          child: MobileScanner(onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (value != null && context.mounted) Navigator.pop(context, value);
          }),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'))
        ],
      ),
    );
    if (code != null) _match(code);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.width,
        child: Autocomplete<Map<String, dynamic>>(
          displayStringForOption: label,
          optionsBuilder: (value) {
            final query = value.text.trim().toLowerCase();
            if (query.isEmpty) return widget.positions;
            return widget.positions
                .where((entry) => label(entry).toLowerCase().contains(query));
          },
          onSelected: _select,
          fieldViewBuilder: (context, _, focusNode, onSubmitted) =>
              TextFormField(
            controller: controller,
            focusNode: focusNode,
            decoration: InputDecoration(
              labelText: widget.required
                  ? 'Lagerplatz / Lagercode *'
                  : 'Lagerplatz / Lagercode',
              hintText: 'Code scannen oder Lagercode suchen',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                  onPressed: _scan,
                  tooltip: 'Lagercode scannen',
                  icon: const Icon(Icons.qr_code_scanner)),
              errorText: error,
            ),
            onFieldSubmitted: (value) {
              _match(value);
              onSubmitted();
            },
            validator: (_) =>
                widget.required && widget.value == null ? 'Pflichtfeld' : null,
          ),
        ),
      );
}
