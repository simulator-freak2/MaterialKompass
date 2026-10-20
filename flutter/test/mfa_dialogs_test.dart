import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/widgets/mfa_dialogs.dart';

void main() {
  testWidgets('MFA dialog keeps push, passkey and code choices separate', (
    tester,
  ) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    final result = verifyMfaChallenge(pageContext, {
      'challenge': 'test-challenge',
      'methods': ['push', 'passkey', 'totp', 'recovery_code'],
    });
    await tester.pumpAndSettle();

    expect(find.text('Push-Benachrichtigung senden'), findsOneWidget);
    expect(find.text('Mit Passkey bestätigen'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}
