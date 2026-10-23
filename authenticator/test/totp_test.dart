import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass_authenticator/main.dart';

void main() {
  test('RFC 6238 SHA1 test vector is generated correctly', () {
    const entry = TotpEntry(
      id: 'test',
      issuer: 'RFC',
      account: 'test',
      secret: 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
      digits: 8,
      period: 30,
    );
    expect(
      generateTotp(
        entry,
        DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true),
      ),
      '94287082',
    );
  });

  test('otpauth parser rejects unsupported HOTP URIs', () {
    expect(
      () => TotpEntry.fromUri(
        Uri.parse('otpauth://hotp/Test?secret=JBSWY3DPEHPK3PXP'),
      ),
      throwsFormatException,
    );
  });

  test('MaterialKompass pairing can carry TOTP for automatic push setup', () {
    final totpUri = Uri.parse(
      'otpauth://totp/MaterialKompass:user@example.org'
      '?secret=JBSWY3DPEHPK3PXP&issuer=MaterialKompass',
    );
    final pairingUri = Uri.parse('materialkompass-auth://pair').replace(
      queryParameters: {
        'server': 'https://material.example.org',
        'token': List.filled(43, 'a').join(),
        'totp': totpUri.toString(),
      },
    );

    final entry = embeddedTotpEntry(pairingUri);

    expect(entry, isNotNull);
    expect(entry!.issuer, 'MaterialKompass');
    expect(entry.account, 'user@example.org');
    expect(entry.secret, 'JBSWY3DPEHPK3PXP');
  });

  test('app lock is limited to supported native platforms', () {
    expect(
      appLockSupportedPlatform(TargetPlatform.android, isWeb: false),
      isTrue,
    );
    expect(
      appLockSupportedPlatform(TargetPlatform.windows, isWeb: false),
      isTrue,
    );
    expect(
      appLockSupportedPlatform(TargetPlatform.linux, isWeb: false),
      isFalse,
    );
    expect(
      appLockSupportedPlatform(TargetPlatform.android, isWeb: true),
      isFalse,
    );
  });

  test('app lock engages when the app leaves the foreground', () {
    expect(appLockTriggeredBy(AppLifecycleState.paused), isTrue);
    expect(appLockTriggeredBy(AppLifecycleState.hidden), isTrue);
    expect(appLockTriggeredBy(AppLifecycleState.detached), isTrue);
    expect(appLockTriggeredBy(AppLifecycleState.inactive), isFalse);
    expect(appLockTriggeredBy(AppLifecycleState.resumed), isFalse);
  });
}
