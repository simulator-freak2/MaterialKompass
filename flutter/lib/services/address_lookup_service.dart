import 'dart:collection';
import 'dart:convert';

import '../constants.dart';
import 'app_http_client.dart';

const Map<String, String> euCountryNames = {
  'at': 'Österreich',
  'be': 'Belgien',
  'bg': 'Bulgarien',
  'hr': 'Kroatien',
  'cy': 'Zypern',
  'cz': 'Tschechien',
  'dk': 'Dänemark',
  'ee': 'Estland',
  'fi': 'Finnland',
  'fr': 'Frankreich',
  'de': 'Deutschland',
  'gr': 'Griechenland',
  'hu': 'Ungarn',
  'ie': 'Irland',
  'it': 'Italien',
  'lv': 'Lettland',
  'lt': 'Litauen',
  'lu': 'Luxemburg',
  'mt': 'Malta',
  'nl': 'Niederlande',
  'pl': 'Polen',
  'pt': 'Portugal',
  'ro': 'Rumänien',
  'sk': 'Slowakei',
  'si': 'Slowenien',
  'es': 'Spanien',
  'se': 'Schweden',
};

const Map<String, String> _countryAliases = {
  'austria': 'at',
  'belgium': 'be',
  'bulgaria': 'bg',
  'croatia': 'hr',
  'cyprus': 'cy',
  'czechia': 'cz',
  'czech republic': 'cz',
  'denmark': 'dk',
  'estonia': 'ee',
  'finland': 'fi',
  'france': 'fr',
  'germany': 'de',
  'greece': 'gr',
  'hungary': 'hu',
  'ireland': 'ie',
  'italy': 'it',
  'latvia': 'lv',
  'lithuania': 'lt',
  'luxembourg': 'lu',
  'malta': 'mt',
  'netherlands': 'nl',
  'poland': 'pl',
  'portugal': 'pt',
  'romania': 'ro',
  'slovakia': 'sk',
  'slovenia': 'si',
  'spain': 'es',
  'sweden': 'se',
};

String _normalizeCountry(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll('ä', 'a')
    .replaceAll('ö', 'o')
    .replaceAll('ü', 'u')
    .replaceAll('ß', 'ss');

final Map<String, String> _countryCodesByName = Map.unmodifiable({
  for (final entry in euCountryNames.entries)
    _normalizeCountry(entry.value): entry.key,
  ..._countryAliases,
});

final List<String> euCountryOptions = List.unmodifiable(
  euCountryNames.values.toList()..sort((left, right) => left.compareTo(right)),
);

String? euCountryCodeFor(String value) {
  final normalized = _normalizeCountry(value);
  return euCountryNames.containsKey(normalized)
      ? normalized
      : _countryCodesByName[normalized];
}

class AddressSuggestion {
  final String id;
  final String label;
  final String street;
  final String houseNumber;
  final String postalCode;
  final String city;
  final String country;
  final String countryCode;

  const AddressSuggestion({
    required this.id,
    required this.label,
    required this.street,
    this.houseNumber = '',
    required this.postalCode,
    required this.city,
    required this.country,
    required this.countryCode,
  });

  factory AddressSuggestion.fromJson(Map<String, dynamic> json) =>
      AddressSuggestion(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        street: json['street']?.toString() ?? '',
        houseNumber: json['houseNumber']?.toString() ?? '',
        postalCode: json['postalCode']?.toString() ?? '',
        city: json['city']?.toString() ?? '',
        country: json['country']?.toString() ?? '',
        countryCode: json['countryCode']?.toString() ?? '',
      );

  bool get isComplete =>
      street.isNotEmpty &&
      postalCode.isNotEmpty &&
      city.isNotEmpty &&
      country.isNotEmpty;
}

class AddressLookupResult {
  final bool configured;
  final bool supported;
  final List<AddressSuggestion> suggestions;

  const AddressLookupResult({
    required this.configured,
    required this.supported,
    required this.suggestions,
  });
}

class AddressLocalityResult {
  final bool configured;
  final bool supported;
  final List<String> suggestions;

  const AddressLocalityResult({
    required this.configured,
    required this.supported,
    required this.suggestions,
  });
}

typedef AddressSuggestionLoader =
    Future<AddressLookupResult> Function(String query, String country);

typedef AddressLocalityLoader =
    Future<AddressLocalityResult> Function(String postalCode, String country);

class AddressLookupService {
  static const _cacheLimit = 30;

  final String token;
  final LinkedHashMap<String, AddressLookupResult> _cache = LinkedHashMap();
  final Map<String, Future<AddressLookupResult>> _pending = {};
  final LinkedHashMap<String, AddressLocalityResult> _localityCache =
      LinkedHashMap();
  final Map<String, Future<AddressLocalityResult>> _localityPending = {};

  AddressLookupService(this.token);

  Future<AddressLookupResult> load(String query, String country) {
    final cacheKey =
        '${country.trim().toLowerCase()}\n${query.trim().toLowerCase()}';
    final cached = _cache.remove(cacheKey);
    if (cached != null) {
      _cache[cacheKey] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(cacheKey, () async {
      try {
        final result = await _request(query.trim(), country.trim());
        if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
        _cache[cacheKey] = result;
        return result;
      } finally {
        _pending.remove(cacheKey);
      }
    });
  }

  Future<AddressLocalityResult> loadLocalities(
    String postalCode,
    String country,
  ) {
    final normalizedPostalCode = postalCode.trim();
    final normalizedCountry = country.trim();
    final cacheKey =
        '${normalizedCountry.toLowerCase()}\n${normalizedPostalCode.toLowerCase()}';
    final cached = _localityCache.remove(cacheKey);
    if (cached != null) {
      _localityCache[cacheKey] = cached;
      return Future.value(cached);
    }
    return _localityPending.putIfAbsent(cacheKey, () async {
      try {
        final result = await _requestLocalities(
          normalizedPostalCode,
          normalizedCountry,
        );
        if (_localityCache.length >= _cacheLimit) {
          _localityCache.remove(_localityCache.keys.first);
        }
        _localityCache[cacheKey] = result;
        return result;
      } finally {
        _localityPending.remove(cacheKey);
      }
    });
  }

  Future<AddressLookupResult> _request(String query, String country) async {
    final uri = Uri.parse('$apiBaseUrl/api/address-suggestions').replace(
      queryParameters: {
        'query': query,
        if (country.isNotEmpty) 'country': country,
      },
    );
    final response = await AppHttpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 7));
    final decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map ? decoded['error']?.toString() : null;
      throw Exception(message ?? 'Adresssuche fehlgeschlagen.');
    }
    final data = Map<String, dynamic>.from(decoded as Map);
    final suggestions = <AddressSuggestion>[];
    for (final raw in (data['suggestions'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final suggestion = AddressSuggestion.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (suggestion.isComplete) suggestions.add(suggestion);
    }
    return AddressLookupResult(
      configured: data['configured'] != false,
      supported: data['supported'] != false,
      suggestions: List.unmodifiable(suggestions),
    );
  }

  Future<AddressLocalityResult> _requestLocalities(
    String postalCode,
    String country,
  ) async {
    final uri = Uri.parse(
      '$apiBaseUrl/api/address-suggestions/localities',
    ).replace(queryParameters: {'postalCode': postalCode, 'country': country});
    final response = await AppHttpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 7));
    final decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map ? decoded['error']?.toString() : null;
      throw Exception(message ?? 'Ortssuche fehlgeschlagen.');
    }
    final data = Map<String, dynamic>.from(decoded as Map);
    final suggestions = <String>[];
    final seen = <String>{};
    for (final raw in (data['suggestions'] as List?) ?? const []) {
      final suggestion = raw?.toString().trim() ?? '';
      final key = suggestion.toLowerCase();
      if (suggestion.isEmpty || suggestion.length > 255 || !seen.add(key)) {
        continue;
      }
      suggestions.add(suggestion);
      if (suggestions.length >= 20) break;
    }
    return AddressLocalityResult(
      configured: data['configured'] != false,
      supported: data['supported'] != false,
      suggestions: List.unmodifiable(suggestions),
    );
  }
}
