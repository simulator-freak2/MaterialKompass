import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/main.dart';

void main() {
  testWidgets('Login page renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialKompassApp());

    expect(find.text('MaterialKompass Login'), findsOneWidget);
    expect(find.text('Interne Materialverwaltung'), findsOneWidget);
  });
}
