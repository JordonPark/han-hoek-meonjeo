import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset;

int quizLevel(int score, {bool assistance = false}) =>
    max(1, min(5, 1 + score ~/ 2) - (assistance ? 1 : 0));

const openingQuestions = {
  'apple',
  'banana',
  'bicycle',
  'cake',
  'circle',
  'cloud',
  'donut',
  'door',
  'eyeglasses',
  'fish',
  'flower',
  'guitar',
  'house',
  'key',
  'ladder',
  'moon',
  'mushroom',
  'pizza',
  'rainbow',
  'smiley face',
  'snowman',
  'square',
  'star',
  'sun',
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
];

({List<String> similar, List<String> distinct}) quizDistractors({
  required String answer,
  required Set<String> candidates,
  required List<String> ranked,
  List<String> outlineRanked = const [],
  Set<String> indistinguishable = const {},
  required int level,
  required Random random,
}) {
  final eligible = candidates.difference({answer, ...indistinguishable});
  for (final group in _confusable) {
    if (group.contains(answer)) eligible.removeAll(group);
  }
  final curated = (_curated[answer] ?? const <String>[])
      .where(eligible.contains)
      .toSet();
  final related = ranked.where(eligible.contains).toSet()..removeAll(curated);
  final outline = outlineRanked.where(eligible.contains).toSet();
  final count = (level - 1).clamp(0, 3);
  final semantic = {...curated, ...related};
  final closeOutlines = outline.take(6).toSet();
  final sameKind =
      semantic.where((id) => !closeOutlines.contains(id)).take(8).toList()
        ..shuffle(random);
  final similar = (switch (level) {
    5 => {...outline.where(semantic.contains), ...outline, ...semantic},
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

int closestQuizOutline(
  List<List<Offset>> drawing,
  List<List<List<Offset>>> references,
) {
  final cells = _outlineCells(drawing);
  var bestIndex = 0;
  var bestSimilarity = -1.0;
  for (final (index, reference) in references.indexed) {
    final other = _outlineCells(reference);
    final overlap = cells.intersection(other).length;
    final similarity = overlap / max(1, cells.length + other.length - overlap);
    if (similarity > bestSimilarity) {
      bestIndex = index;
      bestSimilarity = similarity;
    }
  }
  return bestIndex;
}

Set<int> _outlineCells(List<List<Offset>> strokes) {
  const size = 12;
  final cells = <int>{};
  void mark(Offset point) {
    final x = (point.dx * size).floor().clamp(0, size - 1);
    final y = (point.dy * size).floor().clamp(0, size - 1);
    cells.add(y * size + x);
  }

  for (final stroke in strokes) {
    mark(stroke.first);
    for (var i = 1; i < stroke.length; i++) {
      final start = stroke[i - 1];
      final end = stroke[i];
      final steps = max(1, ((end - start).distance * size * 2).ceil());
      for (var step = 1; step <= steps; step++) {
        mark(start + (end - start) * (step / steps));
      }
    }
  }
  return cells;
}

enum QuizOutcome { correct, wrong, skipped, timeUp }

class QuizResult {
  const QuizResult({
    required this.level,
    required this.questionId,
    required this.generated,
    required this.assisted,
    required this.outcome,
    required this.wrongTaps,
    required this.firstTapMs,
    this.firstTapProgress,
    required this.durationMs,
  });

  final int level;
  final String questionId;
  final bool generated;
  final bool assisted;
  final QuizOutcome outcome;
  final int wrongTaps;
  final int? firstTapMs;
  final double? firstTapProgress;
  final int durationMs;

  Map<String, Object?> toJson() => {
    'level': level,
    'questionId': questionId,
    'generated': generated,
    'assisted': assisted,
    'outcome': outcome.name,
    'wrongTaps': wrongTaps,
    'firstTapMs': firstTapMs,
    'firstTapProgress': firstTapProgress,
    'durationMs': durationMs,
  };
}

class QuizBalanceHistory {
  QuizBalanceHistory(Iterable<String> rounds) {
    for (final round in rounds) {
      try {
        final questions = (jsonDecode(round) as Map)['questions'] as List;
        var score = 0;
        var previousScore = 0;
        for (final row in questions.whereType<Map>()) {
          final level = row['level'];
          final ai = row['generated'];
          final duration = row['durationMs'];
          if (level is! int || ai is! bool || duration is! int) continue;
          final outcome = row['outcome'];
          final correct = outcome == QuizOutcome.correct.name;
          final skipped = outcome == QuizOutcome.skipped.name;
          // Older versions counted a skip without an answer as a first tap.
          final skipWasFirst = skipped && row['wrongTaps'] == 0;
          final firstTap = skipWasFirst ? null : row['firstTapMs'];
          final progress = skipWasFirst ? null : row['firstTapProgress'];
          final firstChoiceMs = firstTap is int ? firstTap : null;
          final id = row['questionId'];
          final totals = _byLevel.putIfAbsent((level, ai), _QuizTotals.new);
          totals.add(correct, duration, skipped, firstChoiceMs);
          if (identical(row, questions.first)) {
            _opening.add(correct, duration, skipped, firstChoiceMs);
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
          if (row['assisted'] == true) {
            _assisted
                .putIfAbsent(level, _QuizTotals.new)
                .add(correct, duration, skipped, firstChoiceMs);
          }
          if (id is String && outcome != QuizOutcome.timeUp.name) {
            _byQuestion
                .putIfAbsent((id, level, ai), _QuizTotals.new)
                .add(correct, duration, skipped, firstChoiceMs);
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
  final _assisted = <int, _QuizTotals>{};
  final _promoted = <int, _QuizTotals>{};
  final _opening = _QuizTotals();

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
    final correctTime = totals.correct == 0
        ? '—'
        : '${(totals.correctMs / totals.correct / 1000).toStringAsFixed(1)}초';
    final early = totals.knownProgress == 0
        ? ''
        : ' · 완성 전 선택 ${totals.beforeFinish}/${totals.knownProgress}';
    return '${totals.questions}문제 · 정답률 $percent% · 정답까지 $correctTime\n'
        '첫 선택 ${totals.firstChoiceTime} · 건너뛰기 ${totals.skipPercent}%$early';
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
