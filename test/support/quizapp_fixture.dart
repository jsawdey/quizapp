/// A `/v1/random` response in this app's API format (see
/// docs/question-backend-plan.md §7). The third clue is missing its response;
/// the fourth is not an object.
const quizApiRandomResponse = '''
{
  "namespace": "jwolle1",
  "questions": [
    {
      "key": "-4182736451234567",
      "category": "POTPOURRI",
      "category_comment": "(Alex: Each one is a mammal.)",
      "clue": "It\\\\'s the largest living land animal",
      "response": "an elephant",
      "value": 800,
      "round": 2,
      "dd_wager": 1500,
      "air_date": "1984-09-11",
      "notes": null
    },
    {
      "key": "77",
      "category": "WORLD CAPITALS",
      "category_comment": "",
      "clue": "It was founded by Peter the Great",
      "response": "St. Petersburg",
      "value": 0,
      "round": 3,
      "dd_wager": 0,
      "air_date": "1984-09-11",
      "notes": "Tournament of Champions game 1."
    },
    {"key": "78", "category": "X", "clue": "No response here"},
    "not a clue"
  ]
}
''';
