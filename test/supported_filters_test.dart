import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/config/source_factory.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';

import 'support/fakes.dart';

void main() {
  const both = {FilterKind.round, FilterKind.airDate};
  const all = {FilterKind.round, FilterKind.airDate, FilterKind.boardRow};
  final base = Uri.parse('https://example.com');

  test('the local database supports every filter', () {
    expect(LocalQuestionSource().supportedFilters, all);
  });

  test('an API source supports what its dialect does', () {
    expect(HttpQuestionSource(baseUrl: base, dialect: QuizApiDialect()).supportedFilters,
        all);
    expect(HttpQuestionSource(baseUrl: base, dialect: JServiceDialect()).supportedFilters,
        isEmpty);
  });

  test('a fallback source supports what both sources do', () {
    FallbackQuestionSource fallback(Set<FilterKind> primary, Set<FilterKind> fallback) =>
        FallbackQuestionSource(
            primary: FakeQuestionSource([], supportedFilters: primary),
            fallback: FakeQuestionSource([], supportedFilters: fallback));
    expect(fallback(both, both).supportedFilters, both);
    expect(fallback(both, {FilterKind.airDate}).supportedFilters, {FilterKind.airDate});
    expect(fallback({}, both).supportedFilters, isEmpty);
  });

  test('an unavailable source supports nothing', () {
    expect(UnavailableQuestionSource('broken').supportedFilters, isEmpty);
  });

  test('limitedTo drops what a source can\'t apply', () {
    final filter = QuestionFilter(rounds: const {3}, from: DateTime(1990), to: DateTime(1999));
    expect(filter.limitedTo(both), filter);
    expect(filter.limitedTo({FilterKind.round}), const QuestionFilter(rounds: {3}));
    expect(filter.limitedTo({FilterKind.airDate}),
        QuestionFilter(from: DateTime(1990), to: DateTime(1999)));
    expect(filter.limitedTo({}), QuestionFilter.any);
    const rows = QuestionFilter(boardRows: {4, 5});
    expect(rows.limitedTo(all), rows);
    expect(rows.limitedTo(both), QuestionFilter.any);
  });
}
