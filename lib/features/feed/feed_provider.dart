import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/client/twitter_client.dart';
import '../../core/models/tweet.dart';
import '../../core/database/repository.dart';
import '../../core/client/discovery_engine.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/media_cache_manager.dart';
import '../settings/settings_provider.dart';
import '../player/player_pool_provider.dart';

final twitterClientProvider = Provider((ref) => TwitterClient());

class FeedState {
  final List<Tweet> tweets;
  final String? cursorBottom;
  final bool isLoadingMore;
  final bool isRefreshing;

  /// False once the source reports no further page. Without this the cursor
  /// could never be cleared (`copyWith` treats null as "keep old value"), so
  /// every scroll past the end re-requested the same page and burned quota.
  final bool hasMore;

  /// The last request was rejected with 429 — lets the UI say "被限流了"
  /// instead of the misleading "未找到媒体内容".
  final bool rateLimited;

  FeedState({
    required this.tweets,
    this.cursorBottom,
    this.isLoadingMore = false,
    this.isRefreshing = false,
    this.hasMore = true,
    this.rateLimited = false,
  });

  FeedState copyWith({
    List<Tweet>? tweets,
    String? cursorBottom,

    /// Set to true to explicitly drop the pagination cursor (e.g. after the
    /// query changed) instead of keeping the previous one.
    bool clearCursor = false,
    bool? isLoadingMore,
    bool? isRefreshing,
    bool? hasMore,
    bool? rateLimited,
  }) {
    return FeedState(
      tweets: tweets ?? this.tweets,
      cursorBottom:
          clearCursor ? null : (cursorBottom ?? this.cursorBottom),
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      hasMore: hasMore ?? this.hasMore,
      rateLimited: rateLimited ?? this.rateLimited,
    );
  }
}

/// Which of the live feeds currently holds a "liked" state for [tweetId].
/// Used by the player's fullscreen bar, which is shared by all three feeds.
final tweetIsLikedProvider = Provider.family<bool, String>((ref, tweetId) {
  bool matches(AsyncValue<FeedState> feed) {
    final tweets = feed.value?.tweets;
    if (tweets == null) return false;
    for (final t in tweets) {
      if (t.id == tweetId) return t.isLiked;
    }
    return false;
  }

  return matches(ref.watch(feedNotifierProvider));
});

class FeedNotifier extends AsyncNotifier<FeedState> {
  int _cacheWriteCount = 0;
  static const int _enforceLimitInterval = 5;

  /// Tweet the user is currently watching, reported by the feed screen. A
  /// background refresh must not reshuffle the item under their fingers.
  String? _anchorId;

  bool _refreshInFlight = false;
  bool _refreshRequested = false;

  void setActiveTweet(String? id) {
    _anchorId = id;
  }

  /// Settings that actually change what we should *fetch*. Watching the whole
  /// [SettingsState] meant that touching an unrelated slider (cache size, log
  /// level, retry count) rebuilt the feed, threw away everything the user had
  /// loaded and reset the video they were watching.
  List<Tweet> _runDiscoveryPipeline(
    List<Tweet> freshPool,
    List<Tweet> localPool,
    SettingsState settings,
    Map<String, int> playedByUser, {
    int protectedIndex = 0,
    List<Tweet> currentTweets = const [],
  }) {
    // Keep everything up to *and including* the item being watched, so a
    // refresh can neither replace it nor move it out from under the user.
    var headEnd = protectedIndex;
    final anchor = _anchorId;
    if (anchor != null && currentTweets.isNotEmpty) {
      final idx = currentTweets.indexWhere((t) => t.id == anchor);
      if (idx != -1) headEnd = idx + 1;
    }
    headEnd = headEnd.clamp(0, currentTweets.length);

    final head = currentTweets.take(headEnd).toList();
    final headIds = head.map((t) => t.id).toSet();
    final headMedia = head
        .where((t) => t.mediaUrls.isNotEmpty)
        .map((t) => t.mediaUrls.first)
        .toSet();

    // Initialize seen sets using a sliding window of already visible tweets
    final dedupeWindow = currentTweets.length >
            settings.mediaDeduplicationWindow
        ? currentTweets
            .sublist(currentTweets.length - settings.mediaDeduplicationWindow)
        : currentTweets;

    final seenIds = {...headIds, ...dedupeWindow.map((t) => t.id)};
    final seenMediaUrls = {
      ...headMedia,
      ...dedupeWindow
          .where((t) => t.mediaUrls.isNotEmpty)
          .map((t) => t.mediaUrls.first)
    };

    List<Tweet> deduplicate(List<Tweet> pool) {
      return pool.where((t) {
        if (seenIds.contains(t.id)) return false;
        if (t.mediaUrls.isNotEmpty &&
            seenMediaUrls.contains(t.mediaUrls.first)) {
          return false;
        }
        seenIds.add(t.id);
        if (t.mediaUrls.isNotEmpty) seenMediaUrls.add(t.mediaUrls.first);
        return true;
      }).toList();
    }

    final uniqueFresh = deduplicate(freshPool)..shuffle();
    final uniqueLocal = deduplicate(localPool)..shuffle();

    final interleaved = DiscoveryEngine.interleave(
        uniqueFresh, uniqueLocal, settings.freshMixRatio);

    var processed = [...head, ...interleaved];

    if (settings.unseenSubscriptionBoost) {
      processed = DiscoveryEngine.applyUnseenSubscriptionBoost(
        processed,
        playedByUser,
        lookahead: settings.unseenBoostLookahead,
        startIndex: head.length,
      );
    }

    processed = DiscoveryEngine.applySaturation(
      processed,
      threshold: settings.saturationThreshold,
      mediaThreshold: settings.mediaSaturationThreshold,
      windowSize: settings.saturationWindow,
      startIndex: head.length,
      maxSaturationSwaps: settings.maxSaturationSwaps,
      maxPasses: settings.maxSaturationPasses,
    );

    return processed;
  }

  @override
  Future<FeedState> build() async {
    // Only rebuild for fetch-relevant settings changes.
    final settings =
        ref.watch(settingsProvider.select((s) => s.fetchSnapshot));

    debugPrint(
        'XFLOW: Building FeedNotifier. filters=${settings.filters.map((f) => f.name).join(',')} strategy=${settings.fetchStrategy}');

    try {
      // Never query the cache before the stored preferences are known: the
      // hard-coded initial state used to run one query with the wrong filters
      // and then rebuild the feed a second time.
      if (!settings.isInitialized) {
        return FeedState(tweets: const [], isRefreshing: true);
      }

      final live = ref.read(settingsProvider);

      // Stage 1: Immediate local candidate retrieval
      final localPool = await Repository.getCachedMediaCandidates(
        live.loadBatchSize * live.dbCandidateMultiplier,
        avoidWatchedContent: live.avoidWatchedContent,
        filters: live.filters,
      );
      final localTagged =
          localPool.map((t) => t.copyWith(source: 'Cache')).toList();
      AppLogger.log(
          'XFLOW: Cold start: Retrieved ${localPool.length} local candidates');

      // EARLY MEDIA WARMUP
      if (localTagged.isNotEmpty) {
        final pool = ref.read(playerPoolProvider.notifier);
        for (int i = 0; i < localTagged.length && i < 3; i++) {
          final tweet = localTagged[i];
          if (tweet.isVideo && tweet.mediaUrls.isNotEmpty) {
            pool.warmup(tweet.id, tweet.mediaUrls.first, scope: 'home');
          }
        }
      }

      // TRIGGER BACKGROUND SYNC
      Future.delayed(Duration.zero, () => _refreshInBackground());

      return FeedState(
        tweets: localTagged,
        cursorBottom: null,
        isRefreshing: localTagged.isEmpty,
      );
    } catch (e, st) {
      debugPrint('XFLOW: Error in build(): $e\n$st');
      return FeedState(tweets: [], isRefreshing: false);
    }
  }

  Future<void> refresh() async {
    final currentState = state.value;
    if (currentState == null) return;
    if (_refreshInFlight) {
      // Remember the request instead of racing two refreshes over the state.
      _refreshRequested = true;
      return;
    }
    state = AsyncData(currentState.copyWith(isRefreshing: true));
    await _refreshInBackground(resetHead: true);
  }

  Future<void> _refreshInBackground({bool resetHead = false}) async {
    if (!ref.exists(feedNotifierProvider)) return;
    if (_refreshInFlight) {
      _refreshRequested = true;
      return;
    }
    _refreshInFlight = true;

    // `isRefreshing` has to be cleared on every exit path. It used to be set
    // before a try block that could throw (the watch-identifier query), leaving
    // the refresh spinner running forever.
    try {
      final client = ref.read(twitterClientProvider);
      final settings = ref.read(settingsProvider);
      final watched = settings.avoidWatchedContent
          ? await Repository.getWatchedIdentifiers()
          : const <String>{};

      debugPrint('XFLOW: Background refresh started');

      // 1. Fetch from API
      final TweetResponse freshResponse;
      if (settings.fetchStrategy == FeedSort.videomixer) {
        freshResponse = await client.fetchVideoMixer(
          count: settings.timelineBatchSize,
          filters: settings.filters,
        );
      } else if (settings.fetchStrategy == FeedSort.algorithmic) {
        freshResponse = await client.fetchAlgorithmicTimeline(
          count: settings.timelineBatchSize,
          filters: settings.filters,
        );
      } else if (settings.fetchStrategy == FeedSort.chronological) {
        freshResponse = await client.fetchChronologicalTimeline(
          count: settings.timelineBatchSize,
          filters: settings.filters,
        );
      } else {
        freshResponse = await client.fetchSubscribedMedia(
          sort: settings.fetchStrategy,
          filters: settings.filters,
          subBatchSize: settings.syncBatchSize,
          loadBatchSize: settings.initialSyncCount,
          cooldownMinutes: settings.cooldownDuration,
          strictSubscriptionsOnly: settings.strictSubscriptionsOnly,
          includeNativeRetweets: settings.includeNativeRetweets,
          useChunkedSubscriptions: settings.useChunkedSubscriptions,
          minFaves: settings.minFavesFilter,
          maxQueryLength: settings.maxQueryLength,
          timeoutSeconds: settings.apiTimeoutSeconds,
        );
      }

      final freshPool = freshResponse.tweets;
      final freshTagged = Repository.filterUnwatched(
        freshPool.map((t) => t.copyWith(source: 'API')).toList(),
        watched,
      );

      debugPrint(
          'XFLOW: Background refresh returned ${freshPool.length} fresh tweets');

      if (freshPool.isEmpty) {
        AppLogger.log(
            'XFLOW: WARNING - Background refresh returned 0 tweets! '
            'fetchStrategy=${settings.fetchStrategy} rateLimited=${freshResponse.rateLimited}');
      }

      if (freshPool.isNotEmpty) {
        await Repository.insertCachedMedia(freshPool);
        _cacheWriteCount++;
        if (_cacheWriteCount >= _enforceLimitInterval) {
          _cacheWriteCount = 0;
          CustomMediaCacheManager.enforceLimit(settings.mediaCacheSizeMB)
              .ignore();
        }
      }

      // 2. Fetch local pool (now including fresh items)
      final localPool = await Repository.getCachedMediaCandidates(
        settings.loadBatchSize * settings.dbCandidateMultiplier,
        avoidWatchedContent: settings.avoidWatchedContent,
        filters: settings.filters,
      );
      final localTagged =
          localPool.map((t) => t.copyWith(source: 'Cache')).toList();

      // Reading this provider from inside itself trips Riverpod's
      // "A provider cannot depend on itself" assertion; `state` is the same
      // (and fresher) value.
      final currentAsync = state;
      if (!currentAsync.hasValue) return;
      final current = currentAsync.value!;

      final playedByUser = settings.unseenSubscriptionBoost
          ? await Repository.getPlayedCountsByUser()
          : const <String, int>{};

      final processed = _runDiscoveryPipeline(
        freshTagged,
        localTagged,
        settings,
        playedByUser,
        protectedIndex: resetHead ? 0 : 2,
        currentTweets: resetHead ? [] : current.tweets,
      );

      state = AsyncData(current.copyWith(
        tweets: processed,
        // Keep the working cursor when this page produced nothing usable.
        cursorBottom: freshResponse.cursorBottom,
        isRefreshing: false,
        rateLimited: freshResponse.rateLimited,
      ));
      debugPrint(
          'XFLOW: Feed state updated from background refresh. Total: ${processed.length}');
    } catch (e) {
      debugPrint('XFLOW: Background refresh error: $e');
      // Reading this provider from inside itself trips Riverpod's
      // "A provider cannot depend on itself" assertion; `state` is the same
      // (and fresher) value.
      final currentAsync = state;
      if (currentAsync.hasValue) {
        state = AsyncData(currentAsync.value!.copyWith(isRefreshing: false));
      }
    } finally {
      _refreshInFlight = false;
      if (_refreshRequested) {
        _refreshRequested = false;
        Future<void>.microtask(() => _refreshInBackground());
      }
    }
  }

  Future<void> fetchMore() async {
    final currentState = state.value;
    if (currentState == null || currentState.isLoadingMore) return;
    if (!currentState.hasMore) {
      AppLogger.log('XFLOW: fetchMore skipped: source reported no more pages');
      return;
    }

    final settings = ref.read(settingsProvider);

    // Always work from a live view of the list: reading `state.value!` after the
    // awaits used to overwrite items a concurrent refresh had appended.
    List<Tweet> latest() =>
        (state.value?.tweets ?? currentState.tweets);

    state = AsyncData(currentState.copyWith(isLoadingMore: true));

    try {
      final watched = settings.avoidWatchedContent
          ? await Repository.getWatchedIdentifiers()
          : const <String>{};

      // Live dedupe sets, updated as candidates are accepted. The previous
      // version computed these once outside the loop, so the same tweet could be
      // appended twice within one "load more".
      final seenIds = latest().map((t) => t.id).toSet();
      final seenMedia = latest()
          .where((t) => t.mediaUrls.isNotEmpty)
          .map((t) => t.mediaUrls.first)
          .toSet();

      void remember(List<Tweet> accepted) {
        for (final t in accepted) {
          seenIds.add(t.id);
          if (t.mediaUrls.isNotEmpty) seenMedia.add(t.mediaUrls.first);
        }
      }

      List<Tweet> accept(List<Tweet> candidates) {
        final out = <Tweet>[];
        for (final t in candidates) {
          if (seenIds.contains(t.id)) continue;
          if (t.mediaUrls.isNotEmpty && seenMedia.contains(t.mediaUrls.first)) {
            continue;
          }
          out.add(t);
        }
        remember(out);
        return out;
      }

      List<Tweet> allNewTweets = [];
      String? currentCursor = currentState.cursorBottom;
      final seenCursors = <String>{};
      int apiRetries = 0;
      int chunkRotations = 0;
      var sourceExhausted = false;
      var wasRateLimited = false;
      final maxRetries =
          settings.apiRetryLimit * 2; // Increase limit for robustness

      while (allNewTweets.length < settings.minNewTweetsThreshold &&
          apiRetries < maxRetries &&
          chunkRotations < settings.chunkRotationLimit) {
        // 1. Try to fetch from DB first (refresh pool)
        final dbCandidates = await Repository.getCachedMediaCandidates(
          settings.loadBatchSize * settings.dbCandidateMultiplier,
          avoidWatchedContent: settings.avoidWatchedContent,
          filters: settings.filters,
        );

        final localNew = accept(Repository.filterUnwatched(
            dbCandidates.where((t) =>
                !seenIds.contains(t.id) &&
                (t.mediaUrls.isEmpty || !seenMedia.contains(t.mediaUrls.first)))
                .toList(),
            watched));

        if (localNew.isNotEmpty) {
          allNewTweets.addAll(localNew);
          if (allNewTweets.length >= settings.minNewTweetsThreshold) break;
        }

        // 2. Hit the API
        final client = ref.read(twitterClientProvider);
        if (currentCursor != null) seenCursors.add(currentCursor);

        try {
          final TweetResponse response;
          if (settings.fetchStrategy == FeedSort.videomixer) {
            response = await client.fetchVideoMixer(
              cursor: currentCursor,
              count: settings.timelineBatchSize,
              filters: settings.filters,
            );
          } else if (settings.fetchStrategy == FeedSort.algorithmic) {
            response = await client.fetchAlgorithmicTimeline(
              cursor: currentCursor,
              count: settings.timelineBatchSize,
              filters: settings.filters,
            );
          } else if (settings.fetchStrategy == FeedSort.chronological) {
            response = await client.fetchChronologicalTimeline(
              cursor: currentCursor,
              count: settings.timelineBatchSize,
              filters: settings.filters,
            );
          } else {
            response = await client.fetchSubscribedMedia(
              cursor: currentCursor,
              sort: settings.fetchStrategy,
              filters: settings.filters,
              subBatchSize: settings.syncBatchSize,
              loadBatchSize: settings.loadBatchSize,
              cooldownMinutes: settings.cooldownDuration,
              strictSubscriptionsOnly: settings.strictSubscriptionsOnly,
              includeNativeRetweets: settings.includeNativeRetweets,
              useChunkedSubscriptions: settings.useChunkedSubscriptions,
              minFaves: settings.minFavesFilter,
              maxQueryLength: settings.maxQueryLength,
              timeoutSeconds: settings.apiTimeoutSeconds,
            );
          }

          wasRateLimited = wasRateLimited || response.rateLimited;

          final freshUnique = accept(Repository.filterUnwatched(
              response.tweets
                  .where((t) =>
                      !seenIds.contains(t.id) &&
                      (t.mediaUrls.isEmpty ||
                          !seenMedia.contains(t.mediaUrls.first)))
                  .toList(),
              watched));

          if (response.tweets.isNotEmpty) {
            await Repository.insertCachedMedia(response.tweets);
          }

          allNewTweets.addAll(freshUnique);
          apiRetries++;

          // Handle Pagination vs Rotation
          if (response.cursorBottom != null &&
              response.cursorBottom != currentCursor &&
              !seenCursors.contains(response.cursorBottom!)) {
            currentCursor = response.cursorBottom;
          } else {
            // Chunk exhausted or stuck cursor
            AppLogger.log(
                'XFLOW: Chunk exhausted or stuck cursor. Rotating to next subscription chunk.');
            if (response.cursorBottom == null) sourceExhausted = true;
            currentCursor = null;
            chunkRotations++;
            await Future.delayed(const Duration(milliseconds: 300));
          }
        } catch (e) {
          AppLogger.log('XFLOW: fetchMore API error: $e');
          apiRetries++;
          await Future.delayed(const Duration(seconds: 1));
        }

        if (allNewTweets.length < settings.minNewTweetsThreshold) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }

      final base = latest();
      if (allNewTweets.isEmpty) {
        final latestState = state.value ?? currentState;
        state = AsyncData(latestState.copyWith(
          isLoadingMore: false,
          hasMore: !sourceExhausted,
          rateLimited: wasRateLimited,
        ));
        return;
      }

      // Shuffle candidates BEFORE taking the batch to improve diversity
      allNewTweets.shuffle();

      final finalNewTweets = allNewTweets
          .take(settings.loadBatchSize)
          .map((t) => t.copyWith(source: t.source ?? 'Mixed'))
          .toList();

      var combined = [...base, ...finalNewTweets];

      // Apply diversity enforcement to the new tail
      combined = DiscoveryEngine.applySaturation(
        combined,
        threshold: settings.saturationThreshold,
        mediaThreshold: settings.mediaSaturationThreshold,
        windowSize: settings.saturationWindow,
        startIndex: base.length,
        maxSaturationSwaps: settings.maxSaturationSwaps,
        maxPasses: settings.maxSaturationPasses,
      );

      // M2: also run unseen-boost on the newly added section, matching refresh behavior
      if (settings.unseenSubscriptionBoost) {
        final playedByUser = await Repository.getPlayedCountsByUser();
        combined = DiscoveryEngine.applyUnseenSubscriptionBoost(
          combined,
          playedByUser,
          lookahead: settings.unseenBoostLookahead,
          startIndex: base.length,
        );
      }

      state = AsyncData(FeedState(
        tweets: combined,
        cursorBottom: currentCursor,
        isLoadingMore: false,
        hasMore: !sourceExhausted,
        rateLimited: wasRateLimited,
        isRefreshing: currentState.isRefreshing,
      ));
      debugPrint(
          'XFLOW: fetchMore complete. Added ${finalNewTweets.length} tweets. Total: ${combined.length}');
    } catch (e, st) {
      debugPrint('Error fetching more: $e\n$st');
      final latestState = state.value;
      if (latestState != null) {
        state = AsyncData(latestState.copyWith(isLoadingMore: false));
      }
    }
  }

  Future<void> toggleLike(String tweetId) async {
    final currentState = state.value;
    if (currentState == null) return;

    final tweetIndex = currentState.tweets.indexWhere((t) => t.id == tweetId);
    if (tweetIndex == -1) return;

    final tweet = currentState.tweets[tweetIndex];
    final newIsLiked = !tweet.isLiked;
    final newFavoriteCount = tweet.favoriteCount + (newIsLiked ? 1 : -1);

    // Optimistic UI Update
    final updatedTweet = tweet.copyWith(
      isLiked: newIsLiked,
      favoriteCount: newFavoriteCount >= 0 ? newFavoriteCount : 0,
    );

    final updatedTweets = List<Tweet>.from(currentState.tweets);
    updatedTweets[tweetIndex] = updatedTweet;
    state = AsyncData(currentState.copyWith(tweets: updatedTweets));

    // API Call
    final client = ref.read(twitterClientProvider);
    final success = newIsLiked
        ? await client.favoriteTweet(tweetId)
        : await client.unfavoriteTweet(tweetId);

    if (!success) {
      // Revert on failure
      // Reading this provider from inside itself trips Riverpod's
      // "A provider cannot depend on itself" assertion; `state` is the same
      // (and fresher) value.
      final currentAsync = state;
      if (currentAsync.hasValue) {
        final latestState = currentAsync.value!;
        final idx = latestState.tweets.indexWhere((t) => t.id == tweetId);
        if (idx != -1) {
          final revertedTweets = List<Tweet>.from(latestState.tweets);
          revertedTweets[idx] = tweet; // original tweet
          state = AsyncData(latestState.copyWith(tweets: revertedTweets));
        }
      }
      AppLogger.log('XFLOW: Failed to toggle like for $tweetId, reverted.');
      return;
    }

    // Persist so the like survives the item being re-read from the cache. It
    // used to live only in memory: the same tweet coming back from the local
    // pool showed "0 likes / not liked" again.
    try {
      await Repository.updateLikeState(tweetId,
          isLiked: newIsLiked,
          favoriteCount: updatedTweet.favoriteCount);
    } catch (e) {
      AppLogger.log('XFLOW: Could not persist like for $tweetId: $e');
    }
    AppLogger.log(
        'XFLOW: Successfully toggled like for $tweetId to $newIsLiked');
  }
}

final feedNotifierProvider =
    AsyncNotifierProvider.autoDispose<FeedNotifier, FeedState>(
        () => FeedNotifier());
