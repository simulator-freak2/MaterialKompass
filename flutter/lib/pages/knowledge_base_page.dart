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
      'Tragen Sie Bezeichnung, Kategorie und Lagerort ein.',
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
    category: 'Beschaffung',
    title: 'Beschaffungsantrag erstellen',
    summary:
        'Bedarf mit Positionen, Budget und Begründung zur Freigabe einreichen.',
    icon: Icons.post_add_outlined,
    readingMinutes: 5,
    prerequisite:
        'Sie benötigen Schreibrechte im Bereich Beschaffung und möglichst bereits Vergleichspreise.',
    steps: [
      'Öffnen Sie „Beschaffung“, wechseln Sie zu „Vorgänge“ und legen Sie einen neuen Antrag an.',
      'Formulieren Sie einen eindeutigen Titel und eine nachvollziehbare Begründung.',
      'Fügen Sie alle Positionen mit Menge, Kategorie und geschätztem Preis hinzu.',
      'Tragen Sie das beantragte Bruttobudget und gegebenenfalls einen bevorzugten Lieferanten ein.',
      'Speichern Sie zunächst als Entwurf oder reichen Sie den vollständigen Antrag zur Freigabe ein.',
    ],
    tip:
        'Fassen Sie zusammengehörige Positionen in einem Antrag zusammen, damit Freigabe und Wareneingang übersichtlich bleiben.',
    keywords: ['antrag', 'budget', 'lieferant', 'freigabe', 'bestellung'],
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
      'Ordnen Sie inventarisierungspflichtige Artikel Kategorie und Lagerort zu.',
      'Schließen Sie den Wareneingang erst ab, wenn alle Angaben geprüft sind.',
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
    title: 'Lagerort und Lagerplatz anlegen',
    summary: 'Die physische Lagerstruktur eindeutig und auffindbar abbilden.',
    icon: Icons.warehouse_outlined,
    readingMinutes: 3,
    prerequisite: 'Sie benötigen Verwaltungsrechte für Lagerorte.',
    steps: [
      'Öffnen Sie „Lagerorte“ und legen Sie zunächst den übergeordneten Standort an.',
      'Ergänzen Sie darunter eindeutig benannte Lagerplätze wie Raum, Regal und Fach.',
      'Verwenden Sie kurze Codes, die auch vor Ort auf Beschriftungen passen.',
      'Speichern Sie die Struktur und ordnen Sie anschließend vorhandenes Material zu.',
    ],
    tip:
        'Ein einheitliches Schema wie „Raum – Regal – Fach“ erleichtert Suche, Inventur und Übergabe.',
    keywords: ['standort', 'raum', 'regal', 'fach', 'lager'],
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
