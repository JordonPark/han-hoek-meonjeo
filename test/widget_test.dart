import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rabbit_sketchbook/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('strokes accelerate smoothly over the round', () {
    double progress(int elapsed, int start) => strokeProgressAt(
      elapsedMs: elapsed,
      questionStartedMs: start,
      level: 3,
    );
    expect(progress(50000, 50000), 0);
    expect(progress(51000, 50000), greaterThan(progress(1000, 0)));
    expect(
      progress(51001, 50000) - progress(51000, 50000),
      inInclusiveRange(0.0, 0.001),
    );
    expect(progress(60000, 50000), 1);
  });
  testWidgets(
    'starts an offline round with four options and skipping initially disabled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const Sketchbook());
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 50 &&
              tester
                      .widget<FilledButton>(find.byType(FilledButton))
                      .onPressed ==
                  null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      final start = find.widgetWithText(FilledButton, '시작');
      expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
      expect(tester.getBottomLeft(start).dy, lessThan(844));
      await tester.tap(start);
      await tester.pump();
      for (final label in ['3', '2', '1']) {
        expect(find.text(label), findsOneWidget);
        expect(find.text('01:00'), findsNothing);
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('게임 시작!'), findsOneWidget);
      expect(find.text('01:00'), findsNothing);
      await tester.pump(const Duration(milliseconds: 450));
      final skip = find.widgetWithText(TextButton, '건너뛰기');
      expect(find.text('01:00'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNWidgets(4));
      expect(tester.widget<TextButton>(skip).onPressed, isNull);
      expect(tester.getBottomLeft(skip).dy, lessThan(844));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
