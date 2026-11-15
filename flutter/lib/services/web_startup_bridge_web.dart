import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'web_startup_bridge_types.dart';

export 'web_startup_bridge_types.dart';

const _readyCallback = 'materialKompassAppReady';
const _pendingLogin = 'materialKompassPendingLogin';
const _startup = 'materialKompassStartup';

JSObject? _startupObject() {
  final value = globalContext.getProperty<JSAny?>(_startup.toJS);
  return value != null && value.isA<JSObject>() ? value as JSObject : null;
}

/// Ob die HTML-Loginseite noch auf eine Eingabe wartet. Die App laeuft dann
/// bereits unsichtbar dahinter.
bool htmlLoginOpen() {
  final value = _startupObject()?.getProperty<JSAny?>('htmlLoginOpen'.toJS);
  return value != null && value.isA<JSBoolean>() && (value as JSBoolean).toDart;
}

/// Wartet, bis die HTML-Loginseite die Anmeldung abgeschlossen oder an die
/// App uebergeben hat, und liefert den Grund ([htmlLoginSession] fuer eine
/// gerade dort ausgestellte Sitzung).
Future<String> waitForHtmlLogin() {
  final startup = _startupObject();
  if (startup == null || !htmlLoginOpen()) {
    return Future.value(htmlLoginRestore);
  }
  final completer = Completer<String>();
  startup.callMethod<JSAny?>(
    'onLoginFinished'.toJS,
    ((JSAny? reason) {
      if (completer.isCompleted) return;
      completer.complete(
        reason != null && reason.isA<JSString>()
            ? (reason as JSString).toDart
            : htmlLoginRestore,
      );
    }).toJS,
  );
  return completer.future;
}

/// Meldet der HTML-Loginseite, dass Flutter die Zielseite gezeichnet hat und
/// der statische Platzhalter entfernt werden kann.
void notifyWebAppReady() {
  final callback = globalContext.getProperty<JSAny?>(_readyCallback.toJS);
  if (callback != null && callback.isA<JSFunction>()) {
    (callback as JSFunction).callAsFunction();
  }
}

/// Liest die Uebergabe der HTML-Loginseite genau einmal und entfernt sie
/// danach, damit das Passwort nicht im Fensterobjekt verbleibt.
PendingWebLogin? takePendingWebLogin() {
  final value = globalContext.getProperty<JSAny?>(_pendingLogin.toJS);
  globalContext.delete(_pendingLogin.toJS);
  if (value == null || !value.isA<JSObject>()) return null;
  final object = value as JSObject;
  String field(String name) {
    final entry = object.getProperty<JSAny?>(name.toJS);
    return entry != null && entry.isA<JSString>()
        ? (entry as JSString).toDart
        : '';
  }

  return PendingWebLogin(
    identifier: field('identifier'),
    password: field('password'),
    action: field('action'),
  );
}
