import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zelda_guardian/widgets/cancel_sos_button.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders a large CANCEL SOS tap target', (tester) async {
    await tester.pumpWidget(_wrap(CancelSosButton(onPressed: () {})));

    expect(find.text('CANCEL SOS'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    final size = tester.getSize(find.byType(ElevatedButton));
    expect(size.height, greaterThanOrEqualTo(64));
    expect(size.width, greaterThanOrEqualTo(200));
  });

  testWidgets('single tap invokes the callback exactly once', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_wrap(CancelSosButton(onPressed: () => calls++)));

    await tester.tap(find.text('CANCEL SOS'));
    await tester.pump();

    expect(calls, 1);
  });

  testWidgets('busy state shows CANCELLING and ignores taps', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _wrap(CancelSosButton(onPressed: () => calls++, busy: true)),
    );

    expect(find.text('CANCELLING…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('CANCELLING…'), warnIfMissed: false);
    await tester.pump();

    expect(calls, 0);
  });

  testWidgets('rapid double tap cannot issue duplicate requests',
      (tester) async {
    var calls = 0;
    var busy = false;
    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) {
            return CancelSosButton(
              onPressed: () {
                calls++;
                setState(() => busy = true);
              },
              busy: busy,
            );
          },
        ),
      ),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump(); // rebuild with busy = true

    await tester.tap(find.text('CANCELLING…'), warnIfMissed: false);
    await tester.pump();

    expect(calls, 1);
  });
}
