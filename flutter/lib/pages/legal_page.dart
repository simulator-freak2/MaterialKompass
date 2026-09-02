import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';

class LegalPage extends StatefulWidget {
  final int initialTab;
  const LegalPage({this.initialTab = 0, super.key});

  @override
  State<LegalPage> createState() => _LegalPageState();
}

class _LegalPageState extends State<LegalPage> {
  late final Future<Map<String, dynamic>> information = _load();

  Future<Map<String, dynamic>> _load() async {
    final response = await http.get(Uri.parse('$apiBaseUrl/api/legal'));
    if (response.statusCode != 200) {
      throw Exception(
        'Rechtliche Informationen sind derzeit nicht erreichbar.',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  String text(Map data, String key) => data[key]?.toString() ?? '–';

  Widget address(Map data) => SelectableText(
    [
      text(data, 'name'),
      text(data, 'legalForm'),
      'Vertreten durch: ${text(data, 'representedBy')}',
      text(data, 'street'),
      '${text(data, 'postalCode')} ${text(data, 'city')}',
      text(data, 'country'),
      'E-Mail: ${text(data, 'email')}',
      'Telefon: ${text(data, 'phone')}',
    ].join('\n'),
  );

  Widget section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );

  Widget list(Object? entries) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: (entries as List? ?? const [])
        .map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('• $entry'),
          ),
        )
        .toList(),
  );

  Widget imprint(Map<String, dynamic> data) {
    final provider = Map<String, dynamic>.from(data['provider'] as Map);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (data['hasDummies'] == true)
          const Card(
            color: Color(0xFFFFE0B2),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Hinweis für den Betreiber: Die gekennzeichneten DUMMY-Angaben müssen vor dem Produktivbetrieb ersetzt werden.',
              ),
            ),
          ),
        section('Anbieter gemäß § 5 DDG', address(provider)),
        section(
          'Register',
          SelectableText(
            '${text(provider, 'register')}\nRegisternummer: ${text(provider, 'registerNumber')}',
          ),
        ),
        section('Umsatzsteuer-ID', SelectableText(text(provider, 'vatId'))),
        section(
          'Verantwortung für Inhalte',
          const Text(
            'Der Anbieter ist für eigene Inhalte nach den allgemeinen Gesetzen verantwortlich.',
          ),
        ),
      ],
    );
  }

  Widget privacy(Map<String, dynamic> data) {
    final privacy = Map<String, dynamic>.from(data['privacy'] as Map);
    final controller = Map<String, dynamic>.from(privacy['controller'] as Map);
    final dpo = Map<String, dynamic>.from(
      privacy['dataProtectionOfficer'] as Map,
    );
    final authority = Map<String, dynamic>.from(
      privacy['supervisoryAuthority'] as Map,
    );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Stand: ${data['version']}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        section('1. Verantwortlicher', address(controller)),
        section(
          '2. Datenschutzbeauftragte Stelle',
          SelectableText(
            '${text(dpo, 'name')}\n${text(dpo, 'address')}\nE-Mail: ${text(dpo, 'email')}',
          ),
        ),
        section('3. Zwecke der Verarbeitung', list(privacy['purposes'])),
        section('4. Rechtsgrundlagen', list(privacy['legalBases'])),
        section('5. Empfänger', list(privacy['recipients'])),
        section('6. Drittlandübermittlungen', Text(text(privacy, 'transfers'))),
        section('7. Speicherdauer', list(privacy['retention'])),
        section('8. Ihre Rechte', list(privacy['rights'])),
        section(
          '9. Erforderlichkeit der Angaben',
          Text(text(privacy, 'requiredData')),
        ),
        section(
          '10. Automatisierte Entscheidungen',
          Text(text(privacy, 'automatedDecisions')),
        ),
        section(
          '11. Lokale Speicherung und Cookies',
          Text(text(privacy, 'localStorage')),
        ),
        section(
          '12. Beschwerderecht',
          SelectableText(
            '${text(authority, 'name')}\n${text(authority, 'address')}\n${text(authority, 'website')}',
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    initialIndex: widget.initialTab,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Rechtliche Informationen'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Anbieterangaben'),
            Tab(text: 'Datenschutz'),
          ],
        ),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: information,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(snapshot.error.toString()));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return TabBarView(
            children: [imprint(snapshot.data!), privacy(snapshot.data!)],
          );
        },
      ),
    ),
  );
}
