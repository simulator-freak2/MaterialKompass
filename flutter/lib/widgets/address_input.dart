import 'dart:async';

import 'package:flutter/material.dart';

import '../services/address_lookup_service.dart';

export '../services/address_lookup_service.dart'
    show
        AddressLookupResult,
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
  final ValueChanged<AddressSuggestion>? onSuggestionSelected;

  const AddressInput({
    required this.token,
    required this.streetController,
    required this.houseNumberController,
    required this.postalCodeController,
    required this.cityController,
    required this.countryController,
    this.suggestionLoader,
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
      List.unmodifiable(euCountryOptions.map(
    (country) => DropdownMenuItem(
      value: country,
      child: Text(country, overflow: TextOverflow.ellipsis),
    ),
  ));

  Timer? _debounce;
  late List<TextEditingController> _searchControllers;
  late AddressSuggestionLoader _loadAddressSuggestions;
  List<AddressSuggestion> _suggestions = const [];
  bool _loading = false;
  bool _applyingSuggestion = false;
  int _requestGeneration = 0;
  String? _message;

  List<TextEditingController> _controllersFor(AddressInput input) => [
        input.streetController,
        input.postalCodeController,
        input.cityController,
        input.countryController,
      ];

  @override
  void initState() {
    super.initState();
    _searchControllers = _controllersFor(widget);
    _addControllerListeners();
    _configureLoader();
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
      _message = null;
    }
    if (oldWidget.token != widget.token ||
        oldWidget.suggestionLoader != widget.suggestionLoader) {
      _configureLoader();
    }
  }

  @override
  void dispose() {
    _cancelPendingSearch();
    _removeControllerListeners();
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

  void _configureLoader() {
    _loadAddressSuggestions =
        widget.suggestionLoader ?? AddressLookupService(widget.token).load;
  }

  void _cancelPendingSearch() {
    _debounce?.cancel();
    _requestGeneration += 1;
  }

  ({String query, String country, bool hasEnoughInput}) _currentQuery() {
    final street = widget.streetController.text.trim();
    final postalCode = widget.postalCodeController.text.trim();
    final city = widget.cityController.text.trim();
    final country = widget.countryController.text.trim();
    return (
      query: [street, postalCode, city, country]
          .where((value) => value.isNotEmpty)
          .join(' '),
      country: country,
      hasEnoughInput:
          street.length >= 3 || postalCode.length >= 3 || city.length >= 3,
    );
  }

  void _scheduleLookup() {
    if (_applyingSuggestion) return;
    _cancelPendingSearch();
    final query = _currentQuery();
    if (!query.hasEnoughInput) {
      _showIdleState();
      return;
    }
    if (query.country.isNotEmpty && euCountryCodeFor(query.country) == null) {
      _showIdleState(message: _unsupportedMessage);
      return;
    }
    final generation = _requestGeneration;
    _debounce = Timer(
      _searchDelay,
      () => _loadSuggestions(generation, query.query, query.country),
    );
  }

  void _showIdleState({String? message}) {
    if (_suggestions.isEmpty && !_loading && _message == message) return;
    setState(() {
      _suggestions = const [];
      _loading = false;
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
        _message = _messageFor(result);
      });
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

  void _selectSuggestion(AddressSuggestion suggestion) {
    _cancelPendingSearch();
    _applyingSuggestion = true;
    widget.streetController.text = suggestion.street;
    widget.postalCodeController.text = suggestion.postalCode;
    widget.cityController.text = suggestion.city;
    widget.countryController.text =
        euCountryNames[suggestion.countryCode] ?? suggestion.country;
    _applyingSuggestion = false;
    setState(() {
      _suggestions = const [];
      _loading = false;
      _message = 'Adresse übernommen. Die Hausnummer bitte manuell eingeben.';
    });
    widget.onSuggestionSelected?.call(suggestion);
  }

  Widget _field(
    TextEditingController controller,
    String label,
    double width,
  ) =>
      SizedBox(
        width: width,
        child: TextField(
          controller: controller,
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
        _field(widget.streetController, 'Straße *', width(430)),
        _field(widget.houseNumberController, 'Hausnummer *', width(158)),
        _field(widget.postalCodeController, 'Postleitzahl *', width(180)),
        _field(widget.cityController, 'Ort *', width(408)),
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
          shrinkWrap: true,
          itemCount: _suggestions.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final suggestion = _suggestions[index];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.location_on_outlined),
              title: Text(suggestion.label),
              subtitle: const Text('Hausnummer wird manuell ergänzt'),
              onTap: () => _selectSuggestion(suggestion),
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
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
              if (_suggestions.isNotEmpty) _buildSuggestionList(context),
            ],
          );
        },
      );
}
