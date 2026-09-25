// Flutter's canvas-based web fields do not expose a stable HTML login form to
// browser extensions. This platform view deliberately uses semantic HTML so
// password managers such as Bitwarden can discover and fill the credentials.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class PasswordLoginForm extends StatefulWidget {
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
  State<PasswordLoginForm> createState() => _PasswordLoginFormState();
}

class _PasswordLoginFormState extends State<PasswordLoginForm> {
  late final String _viewType;
  late final html.FormElement _form;
  late final html.InputElement _usernameInput;
  late final html.InputElement _passwordInput;
  late final html.ButtonElement _submitButton;
  final List<StreamSubscription<html.Event>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _viewType = 'materialkompass-password-login-${identityHashCode(this)}';
    _usernameInput = _createInput(
      id: 'materialkompass-username',
      name: 'username',
      type: 'text',
      autocomplete: 'username',
      label: 'Nutzername oder E-Mail',
      value: widget.usernameController.text,
    );
    _passwordInput = _createInput(
      id: 'materialkompass-password',
      name: 'password',
      type: 'password',
      autocomplete: 'current-password',
      label: 'Passwort',
      value: widget.passwordController.text,
    );
    _submitButton = html.ButtonElement()
      ..type = 'submit'
      ..text = widget.loading ? 'Anmeldung läuft …' : 'Anmelden'
      ..disabled = widget.loading
      ..style.cssText = _buttonStyle;

    _form = html.FormElement()
      ..id = 'materialkompass-login-form'
      ..method = 'post'
      ..action = '/api/auth/login'
      ..autocomplete = 'on'
      ..setAttribute('aria-label', 'MaterialKompass Anmeldung')
      ..style.cssText = _formStyle
      ..append(_field(_usernameInput, 'Nutzername oder E-Mail'))
      ..append(_field(_passwordInput, 'Passwort'))
      ..append(_submitButton);

    _subscriptions
      ..add(_usernameInput.onInput.listen((_) => _syncControllers()))
      ..add(_usernameInput.onChange.listen((_) => _syncControllers()))
      ..add(_passwordInput.onInput.listen((_) => _syncControllers()))
      ..add(_passwordInput.onChange.listen((_) => _syncControllers()))
      ..add(
        _form.onSubmit.listen((event) {
          event.preventDefault();
          _syncControllers();
          if (!widget.loading) widget.onSubmitted();
        }),
      );
    widget.usernameController.addListener(_syncInputs);
    widget.passwordController.addListener(_syncInputs);

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) => _form);
  }

  @override
  void didUpdateWidget(covariant PasswordLoginForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.usernameController != widget.usernameController) {
      oldWidget.usernameController.removeListener(_syncInputs);
      widget.usernameController.addListener(_syncInputs);
    }
    if (oldWidget.passwordController != widget.passwordController) {
      oldWidget.passwordController.removeListener(_syncInputs);
      widget.passwordController.addListener(_syncInputs);
    }
    _submitButton
      ..disabled = widget.loading
      ..text = widget.loading ? 'Anmeldung läuft …' : 'Anmelden';
    _syncInputs();
  }

  html.InputElement _createInput({
    required String id,
    required String name,
    required String type,
    required String autocomplete,
    required String label,
    required String value,
  }) {
    return html.InputElement()
      ..id = id
      ..name = name
      ..type = type
      ..autocomplete = autocomplete
      ..value = value
      ..required = true
      ..setAttribute('aria-label', label)
      ..setAttribute('autocapitalize', 'none')
      ..setAttribute('spellcheck', 'false')
      ..style.cssText = _inputStyle;
  }

  html.DivElement _field(html.InputElement input, String label) {
    final labelElement = html.LabelElement()
      ..htmlFor = input.id
      ..text = label
      ..style.cssText = _labelStyle;
    return html.DivElement()
      ..style.cssText = _fieldStyle
      ..append(labelElement)
      ..append(input);
  }

  void _syncControllers() {
    final username = _usernameInput.value ?? '';
    final password = _passwordInput.value ?? '';
    if (widget.usernameController.text != username) {
      widget.usernameController.text = username;
    }
    if (widget.passwordController.text != password) {
      widget.passwordController.text = password;
    }
  }

  void _syncInputs() {
    if (_usernameInput.value != widget.usernameController.text) {
      _usernameInput.value = widget.usernameController.text;
    }
    if (_passwordInput.value != widget.passwordController.text) {
      _passwordInput.value = widget.passwordController.text;
    }
  }

  @override
  void dispose() {
    widget.usernameController.removeListener(_syncInputs);
    widget.passwordController.removeListener(_syncInputs);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _form.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 204,
      width: double.infinity,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}

const _formStyle = '''
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
  width: 100%;
  height: 100%;
  padding: 7px 0 0;
  font-family: Roboto, Arial, sans-serif;
''';

const _fieldStyle = '''
  box-sizing: border-box;
  position: relative;
  width: 100%;
  padding-top: 1px;
''';

const _labelStyle = '''
  box-sizing: border-box;
  position: absolute;
  z-index: 1;
  top: -7px;
  left: 12px;
  padding: 0 4px;
  color: #49454f;
  background: #ffffff;
  font-size: 12px;
  line-height: 16px;
''';

const _inputStyle = '''
  box-sizing: border-box;
  width: 100%;
  height: 56px;
  padding: 0 48px 0 16px;
  border: 1px solid #79747e;
  border-radius: 4px;
  color: #1d1b20;
  background: #ffffff;
  font: 16px/24px Roboto, Arial, sans-serif;
''';

const _buttonStyle = '''
  box-sizing: border-box;
  min-width: 104px;
  min-height: 48px;
  margin-top: 8px;
  padding: 0 20px;
  border: 0;
  border-radius: 12px;
  color: #2b2100;
  background: #f4b400;
  font: 500 14px/20px Roboto, Arial, sans-serif;
  letter-spacing: .1px;
  cursor: pointer;
''';
