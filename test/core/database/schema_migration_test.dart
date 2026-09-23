import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xplay/core/database/repository.dart';

/// Guards the schema path itself: `Repository.database` is always created fresh
/// (in-memory) in tests, so without these the upgrade ladder that real users
/// walk through is never executed.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory sandbox;
  late String dbPath;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('xflow_mig');
    dbPath = p.join(sandbox.path, 'xflow_test.db');
  });

  tearDown(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {
      // A handle closed later can keep the file locked on Windows; the temp
      // directory is disposable, so never fail a test over cleanup.
    }
  });

  Future<Set<String>> columnsOf(Database db, String table) async => {
        for (final row in await db.rawQuery('PRAGMA table_info($table)'))
          row['name'] as String,
      };

  Future<Set<String>> indexesOf(Database db, String table) async => {
        for (final row in await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = ? AND name NOT LIKE 'sqlite_autoindex%'",
            [table]))
          row['name'] as String,
      };

  test('v13 -> v14 adds the watched_media indexes', () async {
    // A faithful v13 database: current tables, minus the two v14 indexes.
    var db = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(
            version: 13, onCreate: Repository.createSchema));
    await db.execute('DROP INDEX idx_watched_media_key');
    await db.execute('DROP INDEX idx_watched_at');
    expect(await indexesOf(db, tableWatchedMedia), isEmpty,
        reason: 'v13 库里不应已有这两个索引');
    await db.close();

    db = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(
            version: Repository.schemaVersion,
            onUpgrade: Repository.upgradeSchema));
    expect(
        await indexesOf(db, tableWatchedMedia),
        containsAll(['idx_watched_media_key', 'idx_watched_at']));
    await db.close();
  });

  test('an ancient database ends up identical to a fresh install', () async {
    // The point of the ladder: someone upgrading across many releases must not
    // get a subtly different schema than someone installing today.
    var db = await databaseFactoryFfi.openDatabase(dbPath,
        options:
            OpenDatabaseOptions(version: 1, onCreate: _createV1Schema));
    await Repository.upgradeSchema(db, 1, Repository.schemaVersion);

    final upgraded = <String, (Set<String>, Set<String>)>{};
    for (final table in _tables) {
      upgraded[table] =
          (await columnsOf(db, table), await indexesOf(db, table));
    }
    await db.close();

    db = await databaseFactoryFfi.openDatabase(p.join(sandbox.path, 'fresh.db'),
        options: OpenDatabaseOptions(
            version: Repository.schemaVersion,
            onCreate: Repository.createSchema));
    for (final table in _tables) {
      expect(upgraded[table]!.$1, await columnsOf(db, table),
          reason: '$table 列结构与全新安装不一致');
      expect(upgraded[table]!.$2, await indexesOf(db, table),
          reason: '$table 索引与全新安装不一致');
    }
    await db.close();
  });

  test('running the upgrade twice is harmless', () async {
    final db = await databaseFactoryFfi.openDatabase(dbPath,
        options:
            OpenDatabaseOptions(version: 1, onCreate: _createV1Schema));
    await Repository.upgradeSchema(db, 1, Repository.schemaVersion);
    await Repository.upgradeSchema(db, 1, Repository.schemaVersion);
    expect(
        await indexesOf(db, tableWatchedMedia),
        containsAll(['idx_watched_media_key', 'idx_watched_at']));
    await db.close();
  });
}

const _tables = [
  tableAccounts,
  tableSubscriptions,
  tableCachedMedia,
  tableHashtags,
  tableWatchedMedia,
];

/// The version-1 shape: only `accounts`, and without the column v2 adds.
Future<void> _createV1Schema(Database db, int version) async {
  await db.execute('CREATE TABLE $tableAccounts '
      '(id TEXT PRIMARY KEY, screen_name TEXT, auth_header TEXT)');
}
