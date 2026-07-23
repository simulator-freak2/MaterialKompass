// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

Future<bool> startBrowserDownload(Uri uri) async {
  html.window.location.assign(uri.toString());
  return true;
}
