import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quizapp/data/clue_database.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/clue_db_fixture.dart';
import 'support/trivia_db_fixture.dart';

class FakeBundle extends CachingAssetBundle {
  final Map<String, Uint8List> assets = {};
  final Map<String, int> loads = {};

  @override
  Future<ByteData> load(String key) async {
    loads[key] = (loads[key] ?? 0) + 1;
    final bytes = assets[key];
    if (bytes == null) throw FlutterError('Unable to load asset: "$key".');
    return ByteData.sublistView(bytes);
  }
}

void main() {
  late Directory tmp;
  late String installDir;
  late FakeBundle bundle;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('clue_database_test');
    installDir = p.join(tmp.path, 'support');
    bundle = FakeBundle();
  });

  tearDown(() => tmp.delete(recursive: true));

  /// Builds a clue database file and returns its bytes.
  Future<Uint8List> dbBytes(String name, {List<FixtureClue> clues = fixtureClues,
      int schemaVersion = 1}) async {
    final path = p.join(tmp.path, name);
    final db = await createClueDb(path: path, clues: clues, schemaVersion: schemaVersion);
    await db.close();
    return File(path).readAsBytes();
  }

  void bundleDb(Uint8List bytes, String version) {
    bundle.assets[LocalDataset.clues.assetPath] = bytes;
    bundle.assets[LocalDataset.clues.versionAssetPath] = utf8.encode(version);
  }

  ClueDatabase clueDatabase() => ClueDatabase(bundle: bundle,
      directory: () async => installDir, databaseFactory: databaseFactoryFfi);

  Future<int> clueCount() async {
    final db = await clueDatabase().open();
    try {
      return (await db.rawQuery('SELECT COUNT(*) AS n FROM clues')).first['n'] as int;
    } finally {
      await db.close();
    }
  }

  test('installs the bundled database once and opens it read-only', () async {
    bundleDb(await dbBytes('a.db'), '{"built_at": "1"}');
    expect(await clueCount(), 6);
    expect(await clueCount(), 6);
    expect(bundle.loads[LocalDataset.clues.assetPath], 1);
    expect(File(p.join(installDir, 'clues.version')).readAsStringSync(), '{"built_at": "1"}');
    expect(File(p.join(installDir, 'clues.db.part')).existsSync(), isFalse);

    final db = await clueDatabase().open();
    await expectLater(db.execute('DELETE FROM clues'), throwsA(isA<DatabaseException>()));
    await db.close();
  });

  test('copies again when the bundled version changes', () async {
    bundleDb(await dbBytes('a.db'), '{"built_at": "1"}');
    expect(await clueCount(), 6);
    bundleDb(await dbBytes('b.db', clues: fixtureClues.take(2).toList()), '{"built_at": "2"}');
    expect(await clueCount(), 2);
    expect(bundle.loads[LocalDataset.clues.assetPath], 2);
  });

  test('copies again after an interrupted install', () async {
    bundleDb(await dbBytes('a.db'), '{"built_at": "1"}');
    expect(await clueCount(), 6);
    // An install that died after replacing the database but before writing
    // the version file.
    File(p.join(installDir, 'clues.version')).deleteSync();
    expect(await clueCount(), 6);
    expect(bundle.loads[LocalDataset.clues.assetPath], 2);
  });

  test('no bundled database is SourceUnavailable with build instructions', () async {
    await expectLater(clueDatabase().open(), throwsA(isA<SourceUnavailable>()
        .having((e) => e.message, 'message', contains('tool/build_clue_db.py'))));

    bundle.assets[LocalDataset.clues.versionAssetPath] = utf8.encode('{}');
    await expectLater(clueDatabase().open(), throwsA(isA<SourceUnavailable>()
        .having((e) => e.message, 'message', contains('tool/build_clue_db.py'))));
  });

  test('an unsupported schema version is SourceUnavailable', () async {
    bundleDb(await dbBytes('a.db', schemaVersion: 2), '{}');
    await expectLater(clueDatabase().open(), throwsA(isA<SourceUnavailable>()
        .having((e) => e.message, 'message', contains('schema version 2'))));
  });

  group('trivia', () {
    Future<Uint8List> triviaBytes(String name, {String kind = 'trivia'}) async {
      final path = p.join(tmp.path, name);
      final db = await createTriviaDb(path: path, kind: kind);
      await db.close();
      return File(path).readAsBytes();
    }

    ClueDatabase triviaDatabase() => ClueDatabase(dataset: LocalDataset.trivia,
        bundle: bundle, directory: () async => installDir, databaseFactory: databaseFactoryFfi);

    test('installs trivia.db beside clues.db', () async {
      bundleDb(await dbBytes('a.db'), '{"built_at": "1"}');
      bundle.assets[LocalDataset.trivia.assetPath] = await triviaBytes('t.db');
      bundle.assets[LocalDataset.trivia.versionAssetPath] = utf8.encode('{"t": 1}');
      final db = await triviaDatabase().open();
      expect((await db.rawQuery('SELECT COUNT(*) AS n FROM questions')).first['n'], 5);
      await db.close();
      expect(await clueCount(), 6);
      expect(File(p.join(installDir, 'trivia.version')).readAsStringSync(), '{"t": 1}');
    });

    test('a missing trivia.db names its build script', () async {
      await expectLater(triviaDatabase().open(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', allOf(
              contains('No trivia database'), contains('tool/build_trivia_db.py')))));
    });

    test('the wrong kind of database is SourceUnavailable', () async {
      // A clue database copied over trivia.db.
      bundle.assets[LocalDataset.trivia.assetPath] = await dbBytes('a.db');
      bundle.assets[LocalDataset.trivia.versionAssetPath] = utf8.encode('{}');
      await expectLater(triviaDatabase().open(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('holds a clues database'))));

      bundleDb(await triviaBytes('t.db'), '{"swapped": 1}');
      await expectLater(clueDatabase().open(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('holds a trivia database'))));
    });
  });

  test('a corrupt database is SourceUnavailable', () async {
    bundleDb(Uint8List.fromList(utf8.encode('not a database')), '{}');
    await expectLater(clueDatabase().open(), throwsA(isA<SourceUnavailable>()));
  });
}
