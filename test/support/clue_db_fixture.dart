import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The schema written by tool/build_clue_db.py. Keep the two in sync;
/// local_question_source_real_db_test.dart checks a real build when one exists.
const clueDbSchema = '''
CREATE TABLE meta       (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE games      (id INTEGER PRIMARY KEY, air_date TEXT NOT NULL UNIQUE);
CREATE TABLE categories (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE clues (
  id               INTEGER PRIMARY KEY,
  clue_key         INTEGER NOT NULL,
  game_id          INTEGER NOT NULL REFERENCES games(id),
  category_id      INTEGER NOT NULL REFERENCES categories(id),
  round            INTEGER NOT NULL,
  value            INTEGER NOT NULL,
  dd_wager         INTEGER NOT NULL,
  category_comment TEXT,
  clue             TEXT NOT NULL,
  response         TEXT NOT NULL,
  notes            TEXT
);
CREATE INDEX clues_round ON clues(round);
''';

class FixtureClue {
  final int key;
  final String airDate;
  final String category;
  final int round;
  final int value;
  final int ddWager;
  final String? comment;
  final String? notes;
  const FixtureClue(this.key, this.airDate, this.category, this.round, this.value,
      {this.ddWager = 0, this.comment, this.notes});
}

/// Six clues across two games; ids 1..6 in this order.
const fixtureClues = [
  FixtureClue(-9001, '1984-09-10', 'ANIMALS', 1, 200),
  FixtureClue(9002, '1984-09-10', 'ANIMALS', 1, 400),
  FixtureClue(9003, '1984-09-10', 'POTPOURRI', 2, 800,
      ddWager: 1500, comment: '(Alex: Each one is a mammal.)'),
  FixtureClue(9004, '1984-09-10', 'WORLD CAPITALS', 3, 0,
      notes: 'Tournament of Champions game 1.'),
  FixtureClue(9005, '2012-09-17', "TEXAS HOLD 'EM", 1, 600),
  FixtureClue(9006, '2012-09-17', "TEXAS HOLD 'EM", 2, 1200),
];

/// Writes a clue database to [path] (or [inMemoryDatabasePath]) and returns it
/// open. Pass `namespace: null` to leave `dataset_namespace` out of `meta`.
Future<Database> createClueDb({String path = inMemoryDatabasePath,
    List<FixtureClue> clues = fixtureClues, String? namespace = 'jwolle1',
    int schemaVersion = 1}) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(path,
      options: OpenDatabaseOptions(singleInstance: false));
  await db.execute(clueDbSchema);
  final games = <String, int>{};
  final categories = <String, int>{};
  final batch = db.batch();
  for (var i = 0; i < clues.length; i++) {
    final c = clues[i];
    final gameId = games.putIfAbsent(c.airDate, () {
      batch.insert('games', {'id': games.length + 1, 'air_date': c.airDate});
      return games.length + 1;
    });
    final categoryId = categories.putIfAbsent(c.category, () {
      batch.insert('categories', {'id': categories.length + 1, 'name': c.category});
      return categories.length + 1;
    });
    batch.insert('clues', {
      'id': i + 1, 'clue_key': c.key, 'game_id': gameId, 'category_id': categoryId,
      'round': c.round, 'value': c.value, 'dd_wager': c.ddWager,
      'category_comment': c.comment, 'clue': 'Clue ${i + 1}',
      'response': 'Response ${i + 1}', 'notes': c.notes,
    });
  }
  batch.insert('meta', {'key': 'schema_version', 'value': '$schemaVersion'});
  if (namespace != null) {
    batch.insert('meta', {'key': 'dataset_namespace', 'value': namespace});
  }
  await batch.commit(noResult: true);
  return db;
}
