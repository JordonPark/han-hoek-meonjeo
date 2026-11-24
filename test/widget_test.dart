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
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(right: 72);
      tester.view.viewPadding = const FakeViewPadding(right: 72);
      addTearDown(tester.view.reset);
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
      expect(tester.getCenter(start).dx, closeTo(195, 0.1));
      expect(tester.getSize(start).width, closeTo(230, 0.1));
      final heading = find.text('토끼의 낙서장');
      expect(tester.widget<Text>(heading).maxLines, 1);
      expect(tester.getCenter(heading).dx, closeTo(195, 0.1));
      tester.view.physicalSize = const Size(466, 678);
      await tester.pump();
      expect(tester.getSize(start).width, closeTo(362, 0.1));
      expect(tester.getBottomLeft(start).dy, lessThan(678));
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
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
      final canvas = find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is StrokePainter,
      );
      expect(tester.getCenter(canvas).dx, closeTo(195, 0.1));
      tester.view.physicalSize = const Size(669, 951);
      await tester.pump();
      expect(find.byKey(const ValueKey('wide-play-layout')), findsOneWidget);
      expect(
        tester.getTopRight(canvas).dx,
        lessThan(tester.getTopLeft(find.byType(OutlinedButton).first).dx),
      );
      expect(find.text('0점'), findsOneWidget);
      expect(tester.getBottomLeft(skip).dy, lessThan(951));
      tester.view.physicalSize = const Size(466, 678);
      await tester.pump();
      expect(find.byKey(const ValueKey('wide-play-layout')), findsNothing);
      expect(
        tester.getBottomLeft(canvas).dy,
        lessThan(tester.getTopLeft(find.byType(OutlinedButton).first).dy),
      );
      expect(find.text('0점'), findsOneWidget);
      final dynamic game = tester.state(find.byType(GameScreen));
      final options = game.options as List<String>;
      final answer = (game.prompt as Prompt).label;
      final wrong = options.firstWhere((option) => option != answer);
      await tester.tap(find.widgetWithText(OutlinedButton, wrong));
      await tester.pump();
      expect(find.text('틀렸어요'), findsOneWidget);
      expect(find.text('✕ $wrong'), findsOneWidget);
      expect(
        tester
            .widgetList<OutlinedButton>(find.byType(OutlinedButton))
            .every((button) => button.onPressed == null),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
