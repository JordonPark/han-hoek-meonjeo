import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset;

int quizLevel(int score, {bool assistance = false}) =>
    max(1, min(5, 1 + score ~/ 2) - (assistance ? 1 : 0));

const openingQuestions = {
  'apple',
  'banana',
  'bicycle',
  'cloud',
  'flower',
  'guitar',
  'moon',
  'mushroom',
  'rainbow',
  'square',
  'star',
  'triangle',
  'umbrella',
};

const familiarQuestions = {
  'airplane',
  'apple',
  'banana',
  'basketball',
  'bicycle',
  'bird',
  'book',
  'bread',
  'bus',
  'butterfly',
  'cactus',
  'cake',
  'camera',
  'candle',
  'car',
  'carrot',
  'cat',
  'chair',
  'circle',
  'clock',
  'cloud',
  'computer',
  'dog',
  'donut',
  'door',
  'duck',
  'elephant',
  'envelope',
  'eyeglasses',
  'fish',
  'flower',
  'fork',
  'guitar',
  'hamburger',
  'hammer',
  'hand',
  'hat',
  'house',
  'ice cream',
  'key',
  'ladder',
  'leaf',
  'light bulb',
  'moon',
  'mushroom',
  'octopus',
  'pencil',
  'pizza',
  'rabbit',
  'rainbow',
  'scissors',
  'smiley face',
  'snail',
  'snowman',
  'soccer ball',
  'spoon',
  'square',
  'star',
  'sun',
  'table',
  'television',
  'tent',
  'toothbrush',
  'train',
  'tree',
  'triangle',
  'umbrella',
  'vase',
  'watermelon',
  'whale',
};

// Zero-based indices in questions.json. Each reviewed sample shows the
// distinguishing feature that was repeatedly missing in the AI review.
const reviewedStoredQuestions = {
  'firetruck': [3, 5],
  'ambulance': [3, 4],
  'key': [4, 5],
  'golf club': [0, 2],
  'fish': [3, 2],
  'umbrella': [2, 0],
  'garden hose': [0, 5],
  'pear': [1, 2],
};

const _curated = <String, List<String>>{
  'apple': ['pear', 'onion', 'potato', 'peanut'],
  'cat': ['rabbit', 'dog', 'raccoon', 'tiger'],
  'firetruck': ['bus', 'tractor', 'bulldozer'],
  'fish': ['shark', 'dolphin', 'whale'],
  'golf club': ['hockey stick', 'baseball bat', 'tennis racquet'],
  'hamburger': ['sandwich', 'hot dog', 'cookie'],
  'octopus': ['spider', 'scorpion', 'crab'],
  'pencil': ['crayon', 'marker', 'paintbrush'],
  'rabbit': ['cat', 'squirrel', 'dog'],
  'toothbrush': ['broom', 'paintbrush', 'fork'],
  'umbrella': ['mushroom', 'parachute', 'hot air balloon'],
};

const _confusable = [
  {'cup', 'coffee cup', 'mug', 'wine glass'},
  {'clock', 'alarm clock', 'wristwatch'},
  {'fan', 'ceiling fan'},
  {'birthday cake', 'cake'},
  {'beard', 'goatee', 'moustache'},
  {'car', 'police car', 'pickup truck', 'van'},
  {'bus', 'school bus'},
  {'canoe', 'speedboat'},
  {'laptop', 'computer'},
  {'cello', 'violin'},
  {'trumpet', 'trombone'},
  {'cell phone', 'remote control', 'calculator'},
  {'floor lamp', 'streetlight'},
  {'firetruck', 'ambulance', 'truck'},
  {'golf club', 'hockey stick', 'baseball bat'},
  {'basketball', 'baseball', 'soccer ball', 'hockey puck'},
  {'stove', 'oven', 'microwave', 'toaster'},
  {'circle', 'donut'},
  {'garden hose', 'snake'},
  {'t-shirt', 'sweater', 'jacket'},
  {'pear', 'snowman'},
];

Iterable<String> quizConfusableWith(String answer) sync* {
  for (final group in _confusable) {
    if (group.contains(answer)) yield* group.where((id) => id != answer);
  }
}

({List<String> similar, List<String> distinct}) quizDistractors({
  required String answer,
  required Set<String> candidates,
  required List<String> ranked,
  List<String> outlineRanked = const [],
  Set<String> indistinguishable = const {},
  required int level,
  bool enteringLevelFive = false,
  bool recovery = false,
  required Random random,
}) {
  final eligible = candidates.difference({
    answer,
    ...indistinguishable,
    ...quizConfusableWith(answer),
  });
  final curated = (_curated[answer] ?? const <String>[])
      .where(eligible.contains)
      .toSet();
  final related = ranked.where(eligible.contains).toSet()..removeAll(curated);
  final outline = outlineRanked.where(eligible.contains).toSet();
  final count = (level - 1).clamp(0, recovery ? 1 : 3);
  final semantic = {...curated, ...related};
  final closeOutlines = outline.take(6).toSet();
  final sameKind =
      semantic.where((id) => !closeOutlines.contains(id)).take(8).toList()
        ..shuffle(random);
  final closest = {...outline.where(semantic.contains), ...outline};
  final similar = (switch (level) {
    5 when enteringLevelFive => {
      ...closest.take(2),
      ...sameKind,
      ...closest,
      ...semantic,
    },
    5 => {...closest, ...semantic},
    4 => {...sameKind, ...semantic},
    _ => {...curated, ...sameKind, ...semantic},
  }).take(count).toList();
  final remaining = eligible.difference(similar.toSet());
  final unrelated =
      remaining.difference(semantic).difference(closeOutlines).toList()
        ..shuffle(random);
  final distinct = {
    ...unrelated,
    ...remaining,
  }.take(3 - similar.length).toList();
  return (similar: similar, distinct: distinct);
}

String chooseQuizQuestion({
  required Iterable<String> shuffled,
  required bool earlyDrawing,
  required bool familiar,
  required bool Function(String) tooHard,
  required bool Function(String) repeatsPrevious,
}) {
  final preferred = earlyDrawing
      ? openingQuestions
      : familiar
      ? familiarQuestions
      : null;
  String? similarChoice;
  for (final id in shuffled) {
    if (preferred != null && (!preferred.contains(id) || tooHard(id))) continue;
    if (!repeatsPrevious(id)) return id;
    similarChoice ??= id;
  }
  if (earlyDrawing) {
    for (final id in shuffled) {
      if (familiarQuestions.contains(id) &&
          !repeatsPrevious(id) &&
          !tooHard(id)) {
        return id;
      }
    }
  }
  return similarChoice ??
      shuffled.firstWhere(
        (id) => !repeatsPrevious(id),
        orElse: () => shuffled.first,
      );
}

typedef QuizOutlineMatch = ({
  bool usable,
  List<String> ranked,
  Set<String> ambiguous,
});

QuizOutlineMatch assessQuizOutline(
  List<List<Offset>> drawing,
  List<List<List<Offset>>> references,
  Map<String, List<List<List<Offset>>>> rivals, {
  required Set<String> plausibleRivals,
}) {
  final shape = _QuizOutline(drawing);
  double bestMatch(List<List<List<Offset>>> examples) => examples.fold(
    0,
    (best, strokes) => max(best, shape.similarity(_QuizOutline(strokes))),
  );
  final own = bestMatch(references);
  final comparisons =
      rivals.entries
          .map((entry) => (id: entry.key, score: bestMatch(entry.value)))
          .toList()
        ..sort((a, b) => b.score.compareTo(a.score));
  final bestRival = comparisons.isEmpty ? 0.0 : comparisons.first.score;
  // Shape comparison is coarse, so require a substantial lead to reject a
  // drawing as a rival category. A close match blocks that choice instead.
  return (
    usable: own >= .30 && (bestRival < .52 || bestRival - own < .12),
    ranked: comparisons.take(12).map((entry) => entry.id).toList(),
    ambiguous: {
      for (final entry in comparisons)
        if (entry.score >= max(.68, own - .02) &&
            (plausibleRivals.contains(entry.id) || entry.score >= .86))
          entry.id,
    },
  );
}

class _QuizOutline {
  _QuizOutline(List<List<Offset>> strokes) {
    void mark(Offset point) {
      final x = (point.dx * size).floor().clamp(0, size - 1);
      final y = (point.dy * size).floor().clamp(0, size - 1);
      cells.add(y * size + x);
    }

    for (final stroke in strokes.where((stroke) => stroke.isNotEmpty)) {
      mark(stroke.first);
      for (var i = 1; i < stroke.length; i++) {
        final start = stroke[i - 1];
        final delta = stroke[i] - start;
        final steps = max(1, (delta.distance * size * 2).ceil());
        for (var step = 1; step <= steps; step++) {
          mark(start + delta * (step / steps));
        }
      }
    }
    for (final index in cells) {
      nearby.add(index);
      if (index % size > 0) nearby.add(index - 1);
      if (index % size < size - 1) nearby.add(index + 1);
      if (index >= size) nearby.add(index - size);
      if (index < size * (size - 1)) nearby.add(index + size);
    }
  }

  static const size = 16;
  final cells = <int>{};
  final nearby = <int>{};

  double similarity(_QuizOutline other) {
    final combined = cells.length + other.cells.length;
    final covered =
        cells.where(other.nearby.contains).length +
        other.cells.where(nearby.contains).length;
    final overlap = cells.where(other.cells.contains).length;
    return .7 * covered / max(1, combined) +
        .3 * overlap / max(1, combined - overlap);
  }
}

enum QuizOutcome { correct, wrong, skipped, timeUp }

class QuizResult {
  const QuizResult({
    required this.level,
    required this.questionId,
    required this.generated,
    this.storedDrawingIndex,
    required this.assisted,
    this.enteringLevelFive = false,
    required this.outcome,
    required this.wrongTaps,
    required this.firstTapMs,
    this.firstTapProgress,
    this.finishedWrongChoices = const [],
    required this.durationMs,
  });

  final int level;
  final String questionId;
  final bool generated;
  final int? storedDrawingIndex;
  final bool assisted;
  final bool enteringLevelFive;
  final QuizOutcome outcome;
  final int wrongTaps;
  final int? firstTapMs;
  final double? firstTapProgress;
  final List<String> finishedWrongChoices;
  final int durationMs;

  Map<String, Object?> toJson() => {
    'level': level,
    'questionId': questionId,
    'generated': generated,
    if (storedDrawingIndex != null) 'storedDrawingIndex': storedDrawingIndex,
    'assisted': assisted,
    if (enteringLevelFive) 'enteringLevelFive': true,
    'outcome': outcome.name,
    'wrongTaps': wrongTaps,
    'firstTapMs': firstTapMs,
    'firstTapProgress': firstTapProgress,
    if (finishedWrongChoices.isNotEmpty)
      'finishedWrongChoices': finishedWrongChoices,
    'durationMs': durationMs,
  };
}

class QuizBalanceHistory {
  QuizBalanceHistory(Iterable<String> rounds) {
    for (final round in rounds) {
      try {
        final entry = jsonDecode(round) as Map;
        final questions = entry['questions'] as List;
        final fourAtSeven = _ReviewOutcomes();
        var sawLevelFiveEntry = false;
        var followsSuccessfulRecovery = false;
        var sawOpeningQuestion = false;
        int? openingFirstCorrectMs;
        var score = 0;
        var previousScore = 0;
        var roundElapsed = 0;
        var roundWrongs = 0;
        var roundSkips = 0;
        var roundFirstChoices = 0;
        var roundEarlyChoices = 0;
        for (final (index, row) in questions.whereType<Map>().indexed) {
          final level = row['level'];
          final ai = row['generated'];
          final duration = row['durationMs'];
          if (level is! int || ai is! bool || duration is! int) continue;
          final outcome = row['outcome'];
          final correct = outcome == QuizOutcome.correct.name;
          final skipped = outcome == QuizOutcome.skipped.name;
          final wrongTaps = row['wrongTaps'];
          if (wrongTaps is int) roundWrongs += wrongTaps;
          if (skipped) roundSkips++;
          final assisted = row['assisted'] == true;
          // Older versions counted a skip without an answer as a first tap.
          final skipWasFirst = skipped && row['wrongTaps'] == 0;
          final firstTap = skipWasFirst ? null : row['firstTapMs'];
          final progress = skipWasFirst ? null : row['firstTapProgress'];
          if (progress is num) {
            roundFirstChoices++;
            if (progress < .5) roundEarlyChoices++;
          }
          final firstChoiceMs = firstTap is int ? firstTap : null;
          final id = row['questionId'];
          final storedIndex = row['storedDrawingIndex'];
          final totals = _byLevel.putIfAbsent((level, ai), _QuizTotals.new);
          totals.add(correct, duration, skipped, firstChoiceMs);
          roundElapsed += duration;
          if (index == 0) {
            _opening.add(correct, duration, skipped, firstChoiceMs);
            sawOpeningQuestion = true;
          } else if (index == 1) {
            _second.add(correct, duration, skipped, firstChoiceMs);
          }
          if (index < 2 && score == 0 && correct) {
            _earlyFirstCorrectMs += roundElapsed;
            _earlyFirstCorrect++;
            openingFirstCorrectMs = roundElapsed;
          }
          if (index < 2 && !ai && id is String) {
            if (storedIndex is int && storedIndex >= 0) {
              _openingDrawings
                  .putIfAbsent((id, storedIndex), _ReviewOutcomes.new)
                  .add(outcome);
            }
            if (entry['firstPlay'] == true && outcome is String) {
              _firstPlayExamples.add((
                id: id,
                sample: storedIndex is int ? storedIndex + 1 : null,
                outcome: outcome,
              ));
            }
          }
          if (level == 4 && score == 7 && !assisted) {
            fourAtSeven.add(outcome);
          }
          if (!sawLevelFiveEntry &&
              level == 5 &&
              score == 8 &&
              row['enteringLevelFive'] == true) {
            sawLevelFiveEntry = true;
            _fourBeforeFive.merge(fourAtSeven);
            _firstFive.add(outcome);
            if (skipped && id is String) {
              _fiveSkipExamples.add((
                id: id,
                sample: storedIndex is int ? storedIndex + 1 : null,
              ));
            }
          }
          if (assisted) _recovery.add(outcome);
          if (followsSuccessfulRecovery && !assisted) {
            _afterRecovery.add(outcome);
          }
          followsSuccessfulRecovery = assisted && correct;
          if (row['enteringLevelFive'] == true) {
            _levelFiveEntry.add(correct, duration, skipped, firstChoiceMs);
          }
          if (quizLevel(previousScore) < quizLevel(score) &&
              level == quizLevel(score)) {
            _promoted
                .putIfAbsent(level, _QuizTotals.new)
                .add(correct, duration, skipped, firstChoiceMs);
          }
          previousScore = score;
          if (correct) score++;
          if (progress is num) {
            totals.knownProgress++;
            if (progress < 1) totals.beforeFinish++;
          }
          if (assisted) {
            _assisted
                .putIfAbsent(level, _QuizTotals.new)
                .add(correct, duration, skipped, firstChoiceMs);
          }
          if (id is String && outcome != QuizOutcome.timeUp.name) {
            _byQuestion
                .putIfAbsent((id, level, ai), _QuizTotals.new)
                .add(correct, duration, skipped, firstChoiceMs);
            if (!assisted && index >= 2 && entry['playtestSeed'] == null) {
              _sourceComparison
                  .putIfAbsent((id, level, ai), _QuizTotals.new)
                  .add(correct, duration, skipped, firstChoiceMs);
            }
          }
          final finishedWrong = row['finishedWrongChoices'];
          if (id is String && finishedWrong is List) {
            for (final choice in finishedWrong.whereType<String>().toSet()) {
              _finishedPairs.update(
                (id, choice),
                (value) => value + 1,
                ifAbsent: () => 1,
              );
            }
          }
        }
        final rules = entry['roundRules'];
        final duration = entry['durationMs'];
        final bonus = entry['bonusGrantedMs'];
        final finalScore = entry['score'];
        if (rules is String &&
            duration is int &&
            bonus is int &&
            finalScore is int) {
          final seed = entry['playtestSeed'];
          final level = entry['playtestLevel'];
          final strategy = entry['playtestStrategy'];
          final capAt = entry['bonusCapAtMs'];
          final capScore = entry['bonusCapScore'];
          _ruleRounds.add((
            rules: rules,
            seed: seed is int ? seed : null,
            level: level is int ? level : null,
            strategy: strategy is String ? strategy : null,
            score: finalScore,
            durationMs: duration,
            bonusMs: bonus,
            wrongs: roundWrongs,
            skips: roundSkips,
            endedBySkip: entry['endedBySkip'] == true,
            capAtMs: capAt is int ? capAt : null,
            afterCap: capScore is int ? max(0, finalScore - capScore) : null,
            firstChoices: roundFirstChoices,
            earlyChoices: roundEarlyChoices,
          ));
        }
        if (sawOpeningQuestion && entry['firstPlay'] == true) {
          _verifiedFirstPlays++;
          if (openingFirstCorrectMs != null) {
            _verifiedFirstPlaySuccesses++;
            _verifiedFirstPlayCorrectMs += openingFirstCorrectMs;
          }
        }
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
  }

  final _byLevel = <(int, bool), _QuizTotals>{};
  final _byQuestion = <(String, int, bool), _QuizTotals>{};
  final _sourceComparison = <(String, int, bool), _QuizTotals>{};
  final _ruleRounds = <_RuleRound>[];
  final _assisted = <int, _QuizTotals>{};
  final _promoted = <int, _QuizTotals>{};
  final _opening = _QuizTotals();
  final _second = _QuizTotals();
  final _levelFiveEntry = _QuizTotals();
  final _finishedPairs = <(String, String), int>{};
  final _openingDrawings = <(String, int), _ReviewOutcomes>{};
  final _firstPlayExamples = <({String id, int? sample, String outcome})>[];
  final _fiveSkipExamples = <({String id, int? sample})>[];
  final _fourBeforeFive = _ReviewOutcomes();
  final _firstFive = _ReviewOutcomes();
  final _recovery = _ReviewOutcomes();
  final _afterRecovery = _ReviewOutcomes();
  int _verifiedFirstPlays = 0;
  int _verifiedFirstPlaySuccesses = 0;
  int _verifiedFirstPlayCorrectMs = 0;
  int _earlyFirstCorrect = 0;
  int _earlyFirstCorrectMs = 0;

  bool prefersStored(String id, int level) {
    final ai = _byQuestion[(id, level, true)];
    final stored = _byQuestion[(id, level, false)];
    return ai != null &&
        stored != null &&
        ai.questions >= 6 &&
        stored.questions >= 6 &&
        stored.correctRate >= 0.65 &&
        stored.correctRate - ai.correctRate >= 0.5;
  }

  bool tooHardForEarlyLevels(String id) {
    var attempts = 0;
    var correct = 0;
    var skips = 0;
    for (final level in [1, 2]) {
      for (final generated in [true, false]) {
        final totals = _byQuestion[(id, level, generated)];
        if (totals == null) continue;
        attempts += totals.questions;
        correct += totals.correct;
        skips += totals.skips;
      }
    }
    return attempts >= 4 && (correct * 2 < attempts || skips * 2 >= attempts);
  }

  bool hasLevel(int level) =>
      _byLevel.containsKey((level, true)) ||
      _byLevel.containsKey((level, false));

  String? get openingSummary =>
      _opening.questions == 0 ? null : _opening.summary;

  String? get secondSummary => _second.questions == 0 ? null : _second.summary;

  String? get earlyFirstCorrectSummary {
    if (_opening.questions == 0) return null;
    final average = _earlyFirstCorrect == 0
        ? '—'
        : '${(_earlyFirstCorrectMs / _earlyFirstCorrect / 1000).toStringAsFixed(1)}초';
    return '$_earlyFirstCorrect/${_opening.questions}판 · 평균 $average';
  }

  String? get levelFiveEntrySummary =>
      _levelFiveEntry.questions == 0 ? null : _levelFiveEntry.summary;

  List<({String title, String value})> roundRulesReview(
    Map<String, String> labels,
  ) {
    final groups = <(String, String?, int?), List<_RuleRound>>{};
    for (final round in _ruleRounds) {
      groups
          .putIfAbsent((round.rules, round.strategy, round.level), () => [])
          .add(round);
    }
    const strategyLabels = {
      'guess': '빠른 추측',
      'wait': '획을 기다리기',
      'skip': '모르면 건너뛰기',
    };
    const ruleLabels = {
      'baseline': '기존 규칙',
      'retry-2200': '두 번째 오답 2.2초',
      'early-retry': '그림 초반 오답 보정',
      'skip-2': '건너뛰기 −2초',
      'late-bonus': '30초 이후 정답 +0.5초',
    };
    final comparisons =
        <({String id, int level, _QuizTotals ai, _QuizTotals stored})>[];
    for (final entry in _sourceComparison.entries) {
      final (id, level, generated) = entry.key;
      if (!generated || entry.value.questions < 6) continue;
      final stored = _sourceComparison[(id, level, false)];
      if (stored != null && stored.questions >= 6) {
        comparisons.add((
          id: id,
          level: level,
          ai: entry.value,
          stored: stored,
        ));
      }
    }
    double gap(_QuizTotals ai, _QuizTotals stored) => max(
      (ai.correctRate - stored.correctRate).abs(),
      (ai.skipRate - stored.skipRate).abs(),
    );
    comparisons.sort(
      (a, b) => gap(b.ai, b.stored).compareTo(gap(a.ai, a.stored)),
    );
    String source(_QuizTotals totals) =>
        '정답 ${totals.correct}/${totals.questions} · 건너뛰기 ${totals.skips}회 · 정답까지 ${totals.averageCorrectTime}';
    return [
      if (groups.isEmpty) (title: '전략과 시간 규칙', value: '검수 빌드에서 완료한 판이 없어요.'),
      for (final entry in groups.entries)
        (
          title:
              '${strategyLabels[entry.key.$2] ?? (entry.key.$3 == null ? '일반 플레이' : '전략 미지정')} · '
              '${ruleLabels[entry.key.$1] ?? entry.key.$1}${entry.key.$3 == null ? '' : ' · ${entry.key.$3}단계'}',
          value: _summarizeRuleRounds(entry.value),
        ),
      if (comparisons.isEmpty)
        (
          title: '같은 제시어와 단계의 그림 출처 비교',
          value: 'AI와 저장 그림의 기록이 각각 6건 이상인 조합이 없어요.',
        ),
      for (final comparison in comparisons.take(4))
        (
          title:
              '${labels[comparison.id] ?? comparison.id} · ${comparison.level}단계',
          value:
              'AI 그림 · ${source(comparison.ai)}\n저장 그림 · ${source(comparison.stored)}',
        ),
    ];
  }

  List<({String title, String value})> levelProgressReview(
    Map<String, String> labels,
  ) {
    final earlyFailures =
        _openingDrawings.entries
            .where((entry) => entry.value.misses >= 2)
            .toList()
          ..sort(
            (a, b) => (b.value.misses / b.value.total).compareTo(
              a.value.misses / a.value.total,
            ),
          );
    final firstPlayTime = _verifiedFirstPlaySuccesses == 0
        ? ''
        : ' · 평균 ${(_verifiedFirstPlayCorrectMs / _verifiedFirstPlaySuccesses / 1000).toStringAsFixed(1)}초';
    final firstPlay = _verifiedFirstPlays == 0
        ? '새 설치 첫 플레이 기록 없음'
        : '새 설치 첫 플레이 $_verifiedFirstPlaySuccesses/$_verifiedFirstPlays판$firstPlayTime';
    final opening = earlyFirstCorrectSummary ?? '기록 없음';
    final increase = _firstFive.skipChangeFrom(_fourBeforeFive);
    final missedReturn = _recovery.correct - _afterRecovery.total;
    String label(String id, int? sample) =>
        '${labels[id] ?? id}${sample == null ? '' : ' · 샘플 $sample번'}';
    final firstExamples = _firstPlayExamples.take(2).map((example) {
      final outcome = switch (example.outcome) {
        'correct' => '정답',
        'skipped' => '건너뛰기',
        'wrong' => '오답',
        'timeUp' => '시간 종료',
        _ => example.outcome,
      };
      return '${label(example.id, example.sample)} · $outcome';
    });
    return [
      (
        title: '첫 두 문제에서 첫 정답',
        value: [firstPlay, ...firstExamples, '최근 전체 $opening'].join('\n'),
      ),
      ...earlyFailures.take(3).map((entry) {
        final (id, index) = entry.key;
        return (
          title: '초반에 반복해서 놓친 그림',
          value:
              '${labels[id] ?? id} · 샘플 ${index + 1}번 · ${entry.value.misses}/${entry.value.total}회 놓침',
        );
      }),
      (
        title: '4단계에서 5단계로',
        value:
            '7점 구간 4단계 · ${_fourBeforeFive.summary}\n첫 5단계 · ${_firstFive.summary}'
            '${increase == null ? '' : '\n건너뛰기 변화 ${increase >= 0 ? '+' : ''}$increase%p'}',
      ),
      if (_fiveSkipExamples.isNotEmpty)
        (
          title: '첫 5단계에서 건너뛴 그림',
          value: _fiveSkipExamples
              .take(3)
              .map((example) => label(example.id, example.sample))
              .join('\n'),
        ),
      (
        title: '회복 문제와 복귀 직후',
        value:
            '회복 문제 · ${_recovery.summary}\n회복 성공 후 첫 일반 문제 · ${_afterRecovery.summary}'
            '${missedReturn > 0 ? '\n복귀 전에 끝난 판 $missedReturn회' : ''}',
      ),
    ];
  }

  List<({String id, String choice, int count})> finishedPairCandidates() {
    final ranked =
        _finishedPairs.entries.where((entry) => entry.value >= 2).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return ranked
        .take(5)
        .map(
          (entry) =>
              (id: entry.key.$1, choice: entry.key.$2, count: entry.value),
        )
        .toList();
  }

  String? assistedSummary(int level) => _assisted[level]?.summary;

  String? promotedSummary(int level) => _promoted[level]?.summary;

  List<
    ({String id, int level, bool generated, int correct, int skips, int total})
  >
  reviewCandidates() {
    final ranked =
        _byQuestion.entries
            .where(
              (entry) =>
                  entry.value.questions >= 6 &&
                  (entry.value.correctRate < 0.5 ||
                      entry.value.skipRate >= 0.5),
            )
            .toList()
          ..sort((a, b) => b.value.skipRate.compareTo(a.value.skipRate));
    return ranked.take(5).map((entry) {
      final (id, level, generated) = entry.key;
      return (
        id: id,
        level: level,
        generated: generated,
        correct: entry.value.correct,
        skips: entry.value.skips,
        total: entry.value.questions,
      );
    }).toList();
  }

  String describe(int level, {required bool generated}) {
    final totals = _byLevel[(level, generated)];
    if (totals == null) return '기록 없음';
    final percent = (100 * totals.correctRate).round();
    final correctTime = totals.averageCorrectTime;
    final early = totals.knownProgress == 0
        ? ''
        : ' · 완성 전 선택 ${totals.beforeFinish}/${totals.knownProgress}';
    return '${totals.questions}문제 · 정답률 $percent% · 정답까지 $correctTime\n'
        '첫 선택 ${totals.firstChoiceTime} · 건너뛰기 ${totals.skipPercent}%$early';
  }
}

typedef _RuleRound = ({
  String rules,
  int? seed,
  int? level,
  String? strategy,
  int score,
  int durationMs,
  int bonusMs,
  int wrongs,
  int skips,
  bool endedBySkip,
  int? capAtMs,
  int? afterCap,
  int firstChoices,
  int earlyChoices,
});

String _summarizeRuleRounds(List<_RuleRound> rounds) {
  String average(num Function(_RuleRound) value) =>
      (rounds.fold<num>(0, (sum, round) => sum + value(round)) / rounds.length)
          .toStringAsFixed(1);
  final skipped = rounds.where((round) => round.skips > 0).length;
  final ended = rounds.where((round) => round.endedBySkip).length;
  final capped = rounds.where((round) => round.capAtMs != null).toList();
  final firstChoices = rounds.fold(0, (sum, round) => sum + round.firstChoices);
  final earlyChoices = rounds.fold(0, (sum, round) => sum + round.earlyChoices);
  final cap = capped.isEmpty
      ? ''
      : ' · 평균 ${(capped.fold<int>(0, (sum, round) => sum + round.capAtMs!) / capped.length / 1000).toStringAsFixed(1)}초';
  final afterCap = capped
      .map((round) => round.afterCap)
      .whereType<int>()
      .toList();
  return [
    '${rounds.length}판 · 평균 ${average((round) => round.score)}점 · ${average((round) => round.durationMs / 1000)}초',
    '평균 오답 ${average((round) => round.wrongs)}회 · 건너뛰기 ${average((round) => round.skips)}회',
    if (firstChoices > 0) '그림 절반 전 첫 선택 $earlyChoices/$firstChoices회',
    '건너뛰기로 종료 $ended/$skipped판 · 평균 보너스 +${average((round) => round.bonusMs / 1000)}초',
    '보너스 상한 도달 ${capped.length}/${rounds.length}판$cap',
    if (afterCap.isNotEmpty)
      '상한 이후 평균 ${(afterCap.reduce((a, b) => a + b) / afterCap.length).toStringAsFixed(1)}개 정답',
    for (final round in rounds)
      if (round.seed case final seed?)
        '시드 $seed · ${round.score}점 · ${(round.durationMs / 1000).toStringAsFixed(1)}초 · 오답 ${round.wrongs}회 · 건너뛰기 ${round.skips}회',
  ].join('\n');
}

class _ReviewOutcomes {
  int completed = 0;
  int correct = 0;
  int skipped = 0;
  int timedOut = 0;

  int get total => completed + timedOut;
  int get misses => total - correct;

  void add(Object? outcome) {
    switch (outcome) {
      case 'correct':
        correct++;
        completed++;
      case 'skipped':
        skipped++;
        completed++;
      case 'wrong':
        completed++;
      case 'timeUp':
        timedOut++;
    }
  }

  void merge(_ReviewOutcomes other) {
    completed += other.completed;
    correct += other.correct;
    skipped += other.skipped;
    timedOut += other.timedOut;
  }

  int? skipChangeFrom(_ReviewOutcomes baseline) {
    if (completed == 0 || baseline.completed == 0) return null;
    return (100 * (skipped / completed - baseline.skipped / baseline.completed))
        .round();
  }

  String get summary {
    if (total == 0) return '기록 없음';
    final outcomes = completed == 0
        ? '완료 0문제'
        : '정답 $correct/$completed · 건너뛰기 $skipped/$completed (${(100 * skipped / completed).round()}%)';
    return timedOut == 0 ? outcomes : '$outcomes · 시간 종료 $timedOut회';
  }
}

class _QuizTotals {
  int questions = 0;
  int correct = 0;
  int correctMs = 0;
  int skips = 0;
  int firstTaps = 0;
  int firstTapMs = 0;
  int knownProgress = 0;
  int beforeFinish = 0;

  double get correctRate => correct / questions;
  String get averageCorrectTime => correct == 0
      ? '—'
      : '${(correctMs / correct / 1000).toStringAsFixed(1)}초';
  double get skipRate => skips / questions;
  int get skipPercent => (100 * skipRate).round();
  String get firstChoiceTime => firstTaps == 0
      ? '—'
      : '${(firstTapMs / firstTaps / 1000).toStringAsFixed(1)}초';
  String get summary =>
      '정답 $correct/$questions · 첫 선택 $firstChoiceTime · 건너뛰기 $skipPercent%';

  void add(bool solved, int duration, bool skipped, int? firstTap) {
    questions++;
    if (solved) {
      correct++;
      correctMs += duration;
    }
    if (skipped) skips++;
    if (firstTap != null) {
      firstTaps++;
      firstTapMs += firstTap;
    }
  }
}
