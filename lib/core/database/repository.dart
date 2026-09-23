import 'dart:async';

import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'entities.dart';
import '../models/tweet.dart';
import '../../features/settings/settings_provider.dart';

const String tableAccounts = 'accounts';
const String tableSubscriptions = 'subscriptions';
const String tableCachedMedia = 'cached_media';
const String tableHashtags = 'hashtags';
const String tableWatchedMedia = 'watched_media';

class Repository {
  static Database? _database;
  static Future<Database>? _opening;

  /// 构建"只保留选中类型"的 SQL 过滤条件。
  /// 返回 null 表示不过滤（未选任何类型 = 显示全部）。
  static String? _mediaFilterClause(Set<MediaFilter>? filters) {
    if (filters == null || filters.isEmpty) return null;
    final conditions = <String>[];
    for (final filter in filters) {
      switch (filter) {
        case MediaFilter.video:
          conditions.add('is_video = 1');
          break;
        case MediaFilter.image:
          conditions.add("(media_urls != '[]' AND is_video = 0)");
          break;
        case MediaFilter.text:
          conditions.add("media_urls = '[]'");
          break;
      }
    }
    if (conditions.isEmpty) return null;
    return '(${conditions.join(' OR ')})';
  }

  /// Single-flight open: two concurrent callers used to each run
  /// `openDatabase`, leaking one handle (and, on the in-memory test database,
  /// handing each caller a *different* empty database).
  static Future<Database> get database async {
    final opened = _database;
    if (opened != null) return opened;
    return _opening ??= _initDatabase().then((db) {
      _database = db;
      _opening = null;
      return db;
    }, onError: (Object error, StackTrace stack) {
      _opening = null;
      throw error;
    });
  }

  static Future<Database> _initDatabase() async {
    String path;
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      path = inMemoryDatabasePath;
    } else {
      path = join(await getDatabasesPath(), 'xflow.db');
    }
    return await openDatabase(
      path,
      version: schemaVersion,
      onCreate: createSchema,
      onUpgrade: upgradeSchema,
    );
  }

  /// Current schema version. Migrations are listed in
  /// `docs/database_migrations.md`; add one entry per version there and a
  /// matching `if (oldVersion < N)` branch below.
  @visibleForTesting
  static const int schemaVersion = 14;

  /// Creates every table and index for a fresh install. Exposed so migration
  /// tests can build a specific starting schema.
  @visibleForTesting
  static Future<void> createSchema(Database db, int version) async {
    await db.execute(
      'CREATE TABLE $tableAccounts (id TEXT PRIMARY KEY, screen_name TEXT, rest_id TEXT, auth_header TEXT)',
    );
    await db.execute(
      'CREATE TABLE $tableSubscriptions (id TEXT PRIMARY KEY, screen_name TEXT, name TEXT, profile_image_url TEXT, description TEXT, followers_count INTEGER, following_count INTEGER, profile_synced_at INTEGER)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_subs_screen ON $tableSubscriptions (LOWER(screen_name))',
    );
    await db.execute(
      'CREATE TABLE $tableHashtags (tag TEXT PRIMARY KEY, added_at INTEGER)',
    );
    await db.execute('''
          CREATE TABLE $tableCachedMedia (
            id TEXT PRIMARY KEY,
            text TEXT,
            user_handle TEXT,
            user_avatar_url TEXT,
            media_key TEXT,
            media_urls TEXT,
            thumbnail_url TEXT,
            is_video INTEGER,
            created_at INTEGER,
            played_count INTEGER DEFAULT 0,
            last_played_at INTEGER,
            duration_watched INTEGER DEFAULT 0,
            last_suggested_at INTEGER,
            media_width INTEGER,
            media_height INTEGER,
            inserted_at INTEGER,
            is_liked INTEGER DEFAULT 0,
            favorite_count INTEGER DEFAULT 0,
            reply_count INTEGER DEFAULT 0
          )
        ''');
    await db.execute(
      'CREATE INDEX idx_discovery_lookup ON $tableCachedMedia (played_count, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_media_key ON $tableCachedMedia (media_key)',
    );
    await db.execute(
      'CREATE INDEX idx_suggested ON $tableCachedMedia (last_suggested_at)',
    );
    await db.execute(
      'CREATE INDEX idx_created_at ON $tableCachedMedia (created_at DESC)',
    );
    await db.execute('''
          CREATE TABLE $tableWatchedMedia (
            id TEXT PRIMARY KEY,
            media_key TEXT,
            watched_at INTEGER
          )
        ''');
    // Indexes on watched_media must come after the table exists.
    await db.execute(
      'CREATE INDEX idx_watched_media_key ON $tableWatchedMedia (media_key)',
    );
    await db.execute(
      'CREATE INDEX idx_watched_at ON $tableWatchedMedia (watched_at)',
    );
  }

  /// Migrates an existing database from [oldVersion] to [newVersion].
  @visibleForTesting
  static Future<void> upgradeSchema(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _addColumnIfMissing(db, tableAccounts, 'rest_id', 'TEXT');
    }
    if (oldVersion < 3) {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS $tableSubscriptions (id TEXT PRIMARY KEY, screen_name TEXT, name TEXT, profile_image_url TEXT)',
      );
    }
    if (oldVersion < 4) {
      await _addColumnIfMissing(db, tableSubscriptions, 'description', 'TEXT');
      await _addColumnIfMissing(
          db, tableSubscriptions, 'followers_count', 'INTEGER');
      await _addColumnIfMissing(
          db, tableSubscriptions, 'following_count', 'INTEGER');
    }
    if (oldVersion < 5) {
      await db.execute('''
            CREATE TABLE IF NOT EXISTS $tableCachedMedia (
              id TEXT PRIMARY KEY,
              text TEXT,
              user_handle TEXT,
              user_avatar_url TEXT,
              media_urls TEXT,
              thumbnail_url TEXT,
              is_video INTEGER,
              created_at INTEGER,
              played_count INTEGER DEFAULT 0,
              last_played_at INTEGER,
              duration_watched INTEGER DEFAULT 0
            )
          ''');
    }
    if (oldVersion < 6) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_discovery_lookup ON $tableCachedMedia (played_count, created_at DESC)',
      );
    }
    if (oldVersion < 7) {
      await _addColumnIfMissing(db, tableCachedMedia, 'media_key', 'TEXT');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_media_key ON $tableCachedMedia (media_key)');
    }
    if (oldVersion < 8) {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS $tableHashtags (tag TEXT PRIMARY KEY, added_at INTEGER)',
      );
    }
    if (oldVersion < 9) {
      await _addColumnIfMissing(
          db, tableCachedMedia, 'last_suggested_at', 'INTEGER');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_suggested ON $tableCachedMedia (last_suggested_at)');
    }
    if (oldVersion < 10) {
      await db.execute('''
            CREATE TABLE IF NOT EXISTS $tableWatchedMedia (
              id TEXT PRIMARY KEY,
              media_key TEXT,
              watched_at INTEGER
            )
          ''');
    }
    if (oldVersion < 11) {
      await _addColumnIfMissing(db, tableCachedMedia, 'media_width', 'INTEGER');
      await _addColumnIfMissing(
          db, tableCachedMedia, 'media_height', 'INTEGER');
    }
    if (oldVersion < 12) {
      await _addColumnIfMissing(
          db, tableSubscriptions, 'profile_synced_at', 'INTEGER');
    }
    if (oldVersion < 13) {
      // Like state + a guaranteed-present timestamp, so pruning can stop
      // treating "no date" as "garbage" (it used to delete every row).
      await _addColumnIfMissing(db, tableCachedMedia, 'inserted_at', 'INTEGER');
      await _addColumnIfMissing(
          db, tableCachedMedia, 'is_liked', 'INTEGER DEFAULT 0');
      await _addColumnIfMissing(
          db, tableCachedMedia, 'favorite_count', 'INTEGER DEFAULT 0');
      await _addColumnIfMissing(
          db, tableCachedMedia, 'reply_count', 'INTEGER DEFAULT 0');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_created_at ON $tableCachedMedia (created_at DESC)',
      );
      // The same handle could be stored twice: once keyed by screen_name
      // (follow-list sync) and once keyed by rest_id (profile fetch /
      // follow button). Collapse to one row per handle, then enforce it.
      await db.execute(
        'DELETE FROM $tableSubscriptions WHERE rowid NOT IN '
        '(SELECT MAX(rowid) FROM $tableSubscriptions GROUP BY LOWER(screen_name))',
      );
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_subs_screen '
        'ON $tableSubscriptions (LOWER(screen_name))',
      );
    }
    if (oldVersion < 14) {
      await _migrateV14(db);
    }
  }

  /// v13 -> v14: index the `watched_media` lookups and bound its growth.
  ///
  /// Every watched item is appended and never removed, so the table grew for the
  /// lifetime of the install and `getWatchedIdentifiers()` loaded all of it into
  /// memory on each feed request.
  static Future<void> _migrateV14(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_watched_media_key ON $tableWatchedMedia (media_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_watched_at ON $tableWatchedMedia (watched_at)',
    );
  }

  /// `ALTER TABLE ... ADD COLUMN` throws when the column is already there,
  /// which aborts the rest of the migration. Add only when missing.
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((row) => (row['name'] as String?) == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  static Future<void> addHashtag(String tag) async {
    final db = await database;
    await db.insert(
      tableHashtags,
      {'tag': tag, 'added_at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<String>> getHashtags() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query(tableHashtags, orderBy: 'added_at DESC');
    return List.generate(maps.length, (i) => maps[i]['tag'] as String);
  }

  static Future<void> deleteHashtag(String tag) async {
    final db = await database;
    await db.delete(tableHashtags, where: 'tag = ?', whereArgs: [tag]);
  }

  static Future<void> insertAccount(Account account) async {
    final db = await database;
    await db.insert(
      tableAccounts,
      account.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<Account>> getAccounts() async {
    final db = await database;
    // Newest row first: `accounts.first` is the account the app signs in with,
    // and an unordered query returned the oldest (usually a stale) row.
    final List<Map<String, dynamic>> maps =
        await db.query(tableAccounts, orderBy: 'rowid DESC');
    return List.generate(maps.length, (i) {
      return Account.fromMap(maps[i]);
    });
  }

  /// Keeps exactly one stored account (the newest). The app has no real
  /// multi-account UI, and leftover rows made `init()` sign in with a stale
  /// session after a re-login.
  static Future<void> replaceAccount(Account account) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(tableAccounts);
      await txn.insert(tableAccounts, account.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static Future<void> insertSubscription(Subscription sub) async {
    final db = await database;
    await db.insert(
      tableSubscriptions,
      sub.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> insertSubscriptions(List<Subscription> subs) async {
    final db = await database;
    final batch = db.batch();
    for (var sub in subs) {
      batch.insert(tableSubscriptions, sub.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Subscription>> getSubscriptions() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(tableSubscriptions);
    return List.generate(maps.length, (i) {
      return Subscription.fromMap(maps[i]);
    });
  }

  static Future<void> clearSubscriptions() async {
    final db = await database;
    await db.delete(tableSubscriptions);
  }

  static Map<String, dynamic> _subscriptionWriteMap(Subscription sub) =>
      sub.toMap();

  /// Inserts or updates a subscription while preserving any locally cached
  /// non-null fields that the incoming data does not carry (merge, not replace).
  static Future<void> mergeSubscription(Subscription newSub) async {
    final db = await database;
    final existing = await db.query(
      tableSubscriptions,
      where: 'id = ?',
      whereArgs: [newSub.id],
      limit: 1,
    );

    Subscription merged = newSub;
    if (existing.isNotEmpty) {
      final old = Subscription.fromMap(existing.first);
      merged = Subscription(
        id: newSub.id,
        screenName: newSub.screenName,
        name: newSub.name,
        profileImageUrl: newSub.profileImageUrl ?? old.profileImageUrl,
        description: newSub.description ?? old.description,
        followersCount: newSub.followersCount ?? old.followersCount,
        followingCount: newSub.followingCount ?? old.followingCount,
        profileSyncedAt: old.profileSyncedAt,
      );
    }

    await db.insert(
      tableSubscriptions,
      _subscriptionWriteMap(merged),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Batch variant of [mergeSubscription].
  static Future<void> mergeSubscriptions(List<Subscription> subs) async {
    final db = await database;
    final existingMaps = await db.query(tableSubscriptions);
    final existingByScreen = <String, Subscription>{};
    for (final m in existingMaps) {
      final s = Subscription.fromMap(m);
      existingByScreen[s.screenName.toLowerCase()] = s;
    }

    final batch = db.batch();
    for (final sub in subs) {
      final old = existingByScreen[sub.screenName.toLowerCase()];
      final merged = old == null
          ? sub
          : Subscription(
              id: sub.id,
              screenName: sub.screenName,
              name: sub.name,
              profileImageUrl: sub.profileImageUrl ?? old.profileImageUrl,
              description: sub.description ?? old.description,
              followersCount: sub.followersCount ?? old.followersCount,
              followingCount: sub.followingCount ?? old.followingCount,
              profileSyncedAt: old.profileSyncedAt,
            );
      batch.insert(tableSubscriptions, _subscriptionWriteMap(merged),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Updates an existing subscription row with fresh profile data (e.g. from
  /// [fetchProfile]). Only touches rows that already exist — never inserts.
  static Future<void> persistProfileIfSubscribed(Subscription sub) async {
    final db = await database;
    final exists = await db.rawQuery(
      'SELECT 1 FROM $tableSubscriptions WHERE LOWER(screen_name) = ? LIMIT 1',
      [sub.screenName.toLowerCase()],
    );
    if (exists.isEmpty) return;
    final content = _subscriptionWriteMap(sub)
      ..remove('id') // Never rewrite the primary key: doing so used to orphan
      // the old row, and the next merge then inserted a duplicate subscription.
      ..['profile_synced_at'] = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      tableSubscriptions,
      content,
      where: 'LOWER(screen_name) = ?',
      whereArgs: [sub.screenName.toLowerCase()],
    );
  }

  /// Reconciles local subscriptions with a remote following list.
  /// Always upserts the remote entries (merged). When [deleteMissing] is true,
  /// local entries not present in [remote] are removed. [deleteMissing] must
  /// only be true when the remote list is known to be complete (otherwise a
  /// partial fetch would wrongly delete valid subscriptions).
  static Future<void> syncFollowingFromList(List<Subscription> remote,
      {required bool deleteMissing}) async {
    await mergeSubscriptions(remote);

    if (deleteMissing && remote.isNotEmpty) {
      final db = await database;
      final names = remote.map((s) => s.screenName.toLowerCase()).toList();
      final placeholders = List.filled(names.length, '?').join(',');
      await db.delete(
        tableSubscriptions,
        where: 'LOWER(screen_name) NOT IN ($placeholders)',
        whereArgs: names,
      );
    }
  }

  /// Upserts fetched tweets.
  ///
  /// Content columns take the newest values, so a row that was first stored
  /// without dimensions/thumbnail/date gets repaired on the next sighting
  /// (`ConflictAlgorithm.ignore` used to freeze the broken row forever). Watch
  /// statistics (`played_count`, `last_played_at`, `duration_watched`,
  /// `last_suggested_at`) are deliberately absent from the SET list so they
  /// survive, and like state only moves towards "liked" so a stale
  /// `favorited: false` from one endpoint cannot wipe a like the user just made.
  static Future<void> insertCachedMedia(List<Tweet> tweets) async {
    if (tweets.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    const sql = '''
      INSERT INTO $tableCachedMedia (
        id, text, user_handle, user_avatar_url, media_key, media_urls,
        thumbnail_url, is_video, created_at, media_width, media_height,
        inserted_at, is_liked, favorite_count, reply_count)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        text = excluded.text,
        user_handle = excluded.user_handle,
        user_avatar_url = COALESCE(excluded.user_avatar_url, user_avatar_url),
        media_key = COALESCE(excluded.media_key, media_key),
        media_urls = excluded.media_urls,
        thumbnail_url = COALESCE(excluded.thumbnail_url, thumbnail_url),
        is_video = excluded.is_video,
        created_at = COALESCE(excluded.created_at, created_at),
        media_width = COALESCE(excluded.media_width, media_width),
        media_height = COALESCE(excluded.media_height, media_height),
        inserted_at = excluded.inserted_at,
        is_liked = MAX(excluded.is_liked, IFNULL(is_liked, 0)),
        favorite_count = MAX(excluded.favorite_count, IFNULL(favorite_count, 0)),
        reply_count = MAX(excluded.reply_count, IFNULL(reply_count, 0))
    ''';
    final batch = db.batch();
    for (final tweet in tweets) {
      batch.rawInsert(sql, [
        tweet.id,
        tweet.text,
        tweet.userHandle,
        tweet.userAvatarUrl,
        tweet.mediaKey,
        jsonEncode(tweet.mediaUrls),
        tweet.thumbnailUrl,
        tweet.isVideo ? 1 : 0,
        tweet.createdAt?.millisecondsSinceEpoch,
        tweet.mediaWidth,
        tweet.mediaHeight,
        now,
        tweet.isLiked ? 1 : 0,
        tweet.favoriteCount,
        tweet.replyCount,
      ]);
    }
    await batch.commit(noResult: true);
  }

  /// Records the like state the user just produced locally, so it survives the
  /// item being re-read from the cache instead of flipping back to "0 likes".
  static Future<void> updateLikeState(String id,
      {required bool isLiked, int? favoriteCount}) async {
    final db = await database;
    await db.update(
      tableCachedMedia,
      {
        'is_liked': isLiked ? 1 : 0,
        if (favoriteCount != null) 'favorite_count': favoriteCount,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Shared row -> [Tweet] mapping. A corrupt `media_urls` blob must not take
  /// the whole query down, so it degrades to "no media".
  static Tweet _tweetFromRow(Map<String, dynamic> row) {
    List<String> urls = const [];
    final raw = row['media_urls'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        urls = List<String>.from(jsonDecode(raw) as List);
      } catch (e) {
        urls = const [];
      }
    }
    final createdAtMs = row['created_at'] as int? ?? row['inserted_at'] as int?;
    return Tweet(
      id: row['id'] as String,
      text: (row['text'] as String?) ?? '',
      userHandle: (row['user_handle'] as String?) ?? '@Unknown',
      userAvatarUrl: row['user_avatar_url'] as String?,
      mediaKey: row['media_key'] as String?,
      mediaUrls: urls,
      thumbnailUrl: row['thumbnail_url'] as String?,
      isVideo: (row['is_video'] as int? ?? 0) == 1,
      createdAt: createdAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
      isLiked: (row['is_liked'] as int? ?? 0) == 1,
      favoriteCount: row['favorite_count'] as int? ?? 0,
      replyCount: row['reply_count'] as int? ?? 0,
      mediaWidth: row['media_width'] as int?,
      mediaHeight: row['media_height'] as int?,
    );
  }

  static Future<List<Tweet>> getUnplayedCachedMedia(int limit,
      {Set<MediaFilter>? filters}) async {
    final db = await database;

    // Use a subquery to exclude any tweets whose media_key has been played elsewhere
    String whereClause = 'played_count = 0';
    whereClause +=
        ' AND (media_key IS NULL OR media_key NOT IN (SELECT media_key FROM $tableCachedMedia WHERE played_count > 0 AND media_key IS NOT NULL))';

    List<dynamic> whereArgs = [];

    final filterClause = _mediaFilterClause(filters);
    if (filterClause != null) {
      whereClause += ' AND $filterClause';
    }

    final List<Map<String, dynamic>> maps = await db.query(
      tableCachedMedia,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'last_suggested_at ASC',
      limit: limit * 2,
    );

    if (maps.isEmpty) return [];

    // Shuffle first and serve `limit` rows, marking only *those* as suggested.
    // The previous version marked all `limit * 2` fetched rows, so the half
    // that was never shown got pushed to the back of the queue for nothing.
    final results = maps.map(_tweetFromRow).toList()..shuffle();
    final served = results.take(limit).toList();
    if (served.isNotEmpty) {
      await markAsSuggested(served.map((t) => t.id).toList());
    }
    return served;
  }

  static Future<List<Tweet>> getCachedMediaCandidates(
    int limit, {
    required bool avoidWatchedContent,
    Set<MediaFilter>? filters,
  }) async {
    if (avoidWatchedContent) {
      return getUnplayedCachedMedia(limit, filters: filters);
    }

    final db = await database;
    String? whereClause = _mediaFilterClause(filters);
    List<dynamic>? whereArgs;

    final List<Map<String, dynamic>> maps = await db.query(
      tableCachedMedia,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'last_suggested_at ASC',
      limit: limit * 2, // Fetch more to allow for shuffling
    );

    // Same as above: only the rows actually handed to the caller are marked.
    final results = maps.map(_tweetFromRow).toList()..shuffle();
    final served = results.take(limit).toList();
    if (served.isNotEmpty) {
      await markAsSuggested(served.map((t) => t.id).toList());
    }

    return served;
  }

  static Future<void> markAsSuggested(List<String> ids) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final id in ids) {
      batch.update(
        tableCachedMedia,
        {'last_suggested_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  static Future<Map<String, int>> getPlayedCountsByUser() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT LOWER(REPLACE(user_handle, '@', '')) AS normalized_handle,
             SUM(played_count) AS total_played
      FROM $tableCachedMedia
      GROUP BY normalized_handle
    ''');

    final out = <String, int>{};
    for (final row in rows) {
      final handle = row['normalized_handle'] as String?;
      if (handle == null || handle.isEmpty) continue;
      out[handle] = (row['total_played'] as int?) ?? 0;
    }
    return out;
  }

  static Future<List<Tweet>> getUserCachedMedia(String userHandle, int limit,
      {Set<MediaFilter>? filters}) async {
    final db = await database;
    final rawHandle =
        userHandle.startsWith('@') ? userHandle.substring(1) : userHandle;
    final normalizedHandle = rawHandle.toLowerCase();

    String whereClause = "LOWER(REPLACE(user_handle, '@', '')) = ?";
    List<dynamic> whereArgs = [normalizedHandle];

    final filterClause = _mediaFilterClause(filters);
    if (filterClause != null) {
      whereClause += ' AND $filterClause';
    }

    final List<Map<String, dynamic>> maps = await db.query(
      tableCachedMedia,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
    );

    return maps.map(_tweetFromRow).toList();
  }

  static Future<List<Tweet>> getHashtagCachedMedia(String hashtag, int limit,
      {Set<MediaFilter>? filters}) async {
    final db = await database;

    String whereClause = 'text LIKE ?';
    List<dynamic> whereArgs = ['%$hashtag%'];

    final filterClause = _mediaFilterClause(filters);
    if (filterClause != null) {
      whereClause += ' AND $filterClause';
    }

    final List<Map<String, dynamic>> maps = await db.query(
      tableCachedMedia,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
    );

    return maps.map(_tweetFromRow).toList();
  }

  static Future<void> markMediaAsPlayed(String id) async {
    final db = await database;
    await db.rawUpdate('''
      UPDATE $tableCachedMedia 
      SET played_count = played_count + 1, last_played_at = ? 
      WHERE id = ?
    ''', [DateTime.now().millisecondsSinceEpoch, id]);
  }

  /// 标记一条内容为已看。写入独立的 watched_media 表(与 cached_media 隔离)。
  /// 话题流只调这个;主页在保留 markMediaAsPlayed 的同时也调这个,保证跨 feed 一致。
  static Future<void> markWatched(String id, {String? mediaKey}) async {
    final db = await database;
    await db.insert(
      tableWatchedMedia,
      {
        'id': id,
        'media_key': mediaKey,
        'watched_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 返回所有已看的标识符集合(id + 非空 media_key),用于过滤。
  ///
  /// [limit] keeps the in-memory set bounded: the table only ever grows, and
  /// this used to be loaded in full on every feed request. Rows are ordered
  /// newest-first, so a cap only drops the oldest watched items — which
  /// [pruneWatchedMedia] deletes anyway.
  static Future<Set<String>> getWatchedIdentifiers({int? limit}) async {
    final db = await database;
    final maps = await db.query(
      tableWatchedMedia,
      columns: ['id', 'media_key'],
      orderBy: 'watched_at DESC',
      limit: limit,
    );
    final set = <String>{};
    for (final m in maps) {
      set.add(m['id'] as String);
      final mk = m['media_key'];
      if (mk != null) set.add(mk as String);
    }
    return set;
  }

  /// SQL-side variant of [filterUnwatched] for a known page of tweets.
  ///
  /// Costs one indexed `IN` lookup over the ids we actually have instead of
  /// materialising the whole watched list in Dart. The lookup is chunked:
  /// Android ships SQLite 3.22 on API 29, which caps a statement at 999 bind
  /// variables, and each tweet contributes up to two.
  static Future<List<Tweet>> filterUnwatchedInDb(List<Tweet> tweets) async {
    if (tweets.isEmpty) return tweets;
    final db = await database;
    const chunkSize = 400;
    final watched = <String>{};

    for (var from = 0; from < tweets.length; from += chunkSize) {
      final chunk =
          tweets.sublist(from, (from + chunkSize).clamp(0, tweets.length));
      final ids = chunk.map((t) => t.id).toList();
      final mediaKeys =
          chunk.map((t) => t.mediaKey).whereType<String>().toList();
      final clauses = <String>[];
      final args = <Object?>[];

      if (ids.isNotEmpty) {
        clauses.add('id IN (${List.filled(ids.length, '?').join(',')})');
        args.addAll(ids);
      }
      if (mediaKeys.isNotEmpty) {
        clauses.add(
            'media_key IN (${List.filled(mediaKeys.length, '?').join(',')})');
        args.addAll(mediaKeys);
      }
      if (clauses.isEmpty) continue;

      final rows = await db.rawQuery(
        'SELECT id, media_key FROM $tableWatchedMedia WHERE ${clauses.join(' OR ')}',
        args,
      );
      for (final r in rows) {
        watched.add(r['id'] as String);
        final mk = r['media_key'];
        if (mk != null) watched.add(mk as String);
      }
    }
    return filterUnwatched(tweets, watched);
  }

  /// Caps `watched_media` at the most recent [keepLimit] rows.
  ///
  /// Without this the table grows for the lifetime of the install while being
  /// read on every feed request.
  static Future<int> pruneWatchedMedia(
      {int keepLimit = _watchedKeepRows}) async {
    final db = await database;
    return db.rawDelete(
      'DELETE FROM $tableWatchedMedia WHERE watched_at < '
      '(SELECT watched_at FROM $tableWatchedMedia ORDER BY watched_at DESC '
      'LIMIT 1 OFFSET ?)',
      [keepLimit],
    );
  }

  /// How many watched entries are kept (and read back) by default.
  static const int _watchedKeepRows = 20000;

  /// Filter-aware convenience for callers: [enabled] carries the user's
  /// "避开已看内容" switch, so a page of tweets can be cleaned without the caller
  /// first materialising the watched set.
  static Future<List<Tweet>> filterWatched(List<Tweet> tweets,
      {required bool enabled}) async {
    if (!enabled || tweets.isEmpty) return tweets;
    return filterUnwatchedInDb(tweets);
  }

  /// 从列表中剔除已看项。media_key 为 null 时只按 id 判定。
  static List<Tweet> filterUnwatched(List<Tweet> tweets, Set<String> watched) {
    if (watched.isEmpty) return tweets;
    return tweets.where((t) {
      if (watched.contains(t.id)) return false;
      if (t.mediaKey != null && watched.contains(t.mediaKey)) return false;
      return true;
    }).toList();
  }

  static Future<int> getMediaPlayedCount(String id) async {
    final db = await database;
    final maps = await db.query(
      tableCachedMedia,
      columns: ['played_count'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isNotEmpty) {
      return (maps.first['played_count'] as int?) ?? 0;
    }
    return 0;
  }

  static Future<int> getUserPlayedCount(String userHandle) async {
    final db = await database;
    final normalized = userHandle.replaceAll('@', '').toLowerCase();
    final rows = await db.rawQuery('''
      SELECT SUM(played_count) AS total_played
      FROM $tableCachedMedia
      WHERE LOWER(REPLACE(user_handle, '@', '')) = ?
    ''', [normalized]);

    if (rows.isNotEmpty) {
      return (rows.first['total_played'] as int?) ?? 0;
    }
    return 0;
  }

  static Future<int> getCachedMediaCount() async {
    final db = await database;
    final countSq =
        await db.rawQuery('SELECT COUNT(*) as count FROM $tableCachedMedia');
    return countSq.first['count'] as int;
  }

  static Future<void> pruneCachedMedia({int threshold = 5000}) async {
    final db = await database;

    // 1. Delete by age: anything older than 7 days. `created_at IS NULL` used
    // to be deleted here as well, which (together with the date-parsing bug)
    // wiped the entire cache table on every prune. Rows with no usable date are
    // only ever removed by the count limit below now.
    final sevenDaysAgo =
        DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    await db.execute(
      '''
      DELETE FROM $tableCachedMedia
      WHERE COALESCE(created_at, inserted_at) IS NOT NULL
        AND COALESCE(created_at, inserted_at) < ?
      ''',
      [sevenDaysAgo],
    );

    // 2. Delete by count: If still over threshold, delete oldest watched items
    final countSq =
        await db.rawQuery('SELECT COUNT(*) as count FROM $tableCachedMedia');
    final count = countSq.first['count'] as int;

    if (count > threshold) {
      final deleteCount = count - threshold;
      await db.execute('''
        DELETE FROM $tableCachedMedia 
        WHERE id IN (
          SELECT id FROM $tableCachedMedia 
          ORDER BY COALESCE(last_played_at, created_at, inserted_at) ASC 
          LIMIT ?
        )
      ''', [deleteCount]);
    }

    // watched_media only ever grew, and it is consulted on every feed request.
    await pruneWatchedMedia();
  }

  static Future<void> purgeSeenMetadata({bool clearWatchedList = true}) async {
    final db = await database;
    // `watched_media` is what actually hides content (see [filterUnwatched]).
    // Deleting only `played_count > 0` rows used to leave every already-seen
    // item hidden, so the button appeared to do nothing.
    if (clearWatchedList) {
      await db.delete(tableWatchedMedia);
    }
    await db.update(
      tableCachedMedia,
      {'played_count': 0, 'last_played_at': null},
    );
  }

  /// Number of entries hidden as "already watched" (for the settings screen).
  static Future<int> getWatchedCount() async {
    final db = await database;
    final rows =
        await db.rawQuery('SELECT COUNT(*) AS count FROM $tableWatchedMedia');
    return (rows.first['count'] as int?) ?? 0;
  }

  /// Closes and deletes the local database. Used by the startup error screen,
  /// where a corrupt/half-migrated file otherwise left the app unusable.
  static Future<void> resetLocalData() async {
    final db = _database;
    _database = null;
    _opening = null;
    if (db != null) {
      try {
        await db.close();
      } catch (_) {}
    }
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    final path = join(await getDatabasesPath(), 'xflow.db');
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final file = File('$path$suffix');
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  static Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) {
      // A cached open-in-flight future would otherwise hand back the closed
      // handle to the next caller.
      try {
        await opening;
      } catch (_) {}
    }
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
