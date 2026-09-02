import 'dart:async';

import 'package:flutter/material.dart' hide DropdownButtonFormField;
import 'package:flutter/services.dart';

import '../services/address_lookup_service.dart';
import 'keyboard_dropdown_button_form_field.dart';

export '../services/address_lookup_service.dart'
    show
        AddressLookupResult,
        AddressLocalityLoader,
        AddressLocalityResult,
        AddressSuggestion,
        AddressSuggestionLoader,
        euCountryCodeFor;

class AddressInput extends StatefulWidget {
  final String token;
  final TextEditingController streetController;
  final TextEditingController houseNumberController;
  final TextEditingController postalCodeController;
  final TextEditingController cityController;
  final TextEditingController countryController;
  final AddressSuggestionLoader? suggestionLoader;
  final AddressLocalityLoader? localityLoader;
  final ValueChanged<AddressSuggestion>? onSuggestionSelected;

  const AddressInput({
    required this.token,
    required this.streetController,
    required this.houseNumberController,
    required this.postalCodeController,
    required this.cityController,
    required this.countryController,
    this.suggestionLoader,
    this.localityLoader,
    this.onSuggestionSelected,
    super.key,
  });

  @override
  State<AddressInput> createState() => _AddressInputState();
}

class _AddressInputState extends State<AddressInput> {
  static const _searchDelay = Duration(milliseconds: 450);
  static const _defaultMessage =
      'Ab drei Zeichen werden passende EU-Adressen vorgeschlagen. Adresssuche über Geoapify.';
  static const _unsupportedMessage =
      'Die automatische Suche ist auf EU-Länder begrenzt. Die Adresse kann manuell eingegeben werden.';
  static const _unavailableMessage =
      'Die automatische Adresssuche ist momentan nicht verfügbar. Alle Felder bleiben manuell ausfüllbar.';

  static final List<DropdownMenuItem<String>> _standardCountryItems =
      List.unmodifiable(
        euCountryOptions.map(
          (country) => DropdownMenuItem(
            value: country,
            child: Text(country, overflow: TextOverflow.ellipsis),
          ),
        ),
      );

  Timer? _debounce;
  late List<TextEditingController> _searchControllers;
  late AddressSuggestionLoader _loadAddressSuggestions;
  late AddressLocalityLoader _loadLocalities;
  List<AddressSuggestion> _suggestions = const [];
  List<String> _localitySuggestions = const [];
  final List<FocusNode> _fieldFocusNodes = List.generate(
    4,
    (index) => FocusNode(debugLabel: 'address-field-$index'),
  );
  final ScrollController _suggestionScrollController = ScrollController();
  bool _loading = false;
  bool _applyingSuggestion = false;
  int _requestGeneration = 0;
  int _highlightedIndex = -1;
  String? _message;

  List<TextEditingController> _controllersFor(AddressInput input) => [
    input.streetController,
    input.houseNumberController,
    input.postalCodeController,
    input.cityController,
    input.countryController,
  ];

  @override
  void initState() {
    super.initState();
    _searchControllers = _controllersFor(widget);
    _addControllerListeners();
    _configureLoaders();
  }

  @override
  void didUpdateWidget(covariant AddressInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextControllers = _controllersFor(widget);
    var controllersChanged = false;
    for (var index = 0; index < nextControllers.length; index += 1) {
      if (!identical(nextControllers[index], _searchControllers[index])) {
        controllersChanged = true;
        break;
      }
    }
    if (controllersChanged) {
      _removeControllerListeners();
      _searchControllers = nextControllers;
      _addControllerListeners();
      _cancelPendingSearch();
      _suggestions = const [];
      _localitySuggestions = const [];
      _highlightedIndex = -1;
      _message = null;
    }
    if (oldWidget.token != widget.token ||
        oldWidget.suggestionLoader != widget.suggestionLoader ||
        oldWidget.localityLoader != widget.localityLoader) {
      _configureLoaders();
    }
  }

  @override
  void dispose() {
    _cancelPendingSearch();
    _removeControllerListeners();
    for (final focusNode in _fieldFocusNodes) {
      focusNode.dispose();
    }
    _suggestionScrollController.dispose();
    super.dispose();
  }

  void _addControllerListeners() {
    for (final controller in _searchControllers) {
      controller.addListener(_scheduleLookup);
    }
  }

  void _removeControllerListeners() {
    for (final controller in _searchControllers) {
      controller.removeListener(_scheduleLookup);
    }
  }

  void _configureLoaders() {
    final service = AddressLookupService(widget.token);
    _loadAddressSuggestions = widget.suggestionLoader ?? service.load;
    _loadLocalities = widget.localityLoader ?? service.loadLocalities;
  }

  void _cancelPendingSearch() {
    _debounce?.cancel();
    _requestGeneration += 1;
  }

  ({String query, String country, bool hasEnoughInput}) _currentQuery() {
    final street = widget.streetController.text.trim();
    final houseNumber = widget.houseNumberController.text.trim();
    final postalCode = widget.postalCodeController.text.trim();
    final city = widget.cityController.text.trim();
    final country = widget.countryController.text.trim();
    return (
      query: [
        street,
        houseNumber,
        postalCode,
        city,
        country,
      ].where((value) => value.isNotEmpty).join(' '),
      country: country,
      hasEnoughInput: street.length >= 3 || city.length >= 3,
    );
  }

  void _scheduleLookup() {
    if (_applyingSuggestion) return;
    _cancelPendingSearch();
    final query = _currentQuery();
    if (query.country.isNotEmpty && euCountryCodeFor(query.country) == null) {
      _showIdleState(message: _unsupportedMessage);
      return;
    }
    final generation = _requestGeneration;
    final postalCode = widget.postalCodeController.text.trim();
    final city = widget.cityController.text.trim();
    if (!query.hasEnoughInput &&
        city.isEmpty &&
        postalCode.length >= 3 &&
        query.country.isNotEmpty) {
      _debounce = Timer(
        _searchDelay,
        () => _loadLocalitySuggestions(generation, postalCode, query.country),
      );
      return;
    }
    if (!query.hasEnoughInput) {
      _showIdleState();
      return;
    }
    _debounce = Timer(
      _searchDelay,
      () => _loadSuggestions(generation, query.query, query.country),
    );
  }

  void _showIdleState({String? message}) {
    if (_suggestions.isEmpty &&
        _localitySuggestions.isEmpty &&
        !_loading &&
        _message == message) {
      return;
    }
    setState(() {
      _suggestions = const [];
      _localitySuggestions = const [];
      _loading = false;
      _highlightedIndex = -1;
      _message = message;
    });
  }

  Future<void> _loadSuggestions(
    int generation,
    String query,
    String country,
  ) async {
    if (!mounted || generation != _requestGeneration) return;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final result = await _loadAddressSuggestions(query, country);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loading = false;
        _suggestions = result.suggestions;
        _localitySuggestions = const [];
        _highlightedIndex = result.suggestions.isEmpty ? -1 : 0;
        _message = _messageFor(result);
      });
      _resetSuggestionScroll();
    } catch (_) {
      if (!mounted || generation != _requestGeneration) return;
      _showIdleState(message: _unavailableMessage);
    }
  }

  Future<void> _loadLocalitySuggestions(
    int generation,
    String postalCode,
    String country,
  ) async {
    if (!mounted || generation != _requestGeneration) return;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final result = await _loadLocalities(postalCode, country);
      if (!mounted ||
          generation != _requestGeneration ||
          widget.postalCodeController.text.trim() != postalCode ||
          widget.countryController.text.trim() != country ||
          widget.cityController.text.trim().isNotEmpty) {
        return;
      }
      if (result.suggestions.length == 1) {
        _selectLocality(result.suggestions.single, automatic: true);
        return;
      }
      setState(() {
        _loading = false;
        _suggestions = const [];
        _localitySuggestions = result.suggestions;
        _highlightedIndex = result.suggestions.isEmpty ? -1 : 0;
        _message = _messageForLocalities(result);
      });
      _resetSuggestionScroll();
    } catch (_) {
      if (!mounted || generation != _requestGeneration) return;
      _showIdleState(message: _unavailableMessage);
    }
  }

  String? _messageFor(AddressLookupResult result) {
    if (!result.configured) {
      return 'Die automatische Adresssuche ist nicht konfiguriert. Alle Felder bleiben manuell ausfüllbar.';
    }
    if (!result.supported) return _unsupportedMessage;
    if (result.suggestions.isEmpty) {
      return 'Keine passende Adresse gefunden. Die Eingabe kann manuell fortgesetzt werden.';
    }
    return null;
  }

  String? _messageForLocalities(AddressLocalityResult result) {
    if (!result.configured) {
      return 'Die automatische Ortssuche ist nicht konfiguriert. Der Ort bleibt manuell ausfüllbar.';
    }
    if (!result.supported) return _unsupportedMessage;
    if (result.suggestions.isEmpty) {
      return 'Kein eindeutiger Ort zu dieser Postleitzahl gefunden. Der Ort kann manuell eingegeben werden.';
    }
    return 'Mehrere Orte gefunden. Bitte einen Ort auswählen.';
  }

  void _selectSuggestion(AddressSuggestion suggestion) {
    _cancelPendingSearch();
    _applyingSuggestion = true;
    widget.streetController.text = suggestion.street;
    if (suggestion.houseNumber.isNotEmpty) {
      widget.houseNumberController.text = suggestion.houseNumber;
    }
    widget.postalCodeController.text = suggestion.postalCode;
    widget.cityController.text = suggestion.city;
    widget.countryController.text =
        euCountryNames[suggestion.countryCode] ?? suggestion.country;
    _applyingSuggestion = false;
    setState(() {
      _suggestions = const [];
      _localitySuggestions = const [];
      _loading = false;
      _highlightedIndex = -1;
      _message = suggestion.houseNumber.isEmpty
          ? 'Adresse übernommen. Die eingegebene Hausnummer bleibt erhalten.'
          : 'Adresse einschließlich Hausnummer übernommen.';
    });
    widget.onSuggestionSelected?.call(suggestion);
  }

  void _selectLocality(String locality, {bool automatic = false}) {
    _cancelPendingSearch();
    _applyingSuggestion = true;
    widget.cityController.text = locality;
    _applyingSuggestion = false;
    setState(() {
      _suggestions = const [];
      _localitySuggestions = const [];
      _loading = false;
      _highlightedIndex = -1;
      _message = automatic
          ? 'Ort aus der Postleitzahl übernommen.'
          : 'Ort übernommen.';
    });
  }

  int get _visibleSuggestionCount => _suggestions.isNotEmpty
      ? _suggestions.length
      : _localitySuggestions.length;

  void _resetSuggestionScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _suggestionScrollController.hasClients) {
        _suggestionScrollController.jumpTo(0);
      }
    });
  }

  void _moveHighlight(int delta) {
    final count = _visibleSuggestionCount;
    if (count == 0) return;
    final current = _highlightedIndex < 0
        ? (delta > 0 ? -1 : 0)
        : _highlightedIndex;
    setState(() {
      _highlightedIndex = (current + delta) % count;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_suggestionScrollController.hasClients) return;
      final target = (_highlightedIndex * 64.0).clamp(
        0.0,
        _suggestionScrollController.position.maxScrollExtent,
      );
      _suggestionScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    });
  }

  void _selectHighlighted() {
    final index = _highlightedIndex;
    if (index < 0 || index >= _visibleSuggestionCount) return;
    if (_suggestions.isNotEmpty) {
      _selectSuggestion(_suggestions[index]);
    } else {
      _selectLocality(_localitySuggestions[index]);
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (!_fieldFocusNodes.any((node) => node.hasFocus) ||
        _visibleSuggestionCount == 0 ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && event is KeyDownEvent) {
      _selectHighlighted();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        event is KeyDownEvent) {
      _showIdleState();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _field(
    TextEditingController controller,
    FocusNode focusNode,
    String label,
    double width,
  ) => SizedBox(
    width: width,
    child: TextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: TextInputType.streetAddress,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  List<DropdownMenuItem<String>> _countryItems(String selectedCountry) {
    if (selectedCountry.isEmpty || euCountryOptions.contains(selectedCountry)) {
      return _standardCountryItems;
    }
    return [
      ..._standardCountryItems,
      DropdownMenuItem(
        value: selectedCountry,
        child: Text(selectedCountry, overflow: TextOverflow.ellipsis),
      ),
    ];
  }

  Widget _buildFields(double Function(double) width) {
    final selectedCountry = widget.countryController.text.trim();
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _field(
          widget.streetController,
          _fieldFocusNodes[0],
          'Straße *',
          width(430),
        ),
        _field(
          widget.houseNumberController,
          _fieldFocusNodes[1],
          'Hausnummer *',
          width(158),
        ),
        _field(
          widget.postalCodeController,
          _fieldFocusNodes[2],
          'Postleitzahl *',
          width(180),
        ),
        _field(widget.cityController, _fieldFocusNodes[3], 'Ort *', width(408)),
        SizedBox(
          width: width(300),
          child: DropdownButtonFormField<String>(
            key: ValueKey(selectedCountry),
            initialValue: selectedCountry.isEmpty ? null : selectedCountry,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Land *',
              border: OutlineInputBorder(),
            ),
            items: _countryItems(selectedCountry),
            onChanged: (value) {
              if (value == null) return;
              widget.countryController.text = value;
              setState(() {});
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatus(BuildContext context) => Row(
    children: [
      if (_loading) ...[
        const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
      ],
      Expanded(
        child: Text(
          _message ?? _defaultMessage,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );

  Widget _buildSuggestionList(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 8),
    constraints: const BoxConstraints(maxHeight: 220),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(8),
    ),
    child: ListView.separated(
      controller: _suggestionScrollController,
      shrinkWrap: true,
      itemCount: _visibleSuggestionCount,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (_suggestions.isEmpty) {
          final locality = _localitySuggestions[index];
          return ListTile(
            dense: true,
            selected: index == _highlightedIndex,
            selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
            leading: const Icon(Icons.location_city_outlined),
            title: Text(locality),
            subtitle: Text(
              'Ort für ${widget.postalCodeController.text.trim()} übernehmen',
            ),
            onTap: () => _selectLocality(locality),
          );
        }
        final suggestion = _suggestions[index];
        return ListTile(
          dense: true,
          selected: index == _highlightedIndex,
          selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
          leading: const Icon(Icons.location_on_outlined),
          title: Text(suggestion.label),
          subtitle: Text(
            suggestion.houseNumber.isEmpty
                ? 'Eingegebene Hausnummer bleibt erhalten'
                : 'Hausnummer wird übernommen',
          ),
          onTap: () => _selectSuggestion(suggestion),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: _handleKeyEvent,
    child: LayoutBuilder(
      builder: (context, constraints) {
        double boundedWidth(double preferred) =>
            constraints.maxWidth.isFinite && preferred > constraints.maxWidth
            ? constraints.maxWidth
            : preferred;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFields(boundedWidth),
            const SizedBox(height: 8),
            _buildStatus(context),
            if (_visibleSuggestionCount > 0) _buildSuggestionList(context),
          ],
        );
      },
    ),
  );
}
