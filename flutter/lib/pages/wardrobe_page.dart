import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
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
  final TextEditingController nameController = TextEditingController();
  final TextEditingController sizeController = TextEditingController();
  final TextEditingController locationController =
      TextEditingController(text: 'loc-2');
  final TextEditingController statusController =
      TextEditingController(text: 'Lagernd');
  final TextEditingController assignedPersonController =
      TextEditingController();
  final TextEditingController transactionPersonController =
      TextEditingController();
  final TextEditingController inventoryNumberController =
      TextEditingController();
  String _filterMode = 'alle';
  String? _editingClothingId;

  @override
  void initState() {
    super.initState();
    _clothingFuture = _fetchClothing();
    _transactionsFuture = _fetchTransactions();
    _historyFuture = _fetchHistory();
  }

  @override
  void dispose() {
    nameController.dispose();
    sizeController.dispose();
    locationController.dispose();
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
        return data
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      }
      return [];
    } catch (_) {
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

  void _resetForm() {
    nameController.clear();
    sizeController.clear();
    inventoryNumberController.clear();
    locationController.text = 'loc-2';
    statusController.text = 'Lagernd';
    assignedPersonController.clear();
    _editingClothingId = null;
  }

  Future<void> _saveClothing({BuildContext? dialogContext}) async {
    final name = nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte einen Kleidungsnamen angeben')),
      );
      return;
    }

    final payload = {
      'name': name,
      'inventoryNumber': inventoryNumberController.text.trim().isEmpty
          ? null
          : inventoryNumberController.text.trim(),
      'size': sizeController.text.trim(),
      'locationId': locationController.text.trim().isEmpty
          ? 'loc-2'
          : locationController.text.trim(),
      'status': statusController.text.trim().isEmpty
          ? 'Lagernd'
          : statusController.text.trim(),
      'assignedPerson': assignedPersonController.text.trim().isEmpty
          ? null
          : assignedPersonController.text.trim(),
    };

    final response = _editingClothingId == null
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
            _editingClothingId == null
                ? 'Kleidungsstück angelegt'
                : 'Kleidungsstück bearbeitet',
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
            _editingClothingId == null
                ? 'Anlegen fehlgeschlagen'
                : 'Bearbeiten fehlgeschlagen',
          ),
        ),
      );
    }
  }

  Future<void> _openCreateDialog() async {
    _resetForm();
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
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
                TextField(
                  controller: inventoryNumberController,
                  decoration:
                      const InputDecoration(labelText: 'Inventarnummer'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: sizeController,
                  decoration: const InputDecoration(labelText: 'Größe'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: locationController,
                  decoration: const InputDecoration(labelText: 'Standort-ID'),
                ),
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
        );
      },
    );
  }

  Future<void> _openEditDialog(Map<String, dynamic> item) async {
    _editingClothingId = item['id']?.toString();
    nameController.text = item['name']?.toString() ?? '';
    sizeController.text = item['size']?.toString() ?? '';
    inventoryNumberController.text = item['inventoryNumber']?.toString() ?? '';
    locationController.text = item['locationId']?.toString() ?? 'loc-2';
    statusController.text = item['status']?.toString() ?? 'Lagernd';
    assignedPersonController.text = item['assignedPerson']?.toString() ?? '';

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
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
                TextField(
                  controller: inventoryNumberController,
                  decoration:
                      const InputDecoration(labelText: 'Inventarnummer'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: sizeController,
                  decoration: const InputDecoration(labelText: 'Größe'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: locationController,
                  decoration: const InputDecoration(labelText: 'Standort-ID'),
                ),
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
        );
      },
    );
  }

  Future<void> _submitTransaction(String clothingId, String action) async {
    final personName = transactionPersonController.text.trim();
    if (personName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte eine Person angeben')),
      );
      return;
    }

    final response = await http.post(
      Uri.parse('$apiBaseUrl/api/transactions'),
      headers: {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'clothingId': clothingId,
        'personName': personName,
        'quantity': 1,
        'action': action,
      }),
    );

    if (!mounted) return;

    if (response.statusCode == 201) {
      transactionPersonController.clear();
      setState(() {
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
    } else if (response.statusCode == 409) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == 'ausgegeben'
                ? 'Dieses Kleidungsstück ist bereits ausgegeben.'
                : 'Dieses Kleidungsstück ist aktuell nicht ausgegeben.',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transaktion fehlgeschlagen')),
      );
    }
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
          content: TextField(
            controller: transactionPersonController,
            decoration: const InputDecoration(labelText: 'Person'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                _submitTransaction(clothingId, action);
              },
              child: Text(action == 'ausgegeben' ? 'Ausgeben' : 'Zurücknehmen'),
            ),
          ],
        );
      },
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
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'alle', label: Text('Alle')),
              ButtonSegment(value: 'verfügbar', label: Text('Verfügbar')),
              ButtonSegment(value: 'ausgegeben', label: Text('Ausgegeben')),
            ],
            selected: {_filterMode},
            onSelectionChanged: (selection) {
              setState(() {
                _filterMode = selection.first;
              });
            },
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _openCreateDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Neue Kleidung anlegen'),
            ),
          ),
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
                    return status != 'ausgegeben';
                  }
                  if (_filterMode == 'ausgegeben') {
                    return status == 'ausgegeben';
                  }
                  return true;
                }).toList();

                return Column(
                  children: [
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
                                return Card(
                                  child: ListTile(
                                    leading: const CircleAvatar(
                                        child: Icon(Icons.checkroom)),
                                    title: Text(item['name']?.toString() ??
                                        'Unbenannt'),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            'Inventarnummer: ${item['inventoryNumber']?.toString() ?? '-'}'),
                                        Text(
                                            'Größe: ${item['size']?.toString() ?? '-'}'),
                                        Text(
                                            'Status: ${item['status']?.toString() ?? '-'}'),
                                        Text(
                                            'Zugewiesen an: ${item['assignedPerson']?.toString() ?? 'nicht vergeben'}'),
                                        Text(
                                            'Standort: ${item['locationId']?.toString() ?? '-'}'),
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
