import 'package:intl/intl.dart';

class JeopardyQuestion {
  final int id;
  final String answer;
  final String question;
  final int? value;
  final String category;
  final DateTime airDate;
  final Map<String, dynamic> rawJson;

  JeopardyQuestion({required this.id, required this.question, required this.answer,
    this.value, required this.category, required this.airDate, required this.rawJson});

  static String _sanitizeString(String jsonString) {
    String sanitized = jsonString.replaceAll(RegExp(r'<\/?i>'), '');
    sanitized = sanitized.replaceAll(RegExp(r'\\'), '');
    return sanitized;
  }

  String formattedDateTime() {
    Intl.defaultLocale = 'en_US';
    var formatter = DateFormat.yMd();
    String formatted = formatter.format(airDate);
    return formatted;
  }

  factory JeopardyQuestion.fromJson(Map<String, dynamic> json) {
    return JeopardyQuestion(
      id: json['id'],
      question: _sanitizeString(json['question']),
      answer: _sanitizeString(json['answer']),
      value: json['value'],
      category: json['category']['title'],
      airDate: DateTime.parse(json['airdate']),
      rawJson: json
    );
  }
}
