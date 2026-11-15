import 'web_startup_bridge_types.dart';

export 'web_startup_bridge_types.dart';

/// Native Apps besitzen keine HTML-Loginseite.
void notifyWebAppReady() {}

PendingWebLogin? takePendingWebLogin() => null;

bool htmlLoginOpen() => false;

Future<String> waitForHtmlLogin() async => htmlLoginRestore;
