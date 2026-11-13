import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlsnap/pin_code.dart';

Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.text(d));
    await tester.pump();
  }
}

Widget _host(PinPad pad) => MaterialApp(home: Scaffold(body: Center(child: SingleChildScrollView(child: pad))));

void main() {
  testWidgets('fixed length: submits automatically, wrong code shows error and clears', (tester) async {
    final submitted = <String>[];
    await tester.pumpWidget(_host(PinPad(
      title: 'Введите код',
      length: 4,
      onSubmit: (pin) async {
        submitted.add(pin);
        return pin == '1234' ? null : 'Неверный код';
      },
    )));

    await _type(tester, '9999');
    await tester.pumpAndSettle();
    expect(submitted, ['9999']);
    expect(find.text('Неверный код'), findsOneWidget);

    await _type(tester, '1234');
    await tester.pumpAndSettle();
    expect(submitted, ['9999', '1234']);
    expect(find.text('Неверный код'), findsNothing);
  });

  testWidgets('variable length: needs at least 4 digits, submits by check key', (tester) async {
    String? submitted;
    await tester.pumpWidget(_host(PinPad(
      title: 'Придумайте код',
      onSubmit: (pin) async {
        submitted = pin;
        return null;
      },
    )));

    await _type(tester, '123');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pump();
    expect(submitted, isNull, reason: 'check key is disabled below 4 digits');

    await _type(tester, '45');
    await tester.tap(find.byIcon(Icons.backspace_outlined));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();
    expect(submitted, '1234');
  });
}
