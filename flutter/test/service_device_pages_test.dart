import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/login_page.dart';
import 'package:materialkompass/pages/service_device_pages.dart';

void main() {
  testWidgets('native login exposes service-device activation', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));

    expect(find.text('Dienstliches Gerät aktivieren'), findsOneWidget);
  });

  testWidgets('activated service device offers system and personal login',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServiceDeviceLoginPage(
        deviceCredential: 'device-credential',
        initialDevice: const {
          'id': 'device-1',
          'name': 'Hallenterminal',
          'systemMfa': 'off',
          'personalMfa': 'off',
        },
      ),
    ));

    expect(find.text('Systemzugang'), findsOneWidget);
    expect(find.text('Persönliches Konto'), findsOneWidget);
    expect(find.text('Systemzugang öffnen'), findsOneWidget);

    await tester.tap(find.text('Persönliches Konto'));
    await tester.pumpAndSettle();

    expect(find.text('Persönlich anmelden'), findsOneWidget);
    expect(find.text('NFC/Dienstausweis'), findsOneWidget);
  });
}
