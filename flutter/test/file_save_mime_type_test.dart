import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/services/file_save_mime_type.dart';

void main() {
  test('maps export and installer extensions to concrete MIME types', () {
    expect(fileMimeType('xlsx'),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    expect(fileMimeType('.pdf'), 'application/pdf');
    expect(fileMimeType('apk'), 'application/vnd.android.package-archive');
    expect(fileMimeType('unknown'), 'application/octet-stream');
  });
}
