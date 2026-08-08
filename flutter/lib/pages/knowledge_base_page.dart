import 'package:flutter/material.dart';

class KnowledgeBasePage extends StatefulWidget {
  const KnowledgeBasePage({super.key});

  @override
  State<KnowledgeBasePage> createState() => _KnowledgeBasePageState();
}

class _KnowledgeBasePageState extends State<KnowledgeBasePage> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _selectedCategory;
  _GuideArticle? _selectedArticle;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<_GuideArticle> get _results {
    final normalized = _query.trim().toLowerCase();
    return _articles.where((article) {
      if (_selectedCategory != null && article.category != _selectedCategory) {
        return false;
      }
      if (normalized.isEmpty) return true;
      return article.searchText.contains(normalized);
    }).toList();
  }

  void _selectCategory(String? category) {
    setState(() {
      _selectedCategory = category;
      _selectedArticle = null;
    });
  }

  void _openArticle(_GuideArticle article) {
    setState(() => _selectedArticle = article);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Handbuch'),
        actions: [
          IconButton(
            tooltip: 'Zur Startseite des Handbuchs',
            onPressed: () {
              _searchController.clear();
              setState(() {
                _query = '';
                _selectedCategory = null;
                _selectedArticle = null;
              });
            },
            icon: const Icon(Icons.home_outlined),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 900;
          if (isDesktop) {
            return Row(
              children: [
                SizedBox(
                  width: 292,
                  child: _GuideSidebar(
                    selectedCategory: _selectedCategory,
                    onSelected: _selectCategory,
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _buildMainContent(isDesktop: true)),
              ],
            );
          }
          return _buildMainContent(isDesktop: false);
        },
      ),
    );
  }

  Widget _buildMainContent({required bool isDesktop}) {
    if (_selectedArticle != null) {
      return _ArticleView(
        article: _selectedArticle!,
        onBack: () => setState(() => _selectedArticle = null),
      );
    }

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: _GuideHero(
            controller: _searchController,
            query: _query,
            onChanged: (value) => setState(() => _query = value),
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
        ),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  isDesktop ? 36 : 16,
                  28,
                  isDesktop ? 36 : 16,
                  12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isDesktop) ...[
                      Text(
                        'Themen',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      _MobileCategorySelector(
                        selectedCategory: _selectedCategory,
                        onSelected: _selectCategory,
                      ),
                      const SizedBox(height: 28),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _selectedCategory ?? 'Alle Anleitungen',
                                style:
                                    Theme.of(context).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _query.isEmpty
                                    ? '${_results.length} Beiträge zum Nachschlagen'
                                    : '${_results.length} Treffer für „$_query“',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        if (_selectedCategory != null)
                          TextButton.icon(
                            onPressed: () => _selectCategory(null),
                            icon: const Icon(Icons.close, size: 18),
                            label: const Text('Filter löschen'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_results.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptySearchResult(),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              isDesktop ? 36 : 16,
              4,
              isDesktop ? 36 : 16,
              40,
            ),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.crossAxisExtent >= 760 ? 2 : 1;
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    mainAxisExtent: 196,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _ArticleCard(
                      article: _results[index],
                      onTap: () => _openArticle(_results[index]),
                    ),
                    childCount: _results.length,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _GuideHero extends StatelessWidget {
  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _GuideHero({
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.secondary,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 34),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              Icon(
                Icons.menu_book_rounded,
                color: colors.onSecondary,
                size: 42,
              ),
              const SizedBox(height: 10),
              Text(
                'Wie können wir helfen?',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: colors.onSecondary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Finden Sie Antworten, Schritt-für-Schritt-Anleitungen und Tipps '
                'für MaterialKompass.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colors.onSecondary.withValues(alpha: 0.88),
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Stand: August 2026',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colors.onSecondary.withValues(alpha: 0.78),
                    ),
              ),
              const SizedBox(height: 22),
              SearchBar(
                controller: controller,
                onChanged: onChanged,
                hintText: 'Handbuch durchsuchen …',
                leading: const Icon(Icons.search),
                trailing: query.isEmpty
                    ? null
                    : [
                        IconButton(
                          tooltip: 'Suche löschen',
                          onPressed: onClear,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                elevation: const WidgetStatePropertyAll(0),
                backgroundColor:
                    WidgetStatePropertyAll(colors.surfaceContainerLowest),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideSidebar extends StatelessWidget {
  final String? selectedCategory;
  final ValueChanged<String?> onSelected;

  const _GuideSidebar({
    required this.selectedCategory,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLowest,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 24, 14, 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Seitenhierarchie',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 10),
          _SidebarTile(
            icon: Icons.apps_outlined,
            label: 'Alle Anleitungen',
            selected: selectedCategory == null,
            onTap: () => onSelected(null),
          ),
          for (final category in _categories)
            _SidebarTile(
              icon: category.icon,
              label: category.name,
              count: _articles
                  .where((article) => article.category == category.name)
                  .length,
              selected: selectedCategory == category.name,
              onTap: () => onSelected(category.name),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 18),
            child: Divider(),
          ),
          Card(
            elevation: 0,
            color: colors.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lightbulb_outline,
                    color: colors.onPrimaryContainer,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Keine Antwort gefunden?',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Wenden Sie sich an Ihre Material- oder '
                    'Systemadministration.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          selected: selected,
          selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          leading: Icon(icon, size: 21),
          title: Text(label),
          trailing: count == null
              ? null
              : Text(
                  '$count',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _MobileCategorySelector extends StatelessWidget {
  final String? selectedCategory;
  final ValueChanged<String?> onSelected;

  const _MobileCategorySelector({
    required this.selectedCategory,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('Alle'),
              selected: selectedCategory == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final category in _categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: Icon(category.icon, size: 17),
                label: Text(category.name),
                selected: selectedCategory == category.name,
                onSelected: (_) => onSelected(category.name),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArticleCard extends StatelessWidget {
  final _GuideArticle article;
  final VoidCallback onTap;

  const _ArticleCard({required this.article, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(article.icon, color: colors.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      article.category,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: colors.secondary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      article.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      article.summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Icon(
                          Icons.schedule,
                          size: 15,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '${article.readingMinutes} Min. Lesedauer',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        const Spacer(),
                        const Icon(Icons.arrow_forward, size: 18),
                      ],
                    ),
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

class _ArticleView extends StatelessWidget {
  final _GuideArticle article;
  final VoidCallback onBack;

  const _ArticleView({required this.article, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton.icon(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Zurück zur Übersicht'),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            article.icon,
                            color: colors.onPrimaryContainer,
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            article.category,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: colors.secondary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      article.title,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      article.summary,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.45,
                          ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(Icons.schedule, size: 17),
                        const SizedBox(width: 6),
                        Text('${article.readingMinutes} Min. Lesedauer'),
                        const SizedBox(width: 18),
                        const Icon(Icons.verified_outlined, size: 17),
                        const SizedBox(width: 6),
                        const Text('MaterialKompass Handbuch'),
                      ],
                    ),
                    const SizedBox(height: 28),
                    _InfoCallout(
                      icon: Icons.info_outline,
                      title: 'Bevor Sie beginnen',
                      text: article.prerequisite,
                    ),
                    const SizedBox(height: 30),
                    Text(
                      'Schritt für Schritt',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    for (var index = 0; index < article.steps.length; index++)
                      _GuideStep(
                        number: index + 1,
                        text: article.steps[index],
                        isLast: index == article.steps.length - 1,
                      ),
                    if (article.tip != null) ...[
                      const SizedBox(height: 22),
                      _InfoCallout(
                        icon: Icons.lightbulb_outline,
                        title: 'Tipp',
                        text: article.tip!,
                        accent: colors.primaryContainer,
                      ),
                    ],
                    const SizedBox(height: 32),
                    const Divider(),
                    const SizedBox(height: 18),
                    Text(
                      'War diese Anleitung hilfreich?',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(
                            content: Text('Danke für Ihre Rückmeldung.'),
                          )),
                          icon: const Icon(Icons.thumb_up_outlined),
                          label: const Text('Ja'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(
                            content: Text(
                              'Hinweis notiert. Bitte wenden Sie sich bei '
                              'offenen Fragen an Ihre Administration.',
                            ),
                          )),
                          icon: const Icon(Icons.thumb_down_outlined),
                          label: const Text('Noch nicht'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GuideStep extends StatelessWidget {
  final int number;
  final String text;
  final bool isLast;

  const _GuideStep({
    required this.number,
    required this.text,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 42,
            child: Column(
              children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: colors.secondary,
                  foregroundColor: colors.onSecondary,
                  child: Text(
                    '$number',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      color: colors.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 22, top: 5),
              child: Text(
                text,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCallout extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final Color? accent;

  const _InfoCallout({
    required this.icon,
    required this.title,
    required this.text,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: accent ?? colors.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(text),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptySearchResult extends StatelessWidget {
  const _EmptySearchResult();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 54,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Keine passende Anleitung gefunden',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'Versuchen Sie einen allgemeineren Suchbegriff oder wählen Sie '
              'ein anderes Thema.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideCategory {
  final String name;
  final IconData icon;

  const _GuideCategory(this.name, this.icon);
}

class _GuideArticle {
  final String category;
  final String title;
  final String summary;
  final IconData icon;
  final int readingMinutes;
  final String prerequisite;
  final List<String> steps;
  final String? tip;
  final List<String> keywords;

  const _GuideArticle({
    required this.category,
    required this.title,
    required this.summary,
    required this.icon,
    required this.readingMinutes,
    required this.prerequisite,
    required this.steps,
    this.tip,
    this.keywords = const [],
  });

  String get searchText => [
        category,
        title,
        summary,
        prerequisite,
        ...steps,
        ...keywords,
      ].join(' ').toLowerCase();
}

const _categories = [
  _GuideCategory('Erste Schritte', Icons.rocket_launch_outlined),
  _GuideCategory('Inventar', Icons.inventory_2_outlined),
  _GuideCategory('Kleiderkammer', Icons.checkroom_outlined),
  _GuideCategory('Inventuren', Icons.fact_check_outlined),
  _GuideCategory('Beschaffung', Icons.shopping_cart_outlined),
  _GuideCategory('Mängel & Prüfungen', Icons.report_problem_outlined),
  _GuideCategory('Struktur & Lagerorte', Icons.warehouse_outlined),
  _GuideCategory('Konten & Rechte', Icons.manage_accounts_outlined),
];

const _articles = [
  _GuideArticle(
    category: 'Erste Schritte',
    title: 'Im MaterialKompass orientieren',
    summary:
        'Dashboard, Schnellzugriffe und persönliche Aufgaben auf einen Blick.',
    icon: Icons.explore_outlined,
    readingMinutes: 2,
    prerequisite: 'Sie benötigen ein aktives MaterialKompass-Konto.',
    steps: [
      'Melden Sie sich an. Das Dashboard zeigt nur Bereiche, für die Ihr Konto berechtigt ist.',
      'Öffnen Sie einen Bereich über die Kacheln unter „Schnellzugriff“.',
      'Prüfen Sie „Aufgaben & Hinweise“ auf fällige Prüfungen, offene Mängel oder Freigaben.',
      'Über das Kontosymbol oben rechts erreichen Sie Ihr Profil und Ihre Kontoeinstellungen.',
    ],
    tip:
        'Ziehen Sie die Seite auf einem Mobilgerät nach unten, um die Dashboard-Daten zu aktualisieren.',
    keywords: ['dashboard', 'navigation', 'anmelden', 'start'],
  ),
  _GuideArticle(
    category: 'Erste Schritte',
    title: 'QR-Code verwenden',
    summary:
        'Material per Kamera finden und unterstützte Anmeldevorgänge abschließen.',
    icon: Icons.qr_code_scanner,
    readingMinutes: 2,
    prerequisite:
        'Erlauben Sie den Kamerazugriff nur auf einem vertrauenswürdigen Gerät.',
    steps: [
      'Öffnen Sie im betreffenden Bereich die Aktion „Scannen“.',
      'Richten Sie die Kamera ruhig auf den vollständigen QR-Code.',
      'Prüfen Sie den gefundenen Datensatz, bevor Sie eine Ausgabe, Rückgabe oder Änderung bestätigen.',
    ],
    tip:
        'Bei schlechten Lichtverhältnissen funktioniert die Eingabe der Inventarnummer meist zuverlässiger.',
    keywords: ['scanner', 'kamera', 'inventarnummer', 'qr login'],
  ),
  _GuideArticle(
    category: 'Inventar',
    title: 'Material neu anlegen',
    summary:
        'Einzelartikel oder Mengenartikel vollständig im Bestand erfassen.',
    icon: Icons.add_box_outlined,
    readingMinutes: 4,
    prerequisite:
        'Sie benötigen Schreibrechte für das Inventar sowie eine passende Kategorie und einen Lagerplatz.',
    steps: [
      'Öffnen Sie „Inventar“ und wählen Sie „Material anlegen“.',
      'Tragen Sie Bezeichnung und Kategorie ein und wählen Sie den vollständigen Lagerplatz aus Ort, Regal, Ebene und Platz.',
      'Wählen Sie, ob es sich um einen einzeln verfolgten Artikel oder einen Mengenbestand handelt.',
      'Ergänzen Sie bei prüfpflichtigem Material das Prüfintervall und den nächsten Prüftermin.',
      'Kontrollieren Sie die Angaben und speichern Sie den Datensatz.',
    ],
    tip:
        'Verwenden Sie eindeutige Bezeichnungen und erfassen Sie Seriennummern bei sicherheitsrelevantem Material.',
    keywords: ['bestand', 'artikel', 'menge', 'seriennummer'],
  ),
  _GuideArticle(
    category: 'Inventar',
    title: 'Material ausgeben und zurücknehmen',
    summary:
        'Bestandsbewegungen nachvollziehbar einer Person oder Einheit zuordnen.',
    icon: Icons.swap_horiz,
    readingMinutes: 3,
    prerequisite:
        'Der Materialdatensatz muss vorhanden und als verfügbar geführt sein.',
    steps: [
      'Suchen oder scannen Sie den gewünschten Artikel.',
      'Öffnen Sie die Aktion zur Ausgabe beziehungsweise Rücknahme.',
      'Wählen Sie Empfänger, Menge und bei Bedarf einen Rückgabetermin.',
      'Prüfen Sie den Zustand und bestätigen Sie die Buchung.',
    ],
    tip:
        'Dokumentieren Sie Schäden direkt als Mangel, statt sie nur in einer Freitextnotiz zu erwähnen.',
    keywords: ['ausleihe', 'rückgabe', 'empfänger', 'buchung'],
  ),
  _GuideArticle(
    category: 'Kleiderkammer',
    title: 'Kleidung erfassen',
    summary:
        'Größen, Kategorien und Lagerbestand in der Kleiderkammer pflegen.',
    icon: Icons.checkroom,
    readingMinutes: 3,
    prerequisite: 'Die Kategorie muss für die Kleiderkammer aktiviert sein.',
    steps: [
      'Öffnen Sie „Kleiderkammer“ und wählen Sie „Neue Kleidung anlegen“.',
      'Wählen Sie Kategorie, Größe und Lagerplatz.',
      'Erfassen Sie die vorhandene Menge oder die Inventarnummer des Einzelstücks.',
      'Speichern Sie den Eintrag und prüfen Sie ihn anschließend in der Übersicht.',
    ],
    keywords: ['größe', 'uniform', 'bekleidung', 'bestand'],
  ),
  _GuideArticle(
    category: 'Kleiderkammer',
    title: 'Kleidung ausgeben oder zurücknehmen',
    summary: 'Bekleidung einer Person zuordnen und Rückgaben dokumentieren.',
    icon: Icons.assignment_ind_outlined,
    readingMinutes: 3,
    prerequisite: 'Person und Kleidungsstück müssen im System auffindbar sein.',
    steps: [
      'Wählen Sie „Ausgeben/Zurücknehmen“ in der Kleiderkammer.',
      'Suchen Sie nach Name, Inventarnummer, Größe oder Kategorie.',
      'Wählen Sie das Kleidungsstück und die betreffende Person.',
      'Bestätigen Sie Ausgabe oder Rücknahme und kontrollieren Sie den neuen Bestand.',
    ],
    keywords: ['person', 'uniform', 'ausgabe', 'rückgabe'],
  ),
  _GuideArticle(
    category: 'Inventuren',
    title: 'Inventur anlegen und vorbereiten',
    summary:
        'Bereiche, Zählmodus und Umfang einer digitalen oder papiergestützten Inventur festlegen.',
    icon: Icons.playlist_add_check_circle_outlined,
    readingMinutes: 4,
    prerequisite:
        'Sie benötigen das Recht, Inventuren anzulegen; Orte und Lagerplätze sollten vorher vollständig gepflegt sein.',
    steps: [
      'Öffnen Sie „Inventuren“ und wählen Sie „Inventur anlegen“.',
      'Vergeben Sie eine Bezeichnung, eine verantwortliche Person und ein Beginn-Datum.',
      'Wählen Sie „Digital“ oder „Papier/Offline“ sowie Blindzählung oder sichtbaren Sollbestand.',
      'Aktivieren Sie Inventar, Kleiderkammer oder beide Bereiche und grenzen Sie die Zählung bei Bedarf auf Orte, Lagerplätze und Fachbereiche ein.',
      'Prüfen Sie den Umfang und legen Sie die Inventur zunächst im Status „Angelegt“ an.',
    ],
    tip:
        'Ändern Sie Lagerstruktur und Inventurumfang vor dem Start; nachfolgende Statuswechsel schützen die Nachvollziehbarkeit.',
    keywords: [
      'bestandsaufnahme',
      'blindzählung',
      'papier',
      'offline',
      'umfang'
    ],
  ),
  _GuideArticle(
    category: 'Inventuren',
    title: 'Bestand zählen und nachzählen',
    summary:
        'Mengen, Einzelartikel, abweichende Lagerplätze und unbekannte Fundstücke erfassen.',
    icon: Icons.qr_code_scanner,
    readingMinutes: 5,
    prerequisite: 'Die Inventur muss gestartet und im Status „In Arbeit“ sein.',
    steps: [
      'Öffnen Sie die Inventur und starten Sie sie mit „Inventur starten“.',
      'Suchen Sie eine Position oder scannen Sie ihre Inventarnummer per Kamera beziehungsweise USB-Handscanner.',
      'Erfassen Sie bei Mengenartikeln die Ist-Menge; bewerten Sie Einzelartikel als vorhanden, beschädigt oder nicht vorhanden.',
      'Tragen Sie einen abweichenden gefundenen Ort oder Lagerplatz ein und ergänzen Sie bei Bedarf eine Notiz.',
      'Scannen Sie unbekannte Inventarnummern als Fundstück ein. Bereits gezählte Positionen können beliebig nachgezählt werden; der Verlauf bleibt erhalten.',
    ],
    tip:
        'Nutzen Sie den Filter „Offen“, um vor dem Ende der Zählung noch nicht bearbeitete Positionen zu finden.',
    keywords: [
      'ist-menge',
      'fundstück',
      'handscanner',
      'kamera',
      'abweichung',
      'nachzählung'
    ],
  ),
  _GuideArticle(
    category: 'Inventuren',
    title: 'Papierliste per E-Mail übernehmen',
    summary:
        'Zähllisten exportieren, dem Inventurpostfach zuordnen und kontrolliert übernehmen.',
    icon: Icons.mark_email_read_outlined,
    readingMinutes: 4,
    prerequisite:
        'Für den E-Mail-Import muss das Inventurpostfach eingerichtet sein; unterstützt werden PDF, JPG, PNG, XLSX und ODS.',
    steps: [
      'Erzeugen Sie über „Listen und Berichte“ eine leere Zählliste als PDF, XLSX oder ODS.',
      'Senden Sie die ausgefüllte Datei an inventur@materialkompass.org und nennen Sie die Inventur-ID im Betreff oder Dateinamen.',
      'Öffnen Sie „Eingescannte Listen“, prüfen Sie Absender und Originalanhang und ordnen Sie nicht eindeutig erkannte Nachrichten manuell zu.',
      'Übertragen Sie die geprüften Werte in die Inventur. Eine automatische Handschrift-OCR verändert den Bestand bewusst nicht.',
      'Verwerfen Sie unbrauchbare Nachrichten nur nach Prüfung; dabei wird die Original-E-Mail endgültig aus dem Postfach gelöscht.',
    ],
    tip:
        'Der importierte Anhang und das Protokoll bleiben in MaterialKompass erhalten, auch wenn die Original-E-Mail beim Abschluss der Inventur gelöscht wird.',
    keywords: [
      'inventur@materialkompass.org',
      'zählliste',
      'xlsx',
      'ods',
      'pdf',
      'postfach'
    ],
  ),
  _GuideArticle(
    category: 'Inventuren',
    title: 'Inventur auswerten und abschließen',
    summary:
        'Abweichungen prüfen, Folgevorgänge erzeugen und Korrekturen kontrolliert übernehmen.',
    icon: Icons.task_alt_outlined,
    readingMinutes: 4,
    prerequisite:
        'Alle erreichbaren Positionen sollten gezählt oder nachvollziehbar als offen dokumentiert sein.',
    steps: [
      'Wählen Sie „Auswertung starten“, um die Zählung zu beenden und Abweichungen festzuschreiben.',
      'Prüfen Sie die Ergebnis- oder Differenzliste; Fehlbestände und technische Schäden erzeugen nachvollziehbare Folge- beziehungsweise Mangelvorgänge.',
      'Entscheiden Sie beim Abschluss ausdrücklich, ob Bestands- und Standortkorrekturen übernommen werden sollen.',
      'Bestätigen Sie „Abschließen“. Die Inventur ist danach revisionssicher unveränderlich.',
      'Zugeordnete Original-E-Mails werden aus dem Postfach gelöscht; bei einer Störung versucht MaterialKompass die Löschung später erneut.',
    ],
    keywords: [
      'auswertung',
      'differenzliste',
      'korrektur',
      'abschließen',
      'fehlbestand'
    ],
  ),
  _GuideArticle(
    category: 'Beschaffung',
    title: 'Beschaffungsantrag erstellen',
    summary:
        'Bedarf mit Positionen, Budget und Begründung zur Freigabe einreichen.',
    icon: Icons.post_add_outlined,
    readingMinutes: 5,
    prerequisite:
        'Sie benötigen Schreibrechte im Bereich Beschaffung und ein begründetes Gesamtbudget.',
    steps: [
      'Öffnen Sie „Beschaffung“, wechseln Sie zu „Vorgänge“ und legen Sie einen neuen Antrag an.',
      'Formulieren Sie einen eindeutigen Titel und eine nachvollziehbare Begründung.',
      'Fügen Sie alle Positionen mit Bezeichnung, Kategorie, Menge, Einheit und Mehrwertsteuersatz hinzu. Einzelpreise werden im Antrag nicht erfasst.',
      'Tragen Sie das beantragte Bruttobudget und gegebenenfalls einen bevorzugten Lieferanten ein.',
      'Speichern Sie zunächst als Entwurf oder reichen Sie den vollständigen Antrag zur Freigabe ein.',
    ],
    tip:
        'Fassen Sie zusammengehörige Positionen in einem Antrag zusammen, damit Freigabe und Wareneingang übersichtlich bleiben.',
    keywords: ['antrag', 'budget', 'lieferant', 'freigabe', 'bestellung'],
  ),
  _GuideArticle(
    category: 'Beschaffung',
    title: 'Angebote aus der Postbox übernehmen',
    summary:
        'Eingegangene Angebots-E-Mails einem Vorgang und Lieferanten zuordnen.',
    icon: Icons.inbox_outlined,
    readingMinutes: 4,
    prerequisite:
        'Es werden ein offener Beschaffungsvorgang und ein aktiver Lieferant benötigt.',
    steps: [
      'Bitten Sie den Lieferanten, die Vorgangsnummer wie „BA-2026-0001“ in Betreff, Nachricht oder Dateiname zu schreiben und an angebote@materialkompass.org zu senden.',
      'Öffnen Sie in „Beschaffung“ den Reiter „Postbox“ und prüfen Sie Absender, erkannte Vorgangsnummer und Anhänge.',
      'Wählen Sie „Angebot übernehmen“, ordnen Sie Vorgang und Lieferant zu und ergänzen Sie Angebotsnummer, Bruttosumme, Datum und Lieferzeit.',
      'Kontrollieren Sie die Anhänge und bestätigen Sie die Übernahme. Der Lieferant wird anhand seiner hinterlegten Absenderadresse vorgeschlagen.',
      'Löschen Sie unbrauchbare E-Mails nur über „Verwerfen“; die Nachricht wird dann unwiderruflich aus MaterialKompass und dem Postfach entfernt.',
    ],
    tip:
        'Übernommene Angebotsdateien und Protokolldaten bleiben erhalten; die Original-E-Mails werden nach Abschluss des Vorgangs aus dem Postfach gelöscht.',
    keywords: [
      'angebote@materialkompass.org',
      'postbox',
      'imap',
      'angebotsvergleich',
      'verwerfen'
    ],
  ),
  _GuideArticle(
    category: 'Beschaffung',
    title: 'Freigeben, bestellen und Angebote vergleichen',
    summary:
        'Budgetentscheidung dokumentieren, ein Angebot auswählen und Bestellungen aufteilen.',
    icon: Icons.approval_outlined,
    readingMinutes: 5,
    prerequisite:
        'Der Antrag muss eingereicht sein; Freigaben dürfen Vorsitz oder Schatzmeister erteilen.',
    steps: [
      'Prüfen Sie Begründung, Positionen und beantragtes Bruttobudget und erteilen oder verweigern Sie die Freigabe mit nachvollziehbarer Notiz.',
      'Erfassen oder übernehmen Sie Angebote und vergleichen Sie Gesamtsumme, Lieferzeit und Gültigkeit.',
      'Wählen Sie das wirtschaftlich passende Angebot. Begründen Sie ausdrücklich, wenn nicht das günstigste gewählt wird.',
      'Legen Sie eine oder mehrere Bestellungen an und verteilen Sie die benötigten Mengen auf Lieferanten.',
      'Achten Sie darauf, dass das freigegebene Budget nicht überschritten wird.',
    ],
    keywords: [
      'vorsitz',
      'schatzmeister',
      'genehmigung',
      'angebotsvergleich',
      'teilbestellung'
    ],
  ),
  _GuideArticle(
    category: 'Beschaffung',
    title: 'Wareneingang buchen',
    summary: 'Gelieferte Positionen prüfen, erfassen und dem Bestand zuführen.',
    icon: Icons.move_to_inbox_outlined,
    readingMinutes: 4,
    prerequisite:
        'Die Bestellung muss ausgelöst sein und Sie benötigen Rechte für Wareneingänge.',
    steps: [
      'Öffnen Sie den bestellten Beschaffungsvorgang.',
      'Vergleichen Sie Lieferung, Lieferschein und bestellte Mengen.',
      'Erfassen Sie die tatsächlich eingegangenen Mengen sowie Abweichungen oder Schäden.',
      'Öffnen Sie „Prüfen & übernehmen“ und ordnen Sie inventarisierungspflichtige Artikel Kategorie und vollständigem Lagerplatz zu.',
      'Übernehmen Sie den Wareneingang erst nach der Kontrolle ins Inventar. Sind alle Lieferungen übernommen, wird der Vorgang abgeschlossen.',
    ],
    keywords: ['lieferung', 'eingang', 'bestellung', 'lager'],
  ),
  _GuideArticle(
    category: 'Mängel & Prüfungen',
    title: 'Mangel melden und bearbeiten',
    summary:
        'Schäden dokumentieren, Maßnahmen festlegen und den Status nachhalten.',
    icon: Icons.report_problem_outlined,
    readingMinutes: 4,
    prerequisite:
        'Halten Sie Inventarnummer, Schadensbild und möglichst aussagekräftige Fotos bereit.',
    steps: [
      'Öffnen Sie „Mängel“ und legen Sie eine neue Meldung an.',
      'Ordnen Sie betroffenes Material zu und beschreiben Sie den Schaden sachlich.',
      'Bewerten Sie die weitere Nutzbarkeit und sperren Sie unsicheres Material.',
      'Weisen Sie eine Maßnahme und eine zuständige Stelle zu.',
      'Dokumentieren Sie die Erledigung und schließen Sie den Mangel erst nach Kontrolle.',
    ],
    tip:
        'Sicherheitsrelevantes Material darf bis zur fachlichen Freigabe nicht weiter ausgegeben werden.',
    keywords: ['defekt', 'schaden', 'reparatur', 'sperren', 'maßnahme'],
  ),
  _GuideArticle(
    category: 'Mängel & Prüfungen',
    title: 'Mangel per E-Mail übernehmen',
    summary:
        'Eingesandte PDF- oder Bildberichte prüfen und daraus eine Mängelmeldung anlegen.',
    icon: Icons.forward_to_inbox_outlined,
    readingMinutes: 4,
    prerequisite:
        'Senden Sie einen PDF-, PNG- oder JPEG-Bericht an maengel@materialkompass.org; die Auswertung erfolgt lokal im Backend.',
    steps: [
      'Öffnen Sie die Liste der zu prüfenden E-Mail-Meldungen im Bereich „Mängel“.',
      'Kontrollieren Sie erkannte Inventarnummer, Kontaktdaten, Beschreibung, Maßnahmen und getrennte Schadensbilder am Originalbericht.',
      'Ergänzen oder korrigieren Sie unsichere Angaben und wählen Sie das betroffene Material.',
      'Wählen Sie „Mangel anlegen“. Der E-Mail-Text wird als Kommentar und die geprüften Bilder werden als Nachweise übernommen.',
      'Verwerfen Sie Spam oder unbrauchbare Meldungen nur nach Bestätigung; die Original-E-Mail wird dabei endgültig gelöscht.',
    ],
    tip:
        'Nutzen Sie nach Möglichkeit die leere oder vorbefüllte PDF-Vorlage aus der Anwendung, damit Angaben zuverlässig erkannt werden.',
    keywords: [
      'maengel@materialkompass.org',
      'ocr',
      'pdf-vorlage',
      'schadensbild',
      'postfach'
    ],
  ),
  _GuideArticle(
    category: 'Mängel & Prüfungen',
    title: 'Fällige Prüfung dokumentieren',
    summary:
        'Prüfergebnis erfassen und den nächsten Termin korrekt fortschreiben.',
    icon: Icons.fact_check_outlined,
    readingMinutes: 3,
    prerequisite:
        'Die Prüfung muss durch eine dafür qualifizierte Person erfolgen.',
    steps: [
      'Öffnen Sie den fälligen Materialdatensatz aus „Aufgaben & Hinweise“.',
      'Führen Sie die vorgeschriebene Prüfung außerhalb des Systems vollständig durch.',
      'Erfassen Sie Datum, Ergebnis und die prüfende Person.',
      'Legen Sie bei Beanstandungen einen Mangel an.',
      'Kontrollieren Sie den automatisch oder manuell gesetzten nächsten Prüftermin.',
    ],
    keywords: ['prüftermin', 'wartung', 'prüfung', 'frist'],
  ),
  _GuideArticle(
    category: 'Struktur & Lagerorte',
    title: 'Lagerstruktur anlegen und pflegen',
    summary:
        'Orte, Regale, Ebenen und Lagerplätze mit eindeutigen vollständigen Lagercodes abbilden.',
    icon: Icons.warehouse_outlined,
    readingMinutes: 3,
    prerequisite: 'Sie benötigen Verwaltungsrechte für Lagerorte.',
    steps: [
      'Öffnen Sie „Lagerstruktur“ und legen Sie einen Ort mit Name, vollständiger Anschrift, Kürzel und Typ an.',
      'Ergänzen Sie darunter in dieser Reihenfolge Regal, Ebene und Lagerplatz.',
      'Vergeben Sie auf jeder Stufe kurze Kürzel aus Buchstaben, Zahlen, „_“ oder „-“; MaterialKompass bildet daraus einen vollständigen Code wie „HL-A-01-01“.',
      'Zeigen oder drucken Sie bei Bedarf den Barcode eines Lagerplatzes und ordnen Sie anschließend Material oder Kleidung zu.',
      'Verschieben oder löschen Sie Strukturen nur nach Prüfung. Belegte oder in Inventuren verwendete Lagerplätze sind geschützt.',
    ],
    tip:
        'Ein einheitliches Schema „Ort – Regal – Ebene – Lagerplatz“ erleichtert Suche, Scan, Inventur und Übergabe.',
    keywords: [
      'standort',
      'anschrift',
      'regal',
      'ebene',
      'lagerplatz',
      'barcode',
      'lagercode'
    ],
  ),
  _GuideArticle(
    category: 'Struktur & Lagerorte',
    title: 'Kategorien sinnvoll strukturieren',
    summary:
        'Haupt- und Unterkategorien für konsistente Bestände und Berichte pflegen.',
    icon: Icons.account_tree_outlined,
    readingMinutes: 4,
    prerequisite:
        'Planen Sie die gewünschte Struktur, bevor Sie bestehende Kategorien verändern.',
    steps: [
      'Öffnen Sie „Kategorien“ und prüfen Sie vorhandene Hauptkategorien.',
      'Legen Sie neue Unterkategorien nur an, wenn sie dauerhaft zur Suche oder Auswertung benötigt werden.',
      'Aktivieren Sie bei Bekleidung die Nutzung in der Kleiderkammer und hinterlegen Sie passende Größen.',
      'Definieren Sie bei prüfpflichtigen Gruppen ein sinnvolles Prüfintervall.',
      'Prüfen Sie nach Änderungen stichprobenartig zugeordnete Datensätze.',
    ],
    keywords: ['kategorie', 'hauptkategorie', 'unterkategorie', 'größe'],
  ),
  _GuideArticle(
    category: 'Konten & Rechte',
    title: 'Nutzerkonto und Rollen verwalten',
    summary:
        'Konten anlegen und Zugriffe nach dem Prinzip der geringsten Rechte vergeben.',
    icon: Icons.manage_accounts_outlined,
    readingMinutes: 4,
    prerequisite:
        'Diese Funktion steht nur Konten mit Verwaltungsrechten zur Verfügung.',
    steps: [
      'Öffnen Sie die Nutzerverwaltung und legen Sie das Konto mit Name und eindeutiger E-Mail-Adresse an.',
      'Wählen Sie nur die Rollen, die für die tatsächlichen Aufgaben benötigt werden.',
      'Prüfen Sie die daraus resultierenden Bereichs- und Schreibrechte.',
      'Aktivieren Sie das Konto und informieren Sie die Person über den vorgesehenen Anmeldeweg.',
      'Deaktivieren Sie nicht mehr benötigte Konten zeitnah.',
    ],
    tip:
        'Vergeben Sie administrative Rechte nicht für die tägliche Arbeit, sondern nur für konkrete Verwaltungsaufgaben.',
    keywords: ['benutzer', 'rolle', 'berechtigung', 'admin', 'konto'],
  ),
];
