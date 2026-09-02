import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/widgets/keyboard_dropdown_button_form_field.dart';

void main() {
  testWidgets('selects and cycles matching entries while closed', (
    tester,
  ) async {
    String? selected = 'Alpha';
    final changes = <String?>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return KeyboardDropdownButtonFormField<String>(
                initialValue: selected,
                autofocus: true,
                items: const [
                  DropdownMenuItem(value: 'Alpha', child: Text('Alpha')),
                  DropdownMenuItem(value: 'Beta', child: Text('Beta')),
                  DropdownMenuItem(value: 'Berlin', child: Text('Berlin')),
                ],
                onChanged: (value) {
                  changes.add(value);
                  setState(() => selected = value);
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b'),
      isTrue,
    );
    await tester.pump();
    expect(selected, 'Beta');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
    await tester.pump();
    expect(selected, 'Berlin');
    expect(changes, ['Beta', 'Berlin']);
  });

  testWidgets('supports prefixes and umlaut-insensitive matching', (
    tester,
  ) async {
    String? selected = 'Start';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return KeyboardDropdownButtonFormField<String>(
                initialValue: selected,
                autofocus: true,
                items: const [
                  DropdownMenuItem(value: 'Start', child: Text('Start')),
                  DropdownMenuItem(value: 'Äther', child: Text('Äther')),
                  DropdownMenuItem(value: 'Mango', child: Text('Mango')),
                  DropdownMenuItem(value: 'Material', child: Text('Material')),
                ],
                onChanged: (value) => setState(() => selected = value),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
    await tester.pump();
    expect(selected, 'Äther');

    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM, character: 'm');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT, character: 't');
    await tester.pump();
    expect(selected, 'Material');
  });

  testWidgets('highlights an open-menu match and confirms it with Enter', (
    tester,
  ) async {
    String? selected = 'Alpha';
    final changes = <String?>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return KeyboardDropdownButtonFormField<String>(
                initialValue: selected,
                items: const [
                  DropdownMenuItem(value: 'Alpha', child: Text('Alpha')),
                  DropdownMenuItem(value: 'Beta', child: Text('Beta')),
                  DropdownMenuItem(value: 'Charlie', child: Text('Charlie')),
                ],
                onChanged: (value) {
                  changes.add(value);
                  setState(() => selected = value);
                },
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
    await tester.pump();

    expect(selected, 'Alpha');
    expect(changes, isEmpty);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'KeyboardDropdown menu item 1',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'Beta');
    expect(changes, ['Beta']);
  });

  testWidgets('ignores modified shortcuts and disabled entries', (
    tester,
  ) async {
    String? selected = 'Alpha';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return KeyboardDropdownButtonFormField<String>(
                initialValue: selected,
                autofocus: true,
                items: const [
                  DropdownMenuItem(value: 'Alpha', child: Text('Alpha')),
                  DropdownMenuItem(
                    value: 'Beta disabled',
                    enabled: false,
                    child: Text('Beta disabled'),
                  ),
                  DropdownMenuItem(value: 'Berlin', child: Text('Berlin')),
                ],
                onChanged: (value) => setState(() => selected = value),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(selected, 'Alpha');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
    await tester.pump();
    expect(selected, 'Berlin');
  });
}
