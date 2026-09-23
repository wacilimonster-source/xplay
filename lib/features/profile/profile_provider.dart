import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/client/twitter_client.dart';
import '../../core/database/repository.dart';
import '../../core/database/entities.dart';
import '../../core/utils/media_cache_manager.dart';
import '../feed/feed_provider.dart'; // For FeedState
import '../settings/settings_provider.dart';

final userProfileProvider =
    FutureProvider.family<Subscription?, String>((ref, screenName) async {
  final client = ref.watch(twitterClientProvider);
  final profile = await client.fetchProfile(screenName);
  if (profile != null) {
    await Repository.persistProfileIfSubscribed(profile);
  }
  return profile;
});

class UserMediaNotifier extends AsyncNotifier<FeedState> {
  UserMediaNotifier(this.arg);
  final String arg;
  bool _disposed = false;

  @override
  FutureOr<FeedState> build() async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);

    final client = ref.read(twitterClientProvider);
    // Only react to fetch-relevant setting changes; the rest is read on demand.
    // Watching the whole SettingsState used to reset an opened profile back to
    // "cache page 1" whenever an unrelated slider moved.
    ref.watch(settingsProvider.select((s) => s.fetchSnapshot));
    final settings = ref.read(settingsProvider);
    final screenName = arg.startsWith('@') ? arg.substring(1) : arg;

    // 1. Try to load from cache immediately to show SOMETHING.
    // User detail filtering is intentionally independent from the home feed
    // setting and defaults to disabled.
    final cached = await Repository.getUserCachedMedia(
        screenName, settings.loadBatchSize,
        filters: settings.filters);
    // SQL-side filtering: the watched table used to be loaded in full on every
    // profile open.
    final visibleCached = await Repository.filterWatched(cached,
        enabled: settings.userDetailAvoidWatchedContent);

    // Trigger async fetch in the background
    unawaited(_fetchFreshData(screenName, client, settings));

    return FeedState(
      tweets: visibleCached.map((t) => t.copyWith(source: 'Cache')).toList(),
      isRefreshing: true, // Mark as refreshing while we fetch
    );
  }

  Future<void> refresh() async {
    final screenName = arg.startsWith('@') ? arg.substring(1) : arg;
    final currentState = state.value;
    if (currentState != null) {
      state = AsyncData(currentState.copyWith(isRefreshing: true));
    }
    final client = ref.read(twitterClientProvider);
    final settings = ref.read(settingsProvider);
    await _fetchFreshData(screenName, client, settings);
  }

  void _set(FeedState Function(FeedState current) update) {
    if (_disposed) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData(update(current));
  }

  Future<void> _fetchFreshData(
    String screenName,
    TwitterClient client,
    SettingsState settings,
  ) async {
    try {
      final response = await _fetchUserMedia(
        client,
        screenName,
        cooldownMinutes: settings.cooldownDuration,
        filters: settings.filters,
        timeoutSeconds: settings.apiTimeoutSeconds,
      );
      final visibleTweets = await Repository.filterWatched(response.tweets,
          enabled: settings.userDetailAvoidWatchedContent);

      if (response.tweets.isEmpty) {
        _set((current) => current.copyWith(
            isRefreshing: false, rateLimited: response.rateLimited));
        return;
      }

      await Repository.insertCachedMedia(response.tweets);
      // Fire-and-forget: directory walking must not delay showing content that
      // is already fetched (and blocks forever without path_provider).
      CustomMediaCacheManager.enforceLimit(settings.mediaCacheSizeMB).ignore();

      final freshTweets =
          visibleTweets.map((t) => t.copyWith(source: 'API')).toList();

      // Update state by MERGING to avoid jumps. Re-read the live list rather
      // than a snapshot taken before the awaits, so a concurrent `fetchMore`
      // result is not thrown away.
      _set((current) {
        final existingIds = current.tweets.map((t) => t.id).toSet();
        final uniqueFresh =
            freshTweets.where((t) => !existingIds.contains(t.id)).toList();
        if (uniqueFresh.isEmpty) {
          return current.copyWith(
              isRefreshing: false, rateLimited: response.rateLimited);
        }
        final merged = [...current.tweets, ...uniqueFresh];
        merged.sort((a, b) => (b.createdAt ?? DateTime(0))
            .compareTo(a.createdAt ?? DateTime(0)));

        return FeedState(
          tweets: merged,
          cursorBottom: response.cursorBottom ?? current.cursorBottom,
          isRefreshing: false,
          isLoadingMore: current.isLoadingMore,
          hasMore: (response.cursorBottom ?? current.cursorBottom) != null,
          rateLimited: response.rateLimited,
        );
      });
    } catch (e) {
      debugPrint('XFLOW: Background user media fetch error: $e');
      _set((current) => current.copyWith(isRefreshing: false));
    }
  }

  Future<void> fetchMore() async {
    final startState = state.value;
    final screenName = arg.startsWith('@') ? arg.substring(1) : arg;

    if (startState == null ||
        startState.isLoadingMore ||
        !startState.hasMore ||
        startState.tweets.isEmpty && startState.cursorBottom == null) {
      return;
    }

    final client = ref.read(twitterClientProvider);
    final settings = ref.read(settingsProvider);
    _set((current) => current.copyWith(isLoadingMore: true));

    try {
      final response = await _fetchUserMedia(
        client,
        screenName,
        cursor: startState.cursorBottom,
        cooldownMinutes: settings.cooldownDuration,
        filters: settings.filters,
        timeoutSeconds: settings.apiTimeoutSeconds,
      );

      final newTweets = await Repository.filterWatched(response.tweets,
          enabled: settings.userDetailAvoidWatchedContent);
      if (response.tweets.isNotEmpty) {
        await Repository.insertCachedMedia(response.tweets);
        // Fire-and-forget: enforcement walks the cache directory, and awaiting it
        // delays showing content the user already has (and blocks forever when
        // path_provider is unavailable, e.g. under `flutter test`).
        CustomMediaCacheManager.enforceLimit(
                settings.mediaCacheSizeMB)
            .ignore();
      }

      _set((current) {
        final seenIds = current.tweets.map((t) => t.id).toSet();
        final uniqueNewTweets =
            newTweets.where((t) => !seenIds.contains(t.id)).toList();
        return FeedState(
          tweets: [...current.tweets, ...uniqueNewTweets],
          cursorBottom: response.cursorBottom,
          isLoadingMore: false,
          isRefreshing: current.isRefreshing,
          // A page without a next cursor is the end: without clearing this the
          // screen kept re-requesting the same last page on every scroll.
          hasMore: response.cursorBottom != null,
          rateLimited: response.rateLimited,
        );
      });
    } catch (e) {
      debugPrint('Error fetching more user media: $e');
      _set((current) => current.copyWith(isLoadingMore: false));
    }
  }

  Future<TweetResponse> _fetchUserMedia(
    TwitterClient client,
    String screenName, {
    String? cursor,
    required int cooldownMinutes,
    Set<MediaFilter>? filters,
    int timeoutSeconds = 15,
  }) async {
    Subscription? profile;
    try {
      profile = await client.fetchProfile(screenName);
    } catch (e) {
      debugPrint('XFLOW: Could not resolve @$screenName profile id: $e');
    }

    final userId = profile?.id;
    debugPrint(
        'XFLOW: User media: profile=$profile userId=$userId cursor=${cursor ?? 'null'}');
    if (userId != null && userId.isNotEmpty) {
      try {
        final timelineResponse = await client.fetchUserTimeline(
          userId,
          cursor: cursor,
          cooldownMinutes: cooldownMinutes,
          filters: filters,
          timeoutSeconds: timeoutSeconds,
        );
        debugPrint(
            'XFLOW: UserTweets for $userId returned ${timelineResponse.tweets.length} tweets');
        if (timelineResponse.tweets.isNotEmpty ||
            cursor != null ||
            timelineResponse.rateLimited) {
          return timelineResponse;
        }
        debugPrint(
            'XFLOW: UserTweets empty for $userId, falling back to SearchTimeline');
      } catch (e) {
        debugPrint('XFLOW: User timeline fetch failed for $userId: $e');
      }
    }

    final fallback = await client.fetchUserTimelineByScreenName(
      screenName,
      cursor: cursor,
      cooldownMinutes: cooldownMinutes,
      filters: filters,
      timeoutSeconds: timeoutSeconds,
    );
    debugPrint(
        'XFLOW: SearchTimeline fallback for @$screenName returned ${fallback.tweets.length} tweets');
    return fallback;
  }
}

final userMediaNotifierProvider =
    AsyncNotifierProvider.family<UserMediaNotifier, FeedState, String>(
        UserMediaNotifier.new);
