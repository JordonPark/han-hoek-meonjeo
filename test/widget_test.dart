import 'dart:convert';
import 'dart:io';
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
    'level four uses related choices and level five favors the actual outline',
    () {
      List<String> choices(int level) => quizDistractors(
        answer: 'firetruck',
        candidates: {
          'firetruck',
          'ambulance',
          'truck',
          'bus',
          'tractor',
          'bulldozer',
          'train',
          'van',
          'school bus',
          'police car',
        },
        ranked: [
          'ambulance',
          'truck',
          'train',
          'school bus',
          'van',
          'police car',
        ],
        outlineRanked: [
          'ambulance',
          'truck',
          'police car',
          'train',
          'van',
          'school bus',
        ],
        indistinguishable: {'train'},
        level: level,
        random: Random(1),
      ).similar;

      expect(choices(4), unorderedEquals(['bus', 'tractor', 'bulldozer']));
      expect(choices(5), unorderedEquals(['police car', 'van', 'school bus']));
    },
  );

  test('progress review compares paired entry rounds and counts timeouts separately', () {
    QuizResult row(
      int level,
      QuizOutcome outcome, {
      String id = 'apple',
      bool assisted = false,
      bool entering = false,
    }) => QuizResult(
      level: level,
      questionId: id,
      generated: false,
      storedDrawingIndex: 1,
      assisted: assisted,
      enteringLevelFive: entering,
      outcome: outcome,
      wrongTaps: 0,
      firstTapMs: null,
      durationMs: 2000,
    );

    final prefix = [
      row(1, QuizOutcome.skipped),
      for (var score = 0; score < 7; score++)
        row(quizLevel(score), QuizOutcome.correct, id: 'banana'),
    ];
    final recorded = QuizBalanceHistory([
      jsonEncode({
        'firstPlay': true,
        'questions': [
          ...prefix.map((row) => row.toJson()),
          row(4, QuizOutcome.skipped).toJson(),
          row(4, QuizOutcome.correct).toJson(),
          row(5, QuizOutcome.skipped, id: 'house', entering: true).toJson(),
          row(5, QuizOutcome.wrong).toJson(),
          row(4, QuizOutcome.correct, assisted: true).toJson(),
          row(5, QuizOutcome.timeUp).toJson(),
        ],
      }),
      jsonEncode({
        'questions': [
          ...prefix.map((row) => row.toJson()),
          row(4, QuizOutcome.skipped).toJson(),
          row(4, QuizOutcome.skipped).toJson(),
          row(3, QuizOutcome.correct, assisted: true).toJson(),
        ],
      }),
    ]);
    final report = {
      for (final section in recorded.levelProgressReview({
        'apple': '사과',
        'house': '집',
      }))
        section.title: section.value,
    };
    expect(report['첫 두 문제에서 첫 정답'], contains('새 설치 첫 플레이 1/1판 · 평균 4.0초'));
    expect(report['첫 두 문제에서 첫 정답'], contains('사과 · 샘플 2번 · 건너뛰기'));
    expect(report['초반에 반복해서 놓친 그림'], '사과 · 샘플 2번 · 2/2회 놓침');
    expect(report['4단계에서 5단계로'], contains('4단계 · 정답 1/2 · 건너뛰기 1/2 (50%)'));
    expect(report['4단계에서 5단계로'], contains('건너뛰기 변화 +50%p'));
    expect(report['첫 5단계에서 건너뛴 그림'], '집 · 샘플 2번');
    expect(report['회복 문제와 복귀 직후'], contains('회복 문제 · 정답 2/2'));
    expect(report['회복 문제와 복귀 직후'], contains('완료 0문제 · 시간 종료 1회'));
    expect(report['회복 문제와 복귀 직후'], contains('복귀 전에 끝난 판 1회'));
  });

  test('AI outlines keep recognizable drawings and block ambiguous rivals', () {
    final vertical = [
      [const Offset(.5, .1), const Offset(.5, .9)],
    ];
    final horizontal = [
      [const Offset(.1, .5), const Offset(.9, .5)],
    ];
    final leftToRight = [
      [const Offset(.9, .5), const Offset(.1, .5)],
    ];
    final matching = assessQuizOutline(
      leftToRight,
      [horizontal],
      {
        'vertical': [vertical],
        'alias': [horizontal],
      },
      plausibleRivals: {'alias'},
    );
    expect(matching.usable, isTrue);
    expect(matching.ranked.first, 'alias');
    expect(matching.ambiguous, {'alias'});
    expect(
      assessQuizOutline(
        leftToRight,
        [vertical],
        {
          'rival': [horizontal],
        },
        plausibleRivals: {'rival'},
      ).usable,
      isFalse,
    );
  });

  test(
    'first level-five question mixes two silhouettes with a related option',
    () {
      final profiles = [
        for (final entering in [true, false])
          quizDistractors(
            answer: 'answer',
            candidates: {'a', 'b', 'c', 'd', 'x', 'y', 'z'},
            ranked: ['a', 'b', 'c', 'd'],
            outlineRanked: ['a', 'b', 'c'],
            level: 5,
            enteringLevelFive: entering,
            random: Random(42),
          ).similar,
      ];
      expect(profiles.first, ['a', 'b', 'd']);
      expect(profiles.last, ['a', 'b', 'c']);
      final recovery = quizDistractors(
        answer: 'answer',
        candidates: {'a', 'b', 'c', 'd', 'x', 'y', 'z'},
        ranked: ['a', 'b', 'c', 'd'],
        outlineRanked: ['a', 'b', 'c'],
        level: 4,
        recovery: true,
        random: Random(42),
      );
      expect(recovery.similar, ['d']);
      expect(recovery.distinct, hasLength(2));
    },
  );

  test('selection favors readable openings and separates similar prompts', () {
    String pick(List<String> deck, {bool early = false}) => chooseQuizQuestion(
      shuffled: deck,
      earlyDrawing: early,
      familiar: false,
      tooHard: (id) => id == 'star',
      repeatsPrevious: (id) => id == 'moon' || id == 'cloud',
    );

    expect(pick(['moon', 'cloud', 'star', 'bicycle'], early: true), 'bicycle');
    expect(pick(['moon', 'cloud', 'elephant'], early: true), 'elephant');
    expect(pick(['moon', 'cloud'], early: true), 'moon');
    expect(pick(['moon', 'elephant', 'cloud']), 'elephant');
  });

  test('every shipped outline can supply three eligible choices at all five levels', () {
    Map readAsset(String name) =>
        jsonDecode(File('assets/$name.json').readAsStringSync()) as Map;
    final outlines = readAsset('outline_questions');
    final related = readAsset('related_questions');
    final candidates = outlines.keys.cast<String>().toSet();
    final random = Random(1);
    expect(candidates, hasLength(345));
    for (final answer in candidates) {
      final row = outlines[answer] as Map;
      final visual = row['visualByDrawing'] as List;
      final ambiguous = row['ambiguousByDrawing'] as List;
      expect(visual, hasLength(6));
      expect(
        row['earlyByDrawing'],
        unorderedEquals(List.generate(6, (i) => i)),
      );
      for (final (index, ranks) in visual.indexed) {
        final blocked = (ambiguous[index] as List).cast<String>().toSet();
        for (var profile = 1; profile <= 6; profile++) {
          final level = min(5, profile);
          final choices = quizDistractors(
            answer: answer,
            candidates: candidates,
            ranked: (related[answer] as List).cast<String>(),
            outlineRanked: (ranks as List).cast<String>(),
            indistinguishable: blocked,
            level: level,
            enteringLevelFive: profile == 6,
            random: random,
          );
          final distinct = {...choices.similar, ...choices.distinct};
          final reason = '$answer drawing $index profile $profile';
          expect(distinct, hasLength(3), reason: reason);
          expect(
            distinct.intersection({answer, ...blocked}),
            isEmpty,
            reason: reason,
          );
        }
      }
    }
  });

  test(
    'history records opening, promotion, skips and assistance separately',
    () {
      Map<String, Object?> row(
        int level,
        QuizOutcome outcome, {
        String id = 'firetruck',
        bool assisted = false,
        bool enteringLevelFive = false,
        List<String> wrongChoices = const [],
      }) => QuizResult(
        level: level,
        questionId: id,
        generated: false,
        assisted: assisted,
        enteringLevelFive: enteringLevelFive,
        outcome: outcome,
        wrongTaps: 0,
        firstTapMs: outcome == QuizOutcome.skipped ? 8000 : 1000,
        finishedWrongChoices: wrongChoices,
        durationMs: 8000,
      ).toJson();

      final history = QuizBalanceHistory([
        jsonEncode({
          'questions': [
            row(1, QuizOutcome.correct, id: 'apple'),
            row(1, QuizOutcome.correct, id: 'banana'),
            row(2, QuizOutcome.skipped),
            row(2, QuizOutcome.skipped),
            row(1, QuizOutcome.correct, assisted: true, id: 'fish'),
            row(2, QuizOutcome.skipped, wrongChoices: ['버스']),
            row(2, QuizOutcome.wrong, wrongChoices: ['버스']),
            row(5, QuizOutcome.correct, enteringLevelFive: true),
          ],
        }),
      ]);
      expect(history.openingSummary, '정답 1/1 · 첫 선택 1.0초 · 건너뛰기 0%');
      expect(history.secondSummary, '정답 1/1 · 첫 선택 1.0초 · 건너뛰기 0%');
      expect(history.earlyFirstCorrectSummary, '1/1판 · 평균 8.0초');
      expect(history.levelFiveEntrySummary, '정답 1/1 · 첫 선택 1.0초 · 건너뛰기 0%');
      expect(history.finishedPairCandidates().single, (
        id: 'firetruck',
        choice: '버스',
        count: 2,
      ));
      expect(history.promotedSummary(2), '정답 0/1 · 첫 선택 — · 건너뛰기 100%');
      expect(history.assistedSummary(1), '정답 1/1 · 첫 선택 1.0초 · 건너뛰기 0%');
      expect(history.tooHardForEarlyLevels('firetruck'), isTrue);
      expect(history.tooHardForEarlyLevels('fish'), isFalse);
    },
  );

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
    expect(find.widgetWithText(FilledButton, 'AI 그림 다운로드'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '기본 그림으로 시작'), findsOneWidget);
    final music = find.widgetWithText(FilterChip, '음악');
    await tester.ensureVisible(music);
    await tester.tap(music);
    await tester.pump();
    expect(tester.widget<FilterChip>(music).selected, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool('game_music'),
      isFalse,
    );
    game.setState(() => game.openingSketchFlow = true);
    await expectHeading('스케치북을 준비 중이에요');
    expect(music, findsNothing);
    game.setState(() {
      game.openingSketchFlow = false;
      game.sketchFlow = _LoadedSketchFlow();
    });
    await expectHeading('스케치북 준비 완료!');
    expect(find.widgetWithText(FilledButton, 'AI 그림으로 시작'), findsOneWidget);
    expect(tester.widget<FilterChip>(music).selected, isFalse);
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
      final startCue = find.text('게임 시작!');
      expect(startCue, findsOneWidget);
      expect(tester.widget<Text>(startCue).style?.fontFamily, 'Gaegu');
      expect(find.text('01:00'), findsNothing);
      final initialCueX = tester.getCenter(startCue).dx;
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getCenter(startCue).dx, isNot(closeTo(initialCueX, 0.1)));
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('game-start-shake')), findsNothing);
      expect(startCue, findsOneWidget);
      await tester.pump(
        gameStartCueDuration - const Duration(milliseconds: 60),
      );
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      await tester.pump();
      final skip = find.byKey(const ValueKey('skip-question'));
      expect(find.text('01:00'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNWidgets(4));
      expect(tester.widget<TextButton>(skip).onPressed, isNull);
      expect(
        find.descendant(
          of: skip,
          matching: find.byIcon(Icons.lock_outline_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: skip, matching: find.text('−3초')),
        findsOneWidget,
      );
      expect(tester.getSize(skip).height, greaterThanOrEqualTo(48));
      expect(tester.getBottomLeft(skip).dy, lessThan(844));
      final original = List<String>.of(game.options as List<String>);
      const longOption = '아주 긴 제시어가 들어간 보기';
      game.setState(() => game.options = [longOption, ...original.skip(1)]);
      await tester.pump();
      final longText = find.text(longOption);
      expect(tester.widget<Text>(longText).maxLines, 1);
      final longChoice = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, longOption),
      );
      expect(longChoice.style?.textStyle?.resolve({})?.fontFamily, 'Gaegu');
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
        closeTo(38, 0.1),
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
      final firstPrompt = game.prompt as Prompt;
      final answer = firstPrompt.label;
      final correctChoice = find.widgetWithText(OutlinedButton, answer);
      final choicePosition = tester.getCenter(correctChoice);
      expect(familiarQuestions, contains((game.prompt as Prompt).id));
      expect(openingQuestions, contains((game.prompt as Prompt).id));
      final wrong = options.firstWhere((option) => option != answer);
      await tester.tap(find.widgetWithText(OutlinedButton, wrong));
      await tester.pump();
      expect(find.text('틀렸어요'), findsOneWidget);
      expect(find.text('곧 다른 보기를 누를 수 있어요'), findsOneWidget);
      expect(tester.getCenter(correctChoice), choicePosition);
      final retryProgress = find.byKey(const ValueKey('retry-wait-progress'));
      expect(
        tester.widget<LinearProgressIndicator>(retryProgress).value,
        inInclusiveRange(0.0, 1.0),
      );
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
      game.setState(() => game.lockedUntil = (game.elapsed as int) - 1);
      await tester.pump();
      expect(retryProgress, findsNothing);
      final retryCue = find.text('다른 보기를 눌러 다시 답해요');
      expect(retryCue, findsOneWidget);
      expect(
        tester.getBottomLeft(retryCue).dy,
        lessThan(tester.getTopLeft(correctChoice).dy),
      );
      expect(tester.getCenter(correctChoice), choicePosition);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, answer))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '✕ $wrong'),
            )
            .onPressed,
        isNull,
      );
      final retryChoice = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, answer),
      );
      expect(retryChoice.style?.side?.resolve({})?.color, blue);
      game.setState(() => game.lockedUntil = (game.elapsed as int) - 1500);
      await tester.pump();
      expect(retryCue, findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, answer));
      await tester.pump();
      final secondPrompt = game.prompt as Prompt;
      expect(openingQuestions, contains(secondPrompt.id));
      expect(secondPrompt.id, isNot(firstPrompt.id));
      expect(game.aiDrawing, isFalse);
      final earlyIndex =
          reviewedStoredQuestions[secondPrompt.id]?.first ??
          (game.earlyDrawingsById[secondPrompt.id] as List<int>).first;
      expect(game.drawing, same(secondPrompt.drawings[earlyIndex]));
      expect(retryCue, findsNothing);
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
      final reviewChoice = find.widgetWithText(OutlinedButton, reviewed.label);
      expect(
        tester
            .widget<OutlinedButton>(reviewChoice)
            .style
            ?.textStyle
            ?.resolve({})
            ?.fontFamily,
        'Gaegu',
      );
      await tester.tap(reviewChoice);
      await tester.pump();
      expect(find.text('정답이에요!'), findsOneWidget);
      expect(game.score, 3);
      final preferences = await SharedPreferences.getInstance();
      final logged = jsonDecode(
        preferences.getStringList(balanceHistoryKey)!.single,
      ) as Map;
      expect(logged['firstPlay'], isTrue);
      expect(
        (logged['questions'] as List).first['storedDrawingIndex'],
        isA<int>(),
      );
      await tester.tap(find.widgetWithText(TextButton, '닫기'));
      await tester.pumpAndSettle();
      await tester.tap(home);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '앱 정보'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '레벨 진행 검수'));
      await tester.pumpAndSettle();
      expect(find.text('레벨 진행 검수').last, findsOneWidget);
      String? copiedReport;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedReport = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.tap(find.widgetWithText(TextButton, '기록 복사'));
      await tester.pumpAndSettle();
      expect(copiedReport, contains('새 설치 첫 플레이 1/1판'));
      expect(copiedReport, contains('회복 문제와 복귀 직후'));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
