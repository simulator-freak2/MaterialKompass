import 'network_probe_stub.dart' if (dart.library.io) 'network_probe_io.dart'
    as probe;

enum OfflineNetworkKind { mobile, unmetered, unknown }

Future<OfflineNetworkKind> offlineNetworkKind() async {
  final names =
      (await probe.activeNetworkNames()).map((entry) => entry.toLowerCase());
  final unmetered = names.any((name) =>
      RegExp(r'wlan|wi-?fi|ethernet|^en\d|^eth\d|lan-verbindung|local area')
          .hasMatch(name));
  if (unmetered) return OfflineNetworkKind.unmetered;
  final mobile = names.any((name) =>
      RegExp(r'rmnet|pdp_ip|wwan|cellular|mobile|ccmni|radio').hasMatch(name));
  return mobile ? OfflineNetworkKind.mobile : OfflineNetworkKind.unknown;
}
