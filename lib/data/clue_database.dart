import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

/// The clue database built by `tool/build_clue_db.py` and bundled as an asset.
///
/// SQLite can't open a database straight from the asset bundle, so the first
/// launch copies it into the app support folder. Next to it the build script
/// writes `clues.version`; the database is copied again whenever the bundled
/// version file differs from the installed one, which is how a rebuilt
/// database reaches the app without reading the whole asset on every launch.
class ClueDatabase {
  static const assetPath = 'assets/db/clues.db';
  static const versionAssetPath = 'assets/db/clues.version';

  /// The `meta.schema_version` this code can read.
  static const supportedSchemaVersion = 1;

  static const _missingMessage =
      'No clue database is bundled with this build. '
      'Run python3 tool/build_clue_db.py, then build the app again.';

  final AssetBundle _bundle;
  final Future<String> Function() _directory;
  // Resolved on open: sqflite's global factory isn't available off-device.
  final sqflite.DatabaseFactory? _databaseFactory;

  ClueDatabase({AssetBundle? bundle, Future<String> Function()? directory,
    sqflite.DatabaseFactory? databaseFactory})
      : _bundle = bundle ?? rootBundle,
        _directory = directory ?? _defaultDirectory,
        _databaseFactory = databaseFactory;

  static Future<String> _defaultDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  /// Installs the bundled database if needed and opens it read-only.
  /// Throws [SourceUnavailable] if no database is bundled or it can't be read.
  Future<sqflite.Database> open() async {
    final String bundledVersion;
    try {
      bundledVersion = await _bundle.loadString(versionAssetPath, cache: false);
    } on FlutterError {
      throw const SourceUnavailable(_missingMessage);
    }

    final directory = await _directory();
    final dbFile = File(p.join(directory, 'clues.db'));
    final versionFile = File(p.join(directory, 'clues.version'));
    if (!await dbFile.exists() || !await versionFile.exists() ||
        await versionFile.readAsString() != bundledVersion) {
      await _install(dbFile, versionFile, bundledVersion);
    }

    final sqflite.Database db;
    try {
      db = await (_databaseFactory ?? sqflite.databaseFactory).openDatabase(dbFile.path,
          options: sqflite.OpenDatabaseOptions(readOnly: true));
    } on sqflite.DatabaseException catch (e) {
      throw SourceUnavailable('Could not open the clue database: $e');
    }
    final schema = await _schemaVersion(db);
    if (schema != supportedSchemaVersion) {
      await db.close();
      throw SourceUnavailable('The clue database has schema version $schema, but '
          'this app reads version $supportedSchemaVersion. '
          'Rebuild it with tool/build_clue_db.py from this checkout.');
    }
    return db;
  }

  Future<void> _install(File dbFile, File versionFile, String version) async {
    final ByteData data;
    try {
      data = await _bundle.load(assetPath);
    } on FlutterError {
      throw const SourceUnavailable(_missingMessage);
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

  static Future<int?> _schemaVersion(sqflite.Database db) async {
    try {
      final rows = await db.rawQuery(
          "SELECT value FROM meta WHERE key = 'schema_version'");
      return rows.isEmpty ? null : int.tryParse('${rows.first['value']}');
    } on sqflite.DatabaseException {
      return null;
    }
  }
}
