import 'package:flutter/material.dart' hide DropdownButtonFormField;
import 'package:flutter/services.dart';

import 'keyboard_dropdown_button_form_field.dart';

/// Signature of the API helper of the procurement page. It returns `null`
/// after it has already shown an error message to the user.
typedef SupplierApiRequest =
    Future<dynamic> Function(String path, {String method, Object? body});

List<String> _stringList(dynamic value) => (value as List? ?? const [])
    .map((entry) => entry.toString())
    .where((entry) => entry.isNotEmpty)
    .toList();

Map<String, dynamic>? _categoryById(
  List<Map<String, dynamic>> categories,
  String? id,
) => categories.where((entry) => entry['id']?.toString() == id).firstOrNull;

String _categoryLabel(
  List<Map<String, dynamic>> categories,
  Map<String, dynamic> article,
) {
  final main = _categoryById(categories, article['categoryId']?.toString());
  final sub = _categoryById(categories, article['subcategoryId']?.toString());
  return [
    main?['name'],
    sub?['name'],
  ].where((value) => value != null).join(' / ');
}

bool isClothingArticle(
  List<Map<String, dynamic>> categories,
  Map<String, dynamic> article,
) =>
    _categoryById(
      categories,
      article['categoryId']?.toString(),
    )?['useInWardrobe'] ==
    true;

String supplierArticleSummary(
  List<Map<String, dynamic>> categories,
  Map<String, dynamic> article,
) {
  final sizes = _stringList(article['sizes']);
  return [
    if (article['manufacturerArticleNumber']?.toString().isNotEmpty == true)
      'Art.-Nr. ${article['manufacturerArticleNumber']}',
    _categoryLabel(categories, article),
    if (sizes.isNotEmpty) 'Größen: ${sizes.join(', ')}',
  ].where((value) => value.isNotEmpty).join(' · ');
}

/// Lists, creates, edits and deletes the frequently ordered articles of one
/// supplier.
class SupplierArticlesDialog extends StatefulWidget {
  final Map<String, dynamic> supplier;
  final List<Map<String, dynamic>> categories;
  final bool canWrite;
  final SupplierApiRequest request;

  const SupplierArticlesDialog({
    required this.supplier,
    required this.categories,
    required this.canWrite,
    required this.request,
    super.key,
  });

  @override
  State<SupplierArticlesDialog> createState() => _SupplierArticlesDialogState();
}

class _SupplierArticlesDialogState extends State<SupplierArticlesDialog> {
  final _search = TextEditingController();
  late List<Map<String, dynamic>> _articles;
  bool _busy = false;

  String get _basePath => '/api/suppliers/${widget.supplier['id']}/articles';

  @override
  void initState() {
    super.initState();
    _articles = (widget.supplier['articles'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered {
    final query = _search.text.trim().toLowerCase();
    final list = _articles.where((article) {
      if (query.isEmpty) return true;
      return [
        article['name'],
        article['manufacturerArticleNumber'],
        _categoryLabel(widget.categories, article),
      ].join(' ').toLowerCase().contains(query);
    }).toList();
    list.sort(
      (a, b) => a['name'].toString().toLowerCase().compareTo(
        b['name'].toString().toLowerCase(),
      ),
    );
    return list;
  }

  Future<void> _edit([Map<String, dynamic>? article]) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SupplierArticleDialog(
        categories: widget.categories,
        article: article,
      ),
    );
    if (payload == null || !mounted) return;
    setState(() => _busy = true);
    final saved = await widget.request(
      article == null ? _basePath : '$_basePath/${article['id']}',
      method: article == null ? 'POST' : 'PUT',
      body: payload,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (saved is Map) {
        final entry = Map<String, dynamic>.from(saved);
        final index = _articles.indexWhere((a) => a['id'] == entry['id']);
        if (index >= 0) {
          _articles[index] = entry;
        } else {
          _articles.add(entry);
        }
      }
    });
  }

  Future<void> _delete(Map<String, dynamic> article) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Artikel löschen?'),
        content: Text(
          '${article['name']} wird aus dem Artikelstamm von '
          '${widget.supplier['name']} entfernt. Bestehende Beschaffungen '
          'bleiben unverändert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final result = await widget.request(
      '$_basePath/${article['id']}',
      method: 'DELETE',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Errors were already reported by the request helper (result == null).
      if (result != null) {
        _articles.removeWhere((entry) => entry['id'] == article['id']);
      }
    });
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Link wurde kopiert.')));
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return AlertDialog(
      title: Text('Artikelstamm · ${widget.supplier['name']}'),
      content: SizedBox(
        width: 760,
        height: 520,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'Artikel suchen',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (widget.canWrite) ...[
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _edit(),
                    icon: const Icon(Icons.add),
                    label: const Text('Artikel anlegen'),
                  ),
                ],
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        _articles.isEmpty
                            ? 'Für diesen Lieferanten sind noch keine Artikel hinterlegt.'
                            : 'Keine passenden Artikel gefunden.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, index) {
                        final article = filtered[index];
                        final url = article['url']?.toString() ?? '';
                        return Card(
                          child: ListTile(
                            leading: Icon(
                              isClothingArticle(widget.categories, article)
                                  ? Icons.checkroom_outlined
                                  : Icons.inventory_2_outlined,
                            ),
                            title: Text(article['name'].toString()),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  supplierArticleSummary(
                                    widget.categories,
                                    article,
                                  ),
                                ),
                                if (url.isNotEmpty)
                                  SelectableText(
                                    url,
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (url.isNotEmpty)
                                  IconButton(
                                    tooltip: 'Link kopieren',
                                    onPressed: () => _copyUrl(url),
                                    icon: const Icon(Icons.link),
                                  ),
                                if (widget.canWrite) ...[
                                  IconButton(
                                    tooltip: 'Bearbeiten',
                                    onPressed: _busy
                                        ? null
                                        : () => _edit(article),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Löschen',
                                    onPressed: _busy
                                        ? null
                                        : () => _delete(article),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Schließen'),
        ),
      ],
    );
  }
}

/// Creates or edits a single supplier article. Returns the request payload.
class SupplierArticleDialog extends StatefulWidget {
  final List<Map<String, dynamic>> categories;
  final Map<String, dynamic>? article;

  const SupplierArticleDialog({
    required this.categories,
    this.article,
    super.key,
  });

  @override
  State<SupplierArticleDialog> createState() => _SupplierArticleDialogState();
}

class _SupplierArticleDialogState extends State<SupplierArticleDialog> {
  final _number = TextEditingController();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _unit = TextEditingController(text: 'Stück');
  final _notes = TextEditingController();
  final _freeSizes = TextEditingController();
  String? _categoryId, _subcategoryId;
  final Set<String> _sizes = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    final article = widget.article;
    if (article == null) return;
    _number.text = article['manufacturerArticleNumber']?.toString() ?? '';
    _name.text = article['name']?.toString() ?? '';
    _url.text = article['url']?.toString() ?? '';
    _unit.text = article['unit']?.toString() ?? 'Stück';
    _notes.text = article['notes']?.toString() ?? '';
    _categoryId = article['categoryId']?.toString();
    _subcategoryId = article['subcategoryId']?.toString();
    _sizes.addAll(_stringList(article['sizes']));
    if (_predefinedSizes.isEmpty) _freeSizes.text = _sizes.join(', ');
  }

  @override
  void dispose() {
    for (final controller in [
      _number,
      _name,
      _url,
      _unit,
      _notes,
      _freeSizes,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _isClothing =>
      _categoryById(widget.categories, _categoryId)?['useInWardrobe'] == true;

  List<String> get _predefinedSizes {
    final own = _stringList(
      _categoryById(widget.categories, _subcategoryId ?? _categoryId)?['sizes'],
    );
    if (own.isNotEmpty) return own;
    return _stringList(_categoryById(widget.categories, _categoryId)?['sizes']);
  }

  void _categoryChanged() {
    _sizes.removeWhere((size) => !_predefinedSizes.contains(size));
    if (_predefinedSizes.isEmpty) _freeSizes.text = '';
  }

  void _save() {
    final url = _url.text.trim();
    final uri = Uri.tryParse(url);
    String? error;
    if (_name.text.trim().isEmpty || _categoryId == null) {
      error = 'Bitte Bezeichnung und Hauptkategorie angeben.';
    } else if (url.isNotEmpty &&
        (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty)) {
      error = 'Die Web-URL muss mit http:// oder https:// beginnen.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final sizes = !_isClothing
        ? <String>[]
        : _predefinedSizes.isNotEmpty
        ? _predefinedSizes.where(_sizes.contains).toList()
        : _freeSizes.text
              .split(',')
              .map((size) => size.trim())
              .where((size) => size.isNotEmpty)
              .toSet()
              .toList();
    Navigator.pop(context, {
      'manufacturerArticleNumber': _number.text.trim(),
      'name': _name.text.trim(),
      'url': url,
      'categoryId': _categoryId,
      'subcategoryId': _subcategoryId,
      'unit': _unit.text.trim(),
      'notes': _notes.text.trim(),
      'sizes': sizes,
    });
  }

  Widget _text(
    TextEditingController controller,
    String label,
    double width, {
    int lines = 1,
    String? hint,
  }) => SizedBox(
    width: width,
    child: TextField(
      controller: controller,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final mains = widget.categories
        .where((entry) => entry['parentId'] == null)
        .toList();
    final subs = widget.categories
        .where(
          (entry) =>
              _categoryId != null &&
              entry['parentId']?.toString() == _categoryId,
        )
        .toList();
    final predefined = _predefinedSizes;
    return AlertDialog(
      title: Text(
        widget.article == null ? 'Artikel anlegen' : 'Artikel bearbeiten',
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _text(_number, 'Artikelnummer des Herstellers', 240),
                  _text(_name, 'Bezeichnung *', 340),
                  _text(_url, 'Web-URL zum Artikel', 592, hint: 'https://'),
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('article-main-$_categoryId'),
                      initialValue: _categoryId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Hauptkategorie *',
                      ),
                      items: mains
                          .map(
                            (entry) => DropdownMenuItem(
                              value: entry['id'].toString(),
                              child: Text(
                                entry['name'].toString(),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() {
                        _categoryId = value;
                        _subcategoryId = null;
                        _categoryChanged();
                      }),
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('article-sub-$_categoryId-$_subcategoryId'),
                      initialValue: _subcategoryId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Unterkategorie',
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('Keine'),
                        ),
                        ...subs.map(
                          (entry) => DropdownMenuItem(
                            value: entry['id'].toString(),
                            child: Text(
                              entry['name'].toString(),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: subs.isEmpty
                          ? null
                          : (value) => setState(() {
                              _subcategoryId = value;
                              _categoryChanged();
                            }),
                    ),
                  ),
                  _text(_unit, 'Einheit', 100),
                  _text(_notes, 'Notizen', 592, lines: 2),
                ],
              ),
              if (_isClothing) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(),
                ),
                Text(
                  'Verfügbare Größen',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (predefined.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ...predefined.map(
                        (size) => FilterChip(
                          label: Text(size),
                          selected: _sizes.contains(size),
                          onSelected: (selected) => setState(() {
                            if (selected) {
                              _sizes.add(size);
                            } else {
                              _sizes.remove(size);
                            }
                          }),
                        ),
                      ),
                      ActionChip(
                        label: Text(
                          _sizes.length == predefined.length ? 'Keine' : 'Alle',
                        ),
                        onPressed: () => setState(() {
                          if (_sizes.length == predefined.length) {
                            _sizes.clear();
                          } else {
                            _sizes.addAll(predefined);
                          }
                        }),
                      ),
                    ],
                  )
                else
                  _text(
                    _freeSizes,
                    'Größen (kommagetrennt)',
                    592,
                    hint: 'z. B. 40, 42, 44',
                  ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _save, child: const Text('Speichern')),
      ],
    );
  }
}

class PickedSupplierArticle {
  final String supplierId;
  final Map<String, dynamic> article;
  const PickedSupplierArticle(this.supplierId, this.article);
}

/// Lets the requester pick a stored supplier article to fill a procurement
/// position.
class SupplierArticlePickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> suppliers;
  final List<Map<String, dynamic>> categories;
  final String? preferredSupplierId;

  const SupplierArticlePickerDialog({
    required this.suppliers,
    required this.categories,
    this.preferredSupplierId,
    super.key,
  });

  @override
  State<SupplierArticlePickerDialog> createState() =>
      _SupplierArticlePickerDialogState();
}

class _SupplierArticlePickerDialogState
    extends State<SupplierArticlePickerDialog> {
  final _search = TextEditingController();
  String? _supplierId;

  @override
  void initState() {
    super.initState();
    _supplierId =
        widget.suppliers.any(
          (entry) =>
              entry['id']?.toString() == widget.preferredSupplierId &&
              (entry['articles'] as List? ?? const []).isNotEmpty,
        )
        ? widget.preferredSupplierId
        : null;
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<PickedSupplierArticle> get _entries {
    final query = _search.text.trim().toLowerCase();
    final result = <PickedSupplierArticle>[];
    for (final supplier in widget.suppliers) {
      final id = supplier['id']?.toString() ?? '';
      if (_supplierId != null && id != _supplierId) continue;
      for (final raw in supplier['articles'] as List? ?? const []) {
        final article = Map<String, dynamic>.from(raw as Map);
        final text = [
          article['name'],
          article['manufacturerArticleNumber'],
          supplier['name'],
          _categoryLabel(widget.categories, article),
        ].join(' ').toLowerCase();
        if (query.isEmpty || text.contains(query)) {
          result.add(PickedSupplierArticle(id, article));
        }
      }
    }
    result.sort(
      (a, b) => a.article['name'].toString().toLowerCase().compareTo(
        b.article['name'].toString().toLowerCase(),
      ),
    );
    return result;
  }

  String _supplierName(String id) =>
      widget.suppliers
          .where((entry) => entry['id']?.toString() == id)
          .map((entry) => entry['name'].toString())
          .firstOrNull ??
      '';

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final withArticles = widget.suppliers
        .where((entry) => (entry['articles'] as List? ?? const []).isNotEmpty)
        .toList();
    return AlertDialog(
      title: const Text('Artikel aus Lieferanten-Artikelstamm'),
      content: SizedBox(
        width: 680,
        height: 480,
        child: Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 360,
                  child: TextField(
                    controller: _search,
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'Bezeichnung oder Artikelnummer',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<String>(
                    initialValue: _supplierId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Lieferant'),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('Alle Lieferanten'),
                      ),
                      ...withArticles.map(
                        (entry) => DropdownMenuItem(
                          value: entry['id'].toString(),
                          child: Text(
                            entry['name'].toString(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() => _supplierId = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: entries.isEmpty
                  ? const Center(child: Text('Keine passenden Artikel.'))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (_, index) {
                        final entry = entries[index];
                        return ListTile(
                          leading: Icon(
                            isClothingArticle(widget.categories, entry.article)
                                ? Icons.checkroom_outlined
                                : Icons.inventory_2_outlined,
                          ),
                          title: Text(entry.article['name'].toString()),
                          subtitle: Text(
                            [
                              _supplierName(entry.supplierId),
                              supplierArticleSummary(
                                widget.categories,
                                entry.article,
                              ),
                            ].where((value) => value.isNotEmpty).join(' · '),
                          ),
                          onTap: () => Navigator.pop(context, entry),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
      ],
    );
  }
}
