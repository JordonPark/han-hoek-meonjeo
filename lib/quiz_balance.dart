import 'dart:math';

int quizLevel(int score, {bool assistance = false}) =>
    max(1, min(5, 1 + score ~/ 2) - (assistance ? 1 : 0));

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
  final count = (level - 1).clamp(0, 3);
  final closest = related.take(level == 5 ? 5 : 10).toList()..shuffle(random);
  final similar = [...curated, ...closest].take(count).toList();
  final distinct =
      (eligible.difference(curated).difference(related).toList()
            ..shuffle(random))
          .take(3 - similar.length)
          .toList();
  return (similar: similar, distinct: distinct);
}

enum QuizOutcome { correct, wrong, skipped, timeUp }

class QuizResult {
  const QuizResult({
    required this.level,
    required this.generated,
    required this.assisted,
    required this.outcome,
    required this.wrongTaps,
    required this.firstTapMs,
    required this.durationMs,
  });

  final int level;
  final bool generated;
  final bool assisted;
  final QuizOutcome outcome;
  final int wrongTaps;
  final int? firstTapMs;
  final int durationMs;

  Map<String, Object?> toJson() => {
    'level': level,
    'generated': generated,
    'assisted': assisted,
    'outcome': outcome.name,
    'wrongTaps': wrongTaps,
    'firstTapMs': firstTapMs,
    'durationMs': durationMs,
  };
}
