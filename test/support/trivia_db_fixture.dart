import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The schema written by tool/build_trivia_db.py. Keep the two in sync;
/// local_trivia_source_test.dart checks a real build when one exists.
const triviaDbSchema = '''
CREATE TABLE meta      (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE questions (
  id         INTEGER PRIMARY KEY,
  key        TEXT NOT NULL UNIQUE,
  category   TEXT NOT NULL,
  difficulty TEXT,
  question   TEXT NOT NULL,
  answer     TEXT NOT NULL,
  choices    TEXT NOT NULL
);
''';

class FixtureTrivia {
  final String key;
  final String category;
  final String difficulty;
  final String answer;
  final List<String> choices;
  const FixtureTrivia(this.key, this.category, this.difficulty, this.answer, this.choices);
}

/// Five questions; ids 1..5 in this order.
const fixtureTrivia = [
  FixtureTrivia('a1', 'Art', 'easy', 'Dutch', ['French', 'Dutch', 'Polish', 'Russian']),
  FixtureTrivia('a2', 'Art', 'hard', 'True', ['True', 'False']),
  FixtureTrivia('g1', 'Geography', 'easy', 'Bern', ['Zürich', 'Wien', 'Bern', 'Frankfurt']),
  FixtureTrivia('g2', 'Geography', 'medium', 'Lesotho',
      ['Burkina Faso', 'Lesotho', 'Mongolia', 'Luxembourg']),
  FixtureTrivia('h1', 'History', 'hard', 'False', ['True', 'False']),
];

/// Writes a trivia database to [path] (or [inMemoryDatabasePath]) and
/// returns it open.
Future<Database> createTriviaDb({String path = inMemoryDatabasePath,
    List<FixtureTrivia> questions = fixtureTrivia, String kind = 'trivia',
    int schemaVersion = 1}) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(path,
      options: OpenDatabaseOptions(singleInstance: false));
  await db.execute(triviaDbSchema);
  final batch = db.batch();
  for (var i = 0; i < questions.length; i++) {
    final q = questions[i];
    batch.insert('questions', {
      'id': i + 1, 'key': q.key, 'category': q.category, 'difficulty': q.difficulty,
      'question': 'Question ${q.key}', 'answer': q.answer, 'choices': json.encode(q.choices),
    });
  }
  for (final MapEntry(:key, :value) in {
    'schema_version': '$schemaVersion',
    'dataset_namespace': 'opentdb',
    'dataset_kind': kind,
    'license': 'CC BY-SA 4.0',
    'attribution': 'Questions from Open Trivia Database (opentdb.com), CC BY-SA 4.0',
  }.entries) {
    batch.insert('meta', {'key': key, 'value': value});
  }
  await batch.commit(noResult: true);
  return db;
}
