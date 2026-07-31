import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/login_page.dart';
import 'pages/auth_link_page.dart';

class MaterialKompassApp extends StatelessWidget {
  const MaterialKompassApp({super.key});

  Widget _initialPage() {
    final fragment = Uri.base.fragment.startsWith('/')
        ? Uri.base.fragment.substring(1)
        : Uri.base.fragment;
    final uri = Uri.tryParse(fragment);
    if (uri != null &&
        (uri.path == 'verify-email' || uri.path == 'password-reset')) {
      return AuthLinkPage(
          action: uri.path, token: uri.queryParameters['token'] ?? '');
    }
    return const LoginPage();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFF4B400),
      primary: const Color(0xFFF4B400),
      onPrimary: const Color(0xFF2B2100),
      secondary: const Color(0xFFD32F2F),
      onSecondary: Colors.white,
      tertiary: const Color(0xFFB71C1C),
      onTertiary: Colors.white,
    );

    return MaterialApp(
      title: 'MaterialKompass',
      locale: const Locale('de', 'DE'),
      supportedLocales: const [Locale('de', 'DE')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFFF7E6),
        appBarTheme: AppBarTheme(
          backgroundColor: colorScheme.secondary,
          foregroundColor: colorScheme.onSecondary,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.secondary,
            foregroundColor: colorScheme.onSecondary,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFB71C1C),
            side: const BorderSide(color: Color(0xFFF4B400), width: 1.4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: _initialPage(),
    );
  }
}
