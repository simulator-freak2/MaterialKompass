import 'dart:io';

Future<List<String>> activeNetworkNames() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.any,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return interfaces.map((entry) => entry.name).toList();
  } catch (_) {
    return const [];
  }
}
