import 'dart:math';

const roundStartMs = 60000;
const correctBonusMs = 1000;
const maxRoundBonusMs = 15000;
const skipPenaltyMs = 3000;
const skipWaitMs = 2000;
const firstWrongLockMs = 800;
const repeatWrongLockMs = 1500;
const lastWrongTransitionMs = 350;

class RoundRules {
  const RoundRules({
    this.skipCostMs = skipPenaltyMs,
    this.secondWrongDelayMs = repeatWrongLockMs,
    this.earlySecondWrongDelayMs,
    this.reducedBonusFromMs,
  });

  final int skipCostMs;
  final int secondWrongDelayMs;
  final int? earlySecondWrongDelayMs;
  final int? reducedBonusFromMs;

  int retryDelayMs(int wrongTaps, double drawingProgress) {
    if (wrongTaps == 1) return firstWrongLockMs;
    if (wrongTaps == 2 && drawingProgress < .5) {
      return earlySecondWrongDelayMs ?? secondWrongDelayMs;
    }
    return secondWrongDelayMs;
  }

  int bonusGrantMs({required int elapsedMs, required int alreadyGrantedMs}) {
    final reducedFrom = reducedBonusFromMs;
    final amount = reducedFrom != null && elapsedMs >= reducedFrom
        ? correctBonusMs ~/ 2
        : correctBonusMs;
    return min(amount, max(0, maxRoundBonusMs - alreadyGrantedMs));
  }
}

const roundRulePresets = {
  'baseline': RoundRules(),
  'retry-2200': RoundRules(secondWrongDelayMs: 2200),
  'early-retry': RoundRules(earlySecondWrongDelayMs: 2600),
  'skip-2': RoundRules(skipCostMs: 2000),
  'late-bonus': RoundRules(reducedBonusFromMs: 30000),
};

double strokeProgressAt({
  required int elapsedMs,
  required int questionStartedMs,
  required int level,
}) {
  final end = max(0, elapsedMs);
  final start = questionStartedMs.clamp(0, end);
  // Speed reaches 2× at 60 seconds and stays there during bonus time.
  double distanceAt(int elapsed) {
    final ramp = min(elapsed, roundStartMs);
    return ramp * (1 + ramp / (2 * roundStartMs)) + 2 * (elapsed - ramp);
  }

  final drawingTime = distanceAt(end) - distanceAt(start);
  return (drawingTime / (1700 + level * 1050)).clamp(0.0, 1.0);
}

bool canSkipAt({
  required int elapsedMs,
  required int questionStartedMs,
  required int level,
}) =>
    strokeProgressAt(
      elapsedMs: elapsedMs - skipWaitMs,
      questionStartedMs: questionStartedMs,
      level: level,
    ) ==
    1;
