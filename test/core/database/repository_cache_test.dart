import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xplay/core/database/entities.dart';
import 'package:xplay/core/database/repository.dart';
import 'package:xplay/core/models/tweet.dart';

/// Regression coverage for the cache/data-layer fixes: the date-parsing bug made
/// every cached row age-prunable (whole table wiped), the `ignore` conflict
/// algorithm froze broken rows forever, the candidate query marked rows it never
/// served, and a profile fetch rewrote subscription primary keys.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Future<List<Map<String, Object?>>> rows([String? where]) =>
      Repository.database.then((db) => db.query(tableCachedMedia, where: where));

  Tweet tweet(
    String id, {
    DateTime? createdAt,
    int? width,
    int? height,
    bool isLiked = false,
    int favoriteCount = 0,
    List<String> urls = const ['https://p.example/x.jpg'],
  }) =>
      Tweet(
        id: id,
        text: 'body $id',
        userHandle: '@user$id',
        mediaUrls: urls,
        thumbnailUrl: urls.isEmpty ? null : urls.first,
        isVideo: false,
        createdAt: createdAt,
        mediaWidth: width,
        mediaHeight: height,
        isLiked: isLiked,
        favoriteCount: favoriteCount,
      );

  group('cached_media upsert', () {
    setUp(() async {
      final db = await Repository.database;
      await db.delete(tableCachedMedia);
    });

    test('a later fetch repairs missing fields but keeps watch statistics',
        () async {
      await Repository.insertCachedMedia([tweet('t1')]);
      await Repository.markMediaAsPlayed('t1');

      // Same tweet fetched again, this time with dimensions and a like.
      await Repository.insertCachedMedia([
        tweet('t1', width: 1080, height: 1920, isLiked: true, favoriteCount: 42)
      ]);

      final row = (await rows("id = 't1'")).single;
      expect(row['media_width'], 1080,
          reason: 'the old ConflictAlgorithm.ignore froze the broken row');
      expect(row['media_height'], 1920);
      expect(row['played_count'], 1, reason: 'statistics must survive an upsert');
      expect(row['is_liked'], 1);
      expect(row['favorite_count'], 42);
      expect(row['inserted_at'], isNotNull);
    });

    test('a stale unfavourited fetch cannot undo a local like', () async {
      await Repository.insertCachedMedia([tweet('t2', isLiked: true)]);
      await Repository.insertCachedMedia([tweet('t2', isLiked: false)]);
      final row = (await rows("id = 't2'")).single;
      expect(row['is_liked'], 1);
    });
  });

  group('pruneCachedMedia', () {
    setUp(() async {
      final db = await Repository.database;
      await db.delete(tableCachedMedia);
    });

    test('keeps rows whose date could not be parsed', () async {
      await Repository.insertCachedMedia([tweet('undated')]);
      final db = await Repository.database;
      // Simulate a legacy row: neither created_at nor inserted_at.
      await db.rawInsert(
        "INSERT INTO $tableCachedMedia (id, text, user_handle, media_urls, "
        "is_video, created_at) VALUES ('legacynull','x','@u','[]',0,NULL)",
      );

      await Repository.pruneCachedMedia(threshold: 100000);

      final ids = (await rows()).map((r) => r['id']).toSet();
      expect(ids, contains('undated'));
      expect(ids, contains('legacynull'),
          reason: 'NULL created_at used to delete the entire cache table');
    });

    test('still deletes genuinely old rows', () async {
      await Repository.insertCachedMedia([
        tweet('old', createdAt: DateTime.now().subtract(const Duration(days: 30))),
        tweet('fresh', createdAt: DateTime.now()),
      ]);

      await Repository.pruneCachedMedia(threshold: 100000);

      final ids = (await rows()).map((r) => r['id']).toSet();
      expect(ids, isNot(contains('old')));
      expect(ids, contains('fresh'));
    });
  });

  group('candidate pool', () {
    setUp(() async {
      final db = await Repository.database;
      await db.delete(tableCachedMedia);
    });

    test('only the served slice is pushed to the back of the queue', () async {
      await Repository.insertCachedMedia(
          List.generate(8, (i) => tweet('c$i', urls: ['https://p/$i.jpg'])));

      final served =
          await Repository.getCachedMediaCandidates(2, avoidWatchedContent: false);

      expect(served.length, 2);
      final marked = await rows('last_suggested_at IS NOT NULL');
      expect(marked.length, 2,
          reason: 'the previous version marked all limit*2 fetched rows');
      final markedIds = marked.map((r) => r['id']).toSet();
      expect(markedIds, containsAll(served.map((t) => t.id)));
    });
  });

  group('subscriptions', () {
    setUp(() async {
      final db = await Repository.database;
      await db.delete(tableSubscriptions);
    });

    test('a profile fetch cannot rewrite the primary key or duplicate the row',
        () async {
      await Repository.mergeSubscriptions([
        Subscription(id: 'handle_a', screenName: 'Handle_A', name: 'A'),
      ]);

      // Opening the profile resolves rest_id and persists it for subscribers.
      await Repository.persistProfileIfSubscribed(
        Subscription(
            id: '9988776655',
            screenName: 'handle_a',
            name: 'A renamed',
            profileImageUrl: 'https://p/a.jpg',
            followersCount: 10),
      );

      var db = await Repository.database;
      var subs = await db.query(tableSubscriptions);
      expect(subs.length, 1, reason: 'the old code left an orphan row behind');
      expect(subs.single['id'], 'handle_a',
          reason: 'the primary key must not be rewritten by an update');
      expect(subs.single['name'], 'A renamed');
      expect(subs.single['profile_synced_at'], isNotNull);

      // A follow-list sync afterwards uses screen_name as id again.
      await Repository.mergeSubscriptions([
        Subscription(id: 'handle_a', screenName: 'Handle_A', name: 'A renamed'),
      ]);
      db = await Repository.database;
      subs = await db.query(tableSubscriptions);
      expect(subs.length, 1);
    });

    test('toMap keeps profile_synced_at', () async {
      final sub = Subscription(
          id: 'x',
          screenName: 'x',
          name: 'X',
          profileSyncedAt: 12345);
      await Repository.insertSubscription(sub);
      final db = await Repository.database;
      final row = (await db.query(tableSubscriptions)).single;
      expect(row['profile_synced_at'], 12345,
          reason: 'an omitted column reset the sync stamp to NULL');
    });
  });

  group('watched list', () {
    setUp(() async {
      final db = await Repository.database;
      await db.delete(tableCachedMedia);
      await db.delete(tableWatchedMedia);
    });

    test('purgeSeenMetadata actually un-hides watched content', () async {
      await Repository.insertCachedMedia([tweet('w1')]);
      await Repository.markMediaAsPlayed('w1');
      await Repository.markWatched('w1', mediaKey: 'key:w1');
      expect((await Repository.getWatchedIdentifiers()).contains('w1'), isTrue);

      await Repository.purgeSeenMetadata();

      expect(await Repository.getWatchedIdentifiers(), isEmpty);
      final row = (await rows("id = 'w1'")).single;
      expect(row['played_count'], 0);
    });

    test('purgeSeenMetadata can keep the watched list when asked', () async {
      await Repository.markWatched('w2');
      await Repository.purgeSeenMetadata(clearWatchedList: false);
      expect((await Repository.getWatchedIdentifiers()).contains('w2'), isTrue);
    });

    /// The doc's verification ask: what does a ten-thousand-row watched list
    /// actually cost, and does SQL-side filtering agree with the old
    /// "load everything into a Set" path? Numbers are printed, not asserted,
    /// because CI machines vary; the equal-result assertions are the guard.
    test('a 10k watched table filters a page in SQL, reads bounded', () async {
      final db = await Repository.database;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var i = 0; i < 10000; i++) {
          batch.insert(tableWatchedMedia, {
            'id': 'seed_$i',
            'media_key': 'key_$i',
            'watched_at': 1700000000000 + i,
          });
        }
        await batch.commit(noResult: true);
      });

      // A page bigger than one SQL chunk, half of it already watched.
      final page = <Tweet>[
        for (var i = 0; i < 250; i++)
          tweet('seed_$i', urls: ['https://p.example/$i.jpg']),
        for (var i = 0; i < 250; i++)
          tweet('fresh_$i', urls: ['https://p.example/f$i.jpg']),
      ];

      final t0 = Stopwatch()..start();
      final fullSet = await Repository.getWatchedIdentifiers();
      t0.stop();
      final t1 = Stopwatch()..start();
      final boundedSet = await Repository.getWatchedIdentifiers(limit: 2000);
      t1.stop();
      final t2 = Stopwatch()..start();
      final bySql = await Repository.filterUnwatchedInDb(page);
      t2.stop();
      final t3 = Stopwatch()..start();
      final byMemory = Repository.filterUnwatched(page, fullSet);
      t3.stop();

      expect(fullSet.length, 20000, reason: 'id + media_key per row');
      expect(boundedSet.length, 4000);
      expect(boundedSet.contains('seed_9999'), isTrue,
          reason: 'a limited read must return the most recent rows');
      expect(boundedSet.contains('seed_0'), isFalse);
      expect(bySql.length, 250);
      expect(bySql.map((t) => t.id).toSet(), byMemory.map((t) => t.id).toSet(),
          reason: 'SQL filtering must agree with the in-memory Set');

      debugPrint('watched_media @10k rows: full '
          '${t0.elapsedMicroseconds / 1000}ms, bounded(2000) ${t1.elapsedMicroseconds / 1000}ms, '
          'SQL filter of a 500-item page ${t2.elapsedMicroseconds / 1000}ms, '
          'in-memory filter of the same page ${t3.elapsedMicroseconds / 1000}ms');
    });
  });
}
