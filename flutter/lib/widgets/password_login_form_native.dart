import 'package:flutter/material.dart';

/// Native login fields with the platform autofill metadata used by password
/// managers on Android, iOS, macOS and supported desktop environments.
class PasswordLoginForm extends StatelessWidget {
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool loading;
  final VoidCallback onSubmitted;

  const PasswordLoginForm({
    required this.usernameController,
    required this.passwordController,
    required this.loading,
    required this.onSubmitted,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: usernameController,
            autofillHints: const [AutofillHints.username],
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Nutzername oder E-Mail',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: passwordController,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (!loading) onSubmitted();
            },
            decoration: const InputDecoration(labelText: 'Passwort'),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: loading ? null : onSubmitted,
            child: loading
                ? CircularProgressIndicator(
                    color: Theme.of(context).colorScheme.onPrimary,
                  )
                : const Text('Anmelden'),
          ),
        ],
      ),
    );
  }
}
