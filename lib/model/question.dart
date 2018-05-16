import 'package:intl/intl.dart';

class JeopardyQuestion {
  final int id;
  final String answer;
  final String question;
  final int value;
  final String category;
  final DateTime airDate;

  JeopardyQuestion({this.id, this.question, this.answer, this.value, this.category, this.airDate});

  static String _sanitizeString(String jsonString) {
    String sanitized = jsonString.replaceAll(new RegExp(r'<\/?i>'), '');
    sanitized = sanitized.replaceAll(new RegExp(r'\\'), '');
    return sanitized;
  }

  String formattedDateTime() {
    Intl.defaultLocale = 'en_US';
    var formatter = new DateFormat.yMd();
    String formatted = formatter.format(airDate);
    return formatted;
  }

  factory JeopardyQuestion.fromJson(Map<String, dynamic> json) {
    return new JeopardyQuestion(
      id: json['id'],
      question: _sanitizeString(json['question']),
      answer: _sanitizeString(json['answer']),
      value: json['value'],
      category: json['category']['title'],
      airDate: DateTime.parse(json['airdate'])
    );
  }
}