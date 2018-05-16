class JeopardyQuestion {
  final int id;
  final String answer;
  final String question;
  final int value;
  final String category;
  final DateTime airDate;

  JeopardyQuestion({this.id, this.question, this.answer, this.value, this.category, this.airDate});

  factory JeopardyQuestion.fromJson(Map<String, dynamic> json) {
    return new JeopardyQuestion(
      id: json['id'],
      question: json['question'],
      answer: json['answer'],
      value: json['value'],
      category: json['category']['title'],
      airDate: DateTime.parse(json['airdate'])
    );
  }
}