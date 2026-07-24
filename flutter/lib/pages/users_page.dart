import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../widgets/qr_login_dialog.dart';

class UsersPage extends StatefulWidget {
  final String token;
  const UsersPage({required this.token, super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  final searchController = TextEditingController();
  List<Map<String, dynamic>> users = [];
  List<Map<String, dynamic>> roles = [];
  List<Map<String, dynamic>> departments = [];
  bool loading = true;

  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    final query = Uri.encodeQueryComponent(searchController.text.trim());
    final responses = await Future.wait([
      http.get(Uri.parse('$apiBaseUrl/api/users?search=$query'),
          headers: headers),
      http.get(Uri.parse('$apiBaseUrl/api/roles'), headers: headers),
      http.get(Uri.parse('$apiBaseUrl/api/departments'), headers: headers),
    ]);
    if (!mounted) return;
    if (responses.any((response) => response.statusCode != 200)) {
      _message('Nutzerverwaltung konnte nicht geladen werden.');
    } else {
      users = (jsonDecode(responses[0].body) as List)
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      roles = (jsonDecode(responses[1].body) as List)
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      departments = (jsonDecode(responses[2].body) as List)
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    setState(() => loading = false);
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _send(String method, String path,
      [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    late http.Response response;
    if (method == 'POST')
      response = await http.post(uri, headers: headers, body: encoded);
    if (method == 'PUT')
      response = await http.put(uri, headers: headers, body: encoded);
    if (method == 'DELETE')
      response = await http.delete(uri, headers: headers, body: encoded);
    if (response.statusCode >= 200 && response.statusCode < 300) return true;
    final data = response.body.isEmpty ? {} : jsonDecode(response.body);
    _message(data['error']?.toString() ?? 'Aktion fehlgeschlagen.');
    return false;
  }

  Future<void> editUser([Map<String, dynamic>? user]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => UserDialog(
          user: user,
          roles: roles.map((role) => role['name'].toString()).toList(),
          departments: departments),
    );
    if (result == null) return;
    final ok = await _send(user == null ? 'POST' : 'PUT',
        user == null ? '/api/users' : '/api/users/${user['id']}', result);
    if (ok) {
      _message(user == null
          ? 'Nutzer wurde angelegt; E-Mails zur Bestätigung und Passwortvergabe wurden versendet.'
          : 'Nutzer wurde aktualisiert.');
      await load();
    }
  }

  Future<void> deleteUser(Map<String, dynamic> user) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Account endgültig löschen?'),
              content: Text(
                  '${user['name']} wird unwiderruflich aus der Nutzerverwaltung gelöscht.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Abbrechen')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Löschen'))
              ],
            ));
    if (confirmed == true && await _send('DELETE', '/api/users/${user['id']}'))
      await load();
  }

  Future<void> createQrLogin(Map<String, dynamic> user) async {
    final options = await chooseQrLoginOptions(context);
    if (options == null || !mounted) return;
    final response = await http.post(
      Uri.parse('$apiBaseUrl/api/users/${user['id']}/qr-credential'),
      headers: headers,
      body: jsonEncode({
        'oneTime': options.oneTime,
        if (!options.oneTime) 'validForDays': options.validForDays,
      }),
    );
    final data = response.body.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (!mounted) return;
    if (response.statusCode != 201) {
      _message(
          data['error']?.toString() ?? 'QR-Code konnte nicht erstellt werden.');
      return;
    }
    await showQrLoginCode(
      context,
      qrValue: data['qrValue'].toString(),
      expiresAt: data['expiresAt'] == null
          ? null
          : DateTime.parse(data['expiresAt'].toString()),
      oneTime: data['oneTime'] != false,
      accountLabel: user['name']?.toString() ?? user['username'].toString(),
    );
  }

  List<String> get allPermissions {
    final allPermissions = roles
        .expand((role) => (role['permissions'] as List? ?? const []))
        .map((e) => e.toString())
        .toSet()
        .toList()
      ..sort();
    return allPermissions;
  }

  Future<void> editRole([Map<String, dynamic>? role]) async {
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => RoleDialog(
              permissions: allPermissions,
              role: role,
            ));
    if (result == null) return;
    final ok = await _send(
      role == null ? 'POST' : 'PUT',
      role == null ? '/api/roles' : '/api/roles/${role['id']}',
      result,
    );
    if (ok) {
      _message(
          role == null ? 'Rolle wurde angelegt.' : 'Rolle wurde aktualisiert.');
      await load();
    }
  }

  Future<void> deleteRole(Map<String, dynamic> role) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rolle löschen?'),
        content: Text(
            'Die Rolle „${role['name']}“ wird dauerhaft gelöscht. Zugewiesene oder geschützte Rollen können nicht gelöscht werden.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed == true &&
        await _send('DELETE', '/api/roles/${role['id']}')) {
      _message('Rolle wurde gelöscht.');
      await load();
    }
  }

  Future<void> editDepartment([Map<String, dynamic>? department]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => DepartmentDialog(department: department),
    );
    if (result == null) return;
    final ok = await _send(
      department == null ? 'POST' : 'PUT',
      department == null
          ? '/api/departments'
          : '/api/departments/${department['id']}',
      result,
    );
    if (ok) {
      _message(department == null
          ? 'Fachbereich wurde angelegt.'
          : 'Fachbereich wurde aktualisiert.');
      await load();
    }
  }

  Future<void> deleteDepartment(Map<String, dynamic> department) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Fachbereich löschen?'),
        content: Text(
            '„${department['name']}“ wird dauerhaft gelöscht. Zugewiesene Fachbereiche können nur deaktiviert werden.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed == true &&
        await _send('DELETE', '/api/departments/${department['id']}')) {
      _message('Fachbereich wurde gelöscht.');
      await load();
    }
  }

  String date(Object? value) {
    if (value == null) return '—';
    final parsed = DateTime.tryParse(value.toString())?.toLocal();
    return parsed == null
        ? '—'
        : '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year}';
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
              title: const Text('Nutzerverwaltung'),
              bottom: const TabBar(tabs: [
                Tab(text: 'Nutzer', icon: Icon(Icons.people)),
                Tab(text: 'Rollen', icon: Icon(Icons.admin_panel_settings)),
                Tab(text: 'Fachbereiche', icon: Icon(Icons.account_tree))
              ])),
          body: loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(children: [
                  Column(children: [
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: searchController,
                                  onSubmitted: (_) => load(),
                                  decoration: const InputDecoration(
                                      prefixIcon: Icon(Icons.search),
                                      labelText:
                                          'Name, Nutzername oder E-Mail suchen',
                                      border: OutlineInputBorder()))),
                          const SizedBox(width: 12),
                          OutlinedButton(
                              onPressed: load, child: const Text('Suchen')),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                              onPressed: () => editUser(),
                              icon: const Icon(Icons.person_add),
                              label: const Text('Nutzer anlegen')),
                        ])),
                    Expanded(
                        child: ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: users.length,
                            itemBuilder: (_, index) {
                              final user = users[index];
                              final active = user['active'] == true;
                              return Card(
                                  child: ListTile(
                                leading: CircleAvatar(
                                    child: Icon(active
                                        ? Icons.person
                                        : Icons.person_off)),
                                title: Text((user['name'] ?? '')
                                        .toString()
                                        .trim()
                                        .isEmpty
                                    ? user['username'].toString()
                                    : '${user['name']} (${user['username']})'),
                                subtitle: Text(
                                    '${user['email']}\n${(user['roles'] as List? ?? const []).join(', ')} · ${active ? 'Aktiv' : 'Deaktiviert'} · Erstellt: ${date(user['createdAt'])} · Letzter Login: ${date(user['lastLoginAt'])}'),
                                isThreeLine: true,
                                trailing: Wrap(children: [
                                  IconButton(
                                      tooltip: 'Einmaligen Anmelde-QR-Code erstellen',
                                      onPressed: active
                                          ? () => createQrLogin(user)
                                          : null,
                                      icon: const Icon(Icons.qr_code_2)),
                                  IconButton(
                                      tooltip: 'Passwort-Reset senden',
                                      onPressed: () async {
                                        if (await _send('POST',
                                            '/api/users/${user['id']}/password-reset'))
                                          _message(
                                              'Reset-E-Mail wurde angefordert.');
                                      },
                                      icon: const Icon(Icons.password)),
                                  IconButton(
                                      tooltip: 'Bearbeiten',
                                      onPressed: () => editUser(user),
                                      icon: const Icon(Icons.edit)),
                                  IconButton(
                                      tooltip: 'Löschen',
                                      onPressed: () => deleteUser(user),
                                      icon: const Icon(Icons.delete_outline)),
                                ]),
                              ));
                            })),
                  ]),
                  Column(children: [
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                                onPressed: () => editRole(),
                                icon: const Icon(Icons.add),
                                label: const Text('Rolle anlegen')))),
                    Expanded(
                        child: ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: roles
                                .map((role) => Card(
                                    child: ListTile(
                                        title: Text(role['name'].toString()),
                                        subtitle: Text(
                                            '${(role['permissions'] as List? ?? const []).length} Berechtigungen'),
                                        trailing: Wrap(children: [
                                          IconButton(
                                              tooltip: 'Rolle bearbeiten',
                                              onPressed: () => editRole(role),
                                              icon: const Icon(Icons.edit)),
                                          IconButton(
                                              tooltip: 'Rolle löschen',
                                              onPressed: () => deleteRole(role),
                                              icon: const Icon(
                                                  Icons.delete_outline)),
                                        ]))))
                                .toList())),
                  ]),
                  Column(children: [
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          const Expanded(
                              child: Text(
                                  'Zentrale Fachbereiche bilden den Geltungsbereich für Fachbereichsleiter.')),
                          FilledButton.icon(
                              onPressed: () => editDepartment(),
                              icon: const Icon(Icons.add),
                              label: const Text('Fachbereich anlegen')),
                        ])),
                    Expanded(
                        child: ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: departments
                                .map((department) => Card(
                                    child: ListTile(
                                        leading: Icon(
                                            department['active'] == false
                                                ? Icons.account_tree_outlined
                                                : Icons.account_tree),
                                        title:
                                            Text(department['name'].toString()),
                                        subtitle: Text(
                                            '${department['code']} · ${department['active'] == false ? 'Deaktiviert' : 'Aktiv'}'),
                                        trailing: Wrap(children: [
                                          IconButton(
                                              tooltip: 'Fachbereich bearbeiten',
                                              onPressed: () =>
                                                  editDepartment(department),
                                              icon: const Icon(Icons.edit)),
                                          IconButton(
                                              tooltip: 'Fachbereich löschen',
                                              onPressed: () =>
                                                  deleteDepartment(department),
                                              icon: const Icon(
                                                  Icons.delete_outline)),
                                        ]))))
                                .toList())),
                  ]),
                ]),
        ),
      );
}

class UserDialog extends StatefulWidget {
  final Map<String, dynamic>? user;
  final List<String> roles;
  final List<Map<String, dynamic>> departments;
  const UserDialog(
      {required this.user,
      required this.roles,
      this.departments = const [],
      super.key});
  @override
  State<UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<UserDialog> {
  late final name =
      TextEditingController(text: widget.user?['name']?.toString());
  late final username =
      TextEditingController(text: widget.user?['username']?.toString());
  late final email =
      TextEditingController(text: widget.user?['email']?.toString());
  final password = TextEditingController();
  late bool active = widget.user?['active'] != false;
  late Set<String> selectedRoles =
      ((widget.user?['roles'] as List?)?.map((e) => e.toString()).toSet()) ??
          {'Nutzer'};
  late Set<String> selectedDepartmentIds =
      ((widget.user?['departmentIds'] as List?)
              ?.map((e) => e.toString())
              .toSet()) ??
          {};

  @override
  Widget build(BuildContext context) => AlertDialog(
        title:
            Text(widget.user == null ? 'Nutzer anlegen' : 'Nutzer bearbeiten'),
        content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name')),
              TextField(
                  controller: username,
                  decoration: const InputDecoration(labelText: 'Nutzername *')),
              TextField(
                  controller: email,
                  decoration: const InputDecoration(labelText: 'E-Mail *')),
              if (widget.user != null)
                TextField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Neues Passwort (optional)',
                        helperText:
                            'Mind. 12 Zeichen, Groß-/Kleinbuchstabe, Zahl, Sonderzeichen')),
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Rollen',
                      style: Theme.of(context).textTheme.titleSmall)),
              ...widget.roles.map((role) => CheckboxListTile(
                  dense: true,
                  value: selectedRoles.contains(role),
                  title: Text(role),
                  onChanged: (value) => setState(() {
                        if (value == true)
                          selectedRoles.add(role);
                        else
                          selectedRoles.remove(role);
                      }))),
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Geleitete Fachbereiche',
                      style: Theme.of(context).textTheme.titleSmall)),
              if (widget.departments.isEmpty)
                const ListTile(
                    dense: true,
                    title: Text('Noch keine Fachbereiche angelegt.'))
              else
                ...widget.departments.map((department) => CheckboxListTile(
                    dense: true,
                    value: selectedDepartmentIds.contains(department['id']),
                    title: Text(department['name'].toString()),
                    subtitle: Text(department['code'].toString()),
                    enabled: department['active'] != false,
                    onChanged: (value) => setState(() {
                          if (value == true) {
                            selectedDepartmentIds
                                .add(department['id'].toString());
                          } else {
                            selectedDepartmentIds
                                .remove(department['id'].toString());
                          }
                        }))),
              SwitchListTile(
                  value: active,
                  title: const Text('Account aktiv'),
                  onChanged: (value) => setState(() => active = value)),
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () {
                final result = <String, dynamic>{
                  'name': name.text,
                  'username': username.text,
                  'email': email.text,
                  'roles': selectedRoles.toList(),
                  'departmentIds': selectedDepartmentIds.toList(),
                  'active': active
                };
                if (password.text.isNotEmpty)
                  result['password'] = password.text;
                Navigator.pop(context, result);
              },
              child: const Text('Speichern'))
        ],
      );
}

class DepartmentDialog extends StatefulWidget {
  final Map<String, dynamic>? department;
  const DepartmentDialog({this.department, super.key});

  @override
  State<DepartmentDialog> createState() => _DepartmentDialogState();
}

class _DepartmentDialogState extends State<DepartmentDialog> {
  late final name =
      TextEditingController(text: widget.department?['name']?.toString());
  late final code =
      TextEditingController(text: widget.department?['code']?.toString());
  late bool active = widget.department?['active'] != false;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.department == null
            ? 'Fachbereich anlegen'
            : 'Fachbereich bearbeiten'),
        content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration:
                      const InputDecoration(labelText: 'Bezeichnung *')),
              TextField(
                  controller: code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Kürzel *')),
              SwitchListTile(
                  value: active,
                  title: const Text('Fachbereich aktiv'),
                  onChanged: (value) => setState(() => active = value)),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, {
                    'name': name.text,
                    'code': code.text,
                    'active': active,
                  }),
              child: const Text('Speichern')),
        ],
      );
}

class RoleDialog extends StatefulWidget {
  final List<String> permissions;
  final Map<String, dynamic>? role;
  const RoleDialog({required this.permissions, this.role, super.key});
  @override
  State<RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<RoleDialog> {
  late final name =
      TextEditingController(text: widget.role?['name']?.toString());
  late final selected = (widget.role?['permissions'] as List? ?? const [])
      .map((permission) => permission.toString())
      .toSet();
  @override
  Widget build(BuildContext context) => AlertDialog(
          title:
              Text(widget.role == null ? 'Rolle anlegen' : 'Rolle bearbeiten'),
          content: SizedBox(
              width: 520,
              height: 520,
              child: Column(children: [
                TextField(
                    controller: name,
                    decoration:
                        const InputDecoration(labelText: 'Rollenname *')),
                const SizedBox(height: 8),
                Expanded(
                    child: ListView(
                        children: widget.permissions
                            .map((permission) => CheckboxListTile(
                                dense: true,
                                title: Text(permission),
                                value: selected.contains(permission),
                                onChanged: (value) => setState(() {
                                      if (value == true)
                                        selected.add(permission);
                                      else
                                        selected.remove(permission);
                                    })))
                            .toList()))
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () => Navigator.pop(context,
                    {'name': name.text, 'permissions': selected.toList()}),
                child: Text(widget.role == null ? 'Anlegen' : 'Speichern'))
          ]);
}
