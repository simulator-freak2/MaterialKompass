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
}
