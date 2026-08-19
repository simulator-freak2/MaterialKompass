import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

final _temporaryFiles = <String>{};

String _safeName(String value) =>
    value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

Future<bool> openTemporaryDeviceFile(String fileName, Uint8List bytes) async {
  final directory = await getTemporaryDirectory();
  final folder = Directory(
      '${directory.path}${Platform.pathSeparator}materialkompass-device');
  await folder.create(recursive: true);
  final file =
      File('${folder.path}${Platform.pathSeparator}${_safeName(fileName)}');
  await file.writeAsBytes(bytes, flush: true);
  _temporaryFiles.add(file.path);
  final result = await OpenFilex.open(file.path);
  return result.type == ResultType.done;
}

Future<void> clearTemporaryDeviceFiles() async {
  for (final path in _temporaryFiles.toList()) {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
  _temporaryFiles.clear();
}
