String fileMimeType(String extension) {
  final normalized = extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  return switch (normalized) {
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ods' => 'application/vnd.oasis.opendocument.spreadsheet',
    'csv' => 'text/csv',
    'pdf' => 'application/pdf',
    'html' || 'htm' => 'text/html',
    'json' => 'application/json',
    'txt' => 'text/plain',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'zip' => 'application/zip',
    'exe' => 'application/vnd.microsoft.portable-executable',
    'deb' => 'application/vnd.debian.binary-package',
    'apk' => 'application/vnd.android.package-archive',
    _ => 'application/octet-stream',
  };
}
