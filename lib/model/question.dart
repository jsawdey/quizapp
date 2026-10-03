import 'package:intl/intl.dart';

/// A single clue, independent of the source it came from.
///
/// Each [QuestionSource] parses its own data into this; the app's naming is
/// kept, so [question] is the clue text and [answer] is the correct response.
class JeopardyQuestion {
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

  /// The source's raw record, shown as-is by the info overlay.
  final Map<String, dynamic> raw;

  JeopardyQuestion({required this.sourceId, required this.key,
    required this.question, required this.answer, required this.category,
    this.value, this.round, this.airDate, this.dailyDoubleWager,
    this.categoryComment, this.notes, this.raw = const {}});

  bool get isFinalJeopardy => round == 3;

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
