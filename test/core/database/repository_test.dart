import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xplay/core/database/repository.dart';
import 'package:xplay/core/models/tweet.dart';
import 'package:xplay/features/settings/settings_provider.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Repository Caching and Pruning Tests', () {
    setUp(() async {
      final db = await Repository.database;
      await db.delete(tableCachedMedia);
    });

    test('insertCachedMedia stores tweets correctly', () async {
      final now = DateTime.now();
      final tweets = [
        Tweet(
          id: 'repo_test_1',
          text: 'Test Tweet 1',
          userHandle: 'user1',
          mediaUrls: ['https://test.com/1.mp4'],
          isVideo: true,
          createdAt: now.subtract(const Duration(minutes: 5)),
        ),
        Tweet(
          id: 'repo_test_2',
          text: 'Test Tweet 2',
          userHandle: 'user2',
          mediaUrls: ['https://test.com/2.jpg'],
          isVideo: false,
          createdAt: now,
        ),
      ];

      await Repository.insertCachedMedia(tweets);

      // We check directly in DB because getUnplayedCachedMedia uses RANDOM()
      final db = await Repository.database;
      final results =
          await db.query(tableCachedMedia, where: "id LIKE 'repo_test_%'");

      expect(results.length, 2);
      expect(results.any((r) => r['id'] == 'repo_test_1'), true);
      expect(results.any((r) => r['id'] == 'repo_test_2'), true);
    });

    test('markMediaAsPlayed updates played_count and last_played_at', () async {
      final tweet = Tweet(
        id: 'play_test_unique',
        text: 'To be played',
        userHandle: 'tester',
        mediaUrls: [],
        createdAt: DateTime.now(),
      );

      await Repository.insertCachedMedia([tweet]);
      await Repository.markMediaAsPlayed('play_test_unique');

      final db = await Repository.database;
      final result = await db.query(tableCachedMedia,
          where: 'id = ?', whereArgs: ['play_test_unique']);
      expect(result.first['played_count'], 1);
      expect(result.first['last_played_at'], isNotNull);
    });

    test('getUserCachedMedia matches handles case-insensitively', () async {
      final tweet = Tweet(
        id: 'case_test_unique',
        text: 'Mixed case handle',
        userHandle: '@MixedCaseUser',
        mediaUrls: ['https://test.com/case.jpg'],
        createdAt: DateTime(2023, 1, 1),
      );

      await Repository.insertCachedMedia([tweet]);

      final results = await Repository.getUserCachedMedia('mixedcaseuser', 10);

      expect(results.map((t) => t.id), contains('case_test_unique'));
    });

    test('pruneCachedMedia removes oldest WATCHED items when limit exceeded',
        () async {
      final db = await Repository.database;
      await db.delete(tableCachedMedia);

      for (int i = 1; i <= 5; i++) {
        await db.insert(tableCachedMedia, {
          'id': 'prune_test_$i',
          'played_count': 1,
          'last_played_at': i * 1000,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'text': 'Watched $i',
          'media_urls': '[]',
        });
      }

      await Repository.pruneCachedMedia(threshold: 3);

      final remaining =
          await db.query(tableCachedMedia, where: "id LIKE 'prune_test_%'");
      expect(remaining.length, 3);
      final remainingIds = remaining.map((row) => row['id']).toList();
      expect(remainingIds.contains('prune_test_1'), false);
      expect(remainingIds.contains('prune_test_2'), false);
      expect(remainingIds.contains('prune_test_3'), true);
    });
  });

  group('Repository media filter semantics (selected = keep)', () {
    setUp(() async {
      final db = await Repository.database;
      await db.delete(tableCachedMedia);
      await Repository.insertCachedMedia([
        Tweet(
          id: 'filter_video',
          text: 'video',
          userHandle: 'u',
          mediaUrls: ['https://test.com/v.mp4'],
          isVideo: true,
        ),
        Tweet(
          id: 'filter_image',
          text: 'image',
          userHandle: 'u',
          mediaUrls: ['https://test.com/i.jpg'],
          isVideo: false,
        ),
        Tweet(
          id: 'filter_text',
          text: 'text',
          userHandle: 'u',
          mediaUrls: const [],
          isVideo: false,
        ),
      ]);
    });

    Future<List<String>> candidateIds({
      required bool avoidWatchedContent,
      Set<MediaFilter>? filters,
    }) async {
      final tweets = await Repository.getCachedMediaCandidates(
        10,
        avoidWatchedContent: avoidWatchedContent,
        filters: filters,
      );
      return tweets.map((t) => t.id).toList()..sort();
    }

    test('video-only selection keeps only videos', () async {
      expect(
        await candidateIds(
            avoidWatchedContent: false, filters: {MediaFilter.video}),
        ['filter_video'],
      );
    });

    test('image+text selection excludes videos', () async {
      expect(
        await candidateIds(
            avoidWatchedContent: false,
            filters: {MediaFilter.image, MediaFilter.text}),
        ['filter_image', 'filter_text'],
      );
    });

    test('empty selection shows everything', () async {
      expect(
        await candidateIds(avoidWatchedContent: false, filters: {}),
        ['filter_image', 'filter_text', 'filter_video'],
      );
    });

    test('unplayed path honors the same semantics', () async {
      expect(
        await candidateIds(
            avoidWatchedContent: true, filters: {MediaFilter.video}),
        ['filter_video'],
      );
    });

    test('user cache honors the same semantics', () async {
      final tweets = await Repository.getUserCachedMedia('u', 10, filters: {
        MediaFilter.video,
      });
      expect(tweets.map((t) => t.id).toList(), ['filter_video']);
    });

    test('hashtag cache honors the same semantics', () async {
      final tweets = await Repository.getHashtagCachedMedia('video', 10,
          filters: {MediaFilter.video});
      expect(tweets.map((t) => t.id).toList(), ['filter_video']);
    });
  });
}
