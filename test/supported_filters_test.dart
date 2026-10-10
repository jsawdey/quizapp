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
    const trivia = QuestionFilter(categories: {'Art'}, difficulties: {'hard'});
    expect(trivia.limitedTo(all), QuestionFilter.any);
    expect(trivia.limitedTo({FilterKind.category}), const QuestionFilter(categories: {'Art'}));
    expect(trivia.limitedTo({FilterKind.difficulty}),
        const QuestionFilter(difficulties: {'hard'}));
  });

  test('a fallback source offers the categories both open sources do', () async {
    final primary = FakeQuestionSource([fakeQuestion('p')],
        categories: ['Art', 'Geography', 'History']);
    final fallback = FakeQuestionSource([fakeQuestion('f')],
        categories: ['History', 'Art']);
    final source = FallbackQuestionSource(primary: primary, fallback: fallback);
    // Nothing is open yet, and asking opens nothing.
    expect(await source.filterCategories(), isEmpty);
    await source.randomQuestion();
    expect(await source.filterCategories(), ['Art', 'Geography', 'History']);
    primary.error = const SourceUnavailable('offline');
    await source.randomQuestion();
    expect(await source.filterCategories(), ['Art', 'History']);
  });
}
