import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xplay/features/feed/tiktok_feed_screen.dart';
import 'package:xplay/features/feed/feed_provider.dart';
import 'package:xplay/features/settings/settings_provider.dart';
import 'package:xplay/core/models/tweet.dart';
import 'package:xplay/core/utils/lifecycle_provider.dart';
import 'package:xplay/features/player/player_pool_provider.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('TiktokFeedScreen Widget Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('renders feed items from mock provider',
        (WidgetTester tester) async {
      final mockTweets = [
        Tweet(
          id: '1',
          text: 'Feed Item 1',
          userHandle: 'user1',
          mediaUrls: ['https://test.com/v1.mp4'],
          isVideo: true,
        ),
      ];

      final mockState = FeedState(tweets: mockTweets);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            feedNotifierProvider
                .overrideWith(() => MockFeedNotifier(mockState)),
            playerPoolProvider.overrideWith(() => MockPlayerPool()),
            // The feed items read settings; keep the real notifier from hitting
            // platform channels.
            settingsProvider.overrideWith(() => MockSettingsNotifier()),
            // The screen folds "app is foregrounded" into item visibility.
            lifecycleProvider.overrideWith(() => MockLifecycle()),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TiktokFeedScreen()),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      // Check if PageView is present
      expect(find.byType(PageView), findsOneWidget);

      // Flush the debounce that records "watched" so nothing is still pending
      // when the test ends.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('every feed item is keyed by its tweet id',
        (WidgetTester tester) async {
      // Without a per-tweet key the element is reused positionally, so after a
      // background refresh the new tweet inherited the previous item's error
      // panel, image page index and retry counter.
      final mockState = FeedState(tweets: [
        Tweet(id: 'a', text: 'A', userHandle: 'u', mediaUrls: const []),
        Tweet(id: 'b', text: 'B', userHandle: 'u', mediaUrls: const []),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            feedNotifierProvider.overrideWith(() => MockFeedNotifier(mockState)),
            playerPoolProvider.overrideWith(() => MockPlayerPool()),
            settingsProvider.overrideWith(() => MockSettingsNotifier()),
            lifecycleProvider.overrideWith(() => MockLifecycle()),
          ],
          child: const MaterialApp(home: Scaffold(body: TiktokFeedScreen())),
        ),
      );
      await tester.pump();
      await tester.pump();

      // PageView only builds the pages around the current one, so check the
      // first page, swipe, then check the second.
      var keys = tester
          .widgetList<TiktokFeedItem>(find.byType(TiktokFeedItem))
          .map((i) => (i.key as ValueKey).value)
          .toList();
      expect(keys, contains('home_feed_a'));

      await tester.drag(find.byType(PageView), const Offset(0, -600));
      await tester.pumpAndSettle();

      keys = tester
          .widgetList<TiktokFeedItem>(find.byType(TiktokFeedItem))
          .map((i) => (i.key as ValueKey).value)
          .toList();
      expect(keys, contains('home_feed_b'),
          reason: 'items must be keyed by tweet id, not reused positionally');

      await tester.pump(const Duration(seconds: 1));
    });
  });
}

class MockFeedNotifier extends FeedNotifier {
  final FeedState mockState;
  MockFeedNotifier(this.mockState);

  @override
  Future<FeedState> build() async => mockState;

  @override
  Future<void> fetchMore() async {}
}

class MockPlayerPool extends PlayerPoolNotifier {
  final warmed = <String>[];
  final cleaned = <Set<String>>[];

  @override
  Map<String, PlayerInstance> build() => {};

  @override
  void warmup(String id, String url,
      {required String scope, bool isLandscape = false}) {
    warmed.add('$scope/$id');
  }

  @override
  void cleanupExcept(String scope, Set<String> activeIds) {
    cleaned.add(activeIds);
  }

  @override
  void releaseScope(String scope) {}
}

class MockSettingsNotifier extends SettingsNotifier {
  @override
  SettingsState build() => SettingsState(isInitialized: true);
}

class MockLifecycle extends LifecycleNotifier {
  @override
  AppLifecycle build() => AppLifecycle.resumed;
}
