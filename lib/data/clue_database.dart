import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

/// The databases a build can bundle, chosen with `LOCAL_DATASET`.
enum LocalDataset {
  /// Jeopardy! clues, built by `tool/build_clue_db.py`.
  clues('clue database', 'build_clue_db.py'),

  /// General trivia from Open Trivia Database, built by
  /// `tool/build_trivia_db.py`.
  trivia('trivia database', 'build_trivia_db.py');

  final String description;
  final String buildScript;
  const LocalDataset(this.description, this.buildScript);

  String get assetPath => 'assets/db/$name.db';

  /// Written next to the database by its build script; see [ClueDatabase].
  String get versionAssetPath => 'assets/db/$name.version';
}

/// A database built by one of the `tool/build_*_db.py` scripts and bundled as
/// an asset: the clue database, or the trivia database (see [LocalDataset]).
///
/// SQLite can't open a database straight from the asset bundle, so the first
/// launch copies it into the app support folder. Next to it the build script
/// writes a `.version` file; the database is copied again whenever the
/// bundled version file differs from the installed one, which is how a
/// rebuilt database reaches the app without reading the whole asset on every
/// launch.
class ClueDatabase {
  /// The `meta.schema_version` this code can read, for either dataset.
  static const supportedSchemaVersion = 1;

  final LocalDataset dataset;
  final AssetBundle _bundle;
  final Future<String> Function() _directory;
  // Resolved on open: sqflite's global factory isn't available off-device.
  final sqflite.DatabaseFactory? _databaseFactory;

  ClueDatabase({this.dataset = LocalDataset.clues, AssetBundle? bundle,
    Future<String> Function()? directory, sqflite.DatabaseFactory? databaseFactory})
      : _bundle = bundle ?? rootBundle,
        _directory = directory ?? _defaultDirectory,
        _databaseFactory = databaseFactory;

  static Future<String> _defaultDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  String get _missingMessage =>
      'No ${dataset.description} is bundled with this build. '
      'Run python3 tool/${dataset.buildScript}, then build the app again.';

  /// Installs the bundled database if needed and opens it read-only.
  /// Throws [SourceUnavailable] if no database is bundled or it can't be read.
  Future<sqflite.Database> open() async {
    final String bundledVersion;
    try {
      bundledVersion = await _bundle.loadString(dataset.versionAssetPath, cache: false);
    } on FlutterError {
      throw SourceUnavailable(_missingMessage);
    }

    final directory = await _directory();
    final dbFile = File(p.join(directory, '${dataset.name}.db'));
    final versionFile = File(p.join(directory, '${dataset.name}.version'));
    if (!await dbFile.exists() || !await versionFile.exists() ||
        await versionFile.readAsString() != bundledVersion) {
      await _install(dbFile, versionFile, bundledVersion);
    }

    final sqflite.Database db;
    try {
      db = await (_databaseFactory ?? sqflite.databaseFactory).openDatabase(dbFile.path,
          options: sqflite.OpenDatabaseOptions(readOnly: true));
    } on sqflite.DatabaseException catch (e) {
      throw SourceUnavailable('Could not open the ${dataset.description}: $e');
    }
    final meta = await _meta(db);
    final schema = int.tryParse(meta['schema_version'] ?? '');
    // Clue databases predate dataset_kind.
    final kind = meta['dataset_kind'] ?? LocalDataset.clues.name;
    final String? problem;
    if (schema != supportedSchemaVersion) {
      problem = 'The ${dataset.description} has schema version $schema, but '
          'this app reads version $supportedSchemaVersion. '
          'Rebuild it with tool/${dataset.buildScript} from this checkout.';
    } else if (kind != dataset.name) {
      problem = '${dataset.assetPath} holds a $kind database. '
          'Rebuild it with tool/${dataset.buildScript}.';
    } else {
      problem = null;
    }
    if (problem != null) {
      await db.close();
      throw SourceUnavailable(problem);
    }
    return db;
  }

  Future<void> _install(File dbFile, File versionFile, String version) async {
    final ByteData data;
    try {
      data = await _bundle.load(dataset.assetPath);
    } on FlutterError {
      throw SourceUnavailable(_missingMessage);
    }
    await dbFile.parent.create(recursive: true);
    // Remove the old version file first and write the new one last, so an
    // interrupted copy is always redone on the next launch.
    if (await versionFile.exists()) await versionFile.delete();
    final tmp = File('${dbFile.path}.part');
    await tmp.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    await tmp.rename(dbFile.path);
    await versionFile.writeAsString(version, flush: true);
  }

  /// The meta table, or nothing if there isn't one.
  static Future<Map<String, String>> _meta(sqflite.Database db) async {
    try {
      final rows = await db.rawQuery('SELECT key, value FROM meta');
      return {for (final row in rows) '${row['key']}': '${row['value']}'};
    } on sqflite.DatabaseException {
      return const {};
    }
  }
}
