import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/widgets/mail_count_badge.dart';

void main() {
  testWidgets('mail badge stays hidden for zero emails', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MailCountBadge(
          count: 0,
          areaLabel: 'Mängel',
          child: Icon(Icons.report_problem_outlined),
        ),
      ),
    );

    expect(find.byType(Badge), findsNothing);
    expect(find.byIcon(Icons.report_problem_outlined), findsOneWidget);
  });

  testWidgets(
    'mail badge limits its visible value and exposes the exact count',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: MailCountBadge(
                count: 123,
                areaLabel: 'Beschaffung',
                child: Icon(Icons.shopping_cart_outlined),
              ),
            ),
          ),
        );

        expect(find.text('99+'), findsOneWidget);
        expect(
          tester.getSemantics(find.byType(MailCountBadge)).label,
          contains('Beschaffung, 123 unbearbeitete E-Mails'),
        );
      } finally {
        semantics.dispose();
      }
    },
  );
}
