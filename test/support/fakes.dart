import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

JeopardyQuestion fakeQuestion(String key, {String sourceId = 'fake',
    int? round, DateTime? airDate, int? value = 200, int? dailyDoubleWager,
    String? category, String? categoryComment}) =>
    JeopardyQuestion(sourceId: sourceId, key: key, question: 'Clue $key',
        answer: 'Response $key', category: category ?? 'Category $key',
        value: value, round: round, airDate: airDate,
        dailyDoubleWager: dailyDoubleWager, categoryComment: categoryComment,
        raw: {'key': key});

/// Serves [questions] in order, round and round, or throws [error] if set.
class FakeQuestionSource extends QuestionSource {
  final List<JeopardyQuestion> questions;
  Object? error;
  Object? openError;
  @override
  final bool supportsRemoteReport;
  Object? reportError;

  /// When set, randomQuestion waits for it first.
  Future<void>? gate;

  int _next = 0;
  int opens = 0;
  int closes = 0;
  final List<JeopardyQuestion> reported = [];

  FakeQuestionSource(this.questions, {this.supportsRemoteReport = false});

  @override
  String get description => 'fake source';

  @override
  Future<void> open() async {
    opens++;
    final e = openError;
    if (e != null) throw e;
  }

  @override
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async {
    final gate = this.gate;
    if (gate != null) await gate;
    final e = error;
    if (e != null) throw e;
    if (questions.isEmpty) throw const NoQuestionFound();
    return questions[_next++ % questions.length];
  }

  @override
  Future<void> reportRemote(JeopardyQuestion question) async {
    reported.add(question);
    final e = reportError;
    if (e != null) throw e;
  }

  @override
  Future<void> close() async => closes++;
}
