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
  return client.fetchProfile(screenName);
});

class UserMediaNotifier extends AsyncNotifier<FeedState> {
  UserMediaNotifier(this.arg);
  final String arg;

  @override
  FutureOr<FeedState> build() async {
    final client = ref.watch(twitterClientProvider);
    final settings = ref.watch(settingsProvider);
    final screenName = arg.startsWith('@') ? arg.substring(1) : arg;

    // 1. Try to load from cache immediately to show SOMETHING.
    // User detail filtering is intentionally independent from the home feed
    // setting and defaults to disabled.
    final cached = await Repository.getUserCachedMedia(
        screenName, settings.loadBatchSize,
        filters: settings.filters);
    final watched = settings.userDetailAvoidWatchedContent
        ? await Repository.getWatchedIdentifiers()
        : const <String>{};
    final visibleCached = settings.userDetailAvoidWatchedContent
        ? Repository.filterUnwatched(cached, watched)
        : cached;

    // Trigger async fetch in the background
    _fetchFreshData(screenName, client, settings);

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
      );
      final watched = settings.userDetailAvoidWatchedContent
          ? await Repository.getWatchedIdentifiers()
          : const <String>{};
      final visibleTweets = settings.userDetailAvoidWatchedContent
          ? Repository.filterUnwatched(response.tweets, watched)
          : response.tweets;

      if (response.tweets.isNotEmpty) {
        await Repository.insertCachedMedia(response.tweets);
        await CustomMediaCacheManager.enforceLimit(
            settings.mediaCacheSizeMB);

        final freshTweets =
            visibleTweets.map((t) => t.copyWith(source: 'API')).toList();

        // Update state by MERGING to avoid jumps
        if (state.hasValue) {
          final currentTweets = state.value!.tweets;
          final existingIds = currentTweets.map((t) => t.id).toSet();
          final uniqueFresh =
              freshTweets.where((t) => !existingIds.contains(t.id)).toList();

          if (uniqueFresh.isNotEmpty) {
            final merged = [...currentTweets, ...uniqueFresh];
            merged.sort((a, b) => (b.createdAt ?? DateTime(0))
                .compareTo(a.createdAt ?? DateTime(0)));

            state = AsyncData(FeedState(
              tweets: merged,
              cursorBottom: response.cursorBottom ?? state.value!.cursorBottom,
              isRefreshing: false,
            ));
          } else {
            state = AsyncData(state.value!.copyWith(isRefreshing: false));
          }
        }
      } else {
        if (state.hasValue) {
          state = AsyncData(state.value!.copyWith(isRefreshing: false));
        }
      }
    } catch (e) {
      debugPrint('XFLOW: Background user media fetch error: $e');
      if (state.hasValue) {
        state = AsyncData(state.value!.copyWith(isRefreshing: false));
      }
    }
  }

  Future<void> fetchMore() async {
    final currentState = state.value;
    final screenName = arg.startsWith('@') ? arg.substring(1) : arg;

    if (currentState == null || currentState.isLoadingMore) {
      return;
    }

    final client = ref.read(twitterClientProvider);
    final settings = ref.read(settingsProvider);
    state = AsyncData(currentState.copyWith(isLoadingMore: true));

    try {
      final response = await _fetchUserMedia(
        client,
        screenName,
        cursor: currentState.cursorBottom,
        cooldownMinutes: settings.cooldownDuration,
        filters: settings.filters,
      );

      final watched = settings.userDetailAvoidWatchedContent
          ? await Repository.getWatchedIdentifiers()
          : const <String>{};
      final newTweets = settings.userDetailAvoidWatchedContent
          ? Repository.filterUnwatched(response.tweets, watched)
          : response.tweets;
      if (response.tweets.isNotEmpty) {
        await Repository.insertCachedMedia(response.tweets);
        await CustomMediaCacheManager.enforceLimit(
            settings.mediaCacheSizeMB);
      }

      final seenIds = currentState.tweets.map((t) => t.id).toSet();
      final uniqueNewTweets =
          newTweets.where((t) => !seenIds.contains(t.id)).toList();

      state = AsyncData(currentState.copyWith(
        tweets: [...currentState.tweets, ...uniqueNewTweets],
        cursorBottom: response.cursorBottom,
        isLoadingMore: false,
      ));
    } catch (e) {
      debugPrint('Error fetching more user media: $e');
      state = AsyncData(currentState.copyWith(isLoadingMore: false));
    }
  }

  Future<TweetResponse> _fetchUserMedia(
    TwitterClient client,
    String screenName, {
    String? cursor,
    required int cooldownMinutes,
    Set<MediaFilter>? filters,
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
        );
        debugPrint(
            'XFLOW: UserTweets for $userId returned ${timelineResponse.tweets.length} tweets');
        if (timelineResponse.tweets.isNotEmpty || cursor != null) {
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
    );
    debugPrint(
        'XFLOW: SearchTimeline fallback for @$screenName returned ${fallback.tweets.length} tweets');
    return fallback;
  }
}

final userMediaNotifierProvider =
    AsyncNotifierProvider.family<UserMediaNotifier, FeedState, String>(
        UserMediaNotifier.new);
