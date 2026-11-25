const dailyRoundStartMs = 30000;
const dailyRecordKey = 'daily_sketch_record';
const replayVisitsKey = 'recent_replay_visits';

int dailySketchDay(DateTime date) =>
    date.year * 10000 + date.month * 100 + date.day;

int dailySketchLevel(int questionIndex) => questionIndex < 2
    ? 1
    : questionIndex < 5
    ? 2
    : 3;

bool isQuickCorrect(num? firstTapProgress, int wrongTaps) =>
    firstTapProgress != null &&
    firstTapProgress >= .15 &&
    firstTapProgress < .5 &&
    wrongTaps == 0;

String replayGoal(int score, int previousBest) => score < previousBest
    ? '최고 기록까지 ${previousBest - score}개'
    : '다음 목표 ${score + 1}개';

({int day, int score})? parseDailyRecord(String? stored) {
  final fields = stored?.split(':');
  if (fields == null || fields.length != 2) return null;
  final day = int.tryParse(fields.first);
  final score = int.tryParse(fields.last);
  return day == null || score == null || score < 0
      ? null
      : (day: day, score: score);
}

List<String> recordReplayVisit(
  List<String> visits,
  String sequence,
  int starts,
) => [
  '$sequence:$starts',
  ...visits.where((visit) => !visit.startsWith('$sequence:')).take(19),
];

String replayVisitSummary(List<String> visits) {
  final starts = visits
      .map((visit) => int.tryParse(visit.split(':').last))
      .whereType<int>()
      .where((rounds) => rounds >= 1);
  if (starts.isEmpty) return '완료한 첫 판 기록이 없어요.';
  return '첫 판을 끝낸 ${starts.length}회 중 두 번째 판 ${starts.where((n) => n >= 2).length}회 · '
      '세 번째 판 ${starts.where((n) => n >= 3).length}회 시작';
}
