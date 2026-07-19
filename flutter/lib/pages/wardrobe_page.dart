import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../constants.dart';
import '../widgets/date_input_field.dart';
import 'login_page.dart';

class WardrobePage extends StatefulWidget {
  final String token;
  final VoidCallback? onLogout;

  const WardrobePage({required this.token, this.onLogout, super.key});

  @override
  State<WardrobePage> createState() => _WardrobePageState();
}

class _WardrobePageState extends State<WardrobePage> {
  late Future<List<Map<String, dynamic>>> _clothingFuture;
  late Future<List<Map<String, dynamic>>> _transactionsFuture;
  late Future<List<Map<String, dynamic>>> _historyFuture;
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _selectableCategories = [];
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _stocks = [];
  final TextEditingController nameController = TextEditingController();
  final TextEditingController sizeController = TextEditingController();
  final TextEditingController locationController =
      TextEditingController(text: 'loc-2');
  final TextEditingController stockController = TextEditingController();
  final TextEditingController statusController =
      TextEditingController(text: 'Lagernd');
  final TextEditingController assignedPersonController =
      TextEditingController();
  final TextEditingController transactionPersonController =
      TextEditingController();
  final TextEditingController inventoryNumberController =
      TextEditingController();
  String _filterMode = 'alle';
  String _categoryFilterId = 'alle';
  String _searchQuery = '';
  String? _editingClothingId;
  String? _selectedCategoryId;
  final Set<String> _selectedClothingIds = {};
  List<Map<String, dynamic>> _currentClothing = [];
  bool _isTransferringTable = false;

  @override
  void initState() {
    super.initState();
    _clothingFuture = _fetchClothing();
    _transactionsFuture = _fetchTransactions();
    _historyFuture = _fetchHistory();
    _fetchCategories();
    _fetchStorageLocations();
  }

  @override
  void dispose() {
    nameController.dispose();
    sizeController.dispose();
    locationController.dispose();
    stockController.dispose();
    statusController.dispose();
    assignedPersonController.dispose();
    transactionPersonController.dispose();
    inventoryNumberController.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _fetchClothing() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/clothing'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode != 200) {
        return [];
      }

      final data = jsonDecode(response.body);
      if (data is List) {
        final clothing =
            data.map((item) => Map<String, dynamic>.from(item as Map)).toList();
        _currentClothing = clothing;
        return clothing;
      }
      _currentClothing = [];
      return [];
    } catch (_) {
      _currentClothing = [];
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchTransactions() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/transactions'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode != 200) {
        return [];
      }

      final data = jsonDecode(response.body);
      if (data is List) {
        return data
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<void> _fetchCategories() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/categories'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body);
      if (data is! List || !mounted) return;
      setState(() {
        _categories =
            data.map((item) => Map<String, dynamic>.from(item as Map)).toList();
        final wardrobeMainIds = _categories
            .where((category) =>
                (category['parentId'] == null ||
                    category['parentId'].toString().isEmpty) &&
                category['useInWardrobe'] == true)
            .map((category) => category['id']?.toString())
            .whereType<String>()
            .toSet();
        _selectableCategories = _categories
            .where((category) =>
                wardrobeMainIds.contains(category['id']?.toString()) ||
                wardrobeMainIds.contains(category['parentId']?.toString()))
            .toList();
        if (_selectedCategoryId != null &&
            !_selectableCategories
                .any((category) => category['id'] == _selectedCategoryId)) {
          _selectedCategoryId = null;
        }
        if (_categoryFilterId != 'alle' &&
            !_selectableCategories
                .any((category) => category['id'] == _categoryFilterId)) {
          _categoryFilterId = 'alle';
        }
      });
    } catch (_) {
      // Die Anwendung bleibt auch bei vorübergehend fehlenden Kategorien nutzbar.
    }
  }

  Future<void> _fetchStorageLocations() async {
    try {
      final responses = await Future.wait([
        http.get(Uri.parse('$apiBaseUrl/api/locations'),
            headers: {'Authorization': 'Bearer ${widget.token}'}),
        http.get(Uri.parse('$apiBaseUrl/api/stock-structures'),
            headers: {'Authorization': 'Bearer ${widget.token}'}),
      ]);
      if (responses.any((response) => response.statusCode != 200) || !mounted)
        return;
      setState(() {
        _locations = (jsonDecode(responses[0].body) as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        _stocks = (jsonDecode(responses[1].body) as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
      });
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _fetchHistory() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/clothing/history'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode != 200) {
        return [];
      }

      final data = jsonDecode(response.body);
      if (data is List) {
        return data
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<void> _importClothingTable() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'ods'],
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Die ausgewählte Datei konnte nicht gelesen werden.')),
      );
      return;
    }

    setState(() => _isTransferringTable = true);
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/clothing/import'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'fileName': file.name,
          'fileBase64': base64Encode(bytes),
        }),
      );
      if (!mounted) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw Exception(data['error']?.toString() ?? 'Import fehlgeschlagen');
      }

      final imported = data['imported'] as int? ?? 0;
      final skipped = data['skipped'] as int? ?? 0;
      final skippedRows = (data['skippedRows'] as List? ?? const [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();
      setState(() {
        _selectedClothingIds.clear();
        _clothingFuture = _fetchClothing();
        _historyFuture = _fetchHistory();
      });

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Import abgeschlossen'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$imported Kleidungsstücke importiert.'),
                if (skipped > 0) ...[
                  const SizedBox(height: 8),
                  Text('$skipped Zeilen wurden übersprungen:'),
                  const SizedBox(height: 4),
                  ...skippedRows.take(8).map(
                        (entry) => Text(
                          'Zeile ${entry['row']}: ${entry['reason']}',
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                      ),
                  if (skippedRows.length > 8)
                    Text('… und ${skippedRows.length - 8} weitere.'),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Schließen'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) setState(() => _isTransferringTable = false);
    }
  }

  Future<void> _exportClothingTable(String format) async {
    setState(() => _isTransferringTable = true);
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/clothing/export?format=$format'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      Map<String, dynamic> data;
      try {
        data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      } catch (_) {
        throw Exception(
            'Der Exportdienst ist noch nicht verfügbar. Bitte den Server neu starten.');
      }
      if (response.statusCode != 200) {
        throw Exception(data['error']?.toString() ??
            'Export fehlgeschlagen (${response.statusCode})');
      }

      final fileName = data['fileName']?.toString() ?? 'kleiderkammer.$format';
      final nameWithoutExtension = fileName.endsWith('.$format')
          ? fileName.substring(0, fileName.length - format.length - 1)
          : fileName;
      await FileSaver.instance.saveFile(
        name: nameWithoutExtension,
        bytes: base64Decode(data['fileBase64'] as String),
        fileExtension: format,
        mimeType: MimeType.custom,
        customMimeType: format == 'ods'
            ? 'application/vnd.oasis.opendocument.spreadsheet'
            : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$fileName wurde exportiert.')),
      );
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _isTransferringTable = false);
    }
  }

  void _resetForm() {
    nameController.clear();
    sizeController.clear();
    inventoryNumberController.clear();
    locationController.text = 'loc-2';
    stockController.clear();
    statusController.text = 'Lagernd';
    assignedPersonController.clear();
    _editingClothingId = null;
    _selectedCategoryId = null;
  }

  Future<void> _saveClothing({BuildContext? dialogContext}) async {
    final name = nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte einen Kleidungsnamen angeben')),
      );
      return;
    }
    final allowedSizes = _sizesForCategory(_selectedCategoryId);
    if (allowedSizes.isNotEmpty &&
        !allowedSizes.contains(sizeController.text.trim())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Bitte eine vordefinierte Größe auswählen')),
      );
      return;
    }

    final payload = {
      'name': name,
      'categoryId': _selectedCategoryId,
      'inventoryNumber': inventoryNumberController.text.trim().isEmpty
          ? null
          : inventoryNumberController.text.trim(),
      'size': sizeController.text.trim(),
      'locationId': locationController.text.trim().isEmpty
          ? 'loc-2'
          : locationController.text.trim(),
      'stockStructureId': stockController.text.trim().isEmpty
          ? null
          : stockController.text.trim(),
      'status': statusController.text.trim().isEmpty
          ? 'Lagernd'
          : statusController.text.trim(),
      'assignedPerson': assignedPersonController.text.trim().isEmpty
          ? null
          : assignedPersonController.text.trim(),
    };

    final isEditing = _editingClothingId != null;
    final response = !isEditing
        ? await http.post(
            Uri.parse('$apiBaseUrl/api/clothing'),
            headers: {
              'Authorization': 'Bearer ${widget.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
        : await http.put(
            Uri.parse('$apiBaseUrl/api/clothing/$_editingClothingId'),
            headers: {
              'Authorization': 'Bearer ${widget.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          );

    if (!mounted) return;

    if (response.statusCode == 201 || response.statusCode == 200) {
      _resetForm();
      setState(() {
        _clothingFuture = _fetchClothing();
        _historyFuture = _fetchHistory();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEditing ? 'Kleidungsstück bearbeitet' : 'Kleidungsstück angelegt',
          ),
        ),
      );
      if (dialogContext != null) {
        Navigator.of(dialogContext).pop();
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEditing ? 'Bearbeiten fehlgeschlagen' : 'Anlegen fehlgeschlagen',
          ),
        ),
      );
    }
  }

  List<String> _sizesForCategory(String? categoryId) {
    Map<String, dynamic>? category;
    for (final entry in _categories) {
      if (entry['id']?.toString() == categoryId) category = entry;
    }
    if (category == null) return const [];
    final ownSizes = (category['sizes'] as List? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList();
    if (ownSizes.isNotEmpty) return ownSizes;
    final parentId = category['parentId']?.toString();
    for (final entry in _categories) {
      if (entry['id']?.toString() == parentId) {
        return (entry['sizes'] as List? ?? const [])
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList();
      }
    }
    return const [];
  }

  Widget _buildCategoryField(VoidCallback refreshDialog) {
    return DropdownButtonFormField<String?>(
      initialValue: _selectableCategories
              .any((category) => category['id'] == _selectedCategoryId)
          ? _selectedCategoryId
          : null,
      decoration: const InputDecoration(labelText: 'Kategorie'),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('Ohne Kategorie'),
        ),
        ..._selectableCategories.map(
          (category) => DropdownMenuItem<String?>(
            value: category['id']?.toString(),
            child: Text(_categoryPath(category)),
          ),
        ),
      ],
      onChanged: (value) {
        _selectedCategoryId = value;
        final sizes = _sizesForCategory(value);
        if (sizes.isNotEmpty && !sizes.contains(sizeController.text)) {
          sizeController.clear();
        }
        refreshDialog();
      },
    );
  }

  Widget _buildSizeField() {
    final sizes = _sizesForCategory(_selectedCategoryId);
    if (sizes.isEmpty) {
      return TextField(
        controller: sizeController,
        decoration: const InputDecoration(labelText: 'Größe'),
      );
    }
    final selectedSize =
        sizes.contains(sizeController.text) ? sizeController.text : null;
    return DropdownButtonFormField<String>(
      key: ValueKey('size-$_selectedCategoryId-$selectedSize'),
      initialValue: selectedSize,
      decoration: const InputDecoration(labelText: 'Größe *'),
      hint: const Text('Vordefinierte Größe auswählen'),
      items: sizes
          .map((size) => DropdownMenuItem(value: size, child: Text(size)))
          .toList(),
      onChanged: (value) => sizeController.text = value ?? '',
    );
  }

  String _categoryName(Object? categoryId) {
    if (categoryId == null) return 'Ohne Kategorie';
    for (final category in _categories) {
      if (category['id']?.toString() == categoryId.toString()) {
        return _categoryPath(category);
      }
    }
    return 'Ohne Kategorie';
  }

  String _storageLabel(Map<String, dynamic> item) {
    final locationId = item['locationId']?.toString();
    final stockId = item['stockStructureId']?.toString();
    final location = _locations.cast<Map<String, dynamic>?>().firstWhere(
          (entry) => entry?['id']?.toString() == locationId,
          orElse: () => null,
        );
    final stock = _stocks.cast<Map<String, dynamic>?>().firstWhere(
          (entry) => entry?['id']?.toString() == stockId,
          orElse: () => null,
        );
    final locationName = location?['name']?.toString() ?? locationId ?? '-';
    if (stock == null) return locationName;
    return '$locationName · ${stock['name']} (${stock['section']})';
  }

  String _categoryPath(Map<String, dynamic> category) {
    final name = category['name']?.toString() ?? 'Unbenannt';
    final parentId = category['parentId']?.toString();
    if (parentId == null || parentId.isEmpty) return name;
    final parent = _categories.cast<Map<String, dynamic>?>().firstWhere(
          (entry) => entry?['id']?.toString() == parentId,
          orElse: () => null,
        );
    final parentName = parent?['name']?.toString();
    return parentName == null ? name : '$parentName › $name';
  }

  List<Widget> _buildStorageFields(VoidCallback refreshDialog) {
    final locationIds =
        _locations.map((entry) => entry['id'].toString()).toSet();
    final selectedLocation = locationIds.contains(locationController.text)
        ? locationController.text
        : (_locations.isEmpty ? null : _locations.first['id'].toString());
    if (selectedLocation != null &&
        locationController.text != selectedLocation) {
      locationController.text = selectedLocation;
    }
    final availableStocks = _stocks
        .where((entry) => entry['locationId']?.toString() == selectedLocation)
        .toList();
    final stockIds =
        availableStocks.map((entry) => entry['id'].toString()).toSet();
    final selectedStock =
        stockIds.contains(stockController.text) ? stockController.text : null;
    if (selectedStock == null && stockController.text.isNotEmpty)
      stockController.clear();
    return [
      DropdownButtonFormField<String>(
        initialValue: selectedLocation,
        decoration: const InputDecoration(labelText: 'Lagerort *'),
        items: _locations
            .map((entry) => DropdownMenuItem(
                  value: entry['id'].toString(),
                  child: Text('${entry['name']} (${entry['code']})'),
                ))
            .toList(),
        onChanged: _locations.isEmpty
            ? null
            : (value) {
                locationController.text = value ?? '';
                stockController.clear();
                refreshDialog();
              },
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: selectedStock,
        decoration: const InputDecoration(labelText: 'Regal / Fach'),
        items: [
          const DropdownMenuItem<String>(
              value: null, child: Text('Kein Regal/Fach')),
          ...availableStocks.map((entry) => DropdownMenuItem(
                value: entry['id'].toString(),
                child: Text('${entry['name']} · ${entry['section']}'),
              )),
        ],
        onChanged: (value) => stockController.text = value ?? '',
      ),
    ];
  }

  Future<void> _openCreateDialog() async {
    _resetForm();
    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Neue Kleidung anlegen'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Bezeichnung'),
                  ),
                  const SizedBox(height: 12),
                  _buildCategoryField(() => setDialogState(() {})),
                  const SizedBox(height: 12),
                  TextField(
                    controller: inventoryNumberController,
                    decoration:
                        const InputDecoration(labelText: 'Inventarnummer'),
                  ),
                  const SizedBox(height: 12),
                  _buildSizeField(),
                  const SizedBox(height: 12),
                  ..._buildStorageFields(() => setDialogState(() {})),
                  const SizedBox(height: 12),
                  TextField(
                    controller: statusController,
                    decoration: const InputDecoration(labelText: 'Status'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: assignedPersonController,
                    decoration:
                        const InputDecoration(labelText: 'Zugewiesene Person'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => _saveClothing(dialogContext: context),
                child: const Text('Speichern'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openEditDialog(Map<String, dynamic> item) async {
    _editingClothingId = item['id']?.toString();
    _selectedCategoryId = item['categoryId']?.toString();
    nameController.text = item['name']?.toString() ?? '';
    sizeController.text = item['size']?.toString() ?? '';
    inventoryNumberController.text = item['inventoryNumber']?.toString() ?? '';
    locationController.text = item['locationId']?.toString() ?? 'loc-2';
    stockController.text = item['stockStructureId']?.toString() ?? '';
    statusController.text = item['status']?.toString() ?? 'Lagernd';
    assignedPersonController.text = item['assignedPerson']?.toString() ?? '';

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Kleidung bearbeiten'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Bezeichnung'),
                  ),
                  const SizedBox(height: 12),
                  _buildCategoryField(() => setDialogState(() {})),
                  const SizedBox(height: 12),
                  TextField(
                    controller: inventoryNumberController,
                    decoration:
                        const InputDecoration(labelText: 'Inventarnummer'),
                  ),
                  const SizedBox(height: 12),
                  _buildSizeField(),
                  const SizedBox(height: 12),
                  ..._buildStorageFields(() => setDialogState(() {})),
                  const SizedBox(height: 12),
                  TextField(
                    controller: statusController,
                    decoration: const InputDecoration(labelText: 'Status'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: assignedPersonController,
                    decoration:
                        const InputDecoration(labelText: 'Zugewiesene Person'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => _saveClothing(dialogContext: context),
                child: const Text('Speichern'),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatDate(Object? value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return '-';
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }

  bool _requiresPsageInspection(Map<String, dynamic> item) {
    final categoryId = item['categoryId']?.toString();
    return _categories.any((category) =>
        category['id']?.toString() == categoryId &&
        category['requiresPsageInspection'] == true);
  }

  Future<void> _openInspectionDialog(Map<String, dynamic> item) async {
    final dateController = TextEditingController(
      text: formatDateForInput(DateTime.now()),
    );
    final notesController = TextEditingController();
    String result = 'Bestanden';
    final inspections = (item['inspections'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Prüfung · ${item['name'] ?? 'Kleidung'}'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_requiresPsageInspection(item))
                    const Card(
                      color: Color(0xFFFFF3CD),
                      child: ListTile(
                        leading: Icon(Icons.verified_user),
                        title: Text('PSAgE-Sachkunde erforderlich'),
                        subtitle: Text(
                            'Diese Prüfung kann nur mit der Rolle „Sachkundiger PSAgE“ gespeichert werden.'),
                      ),
                    ),
                  DateInputField(
                    controller: dateController,
                    label: 'Prüfdatum',
                    required: true,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: result,
                    decoration: const InputDecoration(labelText: 'Ergebnis'),
                    items: const [
                      DropdownMenuItem(
                          value: 'Bestanden', child: Text('Bestanden')),
                      DropdownMenuItem(value: 'Mangel', child: Text('Mangel')),
                      DropdownMenuItem(
                          value: 'Nicht bestanden',
                          child: Text('Nicht bestanden')),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => result = value ?? 'Bestanden'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Bemerkungen'),
                  ),
                  if (inspections.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text('Bisherige Prüfungen',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    ...inspections.take(5).map(
                          (inspection) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(
                                '${_formatDate(inspection['inspectionDate'])} · ${inspection['result']}'),
                            subtitle: Text(
                                '${inspection['inspector'] ?? '-'}${inspection['nextInspectionDate'] == null ? '' : ' · nächste Prüfung ${_formatDate(inspection['nextInspectionDate'])}'}'),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () async {
                final response = await http.post(
                  Uri.parse(
                      '$apiBaseUrl/api/clothing/${item['id']}/inspections'),
                  headers: {
                    'Authorization': 'Bearer ${widget.token}',
                    'Content-Type': 'application/json',
                  },
                  body: jsonEncode({
                    'inspectionDate': dateInputToIso(dateController.text),
                    'result': result,
                    'notes': notesController.text.trim(),
                  }),
                );
                if (!dialogContext.mounted) return;
                if (response.statusCode == 201) {
                  Navigator.pop(dialogContext, true);
                  return;
                }
                var message = 'Prüfung konnte nicht gespeichert werden.';
                try {
                  message =
                      jsonDecode(response.body)['error']?.toString() ?? message;
                } catch (_) {}
                ScaffoldMessenger.of(dialogContext)
                    .showSnackBar(SnackBar(content: Text(message)));
              },
              child: const Text('Prüfung speichern'),
            ),
          ],
        ),
      ),
    );
    dateController.dispose();
    notesController.dispose();
    if (saved == true && mounted) {
      setState(() => _clothingFuture = _fetchClothing());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prüfung wurde gespeichert.')),
      );
    }
  }

  Future<bool> _submitTransaction(
      List<String> clothingIds, String action) async {
    final isReturn = action == 'zurückgegeben';
    final personName =
        isReturn ? 'nicht Ausgegeben' : transactionPersonController.text.trim();
    if (!isReturn && personName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte eine Person angeben')),
      );
      return false;
    }

    if (clothingIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte Kleidung auswählen')),
      );
      return false;
    }

    late final http.Response response;
    try {
      response = await http.post(
        Uri.parse('$apiBaseUrl/api/transactions'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'clothingIds': clothingIds,
          'personName': personName,
          'action': action,
        }),
      );
    } catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Verbindung zum Server fehlgeschlagen: $error')),
      );
      return false;
    }

    if (!mounted) return false;

    if (response.statusCode == 201) {
      transactionPersonController.clear();
      setState(() {
        _selectedClothingIds.clear();
        _clothingFuture = _fetchClothing();
        _transactionsFuture = _fetchTransactions();
        _historyFuture = _fetchHistory();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == 'ausgegeben' ? 'Ausgabe gebucht' : 'Rückgabe gebucht',
          ),
        ),
      );
      return true;
    } else if (response.statusCode == 409) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == 'ausgegeben'
                ? 'Mindestens ein Kleidungsstück ist bereits ausgegeben.'
                : 'Mindestens ein Kleidungsstück ist nicht ausgegeben.',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transaktion fehlgeschlagen')),
      );
    }
    return false;
  }

  Future<void> _deleteClothing(String clothingId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kleidung löschen?'),
        content:
            const Text('Möchtest du dieses Kleidungsstück wirklich löschen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final response = await http.delete(
      Uri.parse('$apiBaseUrl/api/clothing/$clothingId'),
      headers: {'Authorization': 'Bearer ${widget.token}'},
    );

    if (!mounted) return;

    if (response.statusCode == 200) {
      setState(() {
        _clothingFuture = _fetchClothing();
        _historyFuture = _fetchHistory();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kleidungsstück gelöscht')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Löschen fehlgeschlagen')),
      );
    }
  }

  Future<void> _openTransactionDialog(String clothingId, String action) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(action == 'ausgegeben'
              ? 'Kleidung ausgeben'
              : 'Kleidung zurücknehmen'),
          content: action == 'ausgegeben'
              ? TextField(
                  controller: transactionPersonController,
                  decoration: const InputDecoration(labelText: 'Person'),
                )
              : const Text(
                  'Für die Rücknahme ist keine Namenseingabe erforderlich.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () async {
                if (clothingId.isNotEmpty) {
                  final success =
                      await _submitTransaction([clothingId], action);
                  if (success && context.mounted) {
                    Navigator.of(context).pop();
                  }
                }
              },
              child: Text(action == 'ausgegeben' ? 'Ausgeben' : 'Zurücknehmen'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSearchDialog() async {
    final searchController = TextEditingController(text: _searchQuery);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Suche'),
          content: TextField(
            controller: searchController,
            decoration: const InputDecoration(
              labelText: 'Suchbegriff',
              hintText: 'Name, Inventarnummer oder Person',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                setState(() {
                  _searchQuery = '';
                });
              },
              child: const Text('Löschen'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                setState(() {
                  _searchQuery = searchController.text.trim();
                });
              },
              child: const Text('Suchen'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _scanClothing() async {
    final manualController = TextEditingController();
    final cameraSupported = kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    var completed = false;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Barcode oder QR-Code scannen'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: manualController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Handscanner / Inventarnummer',
                  prefixIcon: Icon(Icons.qr_code_scanner),
                ),
                onSubmitted: (input) =>
                    Navigator.pop(dialogContext, input.trim()),
              ),
              if (cameraSupported) ...[
                const SizedBox(height: 16),
                SizedBox(
                  height: 260,
                  child: MobileScanner(
                    onDetect: (capture) {
                      final code = capture.barcodes.isEmpty
                          ? null
                          : capture.barcodes.first.rawValue;
                      if (code != null && !completed) {
                        completed = true;
                        Navigator.pop(dialogContext, code);
                      }
                    },
                  ),
                ),
              ] else
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'Auf Windows/Linux bitte einen USB-Handscanner verwenden. Die Kamera wird im Webbrowser unterstützt.',
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, manualController.text.trim()),
            child: const Text('Suchen'),
          ),
        ],
      ),
    );
    manualController.dispose();
    if (value != null && value.trim().isNotEmpty && mounted) {
      setState(() => _searchQuery = value.trim());
    }
  }

  Future<void> _openCodesDialog(Map<String, dynamic> item) async {
    final inventoryNumber = item['inventoryNumber']?.toString().trim() ?? '';
    if (inventoryNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Für dieses Kleidungsstück fehlt eine Inventarnummer.')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Barcode & QR-Code'),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item['name']?.toString() ?? 'Kleidungsstück',
                  style: Theme.of(dialogContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                SelectableText(inventoryNumber),
                const SizedBox(height: 24),
                bw.BarcodeWidget(
                  barcode: bw.Barcode.code128(),
                  data: inventoryNumber,
                  width: 400,
                  height: 90,
                ),
                const SizedBox(height: 28),
                bw.BarcodeWidget(
                  barcode: bw.Barcode.qrCode(),
                  data: inventoryNumber,
                  width: 200,
                  height: 200,
                  drawText: false,
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  Future<void> _openBulkActionDialog() async {
    final dialogSelectedIds = Set<String>.from(_selectedClothingIds);
    final clothingSearchController = TextEditingController();
    final clothingSearchFocusNode = FocusNode();
    String selectedAction = 'ausgegeben';
    String clothingSearchQuery = '';

    bool matchesAction(Map<String, dynamic> item) {
      final isIssued = item['status']?.toString().toLowerCase() == 'ausgegeben';
      return selectedAction == 'ausgegeben' ? !isIssued : isIssued;
    }

    dialogSelectedIds.removeWhere((id) => !_currentClothing
        .any((item) => item['id']?.toString() == id && matchesAction(item)));

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final items = _currentClothing;
            final unselectedItems = items
                .where(matchesAction)
                .where((item) =>
                    !dialogSelectedIds.contains(item['id']?.toString() ?? ''))
                .toList();
            final normalizedSearch = clothingSearchQuery.trim().toLowerCase();
            final searchResults = normalizedSearch.isEmpty
                ? <Map<String, dynamic>>[]
                : unselectedItems.where((item) {
                    final searchableValues = [
                      item['inventoryNumber'],
                      item['name'],
                      item['size'],
                      item['assignedPerson'],
                      item['locationId'],
                      item['status'],
                      _categoryName(item['categoryId']),
                    ];
                    return searchableValues.any((value) => value
                        .toString()
                        .toLowerCase()
                        .contains(normalizedSearch));
                  }).toList();

            void addSearchResult(Map<String, dynamic> item) {
              final itemId = item['id']?.toString() ?? '';
              if (itemId.isEmpty) return;
              setState(() {
                dialogSelectedIds.add(itemId);
                clothingSearchController.clear();
                clothingSearchQuery = '';
              });
              if (clothingSearchFocusNode.canRequestFocus) {
                clothingSearchFocusNode.requestFocus();
              }
            }

            void addUniqueSearchResult(String value) {
              final normalizedValue = value.trim().toLowerCase();
              if (normalizedValue.isEmpty) return;

              final exactInventoryMatches = searchResults
                  .where((item) =>
                      item['inventoryNumber']
                          ?.toString()
                          .trim()
                          .toLowerCase() ==
                      normalizedValue)
                  .toList();
              if (exactInventoryMatches.length == 1) {
                addSearchResult(exactInventoryMatches.single);
              } else if (searchResults.length == 1) {
                addSearchResult(searchResults.single);
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text('Ausgeben / Zurücknehmen'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ToggleButtons(
                      isSelected: [
                        selectedAction == 'ausgegeben',
                        selectedAction == 'zurückgegeben',
                      ],
                      onPressed: (index) {
                        setState(() {
                          selectedAction =
                              index == 0 ? 'ausgegeben' : 'zurückgegeben';
                          dialogSelectedIds.clear();
                        });
                      },
                      borderRadius: BorderRadius.circular(12),
                      selectedColor: Colors.white,
                      fillColor: Colors.blue.shade700,
                      color: Colors.black87,
                      constraints:
                          const BoxConstraints(minHeight: 40, minWidth: 120),
                      children: const [
                        Text('Ausgeben'),
                        Text('Zurücknehmen'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (selectedAction == 'ausgegeben') ...[
                      TextField(
                        controller: transactionPersonController,
                        decoration: const InputDecoration(
                          labelText: 'Person',
                          hintText: 'Name eingeben',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.person),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ] else ...[
                      const Text(
                        'Bei der Rücknahme wird der Name automatisch auf '
                        '„nicht Ausgegeben“ gesetzt.',
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: clothingSearchController,
                      focusNode: clothingSearchFocusNode,
                      decoration: InputDecoration(
                        labelText: 'Kleidung suchen',
                        hintText:
                            'Name, Inventarnummer, Größe, Kategorie oder Person',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: clothingSearchQuery.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Suche löschen',
                                onPressed: () {
                                  clothingSearchController.clear();
                                  setState(() {
                                    clothingSearchQuery = '';
                                  });
                                },
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          clothingSearchQuery = value;
                        });
                      },
                      textInputAction: TextInputAction.done,
                      onSubmitted: addUniqueSearchResult,
                    ),
                    const SizedBox(height: 8),
                    if (normalizedSearch.isEmpty)
                      const Text(
                        'Suchbegriff eingeben und Kleidung direkt aus den '
                        'Treffern auswählen.',
                      )
                    else if (searchResults.isEmpty)
                      const Text('Keine passende Kleidung gefunden.')
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: searchResults.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = searchResults[index];
                            final itemId = item['id']?.toString() ?? '';
                            final name =
                                item['name']?.toString() ?? 'Unbenannt';
                            final inventoryNumber =
                                item['inventoryNumber']?.toString() ?? '-';
                            final size = item['size']?.toString() ?? '-';
                            final category = _categoryName(item['categoryId']);
                            final assignedPerson =
                                item['assignedPerson']?.toString();
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text('$inventoryNumber • $name'),
                              subtitle: Text([
                                'Größe $size',
                                category,
                                if (assignedPerson != null &&
                                    assignedPerson.isNotEmpty)
                                  assignedPerson,
                              ].join(' • ')),
                              trailing: FilledButton.icon(
                                onPressed: itemId.isEmpty
                                    ? null
                                    : () => addSearchResult(item),
                                icon: const Icon(Icons.add),
                                label: const Text('Auswählen'),
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text('Gewählte Kleidungsstücke',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (dialogSelectedIds.isEmpty)
                      const Text('Noch keine Kleidungsstücke ausgewählt.'),
                    if (dialogSelectedIds.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: dialogSelectedIds.map((itemId) {
                          final item = items.firstWhere(
                            (item) => item['id']?.toString() == itemId,
                            orElse: () => <String, dynamic>{},
                          );
                          final name = item['name']?.toString() ?? 'Unbenannt';
                          final inventoryNumber =
                              item['inventoryNumber']?.toString() ?? '-';
                          return InputChip(
                            label: Text('$inventoryNumber • $name'),
                            onDeleted: () {
                              setState(() {
                                dialogSelectedIds.remove(itemId);
                              });
                            },
                          );
                        }).toList(),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (dialogSelectedIds.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Bitte mindestens ein Kleidungsstück auswählen')),
                      );
                      return;
                    }
                    final success = await _submitTransaction(
                        dialogSelectedIds.toList(), selectedAction);
                    if (success && context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: const Text('Ausführen'),
                ),
              ],
            );
          },
        );
      },
    );
    clothingSearchController.dispose();
    clothingSearchFocusNode.dispose();
  }

  Future<void> _deleteSelectedClothing() async {
    if (_selectedClothingIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Bitte mindestens ein Kleidungsstück auswählen')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ausgewählte Kleidung löschen?'),
        content: Text(
            'Möchtest du ${_selectedClothingIds.length} ausgewählte Kleidungsstücke löschen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final deletedIds = <String>[];
    var failedCount = 0;
    for (final id in List<String>.from(_selectedClothingIds)) {
      if (id.isEmpty) {
        continue;
      }
      try {
        final response = await http.delete(
          Uri.parse('$apiBaseUrl/api/clothing/$id'),
          headers: {'Authorization': 'Bearer ${widget.token}'},
        );
        if (response.statusCode == 200) {
          deletedIds.add(id);
        } else {
          failedCount++;
        }
      } catch (_) {
        failedCount++;
      }
    }

    if (!mounted) return;
    setState(() {
      _selectedClothingIds.removeAll(deletedIds);
      _clothingFuture = _fetchClothing();
      _historyFuture = _fetchHistory();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failedCount == 0
            ? '${deletedIds.length} Kleidungsstücke gelöscht'
            : '${deletedIds.length} gelöscht, $failedCount konnten nicht gelöscht werden'),
      ),
    );
  }

  Widget _buildInventoryTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Kleidung im Bestand',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'alle', label: Text('Alle')),
                    ButtonSegment(value: 'verfügbar', label: Text('Verfügbar')),
                    ButtonSegment(
                        value: 'ausgegeben', label: Text('Ausgegeben')),
                  ],
                  selected: {_filterMode},
                  onSelectionChanged: (selection) {
                    setState(() {
                      _filterMode = selection.first;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 180,
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _categoryFilterId,
                  items: [
                    const DropdownMenuItem(
                      value: 'alle',
                      child: Text('Alle Kategorien'),
                    ),
                    ..._selectableCategories.map(
                      (category) => DropdownMenuItem(
                        value: category['id']?.toString(),
                        child: Text(_categoryPath(category)),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _categoryFilterId = value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ElevatedButton.icon(
                onPressed: _openCreateDialog,
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.add_circle_outline, size: 18),
                label: const Text('Neue Kleidung anlegen'),
              ),
              ElevatedButton.icon(
                onPressed: _openSearchDialog,
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.search, size: 18),
                label: const Text('Suche'),
              ),
              ElevatedButton.icon(
                onPressed: _scanClothing,
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  backgroundColor: Colors.indigo.shade700,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('Scannen'),
              ),
              ElevatedButton.icon(
                onPressed: _openBulkActionDialog,
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  backgroundColor: Colors.orange.shade700,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.inventory_2, size: 18),
                label: const Text('Ausgeben/Zurücknehmen'),
              ),
              ElevatedButton.icon(
                onPressed: _deleteSelectedClothing,
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Löschen'),
              ),
              ElevatedButton.icon(
                onPressed: _isTransferringTable ? null : _importClothingTable,
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  backgroundColor: Colors.teal.shade700,
                  foregroundColor: Colors.white,
                ),
                icon: _isTransferringTable
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file, size: 18),
                label: const Text('Tabelle importieren'),
              ),
              PopupMenuButton<String>(
                enabled: !_isTransferringTable,
                onSelected: _exportClothingTable,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'xlsx', child: Text('Excel (.xlsx)')),
                  PopupMenuItem(
                      value: 'ods', child: Text('OpenDocument (.ods)')),
                ],
                child: IgnorePointer(
                  child: ElevatedButton.icon(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                      backgroundColor: Colors.indigo.shade700,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Tabelle exportieren'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _clothingFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Column(
                    children: const [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Ausgabe-/Rückgabe-Log',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      SizedBox(height: 8),
                      Expanded(
                          child: Center(child: CircularProgressIndicator())),
                    ],
                  );
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(snapshot.error.toString()),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: () => setState(() {
                            _clothingFuture = _fetchClothing();
                            _transactionsFuture = _fetchTransactions();
                            _historyFuture = _fetchHistory();
                          }),
                          child: const Text('Erneut laden'),
                        ),
                      ],
                    ),
                  );
                }

                final clothing = snapshot.data ?? [];
                final filteredClothing = clothing.where((item) {
                  final status = item['status']?.toString().toLowerCase() ?? '';
                  if (_filterMode == 'verfügbar') {
                    if (status == 'ausgegeben') return false;
                  }
                  if (_filterMode == 'ausgegeben') {
                    if (status != 'ausgegeben') return false;
                  }
                  if (_categoryFilterId != 'alle' &&
                      item['categoryId']?.toString() != _categoryFilterId) {
                    return false;
                  }

                  final query = _searchQuery.toLowerCase();
                  if (query.isEmpty) return true;
                  return [
                    item['name'],
                    item['inventoryNumber'],
                    item['assignedPerson'],
                    item['size'],
                    item['locationId'],
                    _categoryName(item['categoryId']),
                  ].any((value) =>
                      value?.toString().toLowerCase().contains(query) ?? false);
                }).toList();
                final visibleIds = filteredClothing
                    .map((item) => item['id']?.toString() ?? '')
                    .where((id) => id.isNotEmpty)
                    .toList();
                final allVisibleSelected = visibleIds.isNotEmpty &&
                    visibleIds.every(_selectedClothingIds.contains);

                return Column(
                  children: [
                    if (visibleIds.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              if (allVisibleSelected) {
                                _selectedClothingIds.removeAll(visibleIds);
                              } else {
                                _selectedClothingIds.addAll(visibleIds);
                              }
                            });
                          },
                          icon: Icon(allVisibleSelected
                              ? Icons.check_box
                              : Icons.check_box_outline_blank),
                          label: Text(allVisibleSelected
                              ? 'Alle abwählen'
                              : 'Alle auswählen'),
                        ),
                      ),
                    Expanded(
                      child: filteredClothing.isEmpty
                          ? const Center(
                              child: Text(
                                  'Keine Kleidungsstücke in dieser Ansicht.'))
                          : ListView.separated(
                              itemCount: filteredClothing.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (_, index) {
                                final item = filteredClothing[index];
                                final isIssued =
                                    (item['status']?.toString() ?? '')
                                            .toLowerCase() ==
                                        'ausgegeben';
                                final itemId = item['id']?.toString() ?? '';
                                final isSelected =
                                    _selectedClothingIds.contains(itemId);
                                return Card(
                                  child: ListTile(
                                    leading: Checkbox(
                                      value: isSelected,
                                      onChanged: (_) {
                                        if (itemId.isEmpty) return;
                                        setState(() {
                                          if (isSelected) {
                                            _selectedClothingIds.remove(itemId);
                                          } else {
                                            _selectedClothingIds.add(itemId);
                                          }
                                        });
                                      },
                                    ),
                                    title: Text(item['name']?.toString() ??
                                        'Unbenannt'),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            'Inventarnummer: ${item['inventoryNumber']?.toString() ?? '-'}'),
                                        Text(
                                            'Kategorie: ${_categoryName(item['categoryId'])}'),
                                        Text(
                                            'Größe: ${item['size']?.toString() ?? '-'}'),
                                        Text(
                                            'Status: ${item['status']?.toString() ?? '-'}'),
                                        Text(
                                            'Zugewiesen an: ${item['assignedPerson']?.toString() ?? 'nicht vergeben'}'),
                                        Text(
                                            'Lagerort: ${_storageLabel(item)}'),
                                        if (item['inspectionIntervalMonths'] !=
                                            null)
                                          Text(
                                              'Prüfintervall: ${item['inspectionIntervalMonths']} Monate'),
                                        if (item['nextInspectionDate'] != null)
                                          Text(
                                            'Nächste Prüfung: ${_formatDate(item['nextInspectionDate'])}',
                                            style: TextStyle(
                                              color: DateTime.tryParse(item[
                                                                  'nextInspectionDate']
                                                              .toString())
                                                          ?.isBefore(
                                                              DateTime.now()) ==
                                                      true
                                                  ? Colors.red.shade700
                                                  : null,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        if (_requiresPsageInspection(item))
                                          const Text(
                                            'Prüfung: nur Sachkundige PSAgE',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600),
                                          ),
                                      ],
                                    ),
                                    trailing: Wrap(
                                      spacing: 8,
                                      children: [
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              _openEditDialog(item),
                                          icon: const Icon(Icons.edit),
                                          label: const Text('Bearbeiten'),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              _openInspectionDialog(item),
                                          icon: const Icon(Icons.fact_check),
                                          label: const Text('Prüfung'),
                                        ),
                                        IconButton(
                                          onPressed: () =>
                                              _openCodesDialog(item),
                                          tooltip: 'Barcode & QR-Code',
                                          icon: const Icon(Icons.qr_code_2),
                                        ),
                                        OutlinedButton(
                                          onPressed: () =>
                                              _openTransactionDialog(
                                            item['id']?.toString() ?? '',
                                            isIssued
                                                ? 'zurückgegeben'
                                                : 'ausgegeben',
                                          ),
                                          child: Text(isIssued
                                              ? 'Zurückgeben'
                                              : 'Ausgeben'),
                                        ),
                                        FilledButton.icon(
                                          onPressed: () => _deleteClothing(
                                              item['id']?.toString() ?? ''),
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                Colors.red.shade700,
                                            foregroundColor: Colors.white,
                                          ),
                                          icon:
                                              const Icon(Icons.delete_outline),
                                          label: const Text('Löschen'),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 16),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Ausgabe-/Rückgabe-Log',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FutureBuilder<List<Map<String, dynamic>>>(
                      future: _transactionsFuture,
                      builder: (context, transactionSnapshot) {
                        if (transactionSnapshot.connectionState !=
                            ConnectionState.done) {
                          return const SizedBox();
                        }
                        if (transactionSnapshot.hasError) {
                          return Text(transactionSnapshot.error.toString());
                        }

                        final transactions = transactionSnapshot.data ?? [];
                        return SizedBox(
                          height: 140,
                          child: transactions.isEmpty
                              ? const Center(
                                  child: Text(
                                      'Noch keine Ausgaben oder Rückgaben.'))
                              : ListView.separated(
                                  itemCount: transactions.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (_, index) {
                                    final transaction = transactions[index];
                                    return Card(
                                      child: ListTile(
                                        dense: true,
                                        title: Text(
                                          transaction['action']?.toString() ==
                                                  'ausgegeben'
                                              ? 'Ausgabe'
                                              : 'Rückgabe',
                                        ),
                                        subtitle: Text(
                                          '${transaction['personName']?.toString() ?? '-'} • ${transaction['createdAt']?.toString() ?? ''}',
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _historyFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(snapshot.error.toString()));
          }

          final history = snapshot.data ?? [];
          if (history.isEmpty) {
            return const Center(
                child: Text('Noch keine gelöschten Kleidungsstücke.'));
          }

          return ListView.separated(
            itemCount: history.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, index) {
              final item = history[index];
              return Card(
                child: ListTile(
                  title: Text(item['name']?.toString() ?? 'Unbenannt'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Inventarnummer: ${item['inventoryNumber']?.toString() ?? '-'}'),
                      Text('Kategorie: ${_categoryName(item['categoryId'])}'),
                      Text(
                          'Gelöscht am: ${item['deletedAt']?.toString() ?? '-'}'),
                      Text(
                          'Gelöscht von: ${item['deletedBy']?.toString() ?? '-'}'),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Kleiderkammer'),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Abmelden',
              onPressed: widget.onLogout ??
                  () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                      (route) => false,
                    );
                  },
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Bestand'),
              Tab(text: 'Historie'),
            ],
          ),
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            setState(() {
              _clothingFuture = _fetchClothing();
              _transactionsFuture = _fetchTransactions();
              _historyFuture = _fetchHistory();
              _fetchCategories();
            });
          },
          child: TabBarView(
            children: [
              _buildInventoryTab(),
              _buildHistoryTab(),
            ],
          ),
        ),
      ),
    );
  }
}
