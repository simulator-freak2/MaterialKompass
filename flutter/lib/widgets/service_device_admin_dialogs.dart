part of 'service_devices_admin_panel.dart';

class _PersonalNfcDialog extends StatefulWidget {
  final List<Map<String, dynamic>> users;
  const _PersonalNfcDialog({required this.users});
  @override
  State<_PersonalNfcDialog> createState() => _PersonalNfcDialogState();
}

class _PersonalNfcDialogState extends State<_PersonalNfcDialog> {
  final label = TextEditingController();
  final credential = TextEditingController();
  late String? userId = widget.users
      .where((entry) => entry['active'] == true)
      .map((entry) => entry['id'].toString())
      .firstOrNull;
  @override
  void dispose() {
    label.dispose();
    credential.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Persönliche NFC-Karte registrieren'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: userId,
              decoration:
                  const InputDecoration(labelText: 'Persönliches Konto'),
              items: widget.users
                  .where((entry) => entry['active'] == true)
                  .map((entry) => DropdownMenuItem(
                        value: entry['id'].toString(),
                        child: Text(
                            entry['name']?.toString().trim().isNotEmpty == true
                                ? entry['name'].toString()
                                : entry['username'].toString()),
                      ))
                  .toList(),
              onChanged: (value) => setState(() => userId = value),
            ),
            TextField(
              controller: label,
              decoration: const InputDecoration(labelText: 'Bezeichnung'),
            ),
            TextField(
              controller: credential,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'USB-Kartenleser',
                helperText: 'Karte auflegen und die Lesereingabe übernehmen.',
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: userId == null || credential.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, {
                      'userId': userId!,
                      'label': label.text.trim(),
                      'credential': credential.text.trim(),
                    }),
            child: const Text('Registrieren'),
          ),
        ],
      );
}

class _ServiceDeviceDialog extends StatefulWidget {
  final Map<String, dynamic>? device;
  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> departments;
  final List<Map<String, dynamic>> locations;
  const _ServiceDeviceDialog(
      {required this.device,
      required this.users,
      required this.departments,
      required this.locations});
  @override
  State<_ServiceDeviceDialog> createState() => _ServiceDeviceDialogState();
}

class _ServiceDeviceDialogState extends State<_ServiceDeviceDialog> {
  late final name =
      TextEditingController(text: widget.device?['name']?.toString());
  late final room =
      TextEditingController(text: widget.device?['room']?.toString());
  late final inventoryNumber = TextEditingController(
      text: widget.device?['inventoryNumber']?.toString());
  late final mac =
      TextEditingController(text: widget.device?['macAddress']?.toString());
  late final description =
      TextEditingController(text: widget.device?['description']?.toString());
  late final networks = TextEditingController(
      text:
          (widget.device?['allowedNetworks'] as List? ?? const []).join('\n'));
  final password = TextEditingController();
  late String? locationId = widget.device?['locationId']?.toString() ??
      (widget.locations.isEmpty
          ? null
          : widget.locations.first['id'].toString());
  late String? responsibleUserId =
      widget.device?['responsibleUserId']?.toString();
  late Set<String> departments =
      (widget.device?['allowedDepartmentIds'] as List? ?? const [])
          .map((e) => e.toString())
          .toSet();
  late String systemMfa = widget.device?['systemMfa']?.toString() ?? 'off';
  late String personalMfa = widget.device?['personalMfa']?.toString() ?? 'off';
  late bool active = widget.device?['active'] != false;
  late bool offlineEnabled = widget.device?['offlineEnabled'] == true;
  late Set<String> offlineUsers =
      (widget.device?['allowedOfflineUserIds'] as List? ?? const [])
          .map((entry) => entry.toString())
          .toSet();
  @override
  void dispose() {
    for (final c in [
      name,
      room,
      inventoryNumber,
      mac,
      description,
      networks,
      password
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  DropdownButtonFormField<String> mfaField(
          String label, String value, ValueChanged<String?> changed) =>
      DropdownButtonFormField(
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: const [
            DropdownMenuItem(value: 'off', child: Text('Aus')),
            DropdownMenuItem(value: 'totp', child: Text('TOTP erforderlich')),
            DropdownMenuItem(value: 'nfc', child: Text('NFC erforderlich'))
          ],
          onChanged: changed);
  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.device == null
              ? 'Dienstgerät anlegen'
              : 'Dienstgerät bearbeiten'),
          content: SizedBox(
              width: 650,
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Name *')),
                DropdownButtonFormField<String>(
                    initialValue: locationId,
                    decoration: const InputDecoration(labelText: 'Standort *'),
                    items: widget.locations
                        .map((entry) => DropdownMenuItem(
                            value: entry['id'].toString(),
                            child: Text(entry['name'].toString())))
                        .toList(),
                    onChanged: (value) => setState(() => locationId = value)),
                TextField(
                    controller: room,
                    decoration: const InputDecoration(labelText: 'Halle/Raum')),
                TextField(
                    controller: inventoryNumber,
                    decoration: const InputDecoration(
                        labelText: 'Inventarnummer des Geräts *')),
                TextField(
                    controller: mac,
                    decoration: const InputDecoration(
                        labelText: 'MAC-Adresse',
                        helperText:
                            'Nur Dokumentation, kein Sicherheitsmerkmal')),
                TextField(
                    controller: description,
                    maxLines: 3,
                    decoration:
                        const InputDecoration(labelText: 'Beschreibung')),
                DropdownButtonFormField<String?>(
                    initialValue: responsibleUserId,
                    decoration:
                        const InputDecoration(labelText: 'Verantwortlicher'),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('Nicht zugeordnet')),
                      ...widget.users.map((entry) => DropdownMenuItem<String?>(
                          value: entry['id'].toString(),
                          child: Text(
                              entry['name']?.toString().trim().isNotEmpty ==
                                      true
                                  ? entry['name'].toString()
                                  : entry['username'].toString())))
                    ],
                    onChanged: (value) =>
                        setState(() => responsibleUserId = value)),
                const SizedBox(height: 12),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Organisatorische Fachbereiche',
                        style: Theme.of(context).textTheme.titleSmall)),
                ...widget.departments.map((entry) => CheckboxListTile(
                    dense: true,
                    value: departments.contains(entry['id']),
                    title: Text(entry['name'].toString()),
                    onChanged: (selected) => setState(() {
                          if (selected == true) {
                            departments.add(entry['id'].toString());
                          } else {
                            departments.remove(entry['id'].toString());
                          }
                        }))),
                const Divider(),
                SwitchListTile(
                    value: offlineEnabled,
                    title: const Text('Offlinebetrieb erlauben'),
                    subtitle: const Text(
                        'Freigaben müssen spätestens alle sieben Tage online erneuert werden.'),
                    onChanged: (value) =>
                        setState(() => offlineEnabled = value)),
                if (offlineEnabled) ...[
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Offline berechtigte Benutzer',
                          style: Theme.of(context).textTheme.titleSmall)),
                  ...widget.users.where((entry) => entry['active'] == true).map(
                      (entry) => CheckboxListTile(
                          dense: true,
                          value: offlineUsers.contains(entry['id'].toString()),
                          title: Text(
                              entry['name']?.toString().trim().isNotEmpty ==
                                      true
                                  ? entry['name'].toString()
                                  : entry['username'].toString()),
                          onChanged: (selected) => setState(() {
                                final id = entry['id'].toString();
                                if (selected == true) {
                                  offlineUsers.add(id);
                                } else {
                                  offlineUsers.remove(id);
                                }
                              }))),
                ],
                TextField(
                    controller: networks,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                        labelText: 'Erlaubte IP-Adressen/CIDR-Netze',
                        helperText:
                            'Ein Eintrag pro Zeile; leer bedeutet keine Einschränkung')),
                Row(children: [
                  Expanded(
                      child: mfaField(
                          'MFA Systemlogin',
                          systemMfa,
                          (value) =>
                              setState(() => systemMfa = value ?? 'off'))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: mfaField(
                          'MFA persönliche Konten',
                          personalMfa,
                          (value) =>
                              setState(() => personalMfa = value ?? 'off')))
                ]),
                TextField(
                    controller: password,
                    obscureText: true,
                    decoration: InputDecoration(
                        labelText: widget.device == null
                            ? 'Gerätepasswort *'
                            : 'Neues Gerätepasswort (optional)',
                        helperText:
                            'Mindestens 12 Zeichen, Groß-/Kleinbuchstabe, Zahl und Sonderzeichen')),
                SwitchListTile(
                    value: active,
                    title: const Text('Gerät freigegeben'),
                    onChanged: (value) => setState(() => active = value)),
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () => Navigator.pop(context, {
                      'name': name.text.trim(),
                      'locationId': locationId,
                      'room': room.text.trim(),
                      'inventoryNumber': inventoryNumber.text.trim(),
                      'macAddress': mac.text.trim(),
                      'description': description.text.trim(),
                      'responsibleUserId': responsibleUserId,
                      'allowedDepartmentIds': departments.toList(),
                      'allowedNetworks': networks.text
                          .split(RegExp(r'[\r\n,]+'))
                          .map((e) => e.trim())
                          .where((e) => e.isNotEmpty)
                          .toList(),
                      'offlineEnabled': offlineEnabled,
                      'allowedOfflineUserIds': offlineUsers.toList(),
                      'systemMfa': systemMfa,
                      'personalMfa': personalMfa,
                      'active': active,
                      if (password.text.isNotEmpty)
                        'systemPassword': password.text
                    }),
                child: const Text('Speichern'))
          ]);
}
