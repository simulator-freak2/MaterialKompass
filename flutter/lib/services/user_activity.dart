import 'dart:async';

import 'package:flutter/foundation.dart';

/// Verfolgt die Nutzeraktivitaet einer Anmeldung.
///
/// Eine Anmeldung endet nach [timeout] ohne Eingabe (Zeiger, Tastatur). Der
/// Server erzwingt dieselbe Grenze fuer Access- und Refresh-Tokens; Anfragen,
/// die innerhalb von [runInBackground] entstehen (Polling, automatische
/// Synchronisierung), tragen den Header [headerName] und halten die Sitzung
/// dort nicht offen.
class UserActivity extends ChangeNotifier {
  UserActivity._();

  static final UserActivity instance = UserActivity._();

  static const timeout = Duration(hours: 1);
  static const headerName = 'X-MaterialKompass-Activity';
  static const backgroundValue = 'background';
  static const _backgroundZoneKey = #materialKompassBackgroundRequest;

  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  late DateTime _lastInteraction = clock();
  bool _expirationReported = false;

  Duration get idle => clock().difference(_lastInteraction);

  bool get expired => idle >= timeout;

  /// Beginnt die Inaktivitaetsfrist einer neuen oder wiederhergestellten
  /// Anmeldung.
  void startSession() {
    _lastInteraction = clock();
    _expirationReported = false;
  }

  /// Wird bei jeder Eingabe aufgerufen. Nach Ablauf der Frist verlaengert eine
  /// Eingabe die Anmeldung nicht mehr, sondern meldet den Ablauf.
  void recordInteraction() {
    if (expired) {
      reportExpiration();
      return;
    }
    _lastInteraction = clock();
  }

  /// Benachrichtigt die Anmeldeoberflaeche einmal ueber den Ablauf.
  void reportExpiration() {
    if (_expirationReported) return;
    _expirationReported = true;
    notifyListeners();
  }

  static bool get inBackground => Zone.current[_backgroundZoneKey] == true;

  /// Fuehrt automatische Abfragen aus, die nicht als Nutzeraktivitaet zaehlen.
  static Future<T> runInBackground<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_backgroundZoneKey: true});

  /// Ergaenzt [headers] innerhalb von [runInBackground] um den
  /// Hintergrund-Header.
  static Map<String, String> headersFor(Map<String, String>? headers) => {
    ...?headers,
    if (inBackground) headerName: backgroundValue,
  };
}
