/// Was die HTML-Loginseite (web/index.html) an die Flutter-App uebergibt,
/// wenn ein Anmeldeweg nur in Flutter verfuegbar ist (Passkey, QR-Code,
/// Pflicht-Einrichtung der 2-FA, Passwort vergessen, rechtliche Hinweise).
/// Ergebnis von waitForHtmlLogin: frisch auf der HTML-Seite angemeldet.
const htmlLoginSession = 'session';

/// Ergebnis von waitForHtmlLogin: vorhandene Sitzung pruefen und
/// wiederherstellen.
const htmlLoginRestore = 'restore';

class PendingWebLogin {
  const PendingWebLogin({
    required this.identifier,
    required this.password,
    required this.action,
  });

  /// Anmeldung mit den eingegebenen Daten automatisch fortsetzen.
  static const submitPassword = 'password';

  /// Den Dialog "Passwort vergessen?" oeffnen.
  static const requestPasswordReset = 'password-reset';

  /// Anbieterangaben bzw. Datenschutzhinweise oeffnen.
  static const showLegal = 'legal';
  static const showPrivacy = 'privacy';

  final String identifier;
  final String password;
  final String action;
}
