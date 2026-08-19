import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../constants.dart';
import '../services/offline_http.dart' as http;
import '../services/offline_store.dart';
import '../services/offline_session_service.dart';
import '../services/service_device_storage.dart';
import '../services/temporary_device_file.dart';
import '../widgets/qr_login_dialog.dart';
import 'dashboard_page.dart';
import 'login_page.dart';

part 'service_device_activation.dart';
part 'service_device_login.dart';
part 'service_device_home.dart';

Map<String, dynamic> _object(http.Response response) {
  if (response.body.isEmpty) return {};
  final decoded = jsonDecode(response.body);
  return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
}

Future<Map<String, String>> _clientInfo() async {
  final package = await PackageInfo.fromPlatform();
  return {
    'clientPlatform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    'clientVersion': '${package.version}+${package.buildNumber}',
  };
}
