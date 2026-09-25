import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/widgets/password_login_form.dart';

void main() {
  testWidgets('native password form exposes password-manager metadata', (
    tester,
  ) async {
    final username = TextEditingController();
    final password = TextEditingController();
    addTearDown(username.dispose);
    addTearDown(password.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PasswordLoginForm(
            usernameController: username,
            passwordController: password,
            loading: false,
            onSubmitted: () => submissions += 1,
          ),
        ),
      ),
    );

    final usernameField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Nutzername oder E-Mail'),
    );
    final passwordField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Passwort'),
    );
    expect(usernameField.autofillHints, contains(AutofillHints.username));
    expect(passwordField.autofillHints, contains(AutofillHints.password));
    expect(passwordField.obscureText, isTrue);

    await tester.enterText(
      find.widgetWithText(TextField, 'Nutzername oder E-Mail'),
      'bitwarden@example.org',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Passwort'),
      'correct horse battery staple',
    );
    await tester.tap(find.text('Anmelden'));

    expect(username.text, 'bitwarden@example.org');
    expect(password.text, 'correct horse battery staple');
    expect(submissions, 1);
  });
}
