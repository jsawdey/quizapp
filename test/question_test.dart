import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

import 'support/fakes.dart';

void main() {
  group('JeopardyQuestion', () {
    test('sanitize strips italics tags and backslashes', () {
      expect(JeopardyQuestion.sanitize(r'<i>Moby-Dick</i> by \"Melville\"'),
          'Moby-Dick by "Melville"');
    });

    test('formattedDateTime is empty without an air date', () {
      expect(fakeQuestion('1').formattedDateTime(), '');
      expect(fakeQuestion('1', airDate: DateTime(2004, 3, 1)).formattedDateTime(),
          '3/1/2004');
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

    test('filters with the same values are equal', () {
      expect(QuestionFilter(rounds: {1, 2}, from: DateTime(2000)),
          QuestionFilter(rounds: {2, 1}, from: DateTime(2000)));
      expect(QuestionFilter(rounds: {1, 2}).hashCode,
          QuestionFilter(rounds: {2, 1}).hashCode);
      expect(const QuestionFilter(rounds: {1}), isNot(QuestionFilter.any));
    });
  });
}
