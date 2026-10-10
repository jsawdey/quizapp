import 'package:intl/intl.dart';

/// How a question is played: [open] questions are flip cards, the others
/// offer [Question.choices] to pick from.
enum QuestionFormat { open, multipleChoice, trueFalse }

/// A single clue or trivia question, independent of the source it came from.
///
/// Each [QuestionSource] parses its own data into this; the app's naming is
/// kept, so [question] is the clue text and [answer] is the correct response.
class Question {
  /// Namespace for [key], e.g. `jwolle1` or `jservice:jservice.io`.
  final String sourceId;

  /// Stable identifier within [sourceId]. A string, because 64-bit keys aren't
  /// safe in JSON for every client.
  final String key;
  final String question;
  final String answer;
  final String category;
  final int? value;

  /// 1 Jeopardy, 2 Double Jeopardy, 3 Final Jeopardy; null if unknown.
  final int? round;
  final DateTime? airDate;
  final int? dailyDoubleWager;
  final String? categoryComment;
  final String? notes;

  /// Every option in display order, [answer] among them. Null for open
  /// questions. Sources put them in order; the UI never shuffles.
  final List<String>? choices;

  /// How hard the source says the question is, such as `easy`, `medium` or
  /// `hard`; null when it doesn't say.
  final String? difficulty;

  /// The source's raw record, shown as-is by the info overlay.
  final Map<String, dynamic> raw;

  /// Throws [ArgumentError] if [choices] is set and doesn't contain
  /// [answer]; sources check [validChoices] first and skip such items.
  Question({required this.sourceId, required this.key,
    required this.question, required this.answer, required this.category,
    this.value, this.round, this.airDate, this.dailyDoubleWager,
    this.categoryComment, this.notes, List<String>? choices, this.difficulty,
    this.raw = const {}})
      : choices = choices == null ? null : List.unmodifiable(choices) {
    if (choices != null && !validChoices(choices, answer)) {
      throw ArgumentError.value(choices, 'choices',
          'must be at least two different options, one of them the answer');
    }
  }

  /// Whether [choices] can be offered for [answer]: at least two options, no
  /// two the same, and [answer] one of them.
  static bool validChoices(List<String> choices, String answer) =>
      choices.length >= 2 && choices.toSet().length == choices.length &&
      choices.contains(answer);

  QuestionFormat get format {
    final choices = this.choices;
    if (choices == null) return QuestionFormat.open;
    return choices.length == 2 && choices.toSet().containsAll(const ['True', 'False'])
        ? QuestionFormat.trueFalse
        : QuestionFormat.multipleChoice;
  }

  bool get isFinalJeopardy => round == 3;

  /// The day clue values doubled, from $100–$500 to $200–$1,000 in Jeopardy!
  /// and from $200–$1,000 to $400–$2,000 in Double Jeopardy!.
  static final valuesDoubledOn = DateTime(2001, 11, 26);

  /// The clue's row on the board, from 1 (top) to 5 (bottom): its value over
  /// the round's base, which [valuesDoubledOn] doubled. Daily Doubles keep
  /// their board value, so they have a row too. Null for Final Jeopardy, and
  /// when the value, round or air date is missing or doesn't fit a row.
  int? get boardRow {
    final value = this.value;
    final airDate = this.airDate;
    if (value == null || airDate == null || (round != 1 && round != 2)) return null;
    final base = (round == 1 ? 100 : 200) * (airDate.isBefore(valuesDoubledOn) ? 1 : 2);
    final row = value ~/ base;
    return value % base == 0 && row >= 1 && row <= 5 ? row : null;
  }

  /// Strips `<i>` tags and stray backslashes from text that wasn't cleaned
  /// before it reached the app (API data).
  static String sanitize(String text) {
    String sanitized = text.replaceAll(RegExp(r'<\/?i>'), '');
    sanitized = sanitized.replaceAll(RegExp(r'\\'), '');
    return sanitized;
  }

  String formattedDateTime() {
    final date = airDate;
    if (date == null) return '';
    Intl.defaultLocale = 'en_US';
    var formatter = DateFormat.yMd();
    return formatter.format(date);
  }
}
