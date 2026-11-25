import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rabbit_sketchbook/main.dart';
import 'package:rabbit_sketchbook/sketchflow.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LoadedSketchFlow implements SketchFlow {
  @override
  Future<void> dispose() async {}

  @override
  Future<List<List<Offset>>>? prepare(String id) => null;
}

void main() {
  testWidgets('download headings fit on one line with side insets', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(right: 72);
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => rootBundle.evict('assets/questions.json'));
    await tester.pumpWidget(const Sketchbook());
    final dynamic game = tester.state(find.byType(GameScreen));
    game.setState(() => game.phase = Phase.download);

    Future<void> expectHeading(String text) async {
      await tester.pump();
      final heading = find.text(text);
      expect(tester.widget<Text>(heading).maxLines, 1);
      expect(tester.widget<Text>(heading).softWrap, isFalse);
      final fitted = find
          .ancestor(of: heading, matching: find.byType(FittedBox))
          .first;
      expect(tester.widget<FittedBox>(fitted).fit, BoxFit.scaleDown);
      expect(tester.getSize(fitted).width, lessThanOrEqualTo(230));
    }

    await expectHeading('스케치북 준비하기');
    game.setState(() => game.openingSketchFlow = true);
    await expectHeading('스케치북을 준비 중이에요');
    game.setState(() {
      game.openingSketchFlow = false;
      game.sketchFlow = _LoadedSketchFlow();
    });
    await expectHeading('스케치북 준비 완료!');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the rabbit moves only when animations are enabled', (
    tester,
  ) async {
    const artwork = ValueKey('rabbit-art');
    Future<void> show({required bool reducedMotion}) => tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: const Center(
          child: RabbitIdle(
            child: SizedBox(key: artwork, width: 100, height: 100),
          ),
        ),
      ),
    );
    await show(reducedMotion: false);
    final resting = tester.getCenter(find.byKey(artwork));
    await tester.pump(const Duration(milliseconds: 1700));
    expect(tester.getCenter(find.byKey(artwork)).dy, lessThan(resting.dy));
    await show(reducedMotion: true);
    await tester.pump(const Duration(milliseconds: 1700));
    expect(tester.getCenter(find.byKey(artwork)), resting);
  });

  test('skipping unlocks three seconds after a drawing completes', () {
    const start = 48000;
    const level = 3;
    final completed = List.generate(5000, (i) => start + i).firstWhere(
      (elapsed) =>
          strokeProgressAt(
            elapsedMs: elapsed,
            questionStartedMs: start,
            level: level,
          ) ==
          1,
    );
    bool canSkip(int elapsed) =>
        canSkipAt(elapsedMs: elapsed, questionStartedMs: start, level: level);
    expect(canSkip(completed), isFalse);
    expect(canSkip(completed + 2999), isFalse);
    expect(canSkip(completed + 3000), isTrue);
  });
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
    expect(progress(62000, 61000), progress(63000, 62000));
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
      final music = find.widgetWithText(FilterChip, '음악');
      final effects = find.widgetWithText(FilterChip, '효과음');
      await tester.ensureVisible(music);
      await tester.tap(music);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<FilterChip>(music).selected, isFalse);
      expect(tester.widget<FilterChip>(effects).selected, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool('game_music'),
        isFalse,
      );
      await tester.ensureVisible(start);
      expect(tester.getBottomLeft(start).dy, lessThan(844));
      expect(tester.getCenter(start).dx, closeTo(195, 0.1));
      expect(tester.getSize(start).width, closeTo(230, 0.1));
      final heading = find.text('토끼의 낙서장');
      expect(tester.widget<Text>(heading).maxLines, 1);
      expect(tester.getCenter(heading).dx, closeTo(195, 0.1));
      tester.view.physicalSize = const Size(466, 678);
      await tester.pump();
      expect(tester.getSize(start).width, closeTo(290, 0.1));
      expect(tester.getCenter(start).dx, closeTo(233, 0.1));
      expect(tester.getCenter(heading).dx, closeTo(233, 0.1));
      tester.view.padding = const FakeViewPadding(left: 72);
      tester.view.viewPadding = const FakeViewPadding(left: 72);
      await tester.pump();
      expect(tester.getCenter(start).dx, closeTo(233, 0.1));
      tester.view.padding = const FakeViewPadding(right: 72);
      tester.view.viewPadding = const FakeViewPadding(right: 72);
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
      final skip = find.widgetWithText(TextButton, '건너뛰기 · −3초');
      expect(find.text('01:00'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNWidgets(4));
      expect(tester.widget<TextButton>(skip).onPressed, isNull);
      expect(tester.getBottomLeft(skip).dy, lessThan(844));
      final canvas = find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is StrokePainter,
      );
      expect(tester.getCenter(canvas).dx, closeTo(195, 0.1));
      tester.view.physicalSize = const Size(626, 890);
      tester.view.padding = const FakeViewPadding(right: 84);
      tester.view.viewPadding = const FakeViewPadding(right: 84);
      await tester.pump();
      expect(find.byKey(const ValueKey('wide-play-layout')), findsOneWidget);
      expect(
        tester.getTopRight(canvas).dx,
        lessThan(tester.getTopLeft(find.byType(OutlinedButton).first).dx),
      );
      expect(find.text('0점'), findsOneWidget);
      expect(tester.getBottomLeft(skip).dy, lessThan(890));
      tester.view.physicalSize = const Size(466, 678);
      tester.view.padding = const FakeViewPadding(right: 72);
      tester.view.viewPadding = const FakeViewPadding(right: 72);
      await tester.pump();
      expect(find.byKey(const ValueKey('wide-play-layout')), findsNothing);
      expect(tester.getCenter(canvas).dx, closeTo(233, 0.1));
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
      game.setState(() => game.lockedUntil = 0);
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, answer));
      await tester.pump();
      expect(game.deadlineMs, roundStartMs + correctBonusMs);
      expect(find.text('+1초'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 160));
      expect(canvas, findsNWidgets(2));
      final pages = canvas.evaluate().toList();
      expect(
        tester.getTopLeft(find.byWidget(pages.last.widget)).dy,
        lessThan(tester.getTopLeft(find.byWidget(pages.first.widget)).dy),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(canvas, findsOneWidget);
      game.finish();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      final replay = find.widgetWithText(FilledButton, '한 판 더');
      final home = find.widgetWithText(OutlinedButton, '홈으로');
      expect(tester.widget<Text>(find.text('한 판 더')).maxLines, 1);
      expect(tester.widget<Text>(find.text('홈으로')).maxLines, 1);
      expect(tester.getSize(replay).height, tester.getSize(home).height);
      expect(tester.getCenter(replay).dy, tester.getCenter(home).dy);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
