import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/repository.dart';
import '../../core/models/tweet.dart';
import '../feed/feed_provider.dart';
import '../settings/settings_provider.dart';

/// Keyword search over X's SearchTimeline. Kept separate from the subscription
/// feed so a search never silently mixes in recommendation results.
class SearchNotifier extends AsyncNotifier<FeedState> {
  String _keyword = '';
  Set<MediaFilter> _filters = <MediaFilter>{};
  String? _activeQuery;
  FeedSort _activeSort = FeedSort.latest;
  bool _inFlight = false;

  @override
  Future<FeedState> build() async {
    return FeedState(tweets: const <Tweet>[], hasMore: false);
  }

  String get keyword => _keyword;
  Set<MediaFilter> get filters => _filters;

  /// Maps chip selection to X search operators, mirroring the topic feed's
  /// query builder but without turning the keyword into a hashtag.
  String buildQuery(String keyword, Set<MediaFilter> filters) {
    final q = keyword.trim();
    if (q.isEmpty) return q;
    if (filters.isEmpty) return '$q (filter:images OR filter:videos)';

    final wantsVideo = filters.contains(MediaFilter.video);
    final wantsImage = filters.contains(MediaFilter.image);
    final wantsText = filters.contains(MediaFilter.text);

    if (wantsVideo && wantsImage && !wantsText) {
      return '$q (filter:images OR filter:videos)';
    }
    if (wantsVideo && !wantsImage && !wantsText) return '$q filter:videos';
    if (wantsImage && !wantsVideo && !wantsText) return '$q filter:images';
    // Text-only or mixed selection: let _applyFilters post-filter the result.
    return q;
  }

  Future<void> search(String rawKeyword, {Set<MediaFilter>? filters}) async {
    final keyword = rawKeyword.trim();
    if (keyword.isEmpty) {
      _keyword = '';
      state = AsyncData(FeedState(tweets: const <Tweet>[], hasMore: false));
      return;
    }
    if (_inFlight) return;
    _inFlight = true;
    state = const AsyncLoading();

    _keyword = keyword;
    _filters = filters ?? <MediaFilter>{};
    final query = buildQuery(_keyword, _filters);
    _activeQuery = query;
    _activeSort = FeedSort.latest;

    try {
      final client = ref.read(twitterClientProvider);
      final settings = ref.read(settingsProvider);
      final response = await client.fetchTrendingMedia(
        query: query,
        sort: FeedSort.latest,
        filters: _filters,
        count: settings.timelineBatchSize,
        timeoutSeconds: settings.apiTimeoutSeconds,
        cooldownMinutes: settings.cooldownDuration,
      );
      final tweets = await Repository.filterWatched(response.tweets,
          enabled: settings.avoidWatchedContent);
      state = AsyncData(FeedState(
        tweets: tweets,
        cursorBottom: response.cursorBottom,
        hasMore: response.cursorBottom != null,
        rateLimited: response.rateLimited,
      ));
    } catch (e, st) {
      state = AsyncError(e, st);
    } finally {
      _inFlight = false;
    }
  }

  Future<void> refresh() => search(_keyword, filters: _filters);

  Future<void> fetchMore() async {
    final current = state.value;
    if (current == null ||
        current.isLoadingMore ||
        !current.hasMore ||
        current.cursorBottom == null ||
        _activeQuery == null) {
      return;
    }
    state = AsyncData(current.copyWith(isLoadingMore: true));

    try {
      final client = ref.read(twitterClientProvider);
      final settings = ref.read(settingsProvider);
      final response = await client.fetchTrendingMedia(
        query: _activeQuery,
        cursor: current.cursorBottom,
        sort: _activeSort,
        filters: _filters,
        count: settings.loadBatchSize,
        timeoutSeconds: settings.apiTimeoutSeconds,
        cooldownMinutes: settings.cooldownDuration,
      );

      final latest = state.value ?? current;
      final seen = latest.tweets.map((t) => t.id).toSet();
      final unique = await Repository.filterWatched(
        response.tweets.where((t) => !seen.contains(t.id)).toList(),
        enabled: settings.avoidWatchedContent,
      );

      state = AsyncData(latest.copyWith(
        tweets: [...latest.tweets, ...unique],
        cursorBottom: response.cursorBottom,
        clearCursor: response.cursorBottom == null,
        isLoadingMore: false,
        hasMore: response.cursorBottom != null,
        rateLimited: response.rateLimited,
      ));
    } catch (e) {
      final latest = state.value ?? current;
      state = AsyncData(latest.copyWith(isLoadingMore: false));
    }
  }
}

final searchProvider =
    AsyncNotifierProvider<SearchNotifier, FeedState>(SearchNotifier.new);
