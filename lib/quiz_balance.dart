import 'dart:convert';
import 'dart:math';

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

const _curated = <String, List<String>>{
  'apple': ['pear', 'onion', 'potato', 'peanut'],
  'cat': ['rabbit', 'dog', 'raccoon', 'tiger'],
  'firetruck': ['ambulance', 'bus', 'truck'],
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
];

({List<String> similar, List<String> distinct}) quizDistractors({
  required String answer,
  required Set<String> candidates,
  required List<String> ranked,
  List<String> outlineRanked = const [],
  required int level,
  required Random random,
}) {
  final eligible = candidates.difference({answer});
  for (final group in _confusable) {
    if (group.contains(answer)) eligible.removeAll(group);
  }
  final curated = (_curated[answer] ?? const <String>[])
      .where(eligible.contains)
      .toSet();
  final related = ranked.where(eligible.contains).toSet()..removeAll(curated);
  final outline = outlineRanked.where(eligible.contains).toSet();
  final count = (level - 1).clamp(0, 3);
  final closest = ranked.where(eligible.contains).take(10).toList()
    ..shuffle(random);
  final similar = (switch (level) {
    5 => {
      ...outline.where((id) => related.contains(id) || curated.contains(id)),
      ...outline,
      ...closest,
    },
    4 => {...closest, ...curated},
    _ => {...curated, ...closest},
  }).take(count).toList();
  final distinct =
      (eligible
              .difference(curated)
              .difference(related)
              .difference(similar.toSet())
              .toList()
            ..shuffle(random))
          .take(3 - similar.length)
          .toList();
  return (similar: similar, distinct: distinct);
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
    required this.durationMs,
  });

  final int level;
  final String questionId;
  final bool generated;
  final bool assisted;
  final QuizOutcome outcome;
  final int wrongTaps;
  final int? firstTapMs;
  final int durationMs;

  Map<String, Object?> toJson() => {
    'level': level,
    'questionId': questionId,
    'generated': generated,
    'assisted': assisted,
    'outcome': outcome.name,
    'wrongTaps': wrongTaps,
    'firstTapMs': firstTapMs,
    'durationMs': durationMs,
  };
}

class QuizBalanceHistory {
  QuizBalanceHistory(Iterable<String> rounds) {
    for (final round in rounds) {
      try {
        final questions = (jsonDecode(round) as Map)['questions'] as List;
        for (final row in questions.whereType<Map>()) {
          final level = row['level'];
          final ai = row['generated'];
          final duration = row['durationMs'];
          if (level is! int || ai is! bool || duration is! int) continue;
          final outcome = row['outcome'];
          final correct = outcome == QuizOutcome.correct.name;
          final firstTap = row['firstTapMs'];
          final id = row['questionId'];
          _byLevel
              .putIfAbsent((level, ai), _QuizTotals.new)
              .add(
                correct,
                duration,
                outcome == QuizOutcome.skipped.name,
                firstTap is int ? firstTap : null,
              );
          if (id is String && outcome != QuizOutcome.timeUp.name) {
            _byQuestion
                .putIfAbsent((id, level, ai), _QuizTotals.new)
                .add(
                  correct,
                  duration,
                  outcome == QuizOutcome.skipped.name,
                  firstTap is int ? firstTap : null,
                );
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

  bool hasLevel(int level) =>
      _byLevel.containsKey((level, true)) ||
      _byLevel.containsKey((level, false));

  String describe(int level, {required bool generated}) {
    final totals = _byLevel[(level, generated)];
    if (totals == null) return '기록 없음';
    final percent = (100 * totals.correctRate).round();
    final correctTime = totals.correct == 0
        ? '—'
        : '${(totals.correctMs / totals.correct / 1000).toStringAsFixed(1)}초';
    final firstTap = totals.firstTaps == 0
        ? '—'
        : '${(totals.firstTapMs / totals.firstTaps / 1000).toStringAsFixed(1)}초';
    return '${totals.questions}문제 · 정답률 $percent% · 정답까지 $correctTime\n첫 선택 $firstTap · 건너뛰기 ${totals.skips}회';
  }
}

class _QuizTotals {
  int questions = 0;
  int correct = 0;
  int correctMs = 0;
  int skips = 0;
  int firstTaps = 0;
  int firstTapMs = 0;

  double get correctRate => correct / questions;

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
