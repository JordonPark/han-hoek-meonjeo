import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game_audio.dart';
import 'quiz_balance.dart';
import 'sketchflow.dart';

const blue = Color(0xff2544c4);
const paper = Color(0xfffff6e3);
const ink = Color(0xff31271c);
const paperTexture = AssetImage('assets/wrinkled-paper.webp');
const roundStartMs = 60000;
const correctBonusMs = 1000;
const maxRoundBonusMs = 15000;
const skipPenaltyMs = 3000;
const skipWaitMs = 2000;
const firstWrongLockMs = 800;
const repeatWrongLockMs = 1500;
const lastWrongTransitionMs = 350;
final quizPlaytestSeed = int.tryParse(
  const String.fromEnvironment('QUIZ_PLAYTEST_SEED'),
);
const quizPlaytestLevel = int.fromEnvironment(
  'QUIZ_PLAYTEST_LEVEL',
  defaultValue: 3,
);
String get balanceHistoryKey =>
    quizPlaytestSeed == null ? 'recent_quiz_balance' : 'quiz_playtest_history';
String get balanceSummaryKey =>
    quizPlaytestSeed == null ? 'last_balance_summary' : 'quiz_playtest_summary';

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
  List<Prompt> pack = [];
  Map<String, String> labelsById = {};
  Map<String, List<String>> relatedById = {};
  Map<String, List<String>> outlinesById = {};
  Map<String, int> openingDrawingById = {};
  final roundResults = <QuizResult>[];
  QuizBalanceHistory balanceHistory = QuizBalanceHistory(const []);
  String? lastBalanceSummary;
  int missedStreak = 0;
  bool assistance = false;
  bool questionLogged = false;
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
  int level = 1;
  int questionAt = 0;
  int deadlineMs = roundStartMs;
  int bonusGrantedMs = 0;
  int correctStreak = 0;
  int streakVisibleUntil = 0;
  bool finalTenCuePlayed = false;
  int timeFeedbackUntil = 0;
  String? timeFeedback;
  int lockedUntil = 0;
  int? advanceAfterWrongAt;
  int countdown = 3;
  bool loading = true;
  bool audioSettingsChanged = false;
  SketchFlow? sketchFlow;
  bool sketchFlowSetupSeen = false;
  bool openingSketchFlow = false;
  SketchFlowTransfer? modelTransfer;
  bool preparingDrawing = false;
  bool aiRound = false;
  bool aiDrawing = false;
  String? modelStatus;
  int? modelPercent;
  final generated = <String, List<List<Offset>>>{};
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
      if (mounted && !transfer.paused) {
        setState(
          () => modelStatus = 'AI 그림을 준비하지 못했어요. 다시 시도하거나 기본 그림으로 시작하세요.',
        );
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

  Future<void> prepareDrawing(Prompt selected) async {
    if (generated.containsKey(selected.id)) return;
    final generation = round;
    final job = sketchFlow?.prepare(selected.id);
    if (job == null) return;
    try {
      final result = await job;
      if (mounted &&
          round == generation &&
          deck.contains(selected) &&
          result.isNotEmpty) {
        generated[selected.id] = result;
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
      final openingDrawings = <String, int>{};
      for (final question in loaded) {
        final row = outlines[question.id] as Map;
        final similar = (row['similar'] as List).cast<String>();
        final opening = row['opening'] as int;
        if (similar.toSet().length != 24 ||
            similar.contains(question.id) ||
            !similar.every(labels.containsKey) ||
            opening < 0 ||
            opening >= question.drawings.length) {
          throw const FormatException('Invalid quiz outlines');
        }
        visualRanks[question.id] = similar;
        openingDrawings[question.id] = opening;
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
          labelsById = labels;
          relatedById = ranked;
          outlinesById = visualRanks;
          openingDrawingById = openingDrawings;
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

  Future<void> start() async {
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
      final seed = quizPlaytestSeed;
      if (seed != null) random = Random(seed);
      deck = List<Prompt>.of(pack)..shuffle(random);
      clock.reset();
      deadlineMs = roundStartMs;
      bonusGrantedMs = 0;
      correctStreak = 0;
      streakVisibleUntil = 0;
      finalTenCuePlayed = false;
      timeFeedbackUntil = 0;
      timeFeedback = null;
      round++;
      generated.clear();
      aiRound = sketchFlow != null;
      preparingDrawing = aiRound;
      if (!preparingDrawing) nextQuestion();
    });
    if (finishingSetup) unawaited(saveSketchFlowSetup());
    if (preparingDrawing) {
      await prepareDrawing(upcomingPrompt(1, opening: true))
          .timeout(const Duration(seconds: 6), onTimeout: () {});
      if (!mounted || phase != Phase.preparing) return;
      setState(() {
        preparingDrawing = false;
        nextQuestion();
      });
    }
    while (countdown > 0) {
      audio.play(GameSound.countdown);
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted || phase != Phase.preparing) return;
      setState(() => countdown--);
    }
    audio.play(GameSound.start);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || phase != Phase.preparing) return;
    setState(() {
      phase = Phase.playing;
      clock.start();
    });
    audio.setRoundPlaying(true);
    refresh?.cancel();
    refresh = Timer.periodic(const Duration(milliseconds: 33), (_) => tick());
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

  Prompt upcomingPrompt(int nextLevel, {bool opening = false}) {
    if (quizPlaytestSeed != null) return deck.last;
    if (opening) {
      for (final candidate in deck.reversed) {
        if (openingQuestions.contains(candidate.id)) return candidate;
      }
    }
    if (nextLevel <= 2) {
      for (final candidate in deck.reversed) {
        if (familiarQuestions.contains(candidate.id)) return candidate;
      }
    }
    return deck.last;
  }

  void prefetchDrawing() {
    if (aiRound && deck.isNotEmpty) {
      unawaited(prepareDrawing(upcomingPrompt(quizLevel(score + 1))));
    }
  }

  void nextQuestion([QuizOutcome? outcome]) {
    if (outcome != null) {
      recordQuestion(outcome);
      missedStreak = outcome == QuizOutcome.correct ? 0 : missedStreak + 1;
    }
    if (deck.isEmpty) {
      finish();
      return;
    }
    final baseLevel = quizLevel(score);
    assistance = quizPlaytestSeed == null && missedStreak >= 2 && baseLevel > 1;
    if (missedStreak >= 2) missedStreak = 0;
    level = quizPlaytestSeed == null
        ? quizLevel(score, assistance: assistance)
        : quizPlaytestLevel.clamp(1, 5);
    final selected = upcomingPrompt(level, opening: outcome == null);
    deck.remove(selected);
    prompt = selected;
    questionLogged = false;
    firstTapMs = null;
    firstTapProgress = null;
    final variants = List<List<List<Offset>>>.of(selected.drawings)
      ..sort((a, b) => a.length.compareTo(b.length));
    final pool = level <= 2
        ? variants.take((variants.length + 1) ~/ 2).toList()
        : level >= 4
        ? variants.skip(variants.length ~/ 2).toList()
        : variants;
    final candidate = generated.remove(selected.id);
    final fresh = balanceHistory.prefersStored(selected.id, level)
        ? null
        : candidate;
    aiDrawing = fresh != null;
    drawing =
        fresh ??
        (outcome == null
            ? selected.drawings[openingDrawingById[selected.id]!]
            : pool[random.nextInt(pool.length)]);
    prefetchDrawing();
    final distractors = quizDistractors(
      answer: selected.id,
      candidates: labelsById.keys.toSet(),
      ranked: relatedById[selected.id]!,
      outlineRanked: outlinesById[selected.id]!,
      level: level,
      random: random,
    );
    options = [
      selected.label,
      for (final id in [...distractors.similar, ...distractors.distinct])
        labelsById[id]!,
    ]..shuffle(random);
    disabled.clear();
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
        assisted: assistance,
        outcome: outcome,
        wrongTaps: disabled.length,
        firstTapMs: firstTapMs,
        firstTapProgress: firstTapProgress,
        durationMs: elapsed - questionAt,
      ),
    );
  }

  Future<void> saveRoundBalance(String summary) async {
    final current = jsonEncode({
      'durationMs': elapsed,
      'score': score,
      if (quizPlaytestSeed != null) 'playtestSeed': quizPlaytestSeed,
      'questions': roundResults.map((result) => result.toJson()).toList(),
    });
    try {
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
        audio.play(GameSound.correct);
        score++;
        correctStreak++;
        if (correctStreak % 3 == 0) {
          streakVisibleUntil = elapsed + 1400;
          unawaited(HapticFeedback.lightImpact());
        }
        if (bonusGrantedMs < maxRoundBonusMs) {
          bonusGrantedMs += correctBonusMs;
          deadlineMs += correctBonusMs;
          timeFeedback = '+1초';
          timeFeedbackUntil = elapsed + 1150;
        } else if (timeFeedback == '+1초') {
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
        lockedUntil =
            now + (disabled.length == 1 ? firstWrongLockMs : repeatWrongLockMs);
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
    noteFirstTap();
    deadlineMs -= skipPenaltyMs;
    if (remainingMs == 0) {
      recordQuestion(QuizOutcome.skipped);
      finish();
      return;
    }
    setState(() {
      timeFeedback = '−3초';
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
    unawaited(saveRoundBalance(summary));
    audio.setRoundPlaying(false);
    audio.play(GameSound.finish);
    setState(() {
      phase = Phase.results;
      lastBalanceSummary = summary;
      if (quizPlaytestSeed == null && score > best) {
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
              'AI가 제시어에 맞춰 새 그림을 그려요.\n한 번 받으면 인터넷 없이 플레이할 수 있어요.',
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
            if (progress != null && !complete)
              title(
                progress == 100 && openingSketchFlow ? '모델 확인 중' : '$progress%',
                size: 24,
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
          else if (openingSketchFlow)
            if (transferring)
              secondary(
                '일시정지',
                modelTransfer!.paused || progress == 100
                    ? null
                    : () => setState(() => modelTransfer!.pause()),
              )
            else
              const SizedBox(height: 48)
          else ...[
            Text('약 ${SketchFlow.downloadMegabytes} MB'),
            const SizedBox(height: 8),
            primary(
              modelStatus != null
                  ? '다시 시도'
                  : progress != null
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
        const Text('정답 +1초 · 건너뛰기 −3초', textAlign: TextAlign.center),
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

  void showBalanceDetails() {
    final history = balanceHistory;
    final candidates = history.reviewCandidates();
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
            for (var level = 1; level <= 5; level++)
              if (history.hasLevel(level))
                Text(
                  '$level단계\nAI 그림 · ${history.describe(level, generated: true)}\n\n'
                  '저장된 그림 · ${history.describe(level, generated: false)}'
                  '${history.assistedSummary(level) == null ? '' : '\n${history.assistedSummary(level)}'}',
                ),
            if (candidates.isNotEmpty)
              const Text(
                '검수 후보',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            for (final candidate in candidates)
              Text(
                '${labelsById[candidate.id] ?? candidate.id} · ${candidate.level}단계 · '
                '${candidate.generated ? 'AI' : '저장된 그림'} 정답 ${candidate.correct}/${candidate.total}',
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
          key: ValueKey(preparingDrawing ? -1 : countdown),
          child: title(
            preparingDrawing
                ? '첫 그림 그리는 중'
                : countdown == 0
                ? '게임 시작!'
                : '$countdown',
            size: preparingDrawing ? 28 : 46,
            color: blue,
          ),
        ),
      ),
    ),
    if (preparingDrawing)
      const Text('준비가 오래 걸리면 기본 그림으로 시작해요.', textAlign: TextAlign.center),
  ]);

  Widget game() => LayoutBuilder(
    builder: (context, constraints) {
      final gutter = constraints.maxWidth < 320 ? 4.0 : 12.0;
      final contentWidth = max(0.0, constraints.maxWidth - 2 * gutter);
      final sideBySide = contentWidth >= 420;
      final largeText = MediaQuery.textScalerOf(context).scale(20) >= 32;
      final singleColumn = sideBySide || (largeText && contentWidth < 360);
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
                    aiRound
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
                              color: feedback == '+1초'
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
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: row == 0 ? 10 : 4),
            ],
          SizedBox(
            height: largeText ? 42 : 28,
            child: answerFeedback(
              answerTime,
              locked: answersLocked,
              retryReady: retryReady,
            ),
          ),
          skipButton(),
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
          : disabled.length == 1
          ? firstWrongLockMs
          : repeatWrongLockMs;
      final remaining = ((end - now) / duration).clamp(0.0, 1.0);
      message = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          title('틀렸어요', size: 14, color: wrongColor),
          const SizedBox(width: 6),
          Text(
            nextDrawingAt == null ? '곧 다시 고를 수 있어요' : '다음 그림 준비 중',
            style: const TextStyle(fontSize: 13, color: neutral),
          ),
          const SizedBox(width: 7),
          ExcludeSemantics(
            child: SizedBox(
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
          ),
        ],
      );
    } else if (retryReady) {
      message = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.keyboard_arrow_up_rounded, size: 19, color: blue),
          const SizedBox(width: 3),
          title('이제 다른 보기를 눌러 보세요', size: 14, color: blue),
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
    } else if (roundResults.isEmpty && !canSkip) {
      message = const Text(
        '그림 완성 2초 뒤에 건너뛸 수 있어요',
        style: TextStyle(fontSize: 13, color: neutral),
      );
    }
    return Semantics(
      liveRegion: true,
      child: FittedBox(fit: BoxFit.scaleDown, child: message),
    );
  }

  Widget skipButton() {
    final enabled = canSkip;
    final foreground = enabled ? blue : const Color(0xff695947);
    return Semantics(
      hint: enabled ? '남은 시간에서 3초를 차감합니다' : '그림이 완성되고 2초 뒤에 사용할 수 있습니다',
      child: TextButton(
        key: const ValueKey('skip-question'),
        onPressed: enabled ? skip : null,
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          disabledForegroundColor: foreground,
          backgroundColor: const Color(0xfff4f5ff),
          disabledBackgroundColor: const Color(0xfff5edde),
          side: BorderSide(
            color: enabled ? const Color(0xff8294ce) : const Color(0xffc5b295),
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
                    '−3초',
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
  }) {
    final wrong = disabled.contains(option);
    final canRetry = retryReady && !wrong;
    final button = OutlinedButton(
      onPressed: wrong || locked ? null : () => answer(option),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 58),
        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
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
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          wrong ? '✕ $option' : option,
          textAlign: TextAlign.center,
          maxLines: 1,
          softWrap: false,
        ),
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

  Widget results() => spacedPage([
    Column(
      children: [
        title('시간 종료', size: 34, handwritten: true),
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
            child: title('$score개 정답', size: 49, color: blue),
          ),
        ),
        title('최고 기록 $best개', size: 17),
      ],
    ),
    if (missed.isNotEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
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
                        width: missed.length == 1 ? 216 : 152,
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
                              title(label, size: 15),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    Column(
      children: [
        Row(
          children: [
            Expanded(child: primary('한 판 더', start, fontSize: 27)),
            const SizedBox(width: 10),
            Expanded(
              child: secondary('홈으로', () => setState(() => phase = Phase.home)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const AdBanner(),
      ],
    ),
  ]);

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
