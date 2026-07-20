import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/services/client_update_service.dart';

void main() {
  test('compares semantic client versions', () {
    expect(compareVersions('1.2.0', '1.1.9'), 1);
    expect(compareVersions('1.0.0+12', '1.0.0'), 0);
    expect(compareVersions('2.0', '2.0.1'), -1);
  });
}
