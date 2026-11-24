import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

const blue = Color(0xff2544c4);
const paper = Color(0xfffff6e3);
const ink = Color(0xff31271c);

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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
    : label = json['label'] as String,
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

enum Phase { home, preparing, playing, results }

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  final random = Random();
  final clock = Stopwatch();

  final missed = <(String, List<List<Offset>>)>[];
  final disabled = <String>{};
  List<Prompt> pack = [];
  List<Prompt> deck = [];
  List<String> options = [];
  List<List<Offset>> drawing = [];
  Prompt? prompt;
  Phase phase = Phase.home;
  Timer? refresh;
  String? error;
  int score = 0;
  int best = 0;
  int level = 1;
  int questionAt = 0;
  int lockedUntil = 0;
  int countdown = 3;
  bool loading = true;

  int get elapsed => clock.elapsedMilliseconds;
  int get questionAge => elapsed - questionAt;
  int get seconds => ((60000 - elapsed).clamp(0, 60000) / 1000).ceil();
  bool get playing => phase == Phase.playing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(loadPack());
    unawaited(loadBest());
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

  Future<void> loadBest() async {
    try {
      final stored =
          (await SharedPreferences.getInstance()).getInt('best_score') ?? 0;
      if (mounted && stored > best) setState(() => best = stored);
    } on Exception catch (_) {
      // Keep the current session playable if platform storage fails.
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
    setState(() {
      phase = Phase.preparing;
      countdown = 3;
      score = 0;
      level = 1;
      missed.clear();
      deck = List<Prompt>.of(pack)..shuffle(random);
      clock.reset();
      nextQuestion(skipped: false);
    });
    while (countdown > 0) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted || phase != Phase.preparing) return;
      setState(() => countdown--);
    }
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || phase != Phase.preparing) return;
    setState(() {
      phase = Phase.playing;
      clock.start();
    });
    refresh?.cancel();
    refresh = Timer.periodic(const Duration(milliseconds: 33), (_) => tick());
  }

  void tick() {
    if (!mounted || !playing) return;
    if (elapsed >= 60000) {
      finish();
    } else {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) tick();
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
    drawing = pool[random.nextInt(pool.length)];
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
        score++;
        nextQuestion(skipped: false);
      } else {
        disabled.add(option);
        lockedUntil = elapsed + 1500;
        if (disabled.length == 3) {
          missed.add((prompt!.label, drawing));
          nextQuestion(skipped: true);
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
    if (questionAge < 2000) return;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewPaddingOf(context);
    final sideInset = max(insets.left, insets.right);
    return Scaffold(
      body: SafeArea(
        minimum: EdgeInsets.symmetric(horizontal: sideInset),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: switch (phase) {
              Phase.home => home(),
              Phase.preparing => prepare(),
              Phase.playing => game(),
              Phase.results => results(),
            },
          ),
        ),
      ),
    );
  }

  Widget title(String label, {double size = 35, Color color = ink}) => Text(
    label,
    textAlign: TextAlign.center,
    style: TextStyle(fontSize: size, fontWeight: FontWeight.w900, color: color),
  );

  Widget primary(String label, VoidCallback? action) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: blue,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 55),
        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
      onPressed: action,
      child: Text(label),
    ),
  );

  Widget spacedPage(List<Widget> sections, {double horizontal = 24}) =>
      LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: max(0, constraints.maxHeight - 32),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: sections,
            ),
          ),
        ),
      );

  Widget home() => spacedPage([
    Column(
      children: [
        title('토끼의 낙서장'),
        const SizedBox(height: 10),
        title('60초 동안 그림을 맞혀요', size: 19),
      ],
    ),
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Image.asset(
        'assets/home-rabbit.png',
        height: (MediaQuery.sizeOf(context).height * 0.30)
            .clamp(170, 300)
            .toDouble(),
        fit: BoxFit.contain,
        excludeFromSemantics: true,
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
  ]);

  Widget prepare() => spacedPage([
    title('토끼의 낙서장'),
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
          key: ValueKey(countdown),
          child: title(
            countdown == 0 ? '게임 시작!' : '$countdown',
            size: 46,
            color: blue,
          ),
        ),
      ),
    ),
  ]);

  Widget game() => LayoutBuilder(
    builder: (context, constraints) {
      final canvasSize = min(
        max(0.0, constraints.maxWidth - 40),
        max(130.0, constraints.maxHeight - 295),
      );
      final progress = strokeProgressAt(
        elapsedMs: elapsed,
        questionStartedMs: questionAt,
        level: level,
      );
      final timer =
          '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
      return spacedPage([
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            title(
              timer,
              size: 30,
              color: seconds <= 10 ? Colors.red.shade800 : ink,
            ),
            title('$score점', size: 24),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: SizedBox.square(
              dimension: canvasSize,
              child: sketch(drawing, progress, true),
            ),
          ),
        ),
        Column(
          children: [
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
            TextButton(
              onPressed: questionAge >= 2000 ? skip : null,
              child: const Text('건너뛰기'),
            ),
          ],
        ),
      ], horizontal: 20);
    },
  );

  Widget choice(String option) {
    final wrong = disabled.contains(option);
    return OutlinedButton(
      onPressed: wrong || elapsed < lockedUntil ? null : () => answer(option),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 54),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        foregroundColor: ink,
        side: BorderSide(color: wrong ? Colors.red.shade700 : ink),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      ),
      child: Text(wrong ? '✕ $option' : option, textAlign: TextAlign.center),
    );
  }

  Widget results() => spacedPage([
    Column(
      children: [
        title('시간 종료', size: 27),
        title('$score개 정답', size: 49, color: blue),
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
                        width: missed.length == 1 ? 176 : 136,
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
        primary('한 판 더', start),
        TextButton(
          onPressed: () => setState(() => phase = Phase.home),
          child: const Text('홈으로'),
        ),
        const SizedBox(height: 12),
        const AdBanner(),
      ],
    ),
  ]);

  Widget sketch(List<List<Offset>> strokes, double progress, bool pencil) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xfffffbef),
          border: Border.all(color: ink, width: 2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: CustomPaint(painter: StrokePainter(strokes, progress, pencil)),
        ),
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
