import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fun_design.dart';
import 'game_audio.dart';
import 'quiz_balance.dart';
import 'round_rules.dart';
import 'sketchflow.dart';

export 'round_rules.dart'
    show
        canSkipAt,
        correctBonusMs,
        firstWrongLockMs,
        lastWrongTransitionMs,
        maxRoundBonusMs,
        repeatWrongLockMs,
        roundStartMs,
        skipPenaltyMs,
        skipWaitMs,
        strokeProgressAt;

const blue = Color(0xff2544c4);
const paper = Color(0xfffff6e3);
const ink = Color(0xff31271c);
const paperTexture = AssetImage('assets/wrinkled-paper.webp');
const gameStartCueDuration = Duration(milliseconds: 450);
const answerLabelSize = 25.0;
const answerLabelStyle = TextStyle(
  fontFamily: 'Gaegu',
  fontSize: answerLabelSize,
  fontWeight: FontWeight.w700,
);
final quizPlaytestSeed = int.tryParse(
  const String.fromEnvironment('QUIZ_PLAYTEST_SEED'),
);
const quizPlaytestLevel = int.fromEnvironment(
  'QUIZ_PLAYTEST_LEVEL',
  defaultValue: 3,
);
const _requestedRulePreset = String.fromEnvironment(
  'QUIZ_PLAYTEST_RULES',
  defaultValue: 'baseline',
);
const _requestedStrategy = String.fromEnvironment('QUIZ_PLAYTEST_STRATEGY');
final activeRulePreset = quizPlaytestSeed == null
    ? 'early-retry'
    : roundRulePresets.containsKey(_requestedRulePreset)
    ? _requestedRulePreset
    : 'baseline';
final activeRoundRules = roundRulePresets[activeRulePreset]!;
String get balanceHistoryKey =>
    quizPlaytestSeed == null ? 'recent_quiz_balance' : 'quiz_playtest_history';
String get balanceSummaryKey =>
    quizPlaytestSeed == null ? 'last_balance_summary' : 'quiz_playtest_summary';
const quizFirstPlayStartedKey = 'quiz_first_play_started';

String secondsLabel(int milliseconds) => milliseconds % 1000 == 0
    ? '${milliseconds ~/ 1000}초'
    : '${(milliseconds / 1000).toStringAsFixed(1)}초';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/fonts/Gaegu-OFL.txt');
    yield LicenseEntryWithLineBreaks(['Gaegu'], license);
  });
  runApp(const Sketchbook());
}

class Sketchbook extends StatelessWidget {
  const Sketchbook({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '토끼의 낙서장',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: blue, surface: paper),
      scaffoldBackgroundColor: paper,
      useMaterial3: true,
    ),
    home: const GameScreen(),
  );
}

class Prompt {
  Prompt.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      label = json['label'] as String,
      drawings = (json['drawings'] as List).map((drawing) {
        final strokes = (drawing as List)
            .map((stroke) {
              final axes = stroke as List;
              final x = axes[0] as List;
              final y = axes[1] as List;
              return List.generate(
                x.length,
                (i) => Offset((x[i] as num) / 255, (y[i] as num) / 255),
              );
            })
            .where((stroke) => stroke.isNotEmpty)
            .toList();
        final points = strokes.expand((stroke) => stroke);
        final left = points.map((point) => point.dx).reduce(min);
        final top = points.map((point) => point.dy).reduce(min);
        final width = points.map((point) => point.dx).reduce(max) - left;
        final height = points.map((point) => point.dy).reduce(max) - top;
        final extent = max(width, height);
        if (extent <= 0) return strokes;
        final origin = Offset(left + width / 2, top + height / 2);
        return strokes
            .map(
              (stroke) => stroke.map((point) {
                return (point - origin) / extent * 0.85 +
                    const Offset(0.5, 0.5);
              }).toList(),
            )
            .toList();
      }).toList();

  final String id;
  final String label;
  final List<List<List<Offset>>> drawings;
}

enum Phase { launching, download, home, preparing, playing, results }

bool get offersSketchFlow => SketchFlow.available && quizPlaytestSeed == null;

const sketchFlowSetupKey = 'sketchflow_setup_seen';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  Random random = Random();
  final clock = Stopwatch();
  final audio = GameAudio();

  final missed = <(String, List<List<Offset>>)>[];
  final disabled = <String>{};
  final finishedWrongChoices = <String>{};
  List<Prompt> pack = [];
  Map<String, Prompt> promptsById = {};
  Map<String, String> labelsById = {};
  Map<String, List<String>> relatedById = {};
  Map<String, List<String>> outlinesById = {};
  Map<String, List<({List<String> ranked, Set<String> ambiguous})>>
  drawingOutlinesById = {};
  Map<String, List<int>> earlyDrawingsById = {};
  final roundResults = <QuizResult>[];
  QuizBalanceHistory balanceHistory = QuizBalanceHistory(const []);
  String? lastBalanceSummary;
  int missedStreak = 0;
  bool assistance = false;
  bool enteringLevelFive = false;
  bool questionLogged = false;
  int? storedDrawingIndex;
  Future<bool>? firstPlayAtStart;
  int? firstTapMs;
  double? firstTapProgress;
  List<Prompt> deck = [];
  List<String> options = [];
  List<List<Offset>> drawing = [];
  Prompt? prompt;
  Phase phase = offersSketchFlow ? Phase.launching : Phase.home;
  Timer? refresh;
  String? error;
  int score = 0;
  int best = 0;
  int? roundDailyDay;
  ({int day, int score})? dailyRecord;
  int roundPreviousBest = 0;
  int quickCueUntil = 0;
  List<String> replayVisits = [];
  String? replaySequence;
  int sequenceStarts = 0;
  int level = 1;
  int questionAt = 0;
  int deadlineMs = roundStartMs;
  int bonusGrantedMs = 0;
  int? bonusCapAtMs;
  int? bonusCapScore;
  bool roundEndedBySkip = false;
  int correctStreak = 0;
  int streakVisibleUntil = 0;
  bool finalTenCuePlayed = false;
  int timeFeedbackUntil = 0;
  String? timeFeedback;
  int lockedUntil = 0;
  int answerLockDurationMs = firstWrongLockMs;
  int? advanceAfterWrongAt;
  int countdown = 3;
  bool loading = true;
  bool audioSettingsChanged = false;
  SketchFlow? sketchFlow;
  bool sketchFlowSetupSeen = false;
  bool openingSketchFlow = false;
  bool modelDownloadPaused = false;
  SketchFlowTransfer? modelTransfer;
  bool aiRound = false;
  bool aiDrawing = false;
  String? modelStatus;
  int? modelPercent;
  final generated =
      <String, ({List<List<Offset>> drawing, QuizOutlineMatch outline})>{};
  int round = 0;

  int get elapsed => clock.elapsedMilliseconds;
  bool get canSkip =>
      advanceAfterWrongAt == null &&
      canSkipAt(
        elapsedMs: elapsed,
        questionStartedMs: questionAt,
        level: level,
      );
  int get remainingMs => max(0, deadlineMs - elapsed);
  int get seconds => (remainingMs / 1000).ceil();
  bool get playing => phase == Phase.playing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(loadPack());
    unawaited(loadPreferences());
    if (offersSketchFlow) {
      unawaited(checkModel());
    }
  }

  Future<void> checkModel() async {
    var seen = false;
    try {
      final preferences = await SharedPreferences.getInstance();
      seen = preferences.getBool(sketchFlowSetupKey) ?? false;
      final model = await SketchFlow.isDownloaded()
          ? await SketchFlow.open()
          : null;
      final savedPercent = model == null
          ? await SketchFlow.savedDownloadPercent()
          : null;
      if (!mounted) {
        await model?.dispose();
        return;
      }
      setState(() {
        sketchFlow = model;
        modelPercent = savedPercent;
        sketchFlowSetupSeen = seen || model != null;
        phase = sketchFlowSetupSeen ? Phase.home : Phase.download;
      });
      if (model != null && !seen) unawaited(saveSketchFlowSetup());
    } catch (_) {
      if (mounted) {
        setState(() {
          sketchFlowSetupSeen = seen;
          phase = seen ? Phase.home : Phase.download;
          modelStatus = 'AI 그림을 불러오지 못했어요. 기본 그림으로 시작할 수 있어요.';
        });
      }
    }
  }

  Future<void> saveSketchFlowSetup() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(sketchFlowSetupKey, true);
    } catch (_) {
      // The choice still applies to this session.
    }
  }

  Future<void> enableModel() async {
    if (openingSketchFlow) return;
    final transfer = SketchFlowTransfer();
    setState(() {
      modelTransfer = transfer;
      openingSketchFlow = true;
      modelDownloadPaused = false;
      modelStatus = null;
    });
    try {
      final model = await SketchFlow.open(
        transfer: transfer,
        onDownload: (progress) {
          final percent = (progress * 100).floor();
          if (mounted && percent != modelPercent) {
            setState(() => modelPercent = percent);
          }
        },
      );
      if (!mounted || transfer.paused) {
        await model.dispose();
        return;
      }
      setState(() => sketchFlow = model);
    } catch (_) {
      int? savedPercent;
      try {
        savedPercent = await SketchFlow.savedDownloadPercent();
      } catch (_) {
        // The download state can be shown without a cached percentage.
      }
      if (mounted) {
        setState(() {
          modelPercent = savedPercent;
          if (!transfer.paused) {
            modelStatus = 'AI 그림을 받지 못했어요. 연결을 확인하고 다시 시도해 주세요.';
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          openingSketchFlow = false;
          modelTransfer = null;
        });
      }
    }
  }

  Future<void> prepareDrawing(Prompt selected, int nextLevel) async {
    if (generated.containsKey(selected.id) ||
        usesStoredDrawing(selected.id, nextLevel)) {
      return;
    }
    final generation = round;
    final job = sketchFlow?.prepare(selected.id);
    if (job == null) return;
    try {
      final result = await job;
      if (mounted &&
          round == generation &&
          deck.contains(selected) &&
          result.isNotEmpty) {
        final id = selected.id;
        final related = {
          ...relatedById[id]!.take(6),
          ...quizConfusableWith(id),
        };
        final rivals = {...outlinesById[id]!.take(12), ...related};
        final outline = assessQuizOutline(result, selected.drawings, {
          for (final rival in rivals)
            if (promptsById[rival] case final prompt?) rival: prompt.drawings,
        }, plausibleRivals: related);
        if (outline.usable) generated[id] = (drawing: result, outline: outline);
      }
    } catch (_) {
      // If inference fails, this question can use its bundled drawing.
    }
    if (mounted &&
        playing &&
        round == generation &&
        deck.isNotEmpty &&
        upcomingPrompt(quizLevel(score + 1)) != selected) {
      prefetchDrawing();
    }
  }

  Future<void> loadPack() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = jsonDecode(
        await rootBundle.loadString('assets/questions.json'),
      ) as List;
      final loaded = data
          .map((row) => Prompt.fromJson(row as Map<String, dynamic>))
          .toList();
      if (loaded.length != 345 ||
          loaded.map((item) => item.label).toSet().length != 345 ||
          loaded.any((item) => item.drawings.isEmpty)) {
        throw const FormatException('Invalid question pack');
      }
      final ranked =
          (jsonDecode(
            await rootBundle.loadString('assets/related_questions.json'),
          ) as Map).map(
            (id, values) =>
                MapEntry(id as String, (values as List).cast<String>()),
          );
      final labels = {
        for (final question in loaded) question.id: question.label,
      };
      final outlines = jsonDecode(
        await rootBundle.loadString('assets/outline_questions.json'),
      ) as Map;
      final visualRanks = <String, List<String>>{};
      final drawingRanks =
          <String, List<({List<String> ranked, Set<String> ambiguous})>>{};
      final earlyDrawings = <String, List<int>>{};
      for (final question in loaded) {
        final row = outlines[question.id] as Map;
        final similar = (row['similar'] as List).cast<String>();
        final byDrawing = (row['visualByDrawing'] as List).cast<List>();
        final ambiguous = (row['ambiguousByDrawing'] as List).cast<List>();
        final early = (row['earlyByDrawing'] as List).cast<int>();
        final reviewed = reviewedStoredQuestions[question.id];
        if (similar.toSet().length != 24 ||
            similar.contains(question.id) ||
            !similar.every(labels.containsKey) ||
            byDrawing.length != question.drawings.length ||
            ambiguous.length != question.drawings.length ||
            (reviewed != null &&
                reviewed.any(
                  (index) => index < 0 || index >= question.drawings.length,
                )) ||
            ![...byDrawing, ...ambiguous].every(
              (ids) =>
                  !ids.contains(question.id) && ids.every(labels.containsKey),
            ) ||
            early.length != question.drawings.length ||
            early.toSet().length != early.length ||
            early.any((index) => index < 0 || index >= early.length)) {
          throw const FormatException('Invalid quiz outlines');
        }
        visualRanks[question.id] = similar;
        drawingRanks[question.id] = List.generate(
          byDrawing.length,
          (index) => (
            ranked: byDrawing[index].cast<String>(),
            ambiguous: ambiguous[index].cast<String>().toSet(),
          ),
        );
        earlyDrawings[question.id] = early;
      }
      if (ranked.length != labels.length ||
          labels.keys.any((id) {
            final neighbors = ranked[id];
            return neighbors == null ||
                neighbors.toSet().length != 20 ||
                neighbors.contains(id) ||
                !neighbors.every(labels.containsKey);
          })) {
        throw const FormatException('Invalid related questions');
      }
      if (mounted) {
        setState(() {
          pack = loaded;
          promptsById = {for (final prompt in loaded) prompt.id: prompt};
          labelsById = labels;
          relatedById = ranked;
          outlinesById = visualRanks;
          drawingOutlinesById = drawingRanks;
          earlyDrawingsById = earlyDrawings;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          error = '문제 목록을 읽지 못했어요.';
          loading = false;
        });
      }
    }
  }

  Future<void> loadPreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      balanceHistory = QuizBalanceHistory(
        preferences.getStringList(balanceHistoryKey) ?? [],
      );
      setState(() {
        best = max(best, preferences.getInt('best_score') ?? 0);
        dailyRecord = parseDailyRecord(preferences.getString(dailyRecordKey));
        replayVisits = preferences.getStringList(replayVisitsKey) ?? [];
        lastBalanceSummary =
            preferences.getString(balanceSummaryKey) ?? lastBalanceSummary;
        if (!audioSettingsChanged) {
          audio.saveSettings(
            music: preferences.getBool('game_music') ?? true,
            effects: preferences.getBool('game_effects') ?? true,
          );
        }
      });
    } on Exception catch (_) {
      // Keep the current session playable if platform storage fails.
    }
  }

  Future<void> setAudioSettings({
    required bool music,
    required bool effects,
  }) async {
    setState(() {
      audioSettingsChanged = true;
      audio.saveSettings(music: music, effects: effects);
    });
    try {
      final preferences = await SharedPreferences.getInstance();
      final latestMusic = audio.musicEnabled;
      final latestEffects = audio.effectsEnabled;
      await Future.wait([
        preferences.setBool('game_music', latestMusic),
        preferences.setBool('game_effects', latestEffects),
      ]);
    } on Exception catch (_) {
      // The in-memory controls still work if storage is unavailable.
    }
  }

  Future<void> saveBest(int value) async {
    try {
      await (await SharedPreferences.getInstance()).setInt('best_score', value);
    } on Exception catch (_) {
      // The score remains visible for the current session.
    }
  }

  Future<void> saveDailyRecord(int day, int score) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        dailyRecordKey,
        '$day:$score',
      );
    } on Exception catch (_) {
      // The daily score is still available in this session.
    }
  }

  Future<void> saveReplayProgress() async {
    final sequence = replaySequence;
    if (sequence == null) return;
    final recent = recordReplayVisit(replayVisits, sequence, sequenceStarts);
    replayVisits = recent;
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        replayVisitsKey,
        recent,
      );
    } on Exception catch (_) {
      // Counts remain available in this session.
    }
  }

  Future<void> start({bool daily = false, bool replay = false}) async {
    if (pack.isEmpty || phase == Phase.preparing || playing) return;
    final finishingSetup = phase == Phase.download && !sketchFlowSetupSeen;
    setState(() {
      if (finishingSetup) sketchFlowSetupSeen = true;
      phase = Phase.preparing;
      countdown = 3;
      score = 0;
      level = 1;
      missed.clear();
      roundResults.clear();
      missedStreak = 0;
      roundDailyDay = daily ? dailySketchDay(DateTime.now()) : null;
      final seed = quizPlaytestSeed ?? roundDailyDay;
      roundPreviousBest = daily
          ? dailyRecord?.day == roundDailyDay
                ? dailyRecord!.score
                : 0
          : best;
      if (seed != null) {
        replaySequence = null;
        sequenceStarts = 0;
      } else if (replay && replaySequence != null) {
        sequenceStarts++;
        unawaited(saveReplayProgress());
      } else {
        replaySequence = DateTime.now().microsecondsSinceEpoch.toString();
        sequenceStarts = 1;
      }
      random = Random(seed);
      deck = List<Prompt>.of(pack)..shuffle(random);
      if (daily) {
        final opening = deck.reversed
            .where((prompt) => openingQuestions.contains(prompt.id))
            .take(2)
            .toList();
        deck.removeWhere(opening.contains);
        deck.addAll(opening.reversed);
      }
      clock.reset();
      deadlineMs = daily ? dailyRoundStartMs : roundStartMs;
      bonusGrantedMs = 0;
      bonusCapAtMs = null;
      bonusCapScore = null;
      roundEndedBySkip = false;
      correctStreak = 0;
      streakVisibleUntil = 0;
      quickCueUntil = 0;
      finalTenCuePlayed = false;
      timeFeedbackUntil = 0;
      timeFeedback = null;
      round++;
      generated.clear();
      aiRound = !daily && sketchFlow != null;
      firstPlayAtStart = seed == null ? markFirstPlay() : null;
      if (daily) unawaited(markFirstPlay());
      prompt = null;
      nextQuestion();
    });
    if (finishingSetup) unawaited(saveSketchFlowSetup());
    while (countdown > 0) {
      audio.play(GameSound.countdown);
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted || phase != Phase.preparing) return;
      setState(() => countdown--);
    }
    audio.play(GameSound.start);
    await Future<void>.delayed(gameStartCueDuration);
    if (!mounted || phase != Phase.preparing) return;
    setState(() {
      phase = Phase.playing;
      clock.start();
    });
    audio.setRoundPlaying(true);
    refresh?.cancel();
    refresh = Timer.periodic(const Duration(milliseconds: 33), (_) => tick());
  }

  Future<bool> markFirstPlay() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (preferences.getBool(quizFirstPlayStartedKey) == true ||
          (preferences.getStringList(balanceHistoryKey)?.isNotEmpty ?? false) ||
          preferences.getString(balanceSummaryKey) != null ||
          preferences.getInt('best_score') != null) {
        return false;
      }
      return await preferences.setBool(quizFirstPlayStartedKey, true);
    } on Exception {
      return false;
    }
  }

  void tick() {
    if (!mounted || !playing) return;
    if (remainingMs == 0) {
      finish();
    } else {
      if (remainingMs <= 10000 && !finalTenCuePlayed) {
        finalTenCuePlayed = true;
        audio.play(GameSound.lastTen);
      }
      setState(() {
        final advanceAt = advanceAfterWrongAt;
        if (advanceAt != null && elapsed >= advanceAt) {
          missed.add((prompt!.label, drawing));
          nextQuestion(QuizOutcome.wrong);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed) tick();
    audio.setActive(resumed);
  }

  Prompt upcomingPrompt(
    int nextLevel, {
    bool earlyDrawing = false,
    bool easing = false,
  }) {
    if (quizPlaytestSeed != null || roundDailyDay != null) return deck.last;
    final previous = prompt?.id;
    return promptsById[chooseQuizQuestion(
      shuffled: deck.reversed.map((prompt) => prompt.id),
      earlyDrawing: earlyDrawing,
      familiar: nextLevel <= 2 || easing,
      tooHard: balanceHistory.tooHardForEarlyLevels,
      repeatsPrevious: (id) =>
          previous != null &&
          (relatedById[previous]!.take(6).contains(id) ||
              relatedById[id]!.take(6).contains(previous) ||
              outlinesById[previous]!.take(6).contains(id) ||
              outlinesById[id]!.take(6).contains(previous)),
    )]!;
  }

  void prefetchDrawing() {
    if (aiRound && deck.isNotEmpty && roundResults.isNotEmpty) {
      final nextLevel = quizLevel(score + 1);
      unawaited(prepareDrawing(upcomingPrompt(nextLevel), nextLevel));
    }
  }

  bool usesStoredDrawing(String id, int level) =>
      reviewedStoredQuestions.containsKey(id) ||
      balanceHistory.prefersStored(id, level);

  void nextQuestion([QuizOutcome? outcome]) {
    if (outcome != null) {
      recordQuestion(outcome);
      missedStreak = outcome == QuizOutcome.correct ? 0 : missedStreak + 1;
    }
    if (deck.isEmpty) {
      finish();
      return;
    }
    final ordinary = quizPlaytestSeed == null && roundDailyDay == null;
    assistance = ordinary && missedStreak >= 2;
    if (missedStreak >= 2) missedStreak = 0;
    level = roundDailyDay != null
        ? dailySketchLevel(roundResults.length)
        : quizPlaytestSeed == null
        ? quizLevel(score, assistance: assistance)
        : quizPlaytestLevel.clamp(1, 5);
    final earlyDrawing = quizPlaytestSeed == null && roundResults.length < 2;
    enteringLevelFive =
        ordinary && outcome == QuizOutcome.correct && score == 8;
    final selected = upcomingPrompt(
      level,
      earlyDrawing: earlyDrawing,
      easing: assistance,
    );
    deck.remove(selected);
    prompt = selected;
    questionLogged = false;
    firstTapMs = null;
    firstTapProgress = null;
    final reviewed = reviewedStoredQuestions[selected.id];
    final candidate = generated.remove(selected.id);
    final fresh =
        earlyDrawing || assistance || usesStoredDrawing(selected.id, level)
        ? null
        : candidate;
    final early = earlyDrawingsById[selected.id]!;
    int? storedIndex;
    if (fresh == null) {
      if (earlyDrawing || level == 1 || assistance) {
        storedIndex = reviewed?.first ?? early.first;
      } else {
        var pool = reviewed ?? early;
        if (reviewed == null && level == 2) {
          pool = early.take((early.length + 1) ~/ 2).toList();
        } else if (reviewed == null && level >= 4) {
          final byStrokeCount = [...early]
            ..sort(
              (a, b) => selected.drawings[a].length.compareTo(
                selected.drawings[b].length,
              ),
            );
          pool = byStrokeCount.skip(byStrokeCount.length ~/ 2).toList();
        }
        storedIndex = pool[random.nextInt(pool.length)];
      }
    }
    aiDrawing = fresh != null;
    storedDrawingIndex = storedIndex;
    drawing = fresh?.drawing ?? selected.drawings[storedIndex!];
    final outline = storedIndex == null
        ? null
        : drawingOutlinesById[selected.id]![storedIndex];
    prefetchDrawing();
    final distractors = quizDistractors(
      answer: selected.id,
      candidates: labelsById.keys.toSet(),
      ranked: relatedById[selected.id]!,
      outlineRanked: outline?.ranked ?? fresh!.outline.ranked,
      indistinguishable: outline?.ambiguous ?? fresh!.outline.ambiguous,
      level: level,
      enteringLevelFive: enteringLevelFive,
      recovery: assistance,
      random: random,
    );
    options = [
      selected.label,
      for (final id in [...distractors.similar, ...distractors.distinct])
        labelsById[id]!,
    ]..shuffle(random);
    disabled.clear();
    finishedWrongChoices.clear();
    questionAt = elapsed;
    lockedUntil = 0;
    advanceAfterWrongAt = null;
  }

  void recordQuestion(QuizOutcome outcome) {
    if (prompt == null || questionLogged) return;
    questionLogged = true;
    roundResults.add(
      QuizResult(
        level: level,
        questionId: prompt!.id,
        generated: aiDrawing,
        storedDrawingIndex: storedDrawingIndex,
        assisted: assistance,
        enteringLevelFive: enteringLevelFive,
        outcome: outcome,
        wrongTaps: disabled.length,
        firstTapMs: firstTapMs,
        firstTapProgress: firstTapProgress,
        finishedWrongChoices: finishedWrongChoices.toList(),
        durationMs: elapsed - questionAt,
      ),
    );
  }

  Future<void> saveRoundBalance(String summary) async {
    final firstPlay = firstPlayAtStart;
    final snapshot = <String, Object>{
      'durationMs': elapsed,
      'score': score,
      'roundRules': activeRulePreset,
      'bonusGrantedMs': bonusGrantedMs,
      'bonusCapAtMs': ?bonusCapAtMs,
      'bonusCapScore': ?bonusCapScore,
      'endedBySkip': roundEndedBySkip,
      'playtestSeed': ?quizPlaytestSeed,
      if (quizPlaytestSeed != null) ...{
        'playtestLevel': quizPlaytestLevel.clamp(1, 5),
        if (const {'guess', 'wait', 'skip'}.contains(_requestedStrategy))
          'playtestStrategy': _requestedStrategy,
      },
      'questions': roundResults.map((result) => result.toJson()).toList(),
    };
    try {
      if (firstPlay != null && await firstPlay) snapshot['firstPlay'] = true;
      final current = jsonEncode(snapshot);
      final preferences = await SharedPreferences.getInstance();
      final rounds = preferences.getStringList(balanceHistoryKey) ?? [];
      final recent = [current, ...rounds.take(19)];
      await preferences.setStringList(balanceHistoryKey, recent);
      balanceHistory = QuizBalanceHistory(recent);
      await preferences.setString(balanceSummaryKey, summary);
    } catch (_) {
      // Statistics remain visible for the current session.
    }
  }

  void noteFirstTap() {
    if (firstTapMs != null) return;
    final now = elapsed;
    firstTapMs = now - questionAt;
    firstTapProgress = strokeProgressAt(
      elapsedMs: now,
      questionStartedMs: questionAt,
      level: level,
    );
  }

  void answer(String option) {
    if (!playing) return;
    if (remainingMs == 0) {
      finish();
      return;
    }
    if (elapsed < lockedUntil || disabled.contains(option)) return;
    noteFirstTap();
    setState(() {
      if (option == prompt!.label) {
        final quick = isQuickCorrect(firstTapProgress, disabled.length);
        audio.play(quick ? GameSound.quickCorrect : GameSound.correct);
        if (quick) quickCueUntil = elapsed + 900;
        score++;
        correctStreak++;
        if (correctStreak % 3 == 0) {
          streakVisibleUntil = elapsed + 1400;
          unawaited(HapticFeedback.lightImpact());
        }
        final now = elapsed;
        final bonus = activeRoundRules.bonusGrantMs(
          elapsedMs: now,
          alreadyGrantedMs: bonusGrantedMs,
        );
        if (bonus > 0) {
          bonusGrantedMs += bonus;
          deadlineMs += bonus;
          if (bonusGrantedMs == maxRoundBonusMs) {
            bonusCapAtMs = now;
            bonusCapScore = score;
          }
          timeFeedback = '+${secondsLabel(bonus)}';
          timeFeedbackUntil = elapsed + 1150;
        } else if (timeFeedback?.startsWith('+') ?? false) {
          timeFeedback = null;
        }
        nextQuestion(QuizOutcome.correct);
      } else {
        correctStreak = 0;
        streakVisibleUntil = 0;
        unawaited(HapticFeedback.mediumImpact());
        audio.play(GameSound.wrong);
        disabled.add(option);
        final now = elapsed;
        final drawingProgress = strokeProgressAt(
          elapsedMs: now,
          questionStartedMs: questionAt,
          level: level,
        );
        if (drawingProgress >= 1) {
          finishedWrongChoices.add(option);
        }
        answerLockDurationMs = activeRoundRules.retryDelayMs(
          disabled.length,
          drawingProgress,
        );
        lockedUntil = now + answerLockDurationMs;
        if (disabled.length == 3) {
          advanceAfterWrongAt = now + lastWrongTransitionMs;
        }
      }
    });
  }

  void skip() {
    if (!playing) return;
    if (remainingMs == 0) {
      finish();
      return;
    }
    if (!canSkip) return;
    correctStreak = 0;
    streakVisibleUntil = 0;
    deadlineMs -= activeRoundRules.skipCostMs;
    if (remainingMs == 0) {
      roundEndedBySkip = true;
      recordQuestion(QuizOutcome.skipped);
      finish();
      return;
    }
    setState(() {
      timeFeedback = '−${secondsLabel(activeRoundRules.skipCostMs)}';
      timeFeedbackUntil = elapsed + 1150;
      missed.add((prompt!.label, drawing));
      nextQuestion(QuizOutcome.skipped);
    });
  }

  void finish() {
    if (!playing) return;
    if (remainingMs == 0 && prompt != null) {
      missed.add((prompt!.label, drawing));
      recordQuestion(QuizOutcome.timeUp);
    }
    refresh?.cancel();
    clock.stop();
    final aiCount = roundResults.where((question) => question.generated).length;
    final skips = roundResults
        .where((question) => question.outcome == QuizOutcome.skipped)
        .length;
    final assists = roundResults.where((question) => question.assisted).length;
    final wrongs = roundResults.fold(
      0,
      (count, question) => count + question.wrongTaps,
    );
    final summary =
        '진행 ${(elapsed / 1000).round()}초 · 정답 $score개 · 오답 $wrongs회 · 건너뛰기 $skips회\n'
        'AI 그림 $aiCount개 · 저장된 그림 ${roundResults.length - aiCount}개 · 난이도 완화 $assists회';
    final dailyDay = roundDailyDay;
    if (dailyDay == null) {
      unawaited(saveRoundBalance(summary));
      if (sequenceStarts == 1) unawaited(saveReplayProgress());
    }
    audio.setRoundPlaying(false);
    audio.play(GameSound.finish);
    setState(() {
      phase = Phase.results;
      if (dailyDay == null) lastBalanceSummary = summary;
      if (dailyDay != null &&
          (dailyRecord?.day != dailyDay || score > dailyRecord!.score)) {
        dailyRecord = (day: dailyDay, score: score);
        unawaited(saveDailyRecord(dailyDay, score));
      }
      if (dailyDay == null && quizPlaytestSeed == null && score > best) {
        best = score;
        unawaited(saveBest(best));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    refresh?.cancel();
    clock.stop();
    audio.dispose();
    modelTransfer?.pause();
    unawaited(sketchFlow?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewPaddingOf(context);
    // Keep the center of the content at the center of the window, even
    // when the system status area removes space from only one edge.
    final sideInset = max(insets.left, insets.right);
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          color: paper,
          image: DecorationImage(image: paperTexture, fit: BoxFit.cover),
        ),
        child: SafeArea(
          minimum: EdgeInsets.symmetric(horizontal: sideInset),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: phase == Phase.playing ? 920 : 560,
              ),
              child: switch (phase) {
                Phase.launching => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      appTitle(),
                      const SizedBox(height: 20),
                      const CircularProgressIndicator(),
                    ],
                  ),
                ),
                Phase.download => downloadPage(),
                Phase.home => home(),
                Phase.preparing => prepare(),
                Phase.playing => game(),
                Phase.results => results(),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget title(
    String label, {
    double size = 36,
    Color color = ink,
    bool handwritten = false,
    bool singleLine = false,
  }) => Text(
    label,
    textAlign: TextAlign.center,
    maxLines: singleLine ? 1 : null,
    softWrap: !singleLine,
    style: TextStyle(
      fontFamily: handwritten ? 'Gaegu' : null,
      fontSize: size,
      fontWeight: handwritten ? FontWeight.w700 : FontWeight.w800,
      color: color,
    ),
  );

  Widget appTitle() => Column(
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        child: title('토끼의 낙서장', size: 44, handwritten: true, singleLine: true),
      ),
      const SizedBox(
        width: 172,
        height: 13,
        child: CustomPaint(painter: BrushUnderline(blue)),
      ),
    ],
  );

  Widget primary(String label, VoidCallback? action, {double fontSize = 34}) =>
      SizedBox(
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            color: action == null ? null : blue,
            image: action == null
                ? null
                : const DecorationImage(
                    image: paperTexture,
                    fit: BoxFit.cover,
                    colorFilter: ColorFilter.mode(blue, BlendMode.multiply),
                  ),
          ),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 55),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(19),
              ),
              textStyle: TextStyle(
                fontFamily: 'Gaegu',
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: action,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, maxLines: 1, softWrap: false),
            ),
          ),
        ),
      );

  double screenGutter(double width) => width < 320 ? 8 : 16;

  Widget secondary(
    String label,
    VoidCallback? action, {
    double fontSize = 27,
  }) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      foregroundColor: ink,
      backgroundColor: const Color(0xccfff8ea),
      minimumSize: const Size(0, 55),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(19)),
      side: const BorderSide(color: ink, width: 1.5),
      textStyle: TextStyle(
        fontFamily: 'Gaegu',
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
      ),
    ),
    onPressed: action,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false),
    ),
  );

  Widget spacedPage(
    List<Widget> sections, {
    MainAxisAlignment distribution = MainAxisAlignment.spaceBetween,
    double? horizontalGutter,
    double verticalGutter = 16,
  }) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalGutter ?? screenGutter(constraints.maxWidth),
        vertical: verticalGutter,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: max(0, constraints.maxHeight - 2 * verticalGutter),
        ),
        child: Column(
          mainAxisAlignment: distribution,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: sections,
        ),
      ),
    ),
  );

  Widget downloadPage() {
    final complete = sketchFlow != null;
    final progress = modelPercent;
    final transferring = modelTransfer != null;
    final firstSetup = !sketchFlowSetupSeen;
    final showAudioSettings = firstSetup && !openingSketchFlow;
    final verifying = openingSketchFlow && progress == 100;
    final paused =
        modelDownloadPaused ||
        (!openingSketchFlow &&
            progress != null &&
            modelStatus == null &&
            !complete);
    final status = complete
        ? 'AI 그림으로 플레이할 수 있어요'
        : verifying
        ? '다운로드 완료 · 모델 확인 중'
        : openingSketchFlow
        ? (modelDownloadPaused
              ? '일시정지 중'
              : '다운로드 중${progress == null ? '' : ' · $progress%'}')
        : paused
        ? '다운로드 일시정지${progress == null ? '' : ' · $progress%'}'
        : modelStatus != null && progress != null
        ? '현재 $progress% 받음'
        : null;
    return spacedPage([
      appTitle(),
      Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: title(
              complete
                  ? '스케치북 준비 완료!'
                  : openingSketchFlow
                  ? '스케치북을 준비 중이에요'
                  : '스케치북 준비하기',
              handwritten: true,
              singleLine: true,
              size: 32,
              color: blue,
            ),
          ),
          if (!openingSketchFlow && !complete)
            const Text(
              '받은 뒤에는 인터넷 없이 AI 그림을 만들 수 있어요.',
              textAlign: TextAlign.center,
            ),
        ],
      ),
      Center(
        child: DownloadRabbit(
          packing: transferring,
          packed: complete || progress != null,
          size:
              (MediaQuery.sizeOf(context).height *
                      (showAudioSettings ? 0.30 : 0.38))
                  .clamp(145, showAudioSettings ? 255 : 310)
                  .toDouble(),
        ),
      ),
      Column(
        children: [
          if (showAudioSettings) ...[
            audioSettings(),
            const SizedBox(height: 8),
          ],
          if (openingSketchFlow || progress != null || complete) ...[
            LinearProgressIndicator(
              value: complete
                  ? 1
                  : progress == null
                  ? null
                  : progress / 100,
              minHeight: 12,
              borderRadius: BorderRadius.circular(10),
            ),
            const SizedBox(height: 8),
          ],
          if (status != null) ...[
            Semantics(
              liveRegion:
                  !openingSketchFlow || verifying || modelDownloadPaused,
              child: title(status, size: 17),
            ),
            const SizedBox(height: 10),
          ],
          if (modelStatus != null)
            Text(modelStatus!, textAlign: TextAlign.center),
          if (complete)
            primary(
              firstSetup ? 'AI 그림으로 시작' : '시작',
              loading || error != null ? null : start,
            )
          else if (openingSketchFlow) ...[
            if (transferring && !verifying)
              secondary(
                '일시정지',
                modelDownloadPaused
                    ? null
                    : () => setState(() {
                        modelDownloadPaused = true;
                        modelTransfer!.pause();
                      }),
              ),
          ] else ...[
            if (modelStatus != null) const SizedBox(height: 8),
            Text('AI 그림 용량 약 ${SketchFlow.downloadMegabytes} MB'),
            const SizedBox(height: 8),
            primary(
              modelStatus != null
                  ? '다시 시도'
                  : paused
                  ? '이어받기'
                  : 'AI 그림 다운로드',
              enableModel,
            ),
            const SizedBox(height: 8),
            secondary(
              '기본 그림으로 시작',
              loading || error != null ? null : start,
              fontSize: 24,
            ),
            if (sketchFlowSetupSeen)
              TextButton(
                onPressed: () => setState(() => phase = Phase.home),
                child: const Text('홈으로'),
              ),
          ],
          if (error != null) ...[
            Text(error!, textAlign: TextAlign.center),
            TextButton(onPressed: loadPack, child: const Text('문제 목록 다시 불러오기')),
          ],
        ],
      ),
    ], distribution: MainAxisAlignment.spaceEvenly);
  }

  Widget home() => spacedPage([
    Column(
      children: [
        appTitle(),
        const SizedBox(height: 10),
        title('60초 동안 그림을 맞혀요', size: 21),
        const SizedBox(height: 4),
        Text(
          '정답 +1초 · 건너뛰기 −${secondsLabel(activeRoundRules.skipCostMs)}',
          textAlign: TextAlign.center,
        ),
        if (activeRoundRules.reducedBonusFromMs case final elapsed?)
          Text(
            '${secondsLabel(elapsed)}부터 정답 +0.5초',
            textAlign: TextAlign.center,
          ),
        const Text('그림이 완성되기 전에도 답을 고를 수 있어요.', textAlign: TextAlign.center),
      ],
    ),
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: RabbitIdle(
        child: Image.asset(
          'assets/paper-rabbit.webp',
          height: (MediaQuery.sizeOf(context).height * 0.32)
              .clamp(150, 300)
              .toDouble(),
          fit: BoxFit.contain,
          excludeFromSemantics: true,
        ),
      ),
    ),
    Column(
      children: [
        if (error != null) ...[
          Text(error!, textAlign: TextAlign.center),
          primary('다시 시도', loadPack),
        ] else
          primary(loading ? '불러오는 중' : '시작', loading ? null : start),
        if (quizPlaytestSeed == null)
          TextButton(
            onPressed: loading || error != null
                ? null
                : () => start(daily: true),
            child: const Text('오늘의 낙서 · 30초'),
          ),
        if (offersSketchFlow && sketchFlow == null)
          TextButton(
            onPressed: () => setState(() => phase = Phase.download),
            child: Text(modelPercent == null ? 'AI 그림 받기' : 'AI 그림 이어받기'),
          ),
        const SizedBox(height: 12),
        title('최고 기록 $best개', size: 17),
      ],
    ),
    Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          audioSettings(),
          TextButton(
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: '토끼의 낙서장',
              children: [
                if (lastBalanceSummary != null)
                  Text('최근 플레이\n$lastBalanceSummary'),
                if (lastBalanceSummary != null)
                  TextButton(
                    onPressed: showBalanceDetails,
                    child: const Text('최근 20판 난이도 비교'),
                  ),
                TextButton(
                  onPressed: showLevelProgressReview,
                  child: const Text('레벨 진행 검수'),
                ),
                TextButton(
                  onPressed: () => showQuizReview(
                    '밸런스 검수',
                    balanceHistory.roundRulesReview(labelsById),
                  ),
                  child: const Text('밸런스 검수'),
                ),
                TextButton(
                  onPressed: () => showQuizReview('재미 검수', [
                    (title: '빠른 정답', value: balanceHistory.quickCorrectSummary),
                    (title: '한 판 더', value: replayVisitSummary(replayVisits)),
                  ], range: '최근 일반 플레이와 재도전 기록'),
                  child: const Text('재미 검수'),
                ),
                const Text('그림 데이터: Google Quick, Draw! (CC BY 4.0)'),
                const SelectableText(
                  'https://github.com/googlecreativelab/quickdraw-dataset',
                ),
                const SelectableText(
                  'https://creativecommons.org/licenses/by/4.0/',
                ),
              ],
            ),
            child: const Text('앱 정보'),
          ),
          const AdBanner(),
        ],
      ),
    ),
  ], distribution: MainAxisAlignment.spaceEvenly);

  Widget audioSettings() => Wrap(
    alignment: WrapAlignment.center,
    spacing: 8,
    children: [
      FilterChip(
        label: const Text('음악'),
        selected: audio.musicEnabled,
        onSelected: (music) => unawaited(
          setAudioSettings(music: music, effects: audio.effectsEnabled),
        ),
      ),
      FilterChip(
        label: const Text('효과음'),
        selected: audio.effectsEnabled,
        onSelected: (effects) => unawaited(
          setAudioSettings(music: audio.musicEnabled, effects: effects),
        ),
      ),
    ],
  );

  void showLevelProgressReview() => showQuizReview(
    '레벨 진행 검수',
    balanceHistory.levelProgressReview(labelsById),
  );

  void showQuizReview(
    String heading,
    List<({String title, String value})> sections, {
    String range = '이 기기의 최근 20판',
  }) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(heading),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(range),
            for (final section in sections)
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${section.title}\n',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(text: section.value),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final report = [
                '$heading · $range',
                for (final section in sections)
                  '${section.title}\n${section.value}',
              ].join('\n\n');
              await Clipboard.setData(ClipboardData(text: report));
              if (!dialogContext.mounted || !mounted) return;
              Navigator.pop(dialogContext);
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('검수 기록을 복사했어요.')));
            },
            child: const Text('기록 복사'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  void showBalanceDetails() {
    final history = balanceHistory;
    final candidates = history.reviewCandidates();
    final finishedPairs = history.finishedPairCandidates();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('최근 20판 난이도 비교'),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            if (history.openingSummary case final summary?)
              Text('첫 문제 · $summary'),
            if (history.secondSummary case final summary?)
              Text('두 번째 문제 · $summary'),
            if (history.earlyFirstCorrectSummary case final summary?)
              Text('첫 두 문제에서 첫 정답 · $summary'),
            for (var level = 1; level <= 5; level++)
              if (history.hasLevel(level)) ...[
                Text(
                  '$level단계\nAI 그림 · ${history.describe(level, generated: true)}\n\n'
                  '저장된 그림 · ${history.describe(level, generated: false)}',
                ),
                if (level == 5 && history.levelFiveEntrySummary != null)
                  Text('5단계 첫 문제 · ${history.levelFiveEntrySummary}')
                else if (history.promotedSummary(level) case final summary?)
                  Text('승급 직후 · $summary'),
                if (history.assistedSummary(level) case final summary?)
                  Text('난이도 완화 직후 · $summary'),
              ],
            if (candidates.isNotEmpty)
              const Text(
                '검수 후보',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            for (final candidate in candidates)
              Text(
                '${labelsById[candidate.id] ?? candidate.id} · ${candidate.level}단계 · '
                '${candidate.generated ? 'AI' : '저장된 그림'} · 정답 ${candidate.correct}/${candidate.total} '
                '· 건너뛰기 ${candidate.skips}회',
              ),
            if (finishedPairs.isNotEmpty)
              const Text(
                '완성 후 반복 오답',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            for (final pair in finishedPairs)
              Text(
                '${labelsById[pair.id] ?? pair.id} → ${pair.choice} ${pair.count}회',
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Widget prepare() => spacedPage([
    appTitle(),
    Image.asset(
      'assets/open-rabbit.png',
      height: (MediaQuery.sizeOf(context).height * 0.35)
          .clamp(170, 300)
          .toDouble(),
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    ),
    Semantics(
      liveRegion: true,
      child: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        child: KeyedSubtree(
          key: ValueKey(countdown),
          child: countdown == 0
              ? gameStartCue(MediaQuery.disableAnimationsOf(context))
              : title('$countdown', size: 46, color: blue),
        ),
      ),
    ),
  ]);

  Widget gameStartCue(bool reducedMotion) {
    final label = title(
      '게임 시작!',
      size: 54,
      color: blue,
      handwritten: true,
      singleLine: true,
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: reducedMotion
            ? label
            : TweenAnimationBuilder<double>(
                key: const ValueKey('game-start-shake'),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 400),
                child: label,
                builder: (context, progress, child) {
                  final swing = sin(progress * 6 * pi) * (1 - progress);
                  return Transform.translate(
                    offset: Offset(9 * swing, 0),
                    child: Transform.rotate(angle: 0.04 * swing, child: child),
                  );
                },
              ),
      ),
    );
  }

  Widget game() => LayoutBuilder(
    builder: (context, constraints) {
      final gutter = constraints.maxWidth < 320 ? 4.0 : 12.0;
      final contentWidth = max(0.0, constraints.maxWidth - 2 * gutter);
      final sideBySide = contentWidth >= 420;
      final textScaler = MediaQuery.textScalerOf(context);
      final labelSize = textScaler.scale(answerLabelSize);
      final largeText = labelSize >= answerLabelSize * 1.6;
      final paneWidth = sideBySide ? (contentWidth - 20) * .4 : contentWidth;
      bool answerNeedsFullWidth() {
        // The button reserves 12 px for padding and 32 px for its answer mark.
        final labelWidth = max(1.0, (paneWidth - 12) / 2 - 44);
        return options.any((option) {
          final text = TextPainter(
            text: TextSpan(text: option, style: answerLabelStyle),
            textDirection: Directionality.of(context),
            textScaler: textScaler,
            maxLines: 2,
          )..layout(maxWidth: labelWidth);
          final needsWidth = text.didExceedMaxLines;
          text.dispose();
          return needsWidth;
        });
      }

      final compactWide =
          sideBySide &&
          constraints.maxHeight <= 440 &&
          !largeText &&
          !answerNeedsFullWidth();
      final singleColumn =
          (sideBySide && !compactWide) ||
          (largeText && contentWidth < 360) ||
          (!sideBySide && contentWidth < 330 && answerNeedsFullWidth());
      final wrapOptions = compactWide || singleColumn || contentWidth < 330;
      final canvasSize = sideBySide
          ? min(
              (contentWidth - 20) * 0.60,
              max(150.0, constraints.maxHeight - 140),
            )
          : min(
              contentWidth,
              max(130.0, constraints.maxHeight - (singleColumn ? 390 : 285)),
            );
      final progress = strokeProgressAt(
        elapsedMs: elapsed,
        questionStartedMs: questionAt,
        level: level,
      );
      final timer =
          '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
      final feedback = elapsed < timeFeedbackUntil ? timeFeedback : null;
      final header = Row(
        children: [
          Expanded(
            flex: 3,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                timer,
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: seconds <= 10 ? Colors.red.shade800 : ink,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    roundDailyDay != null
                        ? '오늘의 낙서'
                        : aiRound
                        ? aiDrawing
                              ? 'AI 그림'
                              : '저장된 그림'
                        : offersSketchFlow
                        ? '기본 그림'
                        : '',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xff594b3e),
                    ),
                  ),
                  SizedBox(
                    height: 21,
                    child: feedback == null
                        ? null
                        : Semantics(
                            liveRegion: true,
                            child: title(
                              feedback,
                              size: 15,
                              color: feedback.startsWith('+')
                                  ? const Color(0xff226548)
                                  : const Color(0xffa33830),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: title('$score점', size: 31, singleLine: true),
            ),
          ),
        ],
      );
      final canvas = Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 10),
        child: Center(
          child: SizedBox.square(
            key: const ValueKey('play-sketchbook'),
            dimension: canvasSize,
            child: boundSketchbook(
              MediaQuery.disableAnimationsOf(context)
                  ? sketchPage(drawing, progress, true)
                  : ClipRect(
                      clipper: const _PageClip(),
                      child: AnimatedSwitcher(
                        duration: Duration.zero,
                        reverseDuration: const Duration(milliseconds: 320),
                        layoutBuilder: (current, previous) => Stack(
                          fit: StackFit.expand,
                          children: [?current, ...previous],
                        ),
                        transitionBuilder: liftSketchPage,
                        child: KeyedSubtree(
                          key: ValueKey(prompt?.id),
                          child: sketchPage(drawing, progress, true),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      );
      final answerTime = elapsed;
      final answersLocked = answerTime < lockedUntil;
      final retryReady = disabled.isNotEmpty && !answersLocked;
      final answers = Column(
        children: [
          SizedBox(
            height: largeText ? 42 : 28,
            child: answerFeedback(
              answerTime,
              locked: answersLocked,
              retryReady: retryReady,
            ),
          ),
          if (singleColumn)
            for (final option in options)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SizedBox(
                  width: double.infinity,
                  child: choice(
                    option,
                    locked: answersLocked,
                    retryReady: retryReady,
                    wrapLabel: wrapOptions,
                  ),
                ),
              )
          else
            for (var row = 0; row < 2; row++) ...[
              Row(
                children: [
                  for (var column = 0; column < 2; column++) ...[
                    if (column == 1) const SizedBox(width: 12),
                    Expanded(
                      child: choice(
                        options[row * 2 + column],
                        locked: answersLocked,
                        retryReady: retryReady,
                        wrapLabel: wrapOptions,
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: row == 0 ? 10 : 4),
            ],
          skipButton(deemphasize: disabled.isNotEmpty),
        ],
      );
      return spacedPage(
        [
          header,
          if (sideBySide)
            Row(
              key: const ValueKey('wide-play-layout'),
              children: [
                Expanded(flex: 3, child: canvas),
                const SizedBox(width: 20),
                Expanded(flex: 2, child: answers),
              ],
            )
          else ...[
            canvas,
            answers,
          ],
        ],
        horizontalGutter: gutter,
        verticalGutter: 12,
        distribution: MainAxisAlignment.center,
      );
    },
  );

  Widget answerFeedback(
    int now, {
    required bool locked,
    required bool retryReady,
  }) {
    const wrongColor = Color(0xffa33830);
    const neutral = Color(0xff594b3e);
    final nextDrawingAt = advanceAfterWrongAt;
    Widget? message;
    if (locked) {
      final end = nextDrawingAt ?? lockedUntil;
      final duration = nextDrawingAt != null
          ? lastWrongTransitionMs
          : answerLockDurationMs;
      final remaining = ((end - now) / duration).clamp(0.0, 1.0);
      message = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          title('틀렸어요', size: 14, color: wrongColor),
          const SizedBox(width: 6),
          Text(
            nextDrawingAt != null
                ? '다음 그림 준비 중'
                : answerLockDurationMs > repeatWrongLockMs
                ? '그림을 더 보고 다시 골라요'
                : '곧 다른 보기를 누를 수 있어요',
            style: const TextStyle(fontSize: 13, color: neutral),
          ),
          const SizedBox(width: 7),
          ExcludeSemantics(
            child: Row(
              children: [
                SizedBox(
                  width: 31,
                  child: LinearProgressIndicator(
                    key: const ValueKey('retry-wait-progress'),
                    value: remaining,
                    minHeight: 4,
                    color: wrongColor,
                    backgroundColor: const Color(0xffebdacc),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                if (nextDrawingAt == null &&
                    answerLockDurationMs > repeatWrongLockMs)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '${((end - now) / 1000).ceil()}초',
                      style: const TextStyle(fontSize: 12, color: neutral),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    } else if (retryReady) {
      message = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.keyboard_arrow_down_rounded, size: 19, color: blue),
          const SizedBox(width: 3),
          title('다른 보기를 눌러 다시 답해요', size: 14, color: blue),
        ],
      );
    } else if (now < streakVisibleUntil && correctStreak >= 3) {
      message = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/paper-rabbit.webp',
            width: 22,
            excludeFromSemantics: true,
          ),
          const SizedBox(width: 5),
          title('$correctStreak연속 정답!', size: 16, color: blue),
        ],
      );
    } else if (now < quickCueUntil) {
      message = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome_rounded, color: blue, size: 17),
          const SizedBox(width: 4),
          title('빠른 정답!', size: 16, color: blue),
        ],
      );
    } else if (roundResults.isEmpty) {
      message = const Text(
        '그림을 보고 답을 골라요',
        style: TextStyle(fontSize: 13, color: neutral),
      );
    }
    return Semantics(
      liveRegion: true,
      child: FittedBox(fit: BoxFit.scaleDown, child: message),
    );
  }

  Widget skipButton({required bool deemphasize}) {
    final enabled = canSkip;
    final emphasized = enabled && !deemphasize;
    final foreground = emphasized ? blue : const Color(0xff695947);
    return Semantics(
      hint: enabled
          ? '남은 시간에서 ${secondsLabel(activeRoundRules.skipCostMs)}를 차감합니다'
          : '그림이 완성되고 2초 뒤에 사용할 수 있습니다',
      child: TextButton(
        key: const ValueKey('skip-question'),
        onPressed: enabled ? skip : null,
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          disabledForegroundColor: foreground,
          backgroundColor: emphasized
              ? const Color(0xfff4f5ff)
              : const Color(0xfffffaf0),
          disabledBackgroundColor: const Color(0xfff5edde),
          side: BorderSide(
            color: emphasized
                ? const Color(0xff8294ce)
                : const Color(0xffb9a587),
          ),
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.padded,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled ? Icons.skip_next_rounded : Icons.lock_outline_rounded,
                size: 17,
              ),
              const SizedBox(width: 5),
              const Text('건너뛰기'),
              const SizedBox(width: 9),
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: enabled
                      ? const Color(0xfff6e4df)
                      : const Color(0xffeae0ce),
                  shape: const StadiumBorder(),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  child: Text(
                    '−${secondsLabel(activeRoundRules.skipCostMs)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: enabled ? const Color(0xff894539) : foreground,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget choice(
    String option, {
    required bool locked,
    required bool retryReady,
    bool wrapLabel = false,
  }) {
    final wrong = disabled.contains(option);
    final canRetry = retryReady && !wrong;
    final button = OutlinedButton(
      onPressed: wrong || locked ? null : () => answer(option),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 58),
        textStyle: answerLabelStyle,
        foregroundColor: ink,
        backgroundColor: canRetry
            ? const Color(0xfff3f5ff)
            : const Color(0xeafffbef),
        overlayColor: blue.withValues(alpha: 0.14),
        disabledForegroundColor: wrong
            ? const Color(0xffa33830)
            : const Color(0xff62564c),
        disabledBackgroundColor: wrong
            ? const Color(0xffffe1dc)
            : const Color(0xbffffbef),
        side: BorderSide(
          color: wrong
              ? const Color(0xffa33830)
              : canRetry
              ? blue
              : ink,
          width: canRetry ? 1.6 : 1,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: wrong
                ? const Icon(
                    Icons.close_rounded,
                    key: ValueKey('wrong-choice-mark'),
                    size: 15,
                    semanticLabel: '오답',
                  )
                : null,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final style = DefaultTextStyle.of(context).style;
                final text = Text(
                  option,
                  style: style,
                  textAlign: TextAlign.center,
                  maxLines: wrapLabel ? 2 : 1,
                  softWrap: wrapLabel,
                );
                var labelWidth = constraints.maxWidth;
                if (wrapLabel && labelWidth > 0) {
                  final painter = TextPainter(
                    text: TextSpan(text: option, style: style),
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                    maxLines: 2,
                  )..layout(maxWidth: labelWidth);
                  if (painter.didExceedMaxLines) {
                    var low = labelWidth;
                    var high = painter.maxIntrinsicWidth.ceilToDouble();
                    while (high - low > 1) {
                      final width = (high + low) / 2;
                      painter.layout(maxWidth: width);
                      if (painter.didExceedMaxLines) {
                        low = width;
                      } else {
                        high = width;
                      }
                    }
                    labelWidth = high;
                  }
                  painter.dispose();
                }
                return FittedBox(
                  fit: BoxFit.scaleDown,
                  child: wrapLabel
                      ? ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: labelWidth),
                          child: text,
                        )
                      : text,
                );
              },
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
    if (!wrong || MediaQuery.disableAnimationsOf(context)) return button;
    return TweenAnimationBuilder<double>(
      key: ValueKey(option),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      child: button,
      builder: (context, progress, child) => Transform.translate(
        offset: Offset(sin(progress * 6 * pi) * (1 - progress) * 8, 0),
        child: child,
      ),
    );
  }

  void reviewQuestion(String answer, List<List<Offset>> strokes) {
    final question = pack.firstWhere((question) => question.label == answer);
    final choices = quizDistractors(
      answer: question.id,
      candidates: labelsById.keys.toSet(),
      ranked: relatedById[question.id]!,
      level: 2,
      random: random,
    );
    final reviewOptions = [
      answer,
      for (final id in [...choices.similar, ...choices.distinct])
        labelsById[id]!,
    ]..shuffle(random);
    final attempts = <String>{};
    var solved = false;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final replay = AspectRatio(
      aspectRatio: 1,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: reducedMotion ? Duration.zero : const Duration(seconds: 4),
        builder: (context, progress, _) =>
            sketch(strokes, progress, !reducedMotion),
      ),
    );
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('다시 맞히기'),
          scrollable: true,
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 6,
              children: [
                const Text(
                  '시간 제한 없이 다시 풀 수 있어요. 최고 기록에는 반영되지 않아요.',
                  textAlign: TextAlign.center,
                ),
                replay,
                for (final option in reviewOptions)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      textStyle: answerLabelStyle,
                    ),
                    onPressed: solved || attempts.contains(option)
                        ? null
                        : () => update(() {
                            if (option == answer) {
                              solved = true;
                              audio.play(GameSound.correct);
                            } else {
                              attempts.add(option);
                              audio.play(GameSound.wrong);
                            }
                          }),
                    child: Text(
                      attempts.contains(option) ? '✕ $option' : option,
                    ),
                  ),
                if (solved || attempts.isNotEmpty)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      solved ? '정답이에요!' : '다른 보기를 골라 보세요',
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기'),
            ),
          ],
        ),
      ),
    );
  }

  Widget resultSummary({bool compact = false}) => Column(
    children: [
      title(
        roundDailyDay == null ? '시간 종료' : '오늘의 낙서 결과',
        size: compact ? 28 : 34,
        handwritten: true,
      ),
      const SizedBox(
        width: 122,
        height: 13,
        child: CustomPaint(painter: BrushUnderline(blue)),
      ),
      const SizedBox(height: 8),
      CustomPaint(
        painter: ScoreBrush(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: title(
              '$score개 정답',
              size: compact ? 42 : 49,
              color: blue,
              singleLine: true,
            ),
          ),
        ),
      ),
      title(
        roundDailyDay == null
            ? '최고 기록 $best개'
            : '오늘 최고 ${dailyRecord?.score ?? score}개',
        size: 17,
      ),
      Text(
        replayGoal(score, roundPreviousBest),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14),
      ),
    ],
  );

  Widget missedDrawings(
    double availableWidth, {
    double? compactCardSize,
  }) => Padding(
    padding: EdgeInsets.symmetric(vertical: compactCardSize == null ? 20 : 0),
    child: Column(
      children: [
        title('놓친 그림', size: 20),
        const Text('그림을 눌러 다시 맞혀 보세요', style: TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        Center(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                for (final (label, strokes) in missed)
                  SizedBox(
                    width: min(
                      availableWidth,
                      compactCardSize ?? (missed.length == 1 ? 216 : 152),
                    ),
                    child: Semantics(
                      button: true,
                      label: '$label 다시 맞히기',
                      onTap: () => reviewQuestion(label, strokes),
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: () => reviewQuestion(label, strokes),
                        borderRadius: BorderRadius.circular(20),
                        child: Column(
                          children: [
                            AspectRatio(
                              aspectRatio: 1,
                              child: sketch(strokes, 1, false),
                            ),
                            const SizedBox(height: 6),
                            if (compactCardSize == null)
                              title(label, size: 15)
                            else
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: title(label, size: 15, singleLine: true),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget results() => LayoutBuilder(
    builder: (context, constraints) {
      final gutter = screenGutter(constraints.maxWidth);
      final height = (MediaQuery.textScalerOf(context).scale(27) + 16).clamp(
        55.0,
        90.0,
      );
      final compact =
          missed.isNotEmpty &&
          constraints.maxWidth >= 460 &&
          constraints.maxHeight <= 440;
      return Column(
        children: [
          Expanded(
            child: compact
                ? LayoutBuilder(
                    builder: (context, area) {
                      final width = max(
                        0.0,
                        (area.maxWidth - 2 * gutter - 16) / 2,
                      );
                      final textScaler = MediaQuery.textScalerOf(context);
                      final direction = Directionality.of(context);
                      final style = DefaultTextStyle.of(context).style;
                      double lineHeight(double size) {
                        final painter = TextPainter(
                          text: TextSpan(
                            text: '한',
                            style: style.copyWith(fontSize: size),
                          ),
                          textDirection: direction,
                          textScaler: textScaler,
                        )..layout();
                        final height = painter.height;
                        painter.dispose();
                        return height;
                      }

                      // Keep both captions and the card label above the footer.
                      final overhead =
                          lineHeight(20) + lineHeight(13) + lineHeight(15) + 40;
                      final card = (area.maxHeight - overhead).clamp(
                        72.0,
                        156.0,
                      );
                      return spacedPage(
                        [
                          Row(
                            key: const ValueKey('wide-result-layout'),
                            children: [
                              Expanded(child: resultSummary(compact: true)),
                              const SizedBox(width: 16),
                              Expanded(
                                child: missedDrawings(
                                  width,
                                  compactCardSize: card,
                                ),
                              ),
                            ],
                          ),
                        ],
                        distribution: MainAxisAlignment.center,
                        verticalGutter: 8,
                      );
                    },
                  )
                : spacedPage(
                    [
                      resultSummary(),
                      if (missed.isNotEmpty)
                        missedDrawings(
                          max(0, constraints.maxWidth - 2 * gutter),
                        ),
                    ],
                    distribution: MainAxisAlignment.spaceEvenly,
                    verticalGutter: 12,
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  key: const ValueKey('result-actions'),
                  height: height,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: primary(
                          roundDailyDay == null ? '한 판 더' : '오늘 다시 도전',
                          () =>
                              start(daily: roundDailyDay != null, replay: true),
                          fontSize: 27,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: secondary(
                          '홈으로',
                          () => setState(() => phase = Phase.home),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const AdBanner(),
              ],
            ),
          ),
        ],
      );
    },
  );

  static Widget liftSketchPage(Widget page, Animation<double> animation) =>
      AnimatedBuilder(
        animation: animation,
        child: page,
        builder: (context, child) => FractionalTranslation(
          translation: Offset(
            0,
            animation.status == AnimationStatus.reverse || animation.isDismissed
                ? -Curves.easeInOutCubic.transform(1 - animation.value)
                : 0,
          ),
          child: child,
        ),
      );

  Widget boundSketchbook(Widget page) => Padding(
    padding: const EdgeInsets.only(top: 5, bottom: 5),
    child: CustomPaint(
      foregroundPainter: const SketchbookBinding(),
      child: page,
    ),
  );

  Widget sketch(List<List<Offset>> strokes, double progress, bool pencil) =>
      boundSketchbook(sketchPage(strokes, progress, pencil));

  Widget sketchPage(List<List<Offset>> strokes, double progress, bool pencil) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xfffffbef),
          image: const DecorationImage(
            image: paperTexture,
            fit: BoxFit.cover,
            opacity: 0.42,
          ),
          border: Border.all(color: ink, width: 1.7),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(color: Color(0xffd9c49c), offset: Offset(0, 4)),
            BoxShadow(color: Color(0xff6b5437), offset: Offset(0, 6)),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: CustomPaint(painter: StrokePainter(strokes, progress, pencil)),
        ),
      );
}

class BrushUnderline extends CustomPainter {
  const BrushUnderline(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.04, size.height * 0.80)
      ..quadraticBezierTo(
        size.width * .48,
        -size.height * .42,
        size.width * .96,
        size.height * .70,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.8
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(BrushUnderline oldDelegate) => oldDelegate.color != color;
}

class ScoreBrush extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(9, size.height * .14)
      ..lineTo(size.width * .83, size.height * .08)
      ..quadraticBezierTo(
        size.width * 1.05,
        size.height * .12,
        size.width - 3,
        size.height * .44,
      )
      ..lineTo(size.width - 9, size.height * .87)
      ..lineTo(size.width * .17, size.height * .95)
      ..quadraticBezierTo(-7, size.height * .90, 4, size.height * .48)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xfff7c9bd));
  }

  @override
  bool shouldRepaint(ScoreBrush oldDelegate) => false;
}

class _PageClip extends CustomClipper<Rect> {
  const _PageClip();

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width, size.height + 6);

  @override
  bool shouldReclip(_PageClip oldClipper) => false;
}

class SketchbookBinding extends CustomPainter {
  const SketchbookBinding();

  @override
  void paint(Canvas canvas, Size size) {
    final ring = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round;
    final hole = Paint()..color = ink;
    final count = (size.width / 46).floor().clamp(2, 8);
    for (var i = 0; i < count; i++) {
      final x = size.width * (i + 1) / (count + 1);
      canvas.drawCircle(Offset(x + 4, 8), 2.0, hole);
      canvas.drawPath(
        Path()
          ..moveTo(x - 5, 2)
          ..cubicTo(x - 5, -12, x + 7, -12, x + 4, 8),
        ring,
      );
    }
  }

  @override
  bool shouldRepaint(SketchbookBinding oldDelegate) => false;
}

class DownloadRabbit extends StatefulWidget {
  const DownloadRabbit({
    super.key,
    required this.packing,
    required this.packed,
    required this.size,
  });

  final bool packing;
  final bool packed;
  final double size;

  @override
  State<DownloadRabbit> createState() => _DownloadRabbitState();
}

class _DownloadRabbitState extends State<DownloadRabbit>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  void updateAnimation() {
    final animate =
        widget.packing &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate && !controller.isAnimating) {
      controller.repeat();
    } else if (!animate && controller.isAnimating) {
      controller.reset();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateAnimation();
  }

  @override
  void didUpdateWidget(DownloadRabbit oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateAnimation();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: AnimatedBuilder(
      animation: controller,
      child: Image.asset(
        '토끼의 낙서장 다운로드 아이들링.png',
        fit: BoxFit.fill,
        excludeFromSemantics: true,
      ),
      builder: (context, child) {
        final elapsed = controller.lastElapsedDuration?.inMilliseconds ?? 0;
        final frame = !controller.isAnimating
            ? (widget.packed || widget.packing ? 2 : 0)
            : elapsed < 250
            ? 0
            : elapsed < 500
            ? 1
            : controller.value > 0.94
            ? 3
            : 2;
        return Stack(
          children: [
            Positioned(
              left: -(frame % 2) * widget.size,
              top: -(frame ~/ 2) * widget.size,
              width: widget.size * 2,
              height: widget.size * 2,
              child: child!,
            ),
          ],
        );
      },
    ),
  );
}

class RabbitIdle extends StatefulWidget {
  const RabbitIdle({super.key, required this.child});

  final Widget child;

  @override
  State<RabbitIdle> createState() => _RabbitIdleState();
}

class _RabbitIdleState extends State<RabbitIdle>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      controller.reset();
    } else if (!controller.isAnimating) {
      controller.repeat();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: RepaintBoundary(child: widget.child),
    builder: (context, child) {
      final phase = controller.value * 2 * pi;
      final breath = (1 - cos(phase)) / 2;
      return Transform.translate(
        offset: Offset(0, -5 * breath),
        child: Transform.rotate(
          angle: sin(phase) * 0.014,
          child: Transform.scale(
            scale: 1 + breath * 0.018,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        ),
      );
    },
  );
}

class StrokePainter extends CustomPainter {
  StrokePainter(this.strokes, this.progress, this.pencil);
  final List<List<Offset>> strokes;
  final double progress;
  final bool pencil;

  @override
  void paint(Canvas canvas, Size size) {
    final strokePaint = Paint()
      ..color = ink
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    Offset point(Offset value) =>
        Offset(value.dx * size.width, value.dy * size.height);
    double timing(List<Offset> stroke) =>
        0.14 +
        (stroke.length < 2
            ? 0.02
            : List.generate(
                stroke.length - 1,
                (i) => (stroke[i + 1] - stroke[i]).distance,
              ).fold(0.0, (sum, distance) => sum + distance));
    var budget =
        strokes.fold(0.0, (sum, stroke) => sum + timing(stroke)) * progress;
    Offset? tip;
    for (final stroke in strokes) {
      if (budget <= 0) break;
      tip = point(stroke.first);
      canvas.drawCircle(tip, 1.3, strokePaint);
      for (var i = 1; i < stroke.length && budget > 0; i++) {
        final length = (stroke[i] - stroke[i - 1]).distance;
        if (length == 0) continue;
        final end = point(stroke[i]);
        final next = Offset.lerp(tip!, end, min(1.0, budget / length))!;
        canvas.drawLine(tip, next, strokePaint);
        tip = next;
        budget -= length;
      }
      budget -= 0.14 + (stroke.length < 2 ? 0.02 : 0);
    }
    if (pencil && progress < 1 && tip != null) {
      canvas.drawLine(
        tip + const Offset(3, -3),
        tip + const Offset(17, -22),
        Paint()
          ..color = const Color(0xffefaa2b)
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(StrokePainter oldDelegate) =>
      oldDelegate.strokes != strokes ||
      oldDelegate.progress != progress ||
      oldDelegate.pencil != pencil;
}

bool get adsSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<InitializationStatus>? _adInitialization;

Future<InitializationStatus> initializeAds() =>
    _adInitialization ??= MobileAds.instance.initialize();

class AdBanner extends StatefulWidget {
  const AdBanner({super.key});
  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? banner;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    if (adsSupported) unawaited(load());
  }

  Future<void> load() async {
    try {
      await initializeAds();
      if (!mounted) return;
      const android = 'ca-app-pub-3940256099942544/6300978111';
      const ios = 'ca-app-pub-3940256099942544/2934735716';
      banner = BannerAd(
        size: AdSize.banner,
        adUnitId: defaultTargetPlatform == TargetPlatform.android
            ? android
            : ios,
        request: const AdRequest(nonPersonalizedAds: true),
        listener: BannerAdListener(
          onAdLoaded: (_) {
            if (mounted) setState(() => loaded = true);
          },
          onAdFailedToLoad: (ad, _) {
            if (banner == ad) banner = null;
            unawaited(ad.dispose());
          },
        ),
      );
      await banner!.load();
    } on Exception catch (_) {
      // Ads can fail without preventing offline play.
    }
  }

  @override
  void dispose() {
    final ad = banner;
    if (ad != null) unawaited(ad.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = banner;
    if (!adsSupported) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const size = AdSize.banner;
        if (constraints.maxWidth < size.width) {
          return const SizedBox.shrink();
        }
        return Center(
          child: SizedBox(
            width: size.width.toDouble(),
            height: size.height.toDouble(),
            child: loaded && ad != null ? AdWidget(ad: ad) : null,
          ),
        );
      },
    );
  }
}
