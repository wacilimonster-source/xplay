import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/repository.dart';
import 'feed_provider.dart';
import '../settings/settings_provider.dart';

class HashtagListNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async {
    return Repository.getHashtags();
  }

  Future<void> addHashtag(String tag) async {
    final cleanTag = tag.startsWith('#') ? tag : '#$tag';
    await Repository.addHashtag(cleanTag);
    ref.invalidateSelf();
  }

  Future<void> removeHashtag(String tag) async {
    // Tags are stored normalised with a leading '#'; deleting by a value that
    // lacks it matched nothing and the tag reappeared.
    await Repository.deleteHashtag(_normalizeHashtag(tag));
    ref.invalidateSelf();
  }
}

final hashtagListProvider =
    AsyncNotifierProvider<HashtagListNotifier, List<String>>(
  () => HashtagListNotifier(),
);

String _normalizeHashtag(String hashtag) {
  final trimmed = hashtag.trim();
  if (trimmed.isEmpty) return trimmed;
  return trimmed.startsWith('#') ? trimmed : '#$trimmed';
}

/// Builds the search query for a topic, honouring the content-type filters.
/// `(filter:images OR filter:videos)` used to be hard-coded, which meant the
/// "只看视频 / 只看图片 / 只看文字" chips had no effect at all in this feed.
String _searchQuery(String hashtag, Set<MediaFilter> filters) {
  final normalized = _normalizeHashtag(hashtag);
  if (filters.isEmpty) {
    return '$normalized (filter:images OR filter:videos)';
  }
  final wantsVideo = filters.contains(MediaFilter.video);
  final wantsImage = filters.contains(MediaFilter.image);
  final wantsText = filters.contains(MediaFilter.text);

  if (wantsVideo && wantsImage && !wantsText) {
    return '$normalized (filter:images OR filter:videos)';
  }
  if (wantsVideo && !wantsImage && !wantsText) {
    return '$normalized filter:videos';
  }
  if (wantsImage && !wantsVideo && !wantsText) {
    return '$normalized filter:images';
  }
  // Text-only (or a mixed selection): search the bare topic and let
  // fetchTrendingMedia narrow it down / _applyFilters post-filter it.
  return normalized;
}

class HashtagMediaNotifier extends AsyncNotifier<FeedState> {
  HashtagMediaNotifier(this.arg);
  final String arg;
  String? _activeQuery;
  FeedSort _activeSort = FeedSort.trending;
  bool _refreshInFlight = false;

  @override
  Future<FeedState> build() async {
    final hashtag = arg;
    final client = ref.watch(twitterClientProvider);
    final settings = ref.watch(settingsProvider.select((s) => s.fetchSnapshot));
    final live = ref.read(settingsProvider);
    final mediaQuery = _searchQuery(hashtag, settings.filters);
    final plainQuery = _normalizeHashtag(hashtag);

    var response = await client.fetchTrendingMedia(
      query: mediaQuery,
      count: live.timelineBatchSize,
      filters: live.filters,
      sort: FeedSort.trending,
    );
    _activeQuery = mediaQuery;
    _activeSort = FeedSort.trending;

    if (response.tweets.isEmpty && !response.rateLimited) {
      response = await client.fetchTrendingMedia(
        query: mediaQuery,
        count: live.timelineBatchSize,
        filters: live.filters,
        sort: FeedSort.latest,
      );
      _activeSort = FeedSort.latest;
    }

    // Only widen to a plain text search when the media query genuinely found
    // nothing (not when we are rate limited or the ids are broken).
    if (response.tweets.isEmpty &&
        !response.rateLimited &&
        !response.allPathsFailed) {
      response = await client.fetchTrendingMedia(
        query: plainQuery,
        count: live.timelineBatchSize,
        filters: live.filters,
        sort: FeedSort.latest,
      );
      _activeQuery = plainQuery;
      _activeSort = FeedSort.latest;
    }

    final filteredTweets = await Repository.filterWatched(response.tweets,
        enabled: live.avoidWatchedContent);
    return FeedState(
      tweets: filteredTweets,
      cursorBottom: response.cursorBottom,
      isRefreshing: false,
      hasMore: response.cursorBottom != null,
      rateLimited: response.rateLimited,
    );
  }

  Future<void> refresh() async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(
          isRefreshing: true, clearCursor: true, hasMore: true));
    }
    try {
      ref.invalidateSelf();
      await future;
    } catch (_) {
      if (current != null) {
        state = AsyncData(current.copyWith(isRefreshing: false));
      }
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<void> fetchMore() async {
    final currentState = state.value;
    if (currentState == null ||
        currentState.isLoadingMore ||
        !currentState.hasMore ||
        currentState.cursorBottom == null) {
      return;
    }

    state = AsyncData(currentState.copyWith(isLoadingMore: true));

    final client = ref.read(twitterClientProvider);
    final settings = ref.read(settingsProvider);
    final query = _activeQuery ?? _searchQuery(arg, settings.filters);

    try {
      final response = await client.fetchTrendingMedia(
        query: query,
        cursor: currentState.cursorBottom,
        count: settings.loadBatchSize,
        filters: settings.filters,
        sort: _activeSort,
      );

      // Use this notifier's own `state` (reading the provider from inside itself
      // trips Riverpod's "A provider cannot depend on itself" assertion): a
      // concurrent `refresh()` may have replaced the list, and writing the old
      // snapshot back would drop the new page.
      final latest = state.value ?? currentState;
      final seenIds = latest.tweets.map((t) => t.id).toSet();
      final uniqueNew = await Repository.filterWatched(
        response.tweets.where((t) => !seenIds.contains(t.id)).toList(),
        enabled: settings.avoidWatchedContent,
      );

      state = AsyncData(latest.copyWith(
        tweets: [...latest.tweets, ...uniqueNew],
        cursorBottom: response.cursorBottom,
        isLoadingMore: false,
        hasMore: response.cursorBottom != null,
        rateLimited: response.rateLimited,
      ));
    } catch (e) {
      final latest = state.value ?? currentState;
      state = AsyncData(latest.copyWith(isLoadingMore: false));
    }
  }
}

final hashtagMediaProvider =
    AsyncNotifierProvider.family<HashtagMediaNotifier, FeedState, String>(
  HashtagMediaNotifier.new,
);
