import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum FeedSort {
  latest,
  popular,
  trending,
  algorithmic,
  chronological,
  videomixer
}

enum MediaFilter { video, image, text }

enum VideoEndAction { pause, replay, playNext }

/// The single source of truth for defaults.
///
/// The hard-coded constructor defaults and the `_init()` fallbacks used to
/// disagree (filters `{image,text}` vs "everything", `chronological` vs
/// `latest`), so a fresh install briefly queried the cache with the wrong
/// filters and then rebuilt the feed once the preferences finished loading.
class SettingsDefaults {
  SettingsDefaults._();

  /// Empty means "no filtering" — the sane default for a media player.
  static const Set<MediaFilter> filters = <MediaFilter>{};
  static const bool autoplay = true;
  static const bool isListView = false;
  static const int mediaCacheSizeMB = 500;
  static const int syncInterval = 15;
  static const int syncBatchSize = 10;
  static const int loadBatchSize = 20;
  static const int timelineBatchSize = 20;
  static const int cooldownDuration = 15;
  static const int pruneThreshold = 50000;
  static const bool avoidWatchedContent = true;
  static const bool unseenSubscriptionBoost = true;
  static const bool userDetailAvoidWatchedContent = false;
  static const double freshMixRatio = 0.3;
  static const int saturationThreshold = 2;
  static const int mediaSaturationThreshold = 1;
  static const FeedSort fetchStrategy = FeedSort.chronological;
  static const int initialSyncCount = 10;
  static const bool strictSubscriptionsOnly = true;
  static const bool includeNativeRetweets = false;
  static const bool useChunkedSubscriptions = true;
  static const bool showDebugInfo = false;
  static const int saturationWindow = 10;
  static const int unseenBoostLookahead = 6;
  static const int minFavesFilter = 50;
  static const int dbCandidateMultiplier = 5;
  static const int apiRetryLimit = 5;
  static const int chunkRotationLimit = 3;
  static const int minNewTweetsThreshold = 5;
  static const int maxQueryLength = 480;
  static const int apiTimeoutSeconds = 15;
  static const int maxSaturationSwaps = 1000;
  static const int maxSaturationPasses = 3;
  static const int playbackRetryLimit = 1;
  static const int autoSkipDelaySeconds = 2;
  static const int lazyLoadThreshold = 10;
  static const int mediaDeduplicationWindow = 50;
  static const VideoEndAction videoEndAction = VideoEndAction.playNext;
}

/// Value-equality slice of [SettingsState] covering only what changes *what we
/// fetch*. Feeding this to `settingsProvider.select` stops unrelated sliders
/// (cache size, timeouts, debug toggles) from tearing down and rebuilding the
/// feed the user is scrolling through.
@immutable
class SettingsSnapshot {
  final Set<MediaFilter> filters;
  final bool avoidWatchedContent;
  final int loadBatchSize;
  final int dbCandidateMultiplier;
  final FeedSort fetchStrategy;
  final bool isInitialized;

  const SettingsSnapshot({
    required this.filters,
    required this.avoidWatchedContent,
    required this.loadBatchSize,
    required this.dbCandidateMultiplier,
    required this.fetchStrategy,
    required this.isInitialized,
  });

  @override
  bool operator ==(Object other) =>
      other is SettingsSnapshot &&
      other.isInitialized == isInitialized &&
      other.avoidWatchedContent == avoidWatchedContent &&
      other.loadBatchSize == loadBatchSize &&
      other.dbCandidateMultiplier == dbCandidateMultiplier &&
      other.fetchStrategy == fetchStrategy &&
      setEquals(other.filters, filters);

  @override
  int get hashCode => Object.hash(
      Object.hashAll(filters.toList()..sort((a, b) => a.index - b.index)),
      avoidWatchedContent,
      loadBatchSize,
      dbCandidateMultiplier,
      fetchStrategy,
      isInitialized);
}

/// True when both filter sets contain the same members.
bool setEquals(Set<MediaFilter> a, Set<MediaFilter> b) {
  if (a.length != b.length) return false;
  for (final item in a) {
    if (!b.contains(item)) return false;
  }
  return true;
}

class SettingsState {
  final bool isInitialized;
  final Set<MediaFilter> filters;
  final bool autoplay;
  final bool isListView;
  final int mediaCacheSizeMB;

  // New architectural parameters
  final int syncInterval;
  final int syncBatchSize;
  final int loadBatchSize;
  final int timelineBatchSize;
  final int cooldownDuration;
  final int pruneThreshold;

  // New Discovery Algorithm parameters
  final bool avoidWatchedContent;
  final bool unseenSubscriptionBoost;

  // User detail page behavior
  final bool userDetailAvoidWatchedContent;
  final double freshMixRatio;
  final int saturationThreshold;
  final int mediaSaturationThreshold;
  final FeedSort fetchStrategy;
  final int initialSyncCount;
  final bool strictSubscriptionsOnly;
  final bool includeNativeRetweets;
  final bool useChunkedSubscriptions;
  final bool showDebugInfo;

  // Granular Discovery parameters
  final int saturationWindow;
  final int unseenBoostLookahead;
  final int minFavesFilter;

  // Advanced Tuning
  final int dbCandidateMultiplier;
  final int apiRetryLimit;
  final int chunkRotationLimit;
  final int minNewTweetsThreshold;
  final int maxQueryLength;
  final int apiTimeoutSeconds;
  final int maxSaturationSwaps;
  final int maxSaturationPasses;

  // Playback & UI Tuning
  final int playbackRetryLimit;
  final int autoSkipDelaySeconds;
  final int lazyLoadThreshold;
  final int mediaDeduplicationWindow;
  final VideoEndAction videoEndAction;

  SettingsState({
    this.isInitialized = false,
    this.filters = SettingsDefaults.filters,
    this.autoplay = SettingsDefaults.autoplay,
    this.isListView = SettingsDefaults.isListView,
    this.mediaCacheSizeMB = SettingsDefaults.mediaCacheSizeMB,
    this.syncInterval = SettingsDefaults.syncInterval,
    this.syncBatchSize = SettingsDefaults.syncBatchSize,
    this.loadBatchSize = SettingsDefaults.loadBatchSize,
    this.timelineBatchSize = SettingsDefaults.timelineBatchSize,
    this.cooldownDuration = SettingsDefaults.cooldownDuration,
    this.pruneThreshold = SettingsDefaults.pruneThreshold,
    this.avoidWatchedContent = SettingsDefaults.avoidWatchedContent,
    this.unseenSubscriptionBoost = SettingsDefaults.unseenSubscriptionBoost,
    this.userDetailAvoidWatchedContent =
        SettingsDefaults.userDetailAvoidWatchedContent,
    this.freshMixRatio = SettingsDefaults.freshMixRatio,
    this.saturationThreshold = SettingsDefaults.saturationThreshold,
    this.mediaSaturationThreshold = SettingsDefaults.mediaSaturationThreshold,
    this.fetchStrategy = SettingsDefaults.fetchStrategy,
    this.initialSyncCount = SettingsDefaults.initialSyncCount,
    this.strictSubscriptionsOnly = SettingsDefaults.strictSubscriptionsOnly,
    this.includeNativeRetweets = SettingsDefaults.includeNativeRetweets,
    this.useChunkedSubscriptions = SettingsDefaults.useChunkedSubscriptions,
    this.showDebugInfo = SettingsDefaults.showDebugInfo,
    this.saturationWindow = SettingsDefaults.saturationWindow,
    this.unseenBoostLookahead = SettingsDefaults.unseenBoostLookahead,
    this.minFavesFilter = SettingsDefaults.minFavesFilter,
    this.dbCandidateMultiplier = SettingsDefaults.dbCandidateMultiplier,
    this.apiRetryLimit = SettingsDefaults.apiRetryLimit,
    this.chunkRotationLimit = SettingsDefaults.chunkRotationLimit,
    this.minNewTweetsThreshold = SettingsDefaults.minNewTweetsThreshold,
    this.maxQueryLength = SettingsDefaults.maxQueryLength,
    this.apiTimeoutSeconds = SettingsDefaults.apiTimeoutSeconds,
    this.maxSaturationSwaps = SettingsDefaults.maxSaturationSwaps,
    this.maxSaturationPasses = SettingsDefaults.maxSaturationPasses,
    this.playbackRetryLimit = SettingsDefaults.playbackRetryLimit,
    this.autoSkipDelaySeconds = SettingsDefaults.autoSkipDelaySeconds,
    this.lazyLoadThreshold = SettingsDefaults.lazyLoadThreshold,
    this.mediaDeduplicationWindow = SettingsDefaults.mediaDeduplicationWindow,
    this.videoEndAction = SettingsDefaults.videoEndAction,
  });

  SettingsSnapshot get fetchSnapshot => SettingsSnapshot(
        filters: filters,
        avoidWatchedContent: avoidWatchedContent,
        loadBatchSize: loadBatchSize,
        dbCandidateMultiplier: dbCandidateMultiplier,
        fetchStrategy: fetchStrategy,
        isInitialized: isInitialized,
      );

  SettingsState copyWith({
    bool? isInitialized,
    Set<MediaFilter>? filters,
    bool? autoplay,
    bool? isListView,
    int? mediaCacheSizeMB,
    int? syncInterval,
    int? syncBatchSize,
    int? loadBatchSize,
    int? timelineBatchSize,
    int? cooldownDuration,
    int? pruneThreshold,
    bool? avoidWatchedContent,
    bool? unseenSubscriptionBoost,
    bool? userDetailAvoidWatchedContent,
    double? freshMixRatio,
    int? saturationThreshold,
    int? mediaSaturationThreshold,
    FeedSort? fetchStrategy,
    int? initialSyncCount,
    bool? strictSubscriptionsOnly,
    bool? includeNativeRetweets,
    bool? useChunkedSubscriptions,
    bool? showDebugInfo,
    int? saturationWindow,
    int? unseenBoostLookahead,
    int? minFavesFilter,
    int? dbCandidateMultiplier,
    int? apiRetryLimit,
    int? chunkRotationLimit,
    int? minNewTweetsThreshold,
    int? maxQueryLength,
    int? apiTimeoutSeconds,
    int? maxSaturationSwaps,
    int? maxSaturationPasses,
    int? playbackRetryLimit,
    int? autoSkipDelaySeconds,
    int? lazyLoadThreshold,
    int? mediaDeduplicationWindow,
    VideoEndAction? videoEndAction,
  }) {
    return SettingsState(
      isInitialized: isInitialized ?? this.isInitialized,
      filters: filters ?? this.filters,
      autoplay: autoplay ?? this.autoplay,
      isListView: isListView ?? this.isListView,
      mediaCacheSizeMB: mediaCacheSizeMB ?? this.mediaCacheSizeMB,
      syncInterval: syncInterval ?? this.syncInterval,
      syncBatchSize: syncBatchSize ?? this.syncBatchSize,
      loadBatchSize: loadBatchSize ?? this.loadBatchSize,
      timelineBatchSize: timelineBatchSize ?? this.timelineBatchSize,
      cooldownDuration: cooldownDuration ?? this.cooldownDuration,
      pruneThreshold: pruneThreshold ?? this.pruneThreshold,
      avoidWatchedContent: avoidWatchedContent ?? this.avoidWatchedContent,
      unseenSubscriptionBoost:
          unseenSubscriptionBoost ?? this.unseenSubscriptionBoost,
      userDetailAvoidWatchedContent: userDetailAvoidWatchedContent ??
          this.userDetailAvoidWatchedContent,
      freshMixRatio: freshMixRatio ?? this.freshMixRatio,
      saturationThreshold: saturationThreshold ?? this.saturationThreshold,
      mediaSaturationThreshold:
          mediaSaturationThreshold ?? this.mediaSaturationThreshold,
      fetchStrategy: fetchStrategy ?? this.fetchStrategy,
      initialSyncCount: initialSyncCount ?? this.initialSyncCount,
      strictSubscriptionsOnly:
          strictSubscriptionsOnly ?? this.strictSubscriptionsOnly,
      includeNativeRetweets:
          includeNativeRetweets ?? this.includeNativeRetweets,
      useChunkedSubscriptions:
          useChunkedSubscriptions ?? this.useChunkedSubscriptions,
      showDebugInfo: showDebugInfo ?? this.showDebugInfo,
      saturationWindow: saturationWindow ?? this.saturationWindow,
      unseenBoostLookahead: unseenBoostLookahead ?? this.unseenBoostLookahead,
      minFavesFilter: minFavesFilter ?? this.minFavesFilter,
      dbCandidateMultiplier:
          dbCandidateMultiplier ?? this.dbCandidateMultiplier,
      apiRetryLimit: apiRetryLimit ?? this.apiRetryLimit,
      chunkRotationLimit: chunkRotationLimit ?? this.chunkRotationLimit,
      minNewTweetsThreshold:
          minNewTweetsThreshold ?? this.minNewTweetsThreshold,
      maxQueryLength: maxQueryLength ?? this.maxQueryLength,
      apiTimeoutSeconds: apiTimeoutSeconds ?? this.apiTimeoutSeconds,
      maxSaturationSwaps: maxSaturationSwaps ?? this.maxSaturationSwaps,
      maxSaturationPasses: maxSaturationPasses ?? this.maxSaturationPasses,
      playbackRetryLimit: playbackRetryLimit ?? this.playbackRetryLimit,
      autoSkipDelaySeconds: autoSkipDelaySeconds ?? this.autoSkipDelaySeconds,
      lazyLoadThreshold: lazyLoadThreshold ?? this.lazyLoadThreshold,
      mediaDeduplicationWindow:
          mediaDeduplicationWindow ?? this.mediaDeduplicationWindow,
      videoEndAction: videoEndAction ?? this.videoEndAction,
    );
  }
}

class SettingsNotifier extends Notifier<SettingsState> {
  /// Resolved lazily instead of a `late SharedPreferences` field: any setter
  /// called during the first frames after launch used to throw
  /// `LateInitializationError` because `_init()` had not finished yet.
  Future<SharedPreferences>? _prefsFuture;

  @override
  SettingsState build() {
    _prefsFuture = null;
    _init();
    return SettingsState(isInitialized: false);
  }

  Future<SharedPreferences> get _prefs =>
      _prefsFuture ??= SharedPreferences.getInstance();

  /// Fire-and-forget write that still surfaces failures (the previous version
  /// ignored the returned Future, so a rejected write lost the setting silently
  /// and could crash the isolate with an unhandled async error).
  void _save(String key, FutureOr<void> Function(SharedPreferences) op) {
    _prefs.then((prefs) async {
      await op(prefs);
    }).catchError((Object e) {
      debugPrint('XFLOW: Could not persist "$key": $e');
    });
  }

  Future<void> flush() => _prefs.then((_) {});

  Future<void> _init() async {
    final prefs = await _prefs;
    final filterStrings =
        prefs.getStringList('filters') ?? SettingsDefaults.filters.map((f) => f.name).toList();

    final filters = filterStrings
        .map((s) {
          try {
            return MediaFilter.values.firstWhere((f) => f.name == s);
          } catch (_) {
            return null;
          }
        })
        .whereType<MediaFilter>()
        .toSet();

    final isListView = prefs.getBool('isListView') ?? SettingsDefaults.isListView;
    final mediaCacheSizeMB =
        prefs.getInt('mediaCacheSizeMB') ?? SettingsDefaults.mediaCacheSizeMB;

    final syncInterval = prefs.getInt('syncInterval') ?? SettingsDefaults.syncInterval;
    final syncBatchSize = prefs.getInt('syncBatchSize') ?? SettingsDefaults.syncBatchSize;
    final loadBatchSize = prefs.getInt('loadBatchSize') ?? SettingsDefaults.loadBatchSize;
    final timelineBatchSize =
        prefs.getInt('timelineBatchSize') ?? SettingsDefaults.timelineBatchSize;
    final cooldownDuration =
        prefs.getInt('cooldownDuration') ?? SettingsDefaults.cooldownDuration;
    final pruneThreshold =
        prefs.getInt('pruneThreshold') ?? SettingsDefaults.pruneThreshold;

    final avoidWatchedContent =
        prefs.getBool('avoidWatchedContent') ?? SettingsDefaults.avoidWatchedContent;
    final userDetailAvoidWatchedContent =
        prefs.getBool('userDetailAvoidWatchedContent') ??
            SettingsDefaults.userDetailAvoidWatchedContent;
    final unseenSubscriptionBoost =
        prefs.getBool('unseenSubscriptionBoost') ??
            SettingsDefaults.unseenSubscriptionBoost;
    final freshMixRatio =
        prefs.getDouble('freshMixRatio') ?? SettingsDefaults.freshMixRatio;
    final saturationThreshold =
        prefs.getInt('saturationThreshold') ?? SettingsDefaults.saturationThreshold;
    final mediaSaturationThreshold =
        prefs.getInt('mediaSaturationThreshold') ??
            SettingsDefaults.mediaSaturationThreshold;
    final fetchStrategyIdx =
        prefs.getInt('fetchStrategy') ?? SettingsDefaults.fetchStrategy.index;
    final initialSyncCount =
        prefs.getInt('initialSyncCount') ?? SettingsDefaults.initialSyncCount;
    final strictSubscriptionsOnly =
        prefs.getBool('strictSubscriptionsOnly') ??
            SettingsDefaults.strictSubscriptionsOnly;
    final includeNativeRetweets =
        prefs.getBool('includeNativeRetweets') ??
            SettingsDefaults.includeNativeRetweets;
    final useChunkedSubscriptions =
        prefs.getBool('useChunkedSubscriptions') ??
            SettingsDefaults.useChunkedSubscriptions;
    final showDebugInfo =
        prefs.getBool('showDebugInfo') ?? SettingsDefaults.showDebugInfo;

    final saturationWindow =
        prefs.getInt('saturationWindow') ?? SettingsDefaults.saturationWindow;
    final unseenBoostLookahead =
        prefs.getInt('unseenBoostLookahead') ?? SettingsDefaults.unseenBoostLookahead;
    final minFavesFilter =
        prefs.getInt('minFavesFilter') ?? SettingsDefaults.minFavesFilter;

    final dbCandidateMultiplier =
        prefs.getInt('dbCandidateMultiplier') ?? SettingsDefaults.dbCandidateMultiplier;
    final apiRetryLimit =
        prefs.getInt('apiRetryLimit') ?? SettingsDefaults.apiRetryLimit;
    final chunkRotationLimit =
        prefs.getInt('chunkRotationLimit') ?? SettingsDefaults.chunkRotationLimit;
    final minNewTweetsThreshold =
        prefs.getInt('minNewTweetsThreshold') ?? SettingsDefaults.minNewTweetsThreshold;
    final maxQueryLength =
        prefs.getInt('maxQueryLength') ?? SettingsDefaults.maxQueryLength;
    final apiTimeoutSeconds =
        prefs.getInt('apiTimeoutSeconds') ?? SettingsDefaults.apiTimeoutSeconds;
    final maxSaturationSwaps =
        prefs.getInt('maxSaturationSwaps') ?? SettingsDefaults.maxSaturationSwaps;
    final maxSaturationPasses =
        prefs.getInt('maxSaturationPasses') ?? SettingsDefaults.maxSaturationPasses;
    final playbackRetryLimit =
        prefs.getInt('playbackRetryLimit') ?? SettingsDefaults.playbackRetryLimit;
    final autoSkipDelaySeconds =
        prefs.getInt('autoSkipDelaySeconds') ?? SettingsDefaults.autoSkipDelaySeconds;
    final lazyLoadThreshold =
        prefs.getInt('lazyLoadThreshold') ?? SettingsDefaults.lazyLoadThreshold;
    final mediaDeduplicationWindow =
        prefs.getInt('mediaDeduplicationWindow') ??
            SettingsDefaults.mediaDeduplicationWindow;
    final videoEndActionIdx =
        prefs.getInt('videoEndAction') ?? SettingsDefaults.videoEndAction.index;

    state = SettingsState(
      isInitialized: true,
      filters: filters,
      autoplay: prefs.getBool('autoplay') ?? SettingsDefaults.autoplay,
      isListView: isListView,
      mediaCacheSizeMB: mediaCacheSizeMB,
      syncInterval: syncInterval,
      syncBatchSize: syncBatchSize,
      loadBatchSize: loadBatchSize,
      timelineBatchSize: timelineBatchSize,
      cooldownDuration: cooldownDuration,
      pruneThreshold: pruneThreshold,
      avoidWatchedContent: avoidWatchedContent,
      unseenSubscriptionBoost: unseenSubscriptionBoost,
      userDetailAvoidWatchedContent: userDetailAvoidWatchedContent,
      freshMixRatio: freshMixRatio,
      saturationThreshold: saturationThreshold,
      mediaSaturationThreshold: mediaSaturationThreshold,
      fetchStrategy: fetchStrategyIdx < FeedSort.values.length
          ? FeedSort.values[fetchStrategyIdx]
          : SettingsDefaults.fetchStrategy,
      initialSyncCount: initialSyncCount,
      strictSubscriptionsOnly: strictSubscriptionsOnly,
      includeNativeRetweets: includeNativeRetweets,
      useChunkedSubscriptions: useChunkedSubscriptions,
      showDebugInfo: showDebugInfo,
      saturationWindow: saturationWindow,
      unseenBoostLookahead: unseenBoostLookahead,
      minFavesFilter: minFavesFilter,
      dbCandidateMultiplier: dbCandidateMultiplier,
      apiRetryLimit: apiRetryLimit,
      chunkRotationLimit: chunkRotationLimit,
      minNewTweetsThreshold: minNewTweetsThreshold,
      maxQueryLength: maxQueryLength,
      apiTimeoutSeconds: apiTimeoutSeconds,
      maxSaturationSwaps: maxSaturationSwaps,
      maxSaturationPasses: maxSaturationPasses,
      playbackRetryLimit: playbackRetryLimit,
      autoSkipDelaySeconds: autoSkipDelaySeconds,
      lazyLoadThreshold: lazyLoadThreshold,
      mediaDeduplicationWindow: mediaDeduplicationWindow,
      videoEndAction: videoEndActionIdx < VideoEndAction.values.length
          ? VideoEndAction.values[videoEndActionIdx]
          : SettingsDefaults.videoEndAction,
    );
  }

  void updateMediaCacheSize(int megabytes) {
    state = state.copyWith(mediaCacheSizeMB: megabytes);
    _save('mediaCacheSizeMB', (p) => p.setInt('mediaCacheSizeMB', megabytes));
  }

  void updateSyncInterval(int minutes) {
    state = state.copyWith(syncInterval: minutes);
    _save('syncInterval', (p) => p.setInt('syncInterval', minutes));
  }

  void updateSyncBatchSize(int size) {
    state = state.copyWith(syncBatchSize: size);
    _save('syncBatchSize', (p) => p.setInt('syncBatchSize', size));
  }

  void updateLoadBatchSize(int size) {
    state = state.copyWith(loadBatchSize: size);
    _save('loadBatchSize', (p) => p.setInt('loadBatchSize', size));
  }

  void updateTimelineBatchSize(int size) {
    state = state.copyWith(timelineBatchSize: size);
    _save('timelineBatchSize', (p) => p.setInt('timelineBatchSize', size));
  }

  void updateCooldownDuration(int minutes) {
    state = state.copyWith(cooldownDuration: minutes);
    _save('cooldownDuration', (p) => p.setInt('cooldownDuration', minutes));
  }

  void updatePruneThreshold(int count) {
    state = state.copyWith(pruneThreshold: count);
    _save('pruneThreshold', (p) => p.setInt('pruneThreshold', count));
  }

  void updateUserDetailAvoidWatchedContent(bool enabled) {
    state = state.copyWith(userDetailAvoidWatchedContent: enabled);
    _save('userDetailAvoidWatchedContent',
        (p) => p.setBool('userDetailAvoidWatchedContent', enabled));
  }

  void updateDiscoveryParam({
    bool? avoidWatchedContent,
    bool? unseenSubscriptionBoost,
    double? freshMixRatio,
    int? saturationThreshold,
    int? mediaSaturationThreshold,
    FeedSort? fetchStrategy,
    int? initialSyncCount,
    bool? strictSubscriptionsOnly,
    bool? includeNativeRetweets,
    bool? useChunkedSubscriptions,
    int? saturationWindow,
    int? unseenBoostLookahead,
    int? minFavesFilter,
    int? dbCandidateMultiplier,
    int? apiRetryLimit,
    int? chunkRotationLimit,
    int? minNewTweetsThreshold,
    int? maxQueryLength,
    int? apiTimeoutSeconds,
    int? maxSaturationSwaps,
    int? maxSaturationPasses,
    int? playbackRetryLimit,
    int? autoSkipDelaySeconds,
    int? lazyLoadThreshold,
    int? mediaDeduplicationWindow,
    VideoEndAction? videoEndAction,
  }) {
    state = state.copyWith(
      avoidWatchedContent: avoidWatchedContent,
      unseenSubscriptionBoost: unseenSubscriptionBoost,
      freshMixRatio: freshMixRatio,
      saturationThreshold: saturationThreshold,
      mediaSaturationThreshold: mediaSaturationThreshold,
      fetchStrategy: fetchStrategy,
      initialSyncCount: initialSyncCount,
      strictSubscriptionsOnly: strictSubscriptionsOnly,
      includeNativeRetweets: includeNativeRetweets,
      useChunkedSubscriptions: useChunkedSubscriptions,
      saturationWindow: saturationWindow,
      unseenBoostLookahead: unseenBoostLookahead,
      minFavesFilter: minFavesFilter,
      dbCandidateMultiplier: dbCandidateMultiplier,
      apiRetryLimit: apiRetryLimit,
      chunkRotationLimit: chunkRotationLimit,
      minNewTweetsThreshold: minNewTweetsThreshold,
      maxQueryLength: maxQueryLength,
      apiTimeoutSeconds: apiTimeoutSeconds,
      maxSaturationSwaps: maxSaturationSwaps,
      maxSaturationPasses: maxSaturationPasses,
      playbackRetryLimit: playbackRetryLimit,
      autoSkipDelaySeconds: autoSkipDelaySeconds,
      lazyLoadThreshold: lazyLoadThreshold,
      mediaDeduplicationWindow: mediaDeduplicationWindow,
      videoEndAction: videoEndAction,
    );

    void saveBool(String key, bool? value) {
      if (value != null) _save(key, (p) => p.setBool(key, value));
    }

    void saveInt(String key, int? value) {
      if (value != null) _save(key, (p) => p.setInt(key, value));
    }

    saveBool('avoidWatchedContent', avoidWatchedContent);
    saveBool('unseenSubscriptionBoost', unseenSubscriptionBoost);
    if (freshMixRatio != null) {
      _save('freshMixRatio', (p) => p.setDouble('freshMixRatio', freshMixRatio));
    }
    saveInt('saturationThreshold', saturationThreshold);
    saveInt('mediaSaturationThreshold', mediaSaturationThreshold);
    saveInt('fetchStrategy', fetchStrategy?.index);
    saveInt('initialSyncCount', initialSyncCount);
    saveBool('strictSubscriptionsOnly', strictSubscriptionsOnly);
    saveBool('includeNativeRetweets', includeNativeRetweets);
    saveBool('useChunkedSubscriptions', useChunkedSubscriptions);
    saveInt('saturationWindow', saturationWindow);
    saveInt('unseenBoostLookahead', unseenBoostLookahead);
    saveInt('minFavesFilter', minFavesFilter);
    saveInt('dbCandidateMultiplier', dbCandidateMultiplier);
    saveInt('apiRetryLimit', apiRetryLimit);
    saveInt('chunkRotationLimit', chunkRotationLimit);
    saveInt('minNewTweetsThreshold', minNewTweetsThreshold);
    saveInt('maxQueryLength', maxQueryLength);
    saveInt('apiTimeoutSeconds', apiTimeoutSeconds);
    saveInt('maxSaturationSwaps', maxSaturationSwaps);
    saveInt('maxSaturationPasses', maxSaturationPasses);
    saveInt('playbackRetryLimit', playbackRetryLimit);
    saveInt('autoSkipDelaySeconds', autoSkipDelaySeconds);
    saveInt('lazyLoadThreshold', lazyLoadThreshold);
    saveInt('mediaDeduplicationWindow', mediaDeduplicationWindow);
    saveInt('videoEndAction', videoEndAction?.index);
  }

  void toggleFilter(MediaFilter filter) {
    final nextFilters = Set<MediaFilter>.from(state.filters);
    if (nextFilters.contains(filter)) {
      nextFilters.remove(filter);
    } else {
      nextFilters.add(filter);
    }
    state = state.copyWith(filters: nextFilters);
    _save('filters',
        (p) => p.setStringList('filters', nextFilters.map((f) => f.name).toList()));
  }

  void setFilters(Set<MediaFilter> nextFilters) {
    state = state.copyWith(filters: nextFilters);
    _save('filters',
        (p) => p.setStringList('filters', nextFilters.map((f) => f.name).toList()));
  }

  void toggleAutoplay(bool value) {
    state = state.copyWith(autoplay: value);
    _save('autoplay', (p) => p.setBool('autoplay', value));
  }

  void toggleListView(bool value) {
    state = state.copyWith(isListView: value);
    _save('isListView', (p) => p.setBool('isListView', value));
  }

  void toggleDebugInfo(bool value) {
    state = state.copyWith(showDebugInfo: value);
    _save('showDebugInfo', (p) => p.setBool('showDebugInfo', value));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, SettingsState>(
  SettingsNotifier.new,
);
