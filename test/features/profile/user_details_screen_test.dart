import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xplay/features/settings/settings_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xplay/features/profile/user_details_screen.dart';
import 'package:xplay/features/profile/profile_provider.dart';
import 'package:xplay/features/feed/feed_provider.dart';
import 'package:xplay/features/subscriptions/subscription_list_screen.dart';
import 'package:xplay/core/client/twitter_client.dart';
import 'package:xplay/core/database/repository.dart';
import 'package:xplay/core/database/entities.dart';
import 'package:xplay/core/models/tweet.dart';

class SubscriptionListNotifierMock extends SubscriptionListNotifier {
  @override
  SubscriptionListState build() {
    return SubscriptionListState(isLoading: false);
  }

  @override
  bool isSubscribed(String screenName) => false;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late TestTwitterClient mockClient;
  const testHandle = 'testuser';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mockClient = TestTwitterClient();
    await Repository.close();
  });

  tearDown(() async {
    await Repository.close();
  });

  group('UserMediaNotifier Logic (Unit Tests)', () {
    test('initial build loads from cache and triggers fresh fetch', () async {
      final cachedTweet = Tweet(
          id: 'c1',
          text: 'Cached',
          userHandle: testHandle,
          mediaUrls: [],
          isVideo: false,
          createdAt: DateTime(2023, 1, 1));
      final freshTweet = Tweet(
          id: 'f1',
          text: 'Fresh',
          userHandle: testHandle,
          mediaUrls: [],
          isVideo: false,
          createdAt: DateTime(2023, 1, 2));

      await Repository.insertCachedMedia([cachedTweet]);

      mockClient.profileByScreenName[testHandle] = Subscription(
        id: 'test_user_id',
        screenName: testHandle,
        name: '',
      );
      mockClient.timelineByUserId['test_user_id'] =
          Future.value(TweetResponse(tweets: [freshTweet]));

      final container = ProviderContainer(overrides: [
        twitterClientProvider.overrideWithValue(mockClient),
      ]);
      addTearDown(container.dispose);

      // Let the settings notifier finish loading its stored values first: a
      // settings change mid-test rebuilds this provider (by design), and the
      // rebuild would still be in flight when the container is disposed.
      await waitForCondition(() => container.read(settingsProvider).isInitialized);

      // Initial read triggers build()
      final firstState =
          await container.read(userMediaNotifierProvider(testHandle).future);
      expect(firstState.tweets.any((t) => t.id == 'c1'), isTrue);

      // Wait for the background fetch to publish its merged page. The old fixed
      // 100ms sleep raced the fetch and left the suite hanging on slower runs.
      FeedState latest() =>
          container.read(userMediaNotifierProvider(testHandle)).value!;
      await waitForCondition(() =>
          latest().tweets.any((t) => t.id == 'f1') && !latest().isRefreshing);

      final finalState = latest();
      expect(finalState.tweets.any((t) => t.id == 'f1'), isTrue);
      expect(finalState.isRefreshing, isFalse);
    });
  });

  group('UserDetailsScreen Widget Tests', () {
    testWidgets('shows loading state then profile name', (tester) async {
      final profile =
          Subscription(id: '1', screenName: testHandle, name: 'Display Name');
      mockClient.profileByScreenName[testHandle] = profile;
      mockClient.timelineByUserId['1'] =
          Future.value(TweetResponse(tweets: []));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          twitterClientProvider.overrideWithValue(mockClient),
          subscriptionListProvider
              .overrideWith(() => SubscriptionListNotifierMock()),
        ],
        child: const MaterialApp(
          home: UserDetailsScreen(screenName: testHandle),
        ),
      ));

      // Initially shows loading
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      // The profile lookup is a real async call: poll until it renders instead
      // of guessing one fixed delay, which flaked when the machine was busy.
      for (var i = 0; i < 20 && find.text('Display Name').evaluate().isEmpty; i++) {
        await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }

      expect(find.text('Display Name'), findsWidgets);
    });
  });
}

class TestTwitterClient extends TwitterClient {
  final profileByScreenName = <String, Subscription?>{};
  final timelineByUserId = <String, Future<TweetResponse>>{};
  final timelineByScreenName = <String, Future<TweetResponse>>{};

  @override
  Future<Subscription?> fetchProfile(String screenName,
      {void Function()? onRateLimit}) async {
    return profileByScreenName[screenName];
  }

  @override
  Future<TweetResponse> fetchUserTimeline(
    String userId, {
    String? cursor,
    int cooldownMinutes = 15,
    int count = 20,
    Set<MediaFilter>? filters,
    int timeoutSeconds = 15,
  }) async {
    return timelineByUserId[userId] ?? Future.value(TweetResponse(tweets: []));
  }

  @override
  Future<TweetResponse> fetchUserTimelineByScreenName(
    String screenName, {
    String? cursor,
    int cooldownMinutes = 15,
    Set<MediaFilter>? filters,
    int timeoutSeconds = 15,
  }) async {
    return timelineByScreenName[screenName] ??
        Future.value(TweetResponse(tweets: []));
  }
}


/// Polls [condition] until true, failing fast (and clearly) on timeout instead
/// of letting the test hang until the framework's 30s limit.
Future<void> waitForCondition(bool Function() condition,
    {Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
