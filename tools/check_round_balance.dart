import 'dart:io';
import 'dart:math';

import 'package:rabbit_sketchbook/round_rules.dart';

enum Strategy { guess, wait, skip }

typedef RoundSample = ({
  int score,
  int wrongs,
  int skips,
  int durationMs,
  bool endedBySkip,
  int? bonusCapAtMs,
});

// The same synthetic trials are replayed for each rule preset. The waiting
// player is assumed to recognize every drawing at 65% of the ink. The skip
// player recognizes three quarters of the drawings at the same point.
RoundSample playTrial(
  int seed,
  int level,
  Strategy strategy,
  RoundRules rules,
) {
  final random = Random(seed);
  var now = 0;
  var deadline = roundStartMs;
  var bonus = 0;
  var score = 0;
  var wrongs = 0;
  var skips = 0;
  var endedBySkip = false;
  int? capAt;
  while (now < deadline) {
    final correctPosition = random.nextInt(4);
    final familiar = random.nextInt(4) != 0;
    final questionAt = now;
    if (strategy == Strategy.skip && !familiar) {
      now =
          _firstTime(
            questionAt,
            deadline,
            (elapsed) => canSkipAt(
              elapsedMs: elapsed,
              questionStartedMs: questionAt,
              level: level,
            ),
          ) +
          200;
      if (now >= deadline) break;
      skips++;
      deadline -= rules.skipCostMs;
      endedBySkip = now >= deadline;
      continue;
    }
    if (strategy == Strategy.guess) {
      now += 250;
      for (
        var position = 0;
        position < correctPosition && position < 3 && now < deadline;
        position++
      ) {
        wrongs++;
        final progress = strokeProgressAt(
          elapsedMs: now,
          questionStartedMs: questionAt,
          level: level,
        );
        now += position == 2
            ? lastWrongTransitionMs
            : rules.retryDelayMs(position + 1, progress) + 180;
      }
      if (now >= deadline) break;
      if (correctPosition == 3) continue;
    } else {
      now =
          _firstTime(
            questionAt,
            deadline,
            (elapsed) =>
                strokeProgressAt(
                  elapsedMs: elapsed,
                  questionStartedMs: questionAt,
                  level: level,
                ) >=
                .65,
          ) +
          200;
      if (now >= deadline) break;
    }
    score++;
    final grant = rules.bonusGrantMs(elapsedMs: now, alreadyGrantedMs: bonus);
    bonus += grant;
    deadline += grant;
    if (bonus == maxRoundBonusMs) capAt ??= now;
  }
  return (
    score: score,
    wrongs: wrongs,
    skips: skips,
    durationMs: endedBySkip ? now : deadline,
    endedBySkip: endedBySkip,
    bonusCapAtMs: capAt,
  );
}

int _firstTime(int low, int high, bool Function(int) reached) {
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (reached(mid)) {
      high = mid;
    } else {
      low = mid + 1;
    }
  }
  return low;
}

void main() {
  const seeds = 200;
  stdout.writeln(
    'rules,level,strategy,meanScore,meanWrong,meanSkip,meanSeconds,endedBySkip,capReached,meanCapSeconds',
  );
  for (final preset in roundRulePresets.entries) {
    for (var level = 1; level <= 5; level++) {
      for (final strategy in Strategy.values) {
        final trials = [
          for (var seed = 0; seed < seeds; seed++)
            playTrial(seed, level, strategy, preset.value),
        ];
        final capTimes = trials
            .map((row) => row.bonusCapAtMs)
            .whereType<int>()
            .toList();
        String mean(num Function(RoundSample) value) =>
            (trials.fold<num>(0, (sum, row) => sum + value(row)) / seeds)
                .toStringAsFixed(2);
        final capAverage = capTimes.isEmpty
            ? ''
            : (capTimes.reduce((a, b) => a + b) / capTimes.length / 1000)
                  .toStringAsFixed(2);
        stdout.writeln(
          [
            preset.key,
            level,
            strategy.name,
            mean((row) => row.score),
            mean((row) => row.wrongs),
            mean((row) => row.skips),
            mean((row) => row.durationMs / 1000),
            trials.where((row) => row.endedBySkip).length,
            capTimes.length,
            capAverage,
          ].join(','),
        );
      }
    }
  }
}
