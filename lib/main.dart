import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game_audio.dart';
import 'sketchflow.dart';

const blue = Color(0xff2544c4);
const paper = Color(0xfffff6e3);
const ink = Color(0xff31271c);
const paperTexture = AssetImage('assets/wrinkled-paper.webp');

double strokeProgressAt({
  required int elapsedMs,
  required int questionStartedMs,
  required int level,
}) {
  final end = elapsedMs.clamp(0, 60000);
  final start = questionStartedMs.clamp(0, end);
  // Integrate a linear increase from 1× to 2× over the round.
  final drawingTime = (end - start) * (1 + (start + end) / 120000);
  return (drawingTime / (1700 + level * 1050)).clamp(0.0, 1.0);
}

bool canSkipAt({
  required int elapsedMs,
  required int questionStartedMs,
  required int level,
}) =>
    strokeProgressAt(
      elapsedMs: elapsedMs - 3000,
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

const related = <String, List<String>>{
  '우산': ['버섯', '지팡이', '낙하산'],
  '문어': ['해파리', '거미', '오징어'],
  '자전거': ['오토바이', '유모차', '킥보드'],
  '고양이': ['토끼', '개', '여우'],
  '소방차': ['구급차', '버스', '트럭'],
  '칫솔': ['빗자루', '붓', '포크'],
};

enum Phase { download, home, preparing, playing, results }

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  final random = Random();
  final clock = Stopwatch();
  final audio = GameAudio();

  final missed = <(String, List<List<Offset>>)>[];
  final disabled = <String>{};
  List<Prompt> pack = [];
  List<Prompt> deck = [];
  List<String> options = [];
  List<List<Offset>> drawing = [];
  Prompt? prompt;
  Phase phase = SketchFlow.available ? Phase.download : Phase.home;
  Timer? refresh;
  String? error;
  int score = 0;
  int best = 0;
  int level = 1;
  int questionAt = 0;
  int lockedUntil = 0;
  int? advanceAfterWrongAt;
  int countdown = 3;
  bool loading = true;
  bool audioSettingsChanged = false;
  SketchFlow? sketchFlow;
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
  int get seconds => ((60000 - elapsed).clamp(0, 60000) / 1000).ceil();
  bool get playing => phase == Phase.playing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(loadPack());
    unawaited(loadPreferences());
    if (SketchFlow.available) unawaited(checkModel());
  }

  Future<void> checkModel() async {
    var openingCachedModel = false;
    try {
      if (!await SketchFlow.isDownloaded() ||
          !mounted ||
          phase != Phase.download ||
          openingSketchFlow) {
        return;
      }
      openingCachedModel = true;
      setState(() => openingSketchFlow = true);
      final model = await SketchFlow.open();
      if (!mounted) {
        await model.dispose();
        return;
      }
      setState(() {
        sketchFlow = model;
        phase = Phase.home;
      });
    } catch (_) {
      if (mounted) setState(() => modelStatus = '스케치북을 열지 못했어요. 다시 시도해 주세요.');
    } finally {
      if (mounted && openingCachedModel) {
        setState(() => openingSketchFlow = false);
      }
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
        setState(() => modelStatus = '다운로드에 문제가 생겼어요. 다시 시도해 주세요.');
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
        deck.last != selected) {
      unawaited(prepareDrawing(deck.last));
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
      if (mounted) {
        setState(() {
          pack = loaded;
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
      setState(() {
        best = max(best, preferences.getInt('best_score') ?? 0);
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
    if (SketchFlow.available && sketchFlow == null) {
      setState(() => phase = Phase.download);
      return;
    }
    setState(() {
      phase = Phase.preparing;
      countdown = 3;
      score = 0;
      level = 1;
      missed.clear();
      deck = List<Prompt>.of(pack)..shuffle(random);
      clock.reset();
      round++;
      generated.clear();
      aiRound = sketchFlow != null;
      preparingDrawing = aiRound;
      if (!preparingDrawing) nextQuestion(skipped: false);
    });
    if (preparingDrawing) {
      await prepareDrawing(deck.last)
          .timeout(const Duration(seconds: 45), onTimeout: () {});
      if (!mounted || phase != Phase.preparing) return;
      setState(() {
        preparingDrawing = false;
        nextQuestion(skipped: false);
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
    if (elapsed >= 60000) {
      finish();
    } else {
      setState(() {
        final advanceAt = advanceAfterWrongAt;
        if (advanceAt != null && elapsed >= advanceAt) {
          missed.add((prompt!.label, drawing));
          nextQuestion(skipped: true);
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

  void nextQuestion({required bool skipped}) {
    if (deck.isEmpty) {
      finish();
      return;
    }
    final oldLevel = level;
    if (oldLevel == 5) {
      level = 3 + random.nextInt(2);
    } else if (!skipped) {
      level = score < 2
          ? 1 + random.nextInt(2)
          : score < 5
          ? 2 + random.nextInt(2)
          : 3 + random.nextInt(3);
    }
    final selected = deck.removeLast();
    prompt = selected;
    final variants = List<List<List<Offset>>>.of(selected.drawings)
      ..sort((a, b) => a.length.compareTo(b.length));
    final pool = level <= 2
        ? variants.take((variants.length + 1) ~/ 2).toList()
        : level >= 4
        ? variants.skip(variants.length ~/ 2).toList()
        : variants;
    final fresh = generated.remove(selected.id);
    aiDrawing = fresh != null;
    drawing = fresh ?? pool[random.nextInt(pool.length)];
    if (aiRound && deck.isNotEmpty) {
      unawaited(prepareDrawing(deck.last));
    }
    final labels =
        pack
            .map((p) => p.label)
            .where(
              (name) =>
                  name != selected.label && !confusable(selected.label, name),
            )
            .toList()
          ..shuffle(random);
    final distractors = <String>{
      if (level >= 3) ...?related[selected.label],
      ...labels,
    }.take(3);
    options = [selected.label, ...distractors]..shuffle(random);
    disabled.clear();
    questionAt = elapsed;
    lockedUntil = 0;
    advanceAfterWrongAt = null;
  }

  bool confusable(String answer, String candidate) => const [
    {'컵', '커피잔', '머그컵', '와인잔'},
    {'시계', '자명종', '손목시계'},
    {'선풍기', '천장 선풍기'},
    {'케이크', '생일 케이크'},
  ].any((group) => group.contains(answer) && group.contains(candidate));

  void answer(String option) {
    if (!playing) return;
    if (elapsed >= 60000) {
      finish();
      return;
    }
    if (elapsed < lockedUntil || disabled.contains(option)) return;
    setState(() {
      if (option == prompt!.label) {
        audio.play(GameSound.correct);
        score++;
        nextQuestion(skipped: false);
      } else {
        unawaited(HapticFeedback.mediumImpact());
        audio.play(GameSound.wrong);
        disabled.add(option);
        lockedUntil = elapsed + 1500;
        if (disabled.length == 3) {
          advanceAfterWrongAt = elapsed + 350;
        }
      }
    });
  }

  void skip() {
    if (!playing) return;
    if (elapsed >= 60000) {
      finish();
      return;
    }
    if (!canSkip) return;
    setState(() {
      missed.add((prompt!.label, drawing));
      nextQuestion(skipped: true);
    });
  }

  void finish() {
    if (!playing) return;
    if (elapsed >= 60000 && prompt != null) {
      missed.add((prompt!.label, drawing));
    }
    refresh?.cancel();
    clock.stop();
    audio.setRoundPlaying(false);
    audio.play(GameSound.finish);
    setState(() {
      phase = Phase.results;
      if (score > best) {
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

  Widget spacedPage(
    List<Widget> sections, {
    MainAxisAlignment distribution = MainAxisAlignment.spaceBetween,
  }) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: screenGutter(constraints.maxWidth),
        vertical: 16,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: max(0, constraints.maxHeight - 32),
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
              '한 번 받으면 오프라인으로 플레이할 수 있어요',
              textAlign: TextAlign.center,
            ),
        ],
      ),
      Center(
        child: DownloadRabbit(
          packing: transferring,
          packed: complete || progress != null,
          size: (MediaQuery.sizeOf(context).height * 0.38)
              .clamp(160, 310)
              .toDouble(),
        ),
      ),
      Column(
        children: [
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
              title(progress == 100 ? '모델 확인 중' : '$progress%', size: 24),
            const SizedBox(height: 10),
          ],
          if (modelStatus != null)
            Text(modelStatus!, textAlign: TextAlign.center),
          if (complete)
            primary('시작', loading || error != null ? null : start)
          else if (openingSketchFlow)
            if (transferring)
              OutlinedButton(
                onPressed: modelTransfer!.paused || progress == 100
                    ? null
                    : () => setState(() => modelTransfer!.pause()),
                child: const Text('일시정지'),
              )
            else
              const SizedBox(height: 48)
          else ...[
            Text('약 ${SketchFlow.downloadMiB} MiB'),
            const SizedBox(height: 8),
            primary(
              modelStatus != null
                  ? '다시 시도'
                  : progress != null
                  ? '이어받기'
                  : '다운로드',
              enableModel,
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => setState(() => phase = Phase.home),
              child: const Text('나중에'),
            ),
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
      ],
    ),
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: RabbitIdle(
        child: Image.asset(
          'assets/paper-rabbit.webp',
          height: (MediaQuery.sizeOf(context).height * 0.37)
              .clamp(170, 330)
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
        const SizedBox(height: 12),
        title('최고 기록 $best개', size: 17),
      ],
    ),
    Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        children: [
          const AdBanner(),
          Wrap(
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
          ),
          TextButton(
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: '토끼의 낙서장',
              children: const [
                Text('그림 데이터: Google Quick, Draw! (CC BY 4.0)'),
                SelectableText(
                  'https://github.com/googlecreativelab/quickdraw-dataset',
                ),
                SelectableText('https://creativecommons.org/licenses/by/4.0/'),
              ],
            ),
            child: const Text('앱 정보'),
          ),
        ],
      ),
    ),
  ], distribution: MainAxisAlignment.spaceEvenly);

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
        duration: const Duration(milliseconds: 160),
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
  ]);

  Widget game() => LayoutBuilder(
    builder: (context, constraints) {
      final contentWidth = max(
        0.0,
        constraints.maxWidth - 2 * screenGutter(constraints.maxWidth),
      );
      final sideBySide = contentWidth >= 420;
      final canvasSize = sideBySide
          ? min(
              (contentWidth - 20) * 0.60,
              max(150.0, constraints.maxHeight - 140),
            )
          : min(contentWidth, max(130.0, constraints.maxHeight - 335));
      final progress = strokeProgressAt(
        elapsedMs: elapsed,
        questionStartedMs: questionAt,
        level: level,
      );
      final timer =
          '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
      final header = Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: title(
                timer,
                size: 35,
                color: seconds <= 10 ? Colors.red.shade800 : ink,
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (aiRound) Text(aiDrawing ? 'AI 그림' : '저장된 그림'),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: title('$score점', size: 27),
            ),
          ),
        ],
      );
      final canvas = Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox.square(
            dimension: canvasSize,
            child: sketch(drawing, progress, true),
          ),
        ),
      );
      final answers = Column(
        children: [
          if (sideBySide)
            for (final option in options)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SizedBox(width: double.infinity, child: choice(option)),
              )
          else
            for (var row = 0; row < 2; row++) ...[
              Row(
                children: [
                  for (var column = 0; column < 2; column++) ...[
                    if (column == 1) const SizedBox(width: 12),
                    Expanded(child: choice(options[row * 2 + column])),
                  ],
                ],
              ),
              const SizedBox(height: 10),
            ],
          Semantics(
            liveRegion: true,
            child: SizedBox(
              height: 26,
              child: elapsed < lockedUntil
                  ? title('틀렸어요', size: 18, color: const Color(0xffa33830))
                  : null,
            ),
          ),
          TextButton(
            onPressed: canSkip ? skip : null,
            child: const Text('건너뛰기', style: TextStyle(fontSize: 17)),
          ),
        ],
      );
      return spacedPage([
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
      ]);
    },
  );

  Widget choice(String option) {
    final wrong = disabled.contains(option);
    final button = OutlinedButton(
      onPressed: wrong || elapsed < lockedUntil ? null : () => answer(option),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 58),
        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        foregroundColor: ink,
        disabledForegroundColor: wrong
            ? const Color(0xffa33830)
            : const Color(0xff62564c),
        disabledBackgroundColor: wrong ? const Color(0xffffe1dc) : null,
        side: BorderSide(color: wrong ? const Color(0xffa33830) : ink),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      ),
      child: Text(wrong ? '✕ $option' : option, textAlign: TextAlign.center),
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
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: ink,
                  backgroundColor: const Color(0xccfff8ea),
                  minimumSize: const Size(0, 55),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(19),
                  ),
                  side: const BorderSide(color: ink, width: 1.5),
                  textStyle: const TextStyle(
                    fontFamily: 'Gaegu',
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: () => setState(() => phase = Phase.home),
                child: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('홈으로', maxLines: 1, softWrap: false),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const AdBanner(),
      ],
    ),
  ]);

  Widget sketch(List<List<Offset>> strokes, double progress, bool pencil) =>
      Padding(
        padding: const EdgeInsets.only(top: 5, bottom: 5),
        child: CustomPaint(
          foregroundPainter: const SketchbookBinding(),
          child: DecoratedBox(
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
              child: CustomPaint(
                painter: StrokePainter(strokes, progress, pencil),
              ),
            ),
          ),
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
    if (!loaded || ad == null) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < ad.size.width) {
          return const SizedBox.shrink();
        }
        return Center(
          child: SizedBox(
            width: ad.size.width.toDouble(),
            height: ad.size.height.toDouble(),
            child: AdWidget(ad: ad),
          ),
        );
      },
    );
  }
}
