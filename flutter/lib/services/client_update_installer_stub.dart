import 'package:http/http.dart' as http;

import 'client_update_service.dart';

Future<bool> downloadAndInstallClientUpdate(
  http.Client client,
  ClientUpdate update, {
  void Function(double progress)? onProgress,
}) async => false;
