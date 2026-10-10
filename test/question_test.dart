import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

import 'support/fakes.dart';

void main() {
  group('Question', () {
    test('sanitize strips italics tags and backslashes', () {
      expect(Question.sanitize(r'<i>Moby-Dick</i> by \"Melville\"'),
          'Moby-Dick by "Melville"');
    });

    test('formattedDateTime is empty without an air date', () {
      expect(fakeQuestion('1').formattedDateTime(), '');
      expect(fakeQuestion('1', airDate: DateTime(2004, 3, 1)).formattedDateTime(),
          '3/1/2004');
    });

    test('boardRow matches the shared examples', () {
      // The same examples check serve_clues.py's SQL (tool/test_serve_clues.py).
      final examples = json.decode(File('test/support/board_rows.json').readAsStringSync())
          as List<dynamic>;
      for (final example in examples.cast<Map<String, dynamic>>()) {
        final q = fakeQuestion('1', round: example['round'] as int,
            value: example['round'] == 3 ? null : example['value'] as int,
            airDate: DateTime.parse(example['air_date'] as String));
        expect(q.boardRow, example['row'], reason: '$example');
      }
    });

    test('boardRow is null without a value, round or air date', () {
      expect(fakeQuestion('1', round: 1, value: 200).boardRow, isNull);
      expect(fakeQuestion('1', value: 200, airDate: DateTime(2015)).boardRow, isNull);
      expect(fakeQuestion('1', round: 1, value: null, airDate: DateTime(2015)).boardRow,
          isNull);
    });

    test('isFinalJeopardy is true only for round 3', () {
      expect(fakeQuestion('1', round: 3).isFinalJeopardy, isTrue);
      expect(fakeQuestion('1', round: 2).isFinalJeopardy, isFalse);
      expect(fakeQuestion('1').isFinalJeopardy, isFalse);
    });
  });

  group('QuestionFilter', () {
    test('any matches everything', () {
      expect(QuestionFilter.any.matches(fakeQuestion('1')), isTrue);
    });

    test('rounds rejects other and unknown rounds', () {
      const filter = QuestionFilter(rounds: {1, 2});
      expect(filter.matches(fakeQuestion('1', round: 2)), isTrue);
      expect(filter.matches(fakeQuestion('1', round: 3)), isFalse);
      expect(filter.matches(fakeQuestion('1')), isFalse);
    });

    test('date range is inclusive and rejects unknown dates', () {
      final filter = QuestionFilter(from: DateTime(2000), to: DateTime(2001));
      expect(filter.matches(fakeQuestion('1', airDate: DateTime(2000))), isTrue);
      expect(filter.matches(fakeQuestion('1', airDate: DateTime(2001))), isTrue);
      expect(filter.matches(fakeQuestion('1', airDate: DateTime(1999))), isFalse);
      expect(filter.matches(fakeQuestion('1', airDate: DateTime(2002))), isFalse);
      expect(filter.matches(fakeQuestion('1')), isFalse);
    });

    test('board rows narrow Jeopardy and Double Jeopardy, not Final Jeopardy', () {
      const filter = QuestionFilter(boardRows: {4, 5});
      final at = DateTime(2015);
      expect(filter.matches(fakeQuestion('1', round: 1, value: 800, airDate: at)), isTrue);
      expect(filter.matches(fakeQuestion('1', round: 2, value: 2000, airDate: at)), isTrue);
      expect(filter.matches(fakeQuestion('1', round: 1, value: 200, airDate: at)), isFalse);
      expect(filter.matches(fakeQuestion('1', round: 3, value: null, airDate: at)), isTrue);
      // No row can be worked out.
      expect(filter.matches(fakeQuestion('1', value: 800, airDate: at)), isFalse);
    });

    test('every board row is no filter', () {
      expect(const QuestionFilter(boardRows: {1, 2, 3, 4, 5}).normalized(), QuestionFilter.any);
      expect(const QuestionFilter(boardRows: {5}).normalized(),
          const QuestionFilter(boardRows: {5}));
      expect(const QuestionFilter(boardRows: {4, 5}), const QuestionFilter(boardRows: {5, 4}));
      expect(const QuestionFilter(boardRows: {4, 5}).hashCode,
          const QuestionFilter(boardRows: {5, 4}).hashCode);
      expect(const QuestionFilter(boardRows: {5}), isNot(QuestionFilter.any));
    });

    test('filters with the same values are equal', () {
      expect(QuestionFilter(rounds: {1, 2}, from: DateTime(2000)),
          QuestionFilter(rounds: {2, 1}, from: DateTime(2000)));
      expect(QuestionFilter(rounds: {1, 2}).hashCode,
          QuestionFilter(rounds: {2, 1}).hashCode);
      expect(const QuestionFilter(rounds: {1}), isNot(QuestionFilter.any));
    });
  });
}
