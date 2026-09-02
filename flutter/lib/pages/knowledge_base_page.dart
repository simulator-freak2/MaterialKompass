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
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _query.isEmpty
                                    ? '${_results.length} Beiträge zum Nachschlagen'
                                    : '${_results.length} Treffer für „$_query“',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
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
                'Wie können wir dir helfen?',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: colors.onSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Finde Antworten, Schritt-für-Schritt-Anleitungen und Tipps '
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
                backgroundColor: WidgetStatePropertyAll(
                  colors.surfaceContainerLowest,
                ),
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
                    'Wende dich an deine Material- oder '
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: Icon(icon, size: 21),
          title: Text(label),
          trailing: count == null
              ? null
              : Text('$count', style: Theme.of(context).textTheme.labelMedium),
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
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: colors.secondary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      article.title,
                      style: Theme.of(context).textTheme.headlineMedium
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
                        const Text('Stand 1.4.2'),
                        const SizedBox(width: 18),
                        const Icon(Icons.groups_outlined, size: 17),
                        const SizedBox(width: 6),
                        Flexible(child: Text(article.audience)),
                      ],
                    ),
                    const SizedBox(height: 28),
                    _InfoCallout(
                      icon: Icons.info_outline,
                      title: 'Bevor du beginnst',
                      text: article.prerequisite,
                    ),
                    const SizedBox(height: 30),
                    Text(
                      'Schritt für Schritt',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    for (
                      var index = 0;
                      index < article.steps.length;
                      index++
                    ) ...[
                      _GuideStep(
                        number: index + 1,
                        text: article.steps[index],
                        isLast: index == article.steps.length - 1,
                      ),
                      for (final illustration in article.illustrations.where(
                        (entry) => entry.afterStep == index + 1,
                      )) ...[
                        const SizedBox(height: 8),
                        _GuideIllustrationView(illustration: illustration),
                        const SizedBox(height: 24),
                      ],
                    ],
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
                          onPressed: () =>
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Danke für deine Rückmeldung.'),
                                ),
                              ),
                          icon: const Icon(Icons.thumb_up_outlined),
                          label: const Text('Ja'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () =>
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Hinweis notiert. Wende dich bei offenen Fragen '
                                    'an deine Administration.',
                                  ),
                                ),
                              ),
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
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(height: 1.5),
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
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
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

class _GuideIllustrationView extends StatelessWidget {
  final _GuideIllustration illustration;

  const _GuideIllustrationView({required this.illustration});

  void _showLarge(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(20),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 820),
          child: Stack(
            children: [
              InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Image.asset(
                  illustration.assetPath,
                  fit: BoxFit.contain,
                  semanticLabel: illustration.altText,
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filledTonal(
                  tooltip: 'Großansicht schließen',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      image: true,
      label: illustration.altText,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => _showLarge(context),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.asset(
                  illustration.assetPath,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  semanticLabel: illustration.altText,
                  errorBuilder: (context, error, stackTrace) => ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        size: 44,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.image_outlined,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      illustration.caption,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.zoom_in, size: 18),
                ],
              ),
            ),
          ],
        ),
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
              'Versuche einen allgemeineren Suchbegriff oder wähle ein '
              'anderes Thema.',
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
  final String audience;
  final String prerequisite;
  final List<String> steps;
  final String? tip;
  final List<String> keywords;
  final List<_GuideIllustration> illustrations;

  const _GuideArticle({
    required this.category,
    required this.title,
    required this.summary,
    required this.icon,
    required this.readingMinutes,
    required this.audience,
    required this.prerequisite,
    required this.steps,
    this.tip,
    this.keywords = const [],
    this.illustrations = const [],
  });

  String get searchText => [
    category,
    title,
    summary,
    audience,
    prerequisite,
    ...steps,
    ...keywords,
    ...illustrations.map((entry) => '${entry.caption} ${entry.altText}'),
  ].join(' ').toLowerCase();
}

class _GuideIllustration {
  final String assetPath;
  final String caption;
  final String altText;
  final int afterStep;

  const _GuideIllustration({
    required this.assetPath,
    required this.caption,
    required this.altText,
    required this.afterStep,
  });
}

const _categories = [
  _GuideCategory('Erste Schritte', Icons.rocket_launch_outlined),
  _GuideCategory('Inventar', Icons.inventory_2_outlined),
  _GuideCategory('Kleiderkammer', Icons.checkroom_outlined),
  _GuideCategory('Beschaffung', Icons.shopping_cart_outlined),
  _GuideCategory('Mängel & Prüfungen', Icons.report_problem_outlined),
  _GuideCategory('Struktur & Lagerorte', Icons.warehouse_outlined),
  _GuideCategory('Dienstgeräte & Offline', Icons.devices_outlined),
  _GuideCategory('Konten & Sicherheit', Icons.admin_panel_settings_outlined),
];

const _articles = [
  _GuideArticle(
    category: 'Erste Schritte',
    title: 'Im MaterialKompass orientieren',
    summary:
        'Dashboard, Schnellzugriffe, Aufgaben und deinen Account sicher finden.',
    icon: Icons.explore_outlined,
    readingMinutes: 3,
    audience: 'Für alle Rollen',
    prerequisite: 'Du benötigst ein aktives MaterialKompass-Konto.',
    steps: [
      'Melde dich an. Auf dem Dashboard erscheinen nur die Bereiche, für die dein Konto berechtigt ist.',
      'Öffne häufig verwendete Bereiche über die Kacheln unter „Schnellzugriff“.',
      'Prüfe „Aufgaben & Hinweise“ auf fällige Prüfungen, offene Mängel, Zuweisungen oder Freigaben.',
      'Über das Kontosymbol oben rechts erreichst du „Mein Account“, deine Sicherheitsfunktionen und Datenschutzoptionen.',
      'Nutze das Wolken-Symbol für den Offline-Status und die Synchronisation, wenn du eine installierte App verwendest.',
    ],
    tip:
        'Auf einem Mobilgerät kannst du die Seite nach unten ziehen, um die Dashboard-Daten zu aktualisieren.',
    keywords: ['dashboard', 'navigation', 'anmelden', 'start', 'aufgaben'],
    illustrations: [
      _GuideIllustration(
        assetPath: 'assets/handbook/dashboard_overview.png',
        caption:
            'Das Dashboard bündelt die freigeschalteten Bereiche und zeigt oben den Offline-Status sowie deinen Account.',
        altText:
            'Echtes MaterialKompass-Dashboard mit Schnellzugriffen auf Handbuch, Inventar, Kleiderkammer, Inventuren, Mängel, Beschaffung, Kategorien, Lagerorte und Nutzerverwaltung.',
        afterStep: 2,
      ),
    ],
  ),
  _GuideArticle(
    category: 'Erste Schritte',
    title: 'Auswahlfelder mit der Tastatur bedienen',
    summary:
        'Dropdown-Felder per Anfangsbuchstabe, Präfix und Pfeiltasten schneller auswählen.',
    icon: Icons.keyboard_alt_outlined,
    readingMinutes: 2,
    audience: 'Für alle Rollen mit einer Hardware-Tastatur',
    prerequisite:
        'Setze den Tastaturfokus per Tabulatortaste oder Mausklick auf das gewünschte Auswahlfeld.',
    steps: [
      'Ist die Liste geschlossen, tippe den Anfangsbuchstaben des sichtbaren Eintrags. Der erste passende Eintrag wird sofort übernommen.',
      'Tippe mehrere Zeichen zügig nacheinander, um nach einem genaueren Präfix zu suchen, zum Beispiel „mat“ für „Material“.',
      'Drücke denselben Anfangsbuchstaben wiederholt, um nacheinander durch alle passenden Einträge zu wechseln.',
      'Ist die Liste geöffnet, wird der Treffer zunächst nur hervorgehoben. Bestätige ihn mit Enter oder per Mausklick.',
      'Mit Pfeil hoch und Pfeil runter wechselst du in der geöffneten Liste zum vorherigen oder nächsten Eintrag. Pos1 und Ende springen an den Anfang oder das Ende.',
      'Groß- und Kleinschreibung werden gleich behandelt. A, O und U finden auch Einträge, die mit Ä, Ö oder Ü beginnen.',
    ],
    tip:
        'Gesucht wird nach dem sichtbaren Text. Beginnt ein Eintrag beispielsweise mit einer Inventarnummer, verwende deren erste Ziffer.',
    keywords: [
      'dropdown',
      'auswahlfeld',
      'tastatur',
      'anfangsbuchstabe',
      'präfix',
      'enter',
      'pfeiltasten',
      'barrierefreiheit',
    ],
  ),
  _GuideArticle(
    category: 'Erste Schritte',
    title: 'QR-Codes richtig verwenden',
    summary:
        'Material scannen und persönliche, System- oder Offline-Codes unterscheiden.',
    icon: Icons.qr_code_scanner,
    readingMinutes: 4,
    audience: 'Für alle Rollen',
    prerequisite:
        'Erlaube den Kamerazugriff nur auf einem vertrauenswürdigen Gerät.',
    steps: [
      'Nutze „Scannen“ im Inventar oder in der Kleiderkammer, um einen Artikel über Inventarnummer oder Barcode zu finden.',
      'Ein persönlicher Anmelde-QR-Code gehört zu deinem Konto und ersetzt nur den ersten Anmeldefaktor.',
      'Ein System-QR-Code öffnet ausschließlich den eingeschränkten Systemzugang eines aktivierten Dienstgeräts.',
      'Ein persönlicher Offline-QR-Code gilt nur für das dafür freigegebene Dienstgerät und höchstens sieben Tage.',
      'Prüfe nach jedem Scan den gefundenen Datensatz oder die angezeigte Anmeldeart, bevor du fortfährst.',
    ],
    tip:
        'Wenn die Kamera den Code nicht erkennt, gib die Inventarnummer manuell ein. Teile Anmelde-QR-Codes niemals als Foto.',
    keywords: [
      'scanner',
      'kamera',
      'inventarnummer',
      'barcode',
      'qr login',
      'system qr',
      'offline qr',
    ],
    illustrations: [
      _GuideIllustration(
        assetPath: 'assets/handbook/qr_login.png',
        caption:
            'Die Loginseite bietet die QR-Anmeldung zusätzlich zu Nutzername und Passwort an.',
        altText:
            'Loginansicht mit den Eingabefeldern für Nutzername und Passwort sowie der Schaltfläche Mit QR-Code anmelden.',
        afterStep: 2,
      ),
    ],
  ),
  _GuideArticle(
    category: 'Inventar',
    title: 'Material neu anlegen',
    summary:
        'Einzelartikel oder Mengenartikel vollständig im Bestand erfassen.',
    icon: Icons.add_box_outlined,
    readingMinutes: 4,
    audience: 'Für Materialverwaltung',
    prerequisite:
        'Du brauchst Schreibrechte für das Inventar sowie eine passende Kategorie und einen Lagerplatz.',
    steps: [
      'Öffne „Inventar“ und wähle „Material anlegen“.',
      'Trage eine eindeutige Bezeichnung ein und ordne Kategorie, Gebäude und bei Bedarf einen konkreten Lagerplatz zu.',
      'Lege fest, ob der Datensatz einen einzeln verfolgten Artikel oder einen Mengenbestand beschreibt.',
      'Ergänze Seriennummer, Anschaffungsdaten und Dokumente, wenn sie für Nachweis oder Wartung benötigt werden.',
      'Hinterlege bei prüfpflichtigem Material Prüfintervall und nächsten Prüftermin.',
      'Kontrolliere die Angaben und speichere den Datensatz.',
    ],
    tip:
        'Erfasse Seriennummern besonders bei sicherheitsrelevantem Material und vermeide austauschbare Bezeichnungen.',
    keywords: ['bestand', 'artikel', 'menge', 'seriennummer', 'prüfintervall'],
  ),
  _GuideArticle(
    category: 'Inventar',
    title: 'Material ausgeben und zurücknehmen',
    summary:
        'Bestandsbewegungen nachvollziehbar einer Person oder Einheit zuordnen.',
    icon: Icons.swap_horiz,
    readingMinutes: 3,
    audience: 'Für Materialverwaltung',
    prerequisite:
        'Der Materialdatensatz muss vorhanden und für die gewünschte Buchung verfügbar sein.',
    steps: [
      'Suche oder scanne den gewünschten Artikel.',
      'Öffne die Aktion zur Ausgabe beziehungsweise Rücknahme.',
      'Wähle Empfänger, Menge und bei Bedarf einen Rückgabetermin.',
      'Kontrolliere Zustand und Zuordnung und bestätige anschließend die Buchung.',
      'Melde einen erkannten Schaden direkt als Mangel. Defektes Material bleibt für neue Ausgaben gesperrt.',
    ],
    tip:
        'Offline erfasste Buchungen sind zunächst vorgemerkt. Prüfe nach der Synchronisation, ob ein Konflikt gemeldet wurde.',
    keywords: ['ausleihe', 'rückgabe', 'empfänger', 'buchung', 'offline'],
  ),
  _GuideArticle(
    category: 'Kleiderkammer',
    title: 'Kleidung erfassen',
    summary:
        'Größen, Kategorien und Lagerbestand in der Kleiderkammer pflegen.',
    icon: Icons.checkroom,
    readingMinutes: 3,
    audience: 'Für Kleiderkammer',
    prerequisite:
        'Die Kategorie muss für die Kleiderkammer aktiviert sein und passende Größen enthalten.',
    steps: [
      'Öffne „Kleiderkammer“ und wähle „Neue Kleidung anlegen“.',
      'Wähle Kategorie, Größe, Gebäude und Lagerplatz.',
      'Erfasse die vorhandene Menge oder die Inventarnummer eines Einzelstücks.',
      'Ergänze bei Bedarf Beschaffungs- und Zustandsangaben.',
      'Speichere den Eintrag und kontrolliere ihn anschließend in der Übersicht.',
    ],
    keywords: ['größe', 'uniform', 'bekleidung', 'bestand', 'kleiderkammer'],
  ),
  _GuideArticle(
    category: 'Kleiderkammer',
    title: 'Kleidung ausgeben oder zurücknehmen',
    summary: 'Bekleidung einer Person zuordnen und Rückgaben dokumentieren.',
    icon: Icons.assignment_ind_outlined,
    readingMinutes: 3,
    audience: 'Für Kleiderkammer',
    prerequisite: 'Person und Kleidungsstück müssen im System auffindbar sein.',
    steps: [
      'Öffne in der Kleiderkammer „Ausgeben/Zurücknehmen“.',
      'Suche nach Name, Inventarnummer, Größe oder Kategorie.',
      'Wähle das Kleidungsstück und die betreffende Person.',
      'Prüfe Menge und Zustand und bestätige Ausgabe oder Rücknahme.',
      'Kontrolliere den neuen Bestand. Offline vorgemerkte Änderungen werden beim nächsten Serverkontakt synchronisiert.',
    ],
    tip:
        'Lege bei beschädigter Kleidung direkt einen Mangel an, damit Ausgabe und weitere Bearbeitung nachvollziehbar bleiben.',
    keywords: ['person', 'uniform', 'ausgabe', 'rückgabe', 'offline'],
  ),
  _GuideArticle(
    category: 'Beschaffung',
    title: 'Beschaffungsantrag erstellen',
    summary:
        'Bedarf mit Positionen, Bruttobudget und Begründung zur Freigabe einreichen.',
    icon: Icons.post_add_outlined,
    readingMinutes: 5,
    audience: 'Für Beschaffung',
    prerequisite:
        'Du brauchst Schreibrechte im Bereich Beschaffung und möglichst bereits Vergleichspreise.',
    steps: [
      'Öffne „Beschaffung“, wechsle zu „Vorgänge“ und lege einen neuen Antrag an.',
      'Formuliere einen eindeutigen Titel und eine nachvollziehbare Begründung.',
      'Füge alle Positionen mit Menge und allgemeiner Kategorie hinzu. Einzelpreise gehören nicht in den Antrag.',
      'Trage das beantragte Bruttobudget und gegebenenfalls einen bevorzugten Lieferanten ein.',
      'Speichere zunächst als Entwurf oder reiche den vollständigen Antrag zur Freigabe durch Vorsitz beziehungsweise Schatzmeister ein.',
    ],
    tip:
        'Fasse zusammengehörige Positionen in einem Antrag zusammen, damit Freigabe, Bestellung und Wareneingang übersichtlich bleiben.',
    keywords: ['antrag', 'budget', 'lieferant', 'freigabe', 'bestellung'],
  ),
  _GuideArticle(
    category: 'Beschaffung',
    title: 'Lieferant und EU-Adresse erfassen',
    summary:
        'Strukturierte Adressen mit Vorschlägen erfassen und vollständig prüfen.',
    icon: Icons.local_shipping_outlined,
    readingMinutes: 3,
    audience: 'Für Beschaffung und Lagerverwaltung',
    prerequisite:
        'Du brauchst Schreibrechte für den betreffenden Lieferanten oder das Gebäude.',
    steps: [
      'Öffne die Eingabemaske für einen Lieferanten oder ein Gebäude und wähle das Land.',
      'Gib mindestens drei Zeichen einer Adresse ein. Nach kurzer Verzögerung erscheinen passende EU-Adressvorschläge.',
      'Wähle den passenden Vorschlag, um Straße, Postleitzahl, Ort und Land zu übernehmen.',
      'Trage die Hausnummer bewusst selbst ein und korrigiere übernommene Felder bei Bedarf.',
      'Ohne Vorschläge oder bei einer unterbrochenen Verbindung füllst du alle Adressfelder manuell aus.',
    ],
    tip:
        'Die Suche überträgt nur eingegebene Adressbestandteile, keine Lieferanten- oder Kontaktdaten.',
    keywords: [
      'adresse',
      'geoapify',
      'straße',
      'postleitzahl',
      'lieferant',
      'gebäude',
    ],
  ),
  _GuideArticle(
    category: 'Beschaffung',
    title: 'Wareneingang buchen',
    summary:
        'Lieferungen prüfen, Abweichungen erfassen und Bestand übernehmen.',
    icon: Icons.move_to_inbox_outlined,
    readingMinutes: 4,
    audience: 'Für Beschaffung und Materialverwaltung',
    prerequisite:
        'Die Bestellung muss ausgelöst sein und du brauchst Rechte für Wareneingänge.',
    steps: [
      'Öffne den bestellten Beschaffungsvorgang.',
      'Vergleiche Lieferung, Lieferschein und bestellte Mengen.',
      'Erfasse tatsächlich eingegangene Mengen sowie Abweichungen oder Schäden. Teil- und Mehrfachlieferungen bleiben im Vorgang sichtbar.',
      'Ordne inventarisierungspflichtige Artikel einer Kategorie, einem Gebäude und bei Bedarf einem Lagerplatz zu.',
      'Übernimm geprüfte Positionen in den Bestand und schließe den Wareneingang erst nach vollständiger Kontrolle ab.',
    ],
    keywords: ['lieferung', 'eingang', 'bestellung', 'lager', 'beanstandung'],
  ),
  _GuideArticle(
    category: 'Mängel & Prüfungen',
    title: 'Mangel melden und bearbeiten',
    summary:
        'Schäden mit Bildern dokumentieren, bewerten und bis zum Abschluss nachhalten.',
    icon: Icons.report_problem_outlined,
    readingMinutes: 5,
    audience: 'Für alle berechtigten Rollen',
    prerequisite:
        'Halte Inventarnummer, Schadensbild und möglichst aussagekräftige JPEG- oder PNG-Bilder bereit.',
    steps: [
      'Öffne „Mängel“ und wähle „Mangel melden“ oder starte die Meldung direkt am betroffenen Artikel.',
      'Ordne Material oder Kleidung zu und beschreibe Schaden, Ursache und bereits getroffene Maßnahmen sachlich.',
      'Bewerte Gefährdung und Einsatzbereitschaft. Unsicheres Material wird für neue Ausgaben gesperrt.',
      'Ergänze bei Bedarf bis zu zehn Bilder, eine zuständige Person, einen Fachbereich und eine Frist.',
      'Führe die Meldung über die Statusfolge „Neu“, „In Prüfung“, „Zugewiesen“, „In Bearbeitung“, „Behoben“ bis „Geprüft/Geschlossen“.',
      'Dokumentiere Entscheidungen in Kommentaren, Checklisten, Folgeaufgaben und dem Änderungsverlauf.',
    ],
    tip:
        'Sicherheitsrelevantes Material darf bis zur fachlichen Prüfung und Freigabe nicht erneut ausgegeben werden.',
    keywords: [
      'defekt',
      'schaden',
      'reparatur',
      'sperren',
      'maßnahme',
      'bilder',
    ],
    illustrations: [
      _GuideIllustration(
        assetPath: 'assets/handbook/defect_workflow.png',
        caption:
            'Die echte Erfassungsmaske bündelt Artikelbezug, Beschreibung, Einstufung, Zuständigkeit und Kontaktangaben.',
        altText:
            'Geöffnete MaterialKompass-Maske Mangel melden mit beispielhaft ausgefülltem Titel, Beschreibung und Schadensart sowie Feldern für Priorität, Gefährdung und Zuständigkeit.',
        afterStep: 5,
      ),
    ],
  ),
  _GuideArticle(
    category: 'Mängel & Prüfungen',
    title: 'Mangel zuweisen und Frist verfolgen',
    summary:
        'Meldungen einem Konto oder einer externen Person verbindlich zuordnen.',
    icon: Icons.assignment_ind_outlined,
    readingMinutes: 3,
    audience: 'Für Mängelbearbeitung',
    prerequisite:
        'Du brauchst Bearbeitungsrechte für den betroffenen Fachbereich.',
    steps: [
      'Öffne die Mängelmeldung und wähle „Mir zuweisen“ oder „Zuweisung & Frist“.',
      'Wähle „Nutzerkonto“, wenn die verantwortliche Person ein aktives und berechtigtes Konto besitzt.',
      'Wähle andernfalls „Externe Person“ und trage den Namen eindeutig ein.',
      'Setze eine realistische Frist und speichere die Zuweisung.',
      'Konto-Zuweisungen erzeugen eine In-App-Benachrichtigung und lassen sich über „Mir zugewiesen“ filtern.',
    ],
    tip:
        'Hebe eine Zuweisung auf oder ändere sie, sobald sich die Verantwortung ändert; der Verlauf bleibt nachvollziehbar.',
    keywords: [
      'zuweisung',
      'verantwortlich',
      'frist',
      'mir zugewiesen',
      'benachrichtigung',
    ],
  ),
  _GuideArticle(
    category: 'Mängel & Prüfungen',
    title: 'Material aussondern und Ersatz anstoßen',
    summary:
        'Defektes Material revisionssicher entfernen – mit oder ohne Ersatzbeschaffung.',
    icon: Icons.delete_sweep_outlined,
    readingMinutes: 4,
    audience: 'Für Mängelbearbeitung und Beschaffung',
    prerequisite:
        'Die Aussonderungsentscheidung muss fachlich geklärt und dokumentiert sein.',
    steps: [
      'Öffne die betroffene Mängelmeldung und das Menü „Weitere Aktionen“.',
      'Wähle „Aussondern ohne Ersatz“, wenn keine Nachbeschaffung nötig ist.',
      'Wähle „Aussondern & Ersatz beschaffen“, um zusätzlich einen vorbefüllten Beschaffungsentwurf anzulegen.',
      'Prüfe Menge, Begründung und Verknüpfungen, bevor du die Aktion bestätigst.',
      'Bei vollständiger Aussonderung wird die Inventarnummer revisionssicher freigegeben und später bevorzugt wiederverwendet; bei einer Teilmenge bleibt sie belegt.',
    ],
    tip:
        'Bearbeite den erzeugten Beschaffungsentwurf vollständig, bevor du ihn zur Freigabe einreichst.',
    keywords: [
      'aussondern',
      'ersatz',
      'beschaffungsentwurf',
      'inventarnummer',
      'teilmenge',
    ],
  ),
  _GuideArticle(
    category: 'Mängel & Prüfungen',
    title: 'Fällige Prüfung dokumentieren',
    summary:
        'Prüfergebnis erfassen und den nächsten Termin korrekt fortschreiben.',
    icon: Icons.fact_check_outlined,
    readingMinutes: 3,
    audience: 'Für qualifizierte Prüfende',
    prerequisite:
        'Die fachliche Prüfung muss durch eine dafür qualifizierte Person erfolgen.',
    steps: [
      'Öffne den fälligen Datensatz über „Aufgaben & Hinweise“ oder den betreffenden Bestandsbereich.',
      'Führe die vorgeschriebene Prüfung außerhalb des Systems vollständig durch.',
      'Erfasse Datum, Ergebnis und prüfende Person.',
      'Bei einer fehlgeschlagenen Prüfung wird automatisch ein Mangel erzeugt.',
      'Kontrolliere den automatisch oder manuell gesetzten nächsten Prüftermin.',
    ],
    keywords: ['prüftermin', 'wartung', 'prüfung', 'frist', 'mangel'],
  ),
  _GuideArticle(
    category: 'Struktur & Lagerorte',
    title: 'Gebäude und Lagerstruktur anlegen',
    summary: 'Gebäude, Regale, Ebenen und Lagerplätze eindeutig strukturieren.',
    icon: Icons.warehouse_outlined,
    readingMinutes: 4,
    audience: 'Für Lagerverwaltung',
    prerequisite: 'Du brauchst Verwaltungsrechte für Lagerorte.',
    steps: [
      'Öffne „Lagerorte“ und lege zunächst das Gebäude mit vollständiger Adresse an.',
      'Ergänze darunter Regale, anschließend Ebenen und zuletzt die konkreten Lagerplätze.',
      'Verwende auf jeder Ebene kurze Kürzel, die innerhalb des übergeordneten Elements eindeutig sind.',
      'Nutze für gleichförmige Lager „Lagerstruktur automatisch anlegen“ und prüfe die Vorschau vor dem Speichern.',
      'Ordne vorhandenes Material dem Gebäude und bei Bedarf einem konkreten Lagerplatz zu.',
    ],
    tip:
        'Der erzeugte Pfad „Gebäude / Regal / Ebene / Lagerplatz“ bleibt auch nach dem Verschieben eines Elements nachvollziehbar.',
    keywords: [
      'gebäude',
      'adresse',
      'regal',
      'ebene',
      'lagerplatz',
      'massenerstellung',
    ],
    illustrations: [
      _GuideIllustration(
        assetPath: 'assets/handbook/storage_structure.png',
        caption:
            'Die Hierarchie führt vom Gebäude über Regal und Ebene bis zum Lagerplatz.',
        altText:
            'Lagerorte-Ansicht mit einem Beispielgebäude und einer aufgeklappten Hierarchie aus Regal, Ebene und Lagerplatz.',
        afterStep: 2,
      ),
    ],
  ),
  _GuideArticle(
    category: 'Struktur & Lagerorte',
    title: 'Kategorien sinnvoll strukturieren',
    summary:
        'Haupt- und Unterkategorien für konsistente Bestände und Berichte pflegen.',
    icon: Icons.account_tree_outlined,
    readingMinutes: 4,
    audience: 'Für Material- und Lagerverwaltung',
    prerequisite:
        'Plane die gewünschte Struktur, bevor du bestehende Kategorien veränderst.',
    steps: [
      'Öffne „Kategorien“ und prüfe die vorhandenen Hauptkategorien.',
      'Lege Unterkategorien nur an, wenn du sie dauerhaft für Suche, Rechte oder Auswertungen brauchst.',
      'Aktiviere bei Bekleidung die Nutzung in der Kleiderkammer und hinterlege die zulässigen Größen.',
      'Definiere bei prüfpflichtigen Gruppen ein fachlich sinnvolles Prüfintervall.',
      'Prüfe nach Änderungen stichprobenartig die zugeordneten Datensätze.',
    ],
    keywords: [
      'kategorie',
      'hauptkategorie',
      'unterkategorie',
      'größe',
      'prüfintervall',
    ],
  ),
  _GuideArticle(
    category: 'Dienstgeräte & Offline',
    title: 'Dienstgerät anlegen und aktivieren',
    summary:
        'Ein verwaltetes Gerät vorbereiten, absichern und einmalig aktivieren.',
    icon: Icons.add_to_home_screen_outlined,
    readingMinutes: 6,
    audience: 'Für Admins',
    prerequisite:
        'Du brauchst Adminrechte und einen nativen Windows-, Linux-, macOS-, Android- oder iOS-Client. Webbrowser lassen sich nicht als Dienstgerät aktivieren.',
    steps: [
      'Öffne „Nutzerverwaltung“ und den Bereich „Dienstgeräte“.',
      'Wähle „Gerät anlegen“ und erfasse Standort, Halle oder Raum, Geräte-Inventarnummer, verantwortliche Person und Fachbereiche.',
      'Lege ein eigenes Gerätepasswort fest. Eine MAC-Adresse dient nur der Dokumentation und ist kein Sicherheitsmerkmal.',
      'Konfiguriere bei Bedarf erlaubte IP-Adressen beziehungsweise IPv4-/IPv6-Netze sowie einen zusätzlichen TOTP- oder NFC-Faktor.',
      'Öffne am Zielgerät die normale Loginseite und führe die einmalige Aktivierung als Admin durch.',
      'Kontrolliere anschließend den Status in der Geräteverwaltung. Sperren oder ein Schlüsselreset beenden bestehende Gerätesitzungen sofort.',
    ],
    tip:
        'Bewahre das Gerätepasswort getrennt vom Gerät auf und erlaube nur die tatsächlich benötigten Fachbereiche.',
    keywords: [
      'dienstgerät',
      'aktivierung',
      'gerätepasswort',
      'mac adresse',
      'ip netz',
      'admin',
    ],
    illustrations: [
      _GuideIllustration(
        assetPath: 'assets/handbook/service_devices.png',
        caption:
            'Im echten Register „Dienstgeräte“ siehst du Aktivierungs- und Freigabestatus und erreichst Offline-Installationen sowie die Geräteanlage.',
        altText:
            'MaterialKompass-Nutzerverwaltung im Register Dienstgeräte mit einem aktivierten Beispielgerät und den Schaltflächen Offline-Installationen und Gerät anlegen.',
        afterStep: 4,
      ),
    ],
  ),
  _GuideArticle(
    category: 'Dienstgeräte & Offline',
    title: 'Am Dienstgerät anmelden',
    summary:
        'Systemzugang und persönliche Sitzung sicher voneinander unterscheiden.',
    icon: Icons.login_outlined,
    readingMinutes: 5,
    audience: 'Für Dienstgeräte-Nutzer',
    prerequisite: 'Das Gerät muss aktiviert und darf nicht gesperrt sein.',
    steps: [
      'Wähle den Systemzugang für eine redigierte Materialsuche und das Erstellen oder Öffnen einer einzelnen Mängelmeldung.',
      'Melde dich am Systemzugang mit Gerätepasswort oder einem aktiven System-QR-Code an und bestätige einen verlangten Gerätefaktor.',
      'Wähle eine persönliche Anmeldung, wenn du deine normalen Rollen und Fachrechte brauchst.',
      'Nutze dafür Passwort, persönlichen QR-Code oder eine am Gerät registrierte USB-NFC-Karte und bestätige anschließend gegebenenfalls deine Konto-2-FA.',
      'Beende die Sitzung nach der Arbeit. Der Systemzugang läuft nach fünf Minuten ab und löscht anschließend Kontakte, Bilder, Suchergebnisse und temporäre Dokumente.',
    ],
    tip:
        'Der Code einer Dienstgeräte-Mängelmeldung öffnet nur genau diese Meldung und ersetzt keine persönliche Anmeldung.',
    keywords: [
      'systemzugang',
      'persönliche anmeldung',
      'gerätepasswort',
      'nfc',
      'totp',
      'mängelcode',
    ],
    illustrations: [
      _GuideIllustration(
        assetPath: 'assets/handbook/service_device_login.png',
        caption:
            'Die aufgeklappte Geräteverwaltung zeigt die verfügbaren Anmeldewege und Faktoren wie System-QR-Code, NFC, Offline-QR-Code und TOTP.',
        altText:
            'Aufgeklapptes Beispielgerät in der MaterialKompass-Dienstgeräteverwaltung mit Aktionen für System-QR-Code, NFC-Karten, Offline-QR-Code, TOTP, Aktivierungsreset und Sperrung.',
        afterStep: 1,
      ),
    ],
  ),
  _GuideArticle(
    category: 'Dienstgeräte & Offline',
    title: 'Offlinebetrieb vorbereiten',
    summary:
        'Gerät, Konto und Standorte für verschlüsseltes Arbeiten ohne Verbindung freigeben.',
    icon: Icons.cloud_off_outlined,
    readingMinutes: 5,
    audience: 'Für Admins und mobile Nutzer',
    prerequisite:
        'Offline-Schreibbetrieb ist nur in installierten Apps möglich. Dein Konto benötigt eingerichtete 2-FA und innerhalb der letzten 365 Tage eine vollständige 2-FA-Anmeldung.',
    steps: [
      'Ein Admin aktiviert den Offlinebetrieb am Dienstgerät und erlaubt die benötigten Nutzerkonten.',
      'Falls erforderlich, stellt der Admin einen persönlichen Offline-QR-Code aus. Er gilt nur für dieses Gerät und höchstens sieben Tage.',
      'Melde dich einmal online vollständig an, damit die App eine verschlüsselte Offlinefreigabe und einen berechtigungsabhängigen Snapshot anlegen kann.',
      'Öffne die Offline-Einstellungen am Dashboard und wähle nur die lokal benötigten Standorte.',
      'Lege fest, ob Mobilfunk verwendet werden darf und ab welcher Dateigröße nur über WLAN oder LAN synchronisiert wird.',
    ],
    tip:
        'Normale native Installationen werden als widerrufbare Offline-Installation registriert. Ein Gerätewiderruf wird beim nächsten Serverkontakt wirksam.',
    keywords: [
      'offlinefreigabe',
      'snapshot',
      'standorte',
      'mobilfunk',
      'offline qr',
      '365 tage',
    ],
  ),
  _GuideArticle(
    category: 'Dienstgeräte & Offline',
    title: 'Offline arbeiten und synchronisieren',
    summary:
        'Buchungen vormerken, Übertragung prüfen und Konflikte sicher behandeln.',
    icon: Icons.sync_outlined,
    readingMinutes: 6,
    audience: 'Für mobile Material- und Kleiderkammerrollen',
    prerequisite:
        'Ein aktueller Offline-Snapshot und eine gültige Offlinefreigabe müssen auf dem Gerät vorhanden sein.',
    steps: [
      'Ohne Verbindung kannst du Material, Kleidung und offene Mängel suchen oder scannen.',
      'Ausgaben, Rücknahmen, Umbuchungen und neue textbasierte Mängelmeldungen werden lokal vorgemerkt. Bilder und sonstige Anhänge lassen sich nicht offline vormerken.',
      'Das Wolken-Symbol im Dashboard zeigt die Anzahl ausstehender Änderungen. Öffne es für Details oder eine manuelle Synchronisation.',
      'Sobald die API erreichbar ist, überträgt die App jede Änderung sicher wiederholbar. Ein erneuter Versuch erzeugt keine Doppelbuchung.',
      'Prüfe abgelehnte Änderungen einzeln. Fachliche Konflikte bleiben sichtbar, bis du sie geklärt oder ausdrücklich verworfen hast.',
      'Eine Abmeldung mit offenen Änderungen wird blockiert. Verwirf Änderungen nur, wenn sie wirklich nicht mehr übertragen werden sollen.',
    ],
    tip:
        'Nicht erneuerte Snapshots und abgelaufene Offline-Anmeldungen werden nach spätestens 30 Tagen bereinigt; offene Fachbuchungen bleiben bis zur Synchronisation oder zum bestätigten Verwerfen erhalten.',
    keywords: [
      'offline',
      'synchronisation',
      'konflikt',
      'warteschlange',
      'doppelbuchung',
      'wolke',
    ],
    illustrations: [
      _GuideIllustration(
        assetPath: 'assets/handbook/offline_sync.png',
        caption:
            'Der echte Synchronisationsdialog zeigt den aktuellen Übertragungsstand und bietet eine manuelle Synchronisation an.',
        altText:
            'MaterialKompass-Dashboard mit geöffnetem Dialog Offline-Synchronisation, dem Hinweis dass alle Änderungen synchronisiert wurden und der Schaltfläche Jetzt synchronisieren.',
        afterStep: 3,
      ),
    ],
  ),
  _GuideArticle(
    category: 'Konten & Sicherheit',
    title: 'Passkey einrichten und verwenden',
    summary:
        'Passwortlos und phishing-resistent mit Gerätesperre, Biometrie oder Sicherheitsschlüssel anmelden.',
    icon: Icons.key_outlined,
    readingMinutes: 5,
    audience: 'Für alle persönlichen Konten',
    prerequisite:
        'Du benötigst ein unterstütztes Gerät mit eingerichteter Gerätesperre oder einen FIDO2-Sicherheitsschlüssel.',
    steps: [
      'Öffne auf dem Dashboard „Mein Account“ und den Abschnitt „Passkeys“.',
      'Wähle „Passkey hinzufügen“, vergib einen verständlichen Gerätenamen und bestätige dein aktuelles Passwort. Ist 2-FA aktiv, gib zusätzlich einen 2-FA- oder Wiederherstellungscode ein.',
      'Bestätige die Einrichtung mit Windows Hello, Touch ID, Face ID, Geräte-PIN oder deinem Sicherheitsschlüssel. MaterialKompass erhält nur den öffentlichen Schlüssel.',
      'Wähle bei der nächsten Anmeldung „Mit Passkey anmelden“ und bestätige die lokale Geräteabfrage. Nutzername, Passwort und ein zusätzlicher 2-FA-Code sind dabei nicht nötig.',
      'Benenne Passkeys unter „Mein Account“ eindeutig und widerrufe verlorene oder nicht mehr verwendete Geräte sofort. Nach Hinzufügen oder Widerruf meldest du dich erneut an.',
      'Wenn kein Passkey mehr verfügbar ist, nutze Passwort und gegebenenfalls 2-FA oder den E-Mail-Passwortreset. Bei verpflichtender starker Anmeldung kann ein Admin nach Identitätsprüfung alle Passkeys zurücksetzen.',
    ],
    tip:
        'Richte möglichst einen zweiten Passkey oder Sicherheitsschlüssel als Reserve ein und behalte Wiederherstellungscodes getrennt vom Hauptgerät. Linux unterstützt im aktuellen Client nur Passwort und optional 2-FA.',
    keywords: [
      'passkey',
      'webauthn',
      'windows hello',
      'touch id',
      'face id',
      'sicherheitsschlüssel',
      'phishing',
    ],
  ),
  _GuideArticle(
    category: 'Konten & Sicherheit',
    title: 'Zwei-Faktor-Authentifizierung einrichten',
    summary:
        'Dein Konto mit einer Authenticator-App und Wiederherstellungscodes absichern.',
    icon: Icons.phonelink_lock_outlined,
    readingMinutes: 5,
    audience: 'Für alle persönlichen Konten',
    prerequisite:
        'Installiere eine vertrauenswürdige Authenticator-App und halte einen sicheren Ort für die Wiederherstellungscodes bereit.',
    steps: [
      'Öffne auf dem Dashboard „Mein Account“ und den Abschnitt „Zwei-Faktor-Authentifizierung“.',
      'Wähle „2-FA einrichten“ und übernimm den angezeigten Schlüssel in deine Authenticator-App.',
      'Gib den aktuellen sechsstelligen Code ein und aktiviere 2-FA.',
      'Sichere die zehn einmal verwendbaren Wiederherstellungscodes. Diese Codes werden nur bei der Erstellung vollständig angezeigt.',
      'Bei späteren Anmeldungen bestätigst du nach Passwort, QR-Code oder Dienstgeräte-Anmeldung zusätzlich den kurzlebigen 2-FA-Code.',
      'Erzeuge bei Bedarf neue Recovery-Codes; alle alten Codes werden dadurch ungültig.',
    ],
    tip:
        'Speichere Authenticator-Schlüssel und Wiederherstellungscodes nicht gemeinsam auf demselben Gerät.',
    keywords: [
      '2fa',
      'mfa',
      'totp',
      'authenticator',
      'recovery codes',
      'wiederherstellungscodes',
    ],
    illustrations: [
      _GuideIllustration(
        assetPath: 'assets/handbook/two_factor_authentication.png',
        caption:
            'Unter „Mein Account“ startest du die 2-FA-Einrichtung und verwaltest außerdem deine persönlichen Anmelde-QR-Codes.',
        altText:
            'Echter MaterialKompass-Accountbereich mit dem Abschnitt Zwei-Faktor-Authentifizierung, der Schaltfläche 2-FA einrichten und dem Abschnitt QR-Anmeldung.',
        afterStep: 1,
      ),
    ],
  ),
  _GuideArticle(
    category: 'Konten & Sicherheit',
    title: 'Starke Anmeldung und Wiederherstellung verwalten',
    summary:
        'Passkey oder 2-FA pro Konto verpflichten, Einrichtungsfristen verstehen und Zugänge zurücksetzen.',
    icon: Icons.security_outlined,
    readingMinutes: 5,
    audience: 'Für Admins',
    prerequisite: 'Du brauchst Verwaltungsrechte für Nutzerkonten.',
    steps: [
      'Öffne die Nutzerverwaltung und bearbeite das gewünschte Konto.',
      'Aktiviere „Starke Anmeldung verpflichtend“, wenn das Konto künftig einen Passkey oder 2-FA verwenden muss.',
      'Hat die Person weder Passkey noch 2-FA eingerichtet, beginnt eine Einrichtungsfrist von 14 Tagen. Danach ist nur noch eine eingeschränkte Anmeldung zur Einrichtung möglich.',
      'Nutze „2-FA zurücksetzen“ nur nach sicherer Identitätsprüfung. Der Reset entfernt die Einrichtung und beendet bestehende Sitzungen.',
      'Nutze „Alle Passkeys widerrufen“ ebenfalls nur nach sicherer Identitätsprüfung. Informiere die betroffene Person, damit sie den vorgesehenen starken Anmeldeweg neu einrichtet.',
    ],
    tip:
        'Ein administrativer Reset ersetzt keine Identitätsprüfung und wird zusammen mit Richtlinienänderungen im System protokolliert.',
    keywords: [
      '2fa pflicht',
      'passkey pflicht',
      'starke anmeldung',
      '14 tage',
      'reset',
      'admin',
      'eingeschränktes login',
    ],
  ),
  _GuideArticle(
    category: 'Konten & Sicherheit',
    title: 'Nutzerkonto, Rollen und Fachbereiche verwalten',
    summary:
        'Konten anlegen und Zugriffe nach dem Prinzip der geringsten Rechte vergeben.',
    icon: Icons.manage_accounts_outlined,
    readingMinutes: 5,
    audience: 'Für Admins',
    prerequisite:
        'Diese Funktionen stehen nur Konten mit Verwaltungsrechten zur Verfügung.',
    steps: [
      'Öffne die Nutzerverwaltung und lege das Konto mit Name, Nutzername und eindeutiger E-Mail-Adresse an.',
      'Wähle nur die Rollen, die für die tatsächlichen Aufgaben benötigt werden.',
      'Ordne bei Bedarf geleitete Fachbereiche zu und prüfe die daraus entstehenden Bereichs- und Schreibrechte.',
      'Lege fest, ob eine starke Anmeldung per Passkey oder 2-FA verpflichtend ist, und aktiviere das Konto.',
      'Informiere die Person über den vorgesehenen Anmeldeweg. Persönliche QR-Codes verwaltet sie unter „Mein Account“ oder ein Admin in der Nutzerverwaltung.',
      'Deaktiviere nicht mehr benötigte Konten zeitnah und lösche sie nur unter Beachtung der Aufbewahrungsregeln.',
    ],
    tip:
        'Vergib administrative Rechte nur für konkrete Verwaltungsaufgaben und nutze sie nicht als Standardrolle für die tägliche Arbeit.',
    keywords: [
      'benutzer',
      'rolle',
      'berechtigung',
      'admin',
      'konto',
      'fachbereich',
    ],
  ),
];
