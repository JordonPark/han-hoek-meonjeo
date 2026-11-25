import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rabbit_sketchbook/main.dart';
import 'package:rabbit_sketchbook/quiz_balance.dart';
import 'package:rabbit_sketchbook/sketchflow.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LoadedSketchFlow implements SketchFlow {
  @override
  Future<void> dispose() async {}

  @override
  Future<List<List<Offset>>>? prepare(String id) => null;
}

void main() {
  test('levels increase every two points and assistance lowers one level', () {
    expect(List.generate(10, quizLevel), [1, 1, 2, 2, 3, 3, 4, 4, 5, 5]);
    expect(quizLevel(8, assistance: true), 4);
    expect(quizLevel(0, assistance: true), 1);
  });

  test('distractor mix changes by level and excludes ambiguous pairs', () {
    const ranked = ['mug', 'coffee cup', 'bowl', 'bucket', 'vase', 'teapot'];
    for (var level = 1; level <= 5; level++) {
      final choices = quizDistractors(
        answer: 'cup',
        candidates: {...ranked, 'cup', 'star', 'cat', 'airplane'},
        ranked: ranked,
        level: level,
        random: Random(1),
      );
      expect(choices.similar, hasLength(min(level - 1, 3)));
      expect(choices.distinct, hasLength(3 - choices.similar.length));
      expect([...choices.similar, ...choices.distinct], isNot(contains('mug')));
    }
  });

  test(
    'drawing validation rejects obvious jumps but accepts a resampled line',
    () {
      final line = List.generate(21, (i) => Offset(i / 20, 0));
      expect(hasSketchArtifacts([line], 1), isFalse);
      expect(
        hasSketchArtifacts([
          [...line, const Offset(0, 1)],
        ], 1),
        isTrue,
      );
    },
  );

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
    addTearDown(() {
      rootBundle.evict('assets/questions.json');
      rootBundle.evict('assets/related_questions.json');
      rootBundle.evict('assets/outline_questions.json');
    });
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

  test('skipping unlocks two seconds after a drawing completes', () {
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
    expect(canSkip(completed + skipWaitMs - 1), isFalse);
    expect(canSkip(completed + skipWaitMs), isTrue);
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
    'plays and reviews an offline round from setup without downloading AI',
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
      final dynamic game = tester.state(find.byType(GameScreen));
      game.setState(() => game.phase = Phase.download);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      final basic = find.widgetWithText(OutlinedButton, '기본 그림으로 시작');
      await tester.ensureVisible(basic);
      expect(tester.takeException(), isNull);
      await tester.tap(basic);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pump();
      expect(
        (await SharedPreferences.getInstance()).getBool(sketchFlowSetupKey),
        isTrue,
      );
      expect(game.aiRound, isFalse);
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
      final original = List<String>.of(game.options as List<String>);
      const longOption = '아주 긴 제시어가 들어간 보기';
      game.setState(() => game.options = [longOption, ...original.skip(1)]);
      await tester.pump();
      final longText = find.text(longOption);
      expect(tester.widget<Text>(longText).maxLines, 1);
      expect(
        tester.getSize(find.widgetWithText(OutlinedButton, longOption)).height,
        greaterThanOrEqualTo(48),
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      final enlargedOptions = find.byType(OutlinedButton);
      expect(enlargedOptions, findsNWidgets(4));
      expect(tester.getSize(enlargedOptions.first).width, closeTo(238, 0.1));
      expect(
        tester.getTopLeft(enlargedOptions.at(1)).dy,
        greaterThan(tester.getBottomLeft(enlargedOptions.first).dy),
      );
      expect(tester.takeException(), isNull);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      game.setState(() => game.options = original);
      await tester.pump();
      final sketchbook = find.byKey(const ValueKey('play-sketchbook'));
      expect(tester.getSize(sketchbook).width, closeTo(238, 0.1));
      expect(
        tester.getTopLeft(find.byType(OutlinedButton).first).dy -
            tester.getBottomLeft(sketchbook).dy,
        closeTo(10, 0.1),
      );
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
      final options = game.options as List<String>;
      final answer = (game.prompt as Prompt).label;
      expect(familiarQuestions, contains((game.prompt as Prompt).id));
      expect(openingQuestions, contains((game.prompt as Prompt).id));
      final wrong = options.firstWhere((option) => option != answer);
      await tester.tap(find.widgetWithText(OutlinedButton, wrong));
      await tester.pump();
      expect(find.text('틀렸어요'), findsOneWidget);
      expect(find.text('✕ $wrong'), findsOneWidget);
      expect(
        (game.lockedUntil as int) - (game.elapsed as int),
        inInclusiveRange(650, 800),
      );
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
      expect(
        (game.roundResults as List<QuizResult>).single.outcome,
        QuizOutcome.correct,
      );
      expect((game.roundResults as List<QuizResult>).single.wrongTaps, 1);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      game.answer((game.prompt as Prompt).label);
      game.bonusGrantedMs = maxRoundBonusMs;
      final cappedDeadline = game.deadlineMs;
      game.answer((game.prompt as Prompt).label);
      await tester.pump();
      expect(canvas, findsOneWidget);
      expect(game.deadlineMs, cappedDeadline);
      expect(find.text('3연속 정답!'), findsOneWidget);
      game.deadlineMs = (game.elapsed as int) + 9000;
      game.tick();
      expect(game.finalTenCuePlayed, isTrue);
      final reviewed = game.prompt as Prompt;
      game.missed.add((reviewed.label, reviewed.drawings.first));
      game.finish();
      expect(game.lastBalanceSummary, contains('정답 3개 · 오답 1회'));
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      final replay = find.widgetWithText(FilledButton, '한 판 더');
      final home = find.widgetWithText(OutlinedButton, '홈으로');
      expect(tester.widget<Text>(find.text('한 판 더')).maxLines, 1);
      expect(tester.widget<Text>(find.text('홈으로')).maxLines, 1);
      expect(tester.getSize(replay).height, tester.getSize(home).height);
      expect(tester.getCenter(replay).dy, tester.getCenter(home).dy);
      final missedCard = find.text(reviewed.label);
      await tester.ensureVisible(missedCard);
      await tester.tap(missedCard);
      await tester.pumpAndSettle();
      expect(find.text('다시 맞히기'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, reviewed.label));
      await tester.pump();
      expect(find.text('정답이에요!'), findsOneWidget);
      expect(game.score, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
