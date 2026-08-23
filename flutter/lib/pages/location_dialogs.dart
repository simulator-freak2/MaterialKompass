import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/address_input.dart';

typedef StorageSubmit = Future<String?> Function(Map<String, dynamic> values);

class BuildingDialog extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? building;
  final StorageSubmit onSubmit;

  const BuildingDialog({
    required this.token,
    required this.onSubmit,
    this.building,
    super.key,
  });

  @override
  State<BuildingDialog> createState() => _BuildingDialogState();
}

class _BuildingDialogState extends State<BuildingDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = _controller('name');
  late final _code = _controller('code');
  late final _street = _controller('street');
  late final _houseNumber = _controller('houseNumber');
  late final _postalCode = _controller('postalCode');
  late final _city = _controller('city');
  late final _country = _controller('country', fallback: 'Deutschland');
  bool _saving = false;
  String? _error;

  TextEditingController _controller(String key, {String fallback = ''}) =>
      TextEditingController(
          text: widget.building?[key]?.toString() ?? fallback);

  @override
  void dispose() {
    for (final controller in [
      _name,
      _code,
      _street,
      _houseNumber,
      _postalCode,
      _city,
      _country,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Pflichtfeld' : null;

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) return;
    final addressValues = [_street, _houseNumber, _postalCode, _city, _country];
    if (addressValues.any((controller) => controller.text.trim().isEmpty)) {
      setState(
          () => _error = 'Bitte die Gebäudeadresse vollständig ausfüllen.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSubmit({
      'name': _name.text.trim(),
      'code': _code.text.trim().toUpperCase(),
      'street': _street.text.trim(),
      'houseNumber': _houseNumber.text.trim(),
      'postalCode': _postalCode.text.trim(),
      'city': _city.text.trim(),
      'country': _country.text.trim(),
    });
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
            widget.building == null ? 'Neues Gebäude' : 'Gebäude bearbeiten'),
        content: SizedBox(
          width: 720,
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: 440,
                        child: TextFormField(
                          controller: _name,
                          autofocus: true,
                          validator: _required,
                          decoration: const InputDecoration(
                            labelText: 'Name *',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 200,
                        child: TextFormField(
                          controller: _code,
                          validator: _required,
                          inputFormatters: [
                            _UpperCaseTextFormatter(),
                            FilteringTextInputFormatter.allow(
                                RegExp(r'[A-Z0-9_-]')),
                            LengthLimitingTextInputFormatter(32),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Kürzel / Nummer *',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text('Adresse',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  AddressInput(
                    token: widget.token,
                    streetController: _street,
                    houseNumberController: _houseNumber,
                    postalCodeController: _postalCode,
                    cityController: _city,
                    countryController: _country,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: const Text('Speichern'),
          ),
        ],
      );
}

class StorageNodeDialog extends StatefulWidget {
  final String title;
  final String parentLabel;
  final String parentIdKey;
  final List<Map<String, dynamic>> parents;
  final Map<String, dynamic>? node;
  final String initialParentId;
  final StorageSubmit onSubmit;

  const StorageNodeDialog({
    required this.title,
    required this.parentLabel,
    required this.parentIdKey,
    required this.parents,
    required this.initialParentId,
    required this.onSubmit,
    this.node,
    super.key,
  });

  @override
  State<StorageNodeDialog> createState() => _StorageNodeDialogState();
}

class _StorageNodeDialogState extends State<StorageNodeDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name =
      TextEditingController(text: widget.node?['name']?.toString() ?? '');
  late final _code = TextEditingController(
      text: widget.node?['code']?.toString() ??
          widget.node?['section']?.toString() ??
          '');
  late String _parentId = widget.initialParentId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Pflichtfeld' : null;

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSubmit({
      'name': _name.text.trim(),
      'code': _code.text.trim().toUpperCase(),
      widget.parentIdKey: _parentId,
    });
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 480,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _parentId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '${widget.parentLabel} *',
                    border: const OutlineInputBorder(),
                  ),
                  items: widget.parents
                      .map((parent) => DropdownMenuItem(
                            value: parent['id']?.toString(),
                            child: Text(
                              parent['path']?.toString() ??
                                  parent['name']?.toString() ??
                                  '',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _parentId = value ?? ''),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  validator: _required,
                  decoration: const InputDecoration(
                    labelText: 'Bezeichnung *',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _code,
                  validator: _required,
                  inputFormatters: [
                    _UpperCaseTextFormatter(),
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9_-]')),
                    LengthLimitingTextInputFormatter(32),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Kürzel / Nummer *',
                    helperText:
                        'Innerhalb des übergeordneten Elements eindeutig',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: const Text('Speichern'),
          ),
        ],
      );
}

class BulkStorageDialog extends StatefulWidget {
  final String buildingName;
  final String locationId;
  final StorageSubmit onSubmit;

  const BulkStorageDialog({
    required this.buildingName,
    required this.locationId,
    required this.onSubmit,
    super.key,
  });

  @override
  State<BulkStorageDialog> createState() => _BulkStorageDialogState();
}

class _BulkStorageDialogState extends State<BulkStorageDialog> {
  final _formKey = GlobalKey<FormState>();
  final _shelves = TextEditingController(text: '1');
  final _levels = TextEditingController(text: '3');
  final _positions = TextEditingController(text: '4');
  final _start = TextEditingController(text: '1');
  final _shelfPrefix = TextEditingController(text: 'R');
  final _levelPrefix = TextEditingController(text: 'E');
  final _positionPrefix = TextEditingController(text: 'P');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [
      _shelves,
      _levels,
      _positions,
      _start,
      _shelfPrefix,
      _levelPrefix,
      _positionPrefix,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  int _number(TextEditingController controller) =>
      int.tryParse(controller.text.trim()) ?? 0;

  String? _positive(String? value) {
    final number = int.tryParse(value?.trim() ?? '');
    return number == null || number < 1 ? 'Mindestens 1' : null;
  }

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) return;
    final total = _number(_shelves) * _number(_levels) * _number(_positions);
    if (total > 1000) {
      setState(() =>
          _error = 'Pro Vorgang sind höchstens 1.000 Lagerplätze erlaubt.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSubmit({
      'locationId': widget.locationId,
      'shelfCount': _number(_shelves),
      'levelsPerShelf': _number(_levels),
      'positionsPerLevel': _number(_positions),
      'startNumber': _number(_start),
      'shelfPrefix': _shelfPrefix.text.trim().toUpperCase(),
      'levelPrefix': _levelPrefix.text.trim().toUpperCase(),
      'positionPrefix': _positionPrefix.text.trim().toUpperCase(),
    });
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  Widget _numberField(TextEditingController controller, String label) =>
      SizedBox(
        width: 180,
        child: TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          validator: _positive,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Widget _prefixField(TextEditingController controller, String label) =>
      SizedBox(
        width: 180,
        child: TextFormField(
          controller: controller,
          validator: (value) =>
              value == null || value.trim().isEmpty ? 'Pflichtfeld' : null,
          inputFormatters: [
            _UpperCaseTextFormatter(),
            FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9_-]')),
            LengthLimitingTextInputFormatter(16),
          ],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final start = _number(_start).clamp(1, 999999);
    final position = start.toString().padLeft(2, '0');
    final preview = '${_shelfPrefix.text}$start / '
        '${_levelPrefix.text}$start / ${_positionPrefix.text}$position';
    final total = _number(_shelves) * _number(_levels) * _number(_positions);
    return AlertDialog(
      title: const Text('Lagerstruktur automatisch anlegen'),
      content: SizedBox(
        width: 620,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Gebäude: ${widget.buildingName}'),
                const SizedBox(height: 16),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  _numberField(_shelves, 'Regale'),
                  _numberField(_levels, 'Ebenen je Regal'),
                  _numberField(_positions, 'Plätze je Ebene'),
                  _numberField(_start, 'Startnummer'),
                ]),
                const SizedBox(height: 16),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  _prefixField(_shelfPrefix, 'Regalpräfix'),
                  _prefixField(_levelPrefix, 'Ebenenpräfix'),
                  _prefixField(_positionPrefix, 'Lagerplatzpräfix'),
                ]),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.preview_outlined),
                    title: Text('Vorschau: $preview'),
                    subtitle: Text('$total Lagerplätze werden erzeugt.'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Abbrechen'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome_outlined),
          label: const Text('Struktur anlegen'),
        ),
      ],
    );
  }
}

class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}
