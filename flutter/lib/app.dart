import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/auth_link_page.dart';
import 'pages/service_device_pages.dart';

class MaterialKompassApp extends StatelessWidget {
  const MaterialKompassApp({super.key});

  ThemeData _theme(ColorScheme colorScheme, {bool highContrast = false}) {
    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      scaffoldBackgroundColor: highContrast
          ? Colors.white
          : const Color(0xFFFFF7E6),
      focusColor: const Color(0xFF005FCC),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.secondary,
        foregroundColor: colorScheme.onSecondary,
        elevation: 0,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          minimumSize: const Size(48, 48),
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
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: highContrast
              ? const Color(0xFF7A0000)
              : const Color(0xFFB71C1C),
          side: BorderSide(
            color: highContrast ? Colors.black : const Color(0xFFF4B400),
            width: highContrast ? 2 : 1.4,
          ),
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 400),
        showDuration: Duration(seconds: 10),
      ),
    );
  }

  Widget _initialPage() {
    final fragment = Uri.base.fragment.startsWith('/')
        ? Uri.base.fragment.substring(1)
        : Uri.base.fragment;
    final uri = Uri.tryParse(fragment);
    if (uri != null &&
        (uri.path == 'verify-email' || uri.path == 'password-reset')) {
      return AuthLinkPage(
        action: uri.path,
        token: uri.queryParameters['token'] ?? '',
      );
    }
    return const ServiceDeviceBootstrap();
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
    final highContrastScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFF4B400),
      primary: const Color(0xFF7A4E00),
      secondary: const Color(0xFF990000),
      tertiary: const Color(0xFF6D0000),
      contrastLevel: 1,
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
      theme: _theme(colorScheme),
      highContrastTheme: _theme(highContrastScheme, highContrast: true),
      home: _initialPage(),
    );
  }
}
