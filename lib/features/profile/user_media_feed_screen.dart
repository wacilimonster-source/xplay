import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/navigation/navigation_provider.dart';
import '../../core/utils/lifecycle_provider.dart';
import '../player/player_pool_provider.dart';
import 'profile_provider.dart';
import '../player/widgets/media_container.dart';
import '../../core/models/tweet.dart';
import '../feed/widgets/tweet_text_overlay.dart';
import '../settings/settings_provider.dart';
import '../settings/settings_screen.dart';

class UserMediaFeedScreen extends ConsumerStatefulWidget {
  final String screenName;
  final int initialIndex;
  final String? initialTweetId;

  const UserMediaFeedScreen({
    super.key,
    required this.screenName,
    required this.initialIndex,
    this.initialTweetId,
  });

  @override
  ConsumerState<UserMediaFeedScreen> createState() =>
      _UserMediaFeedScreenState();
}

class _UserMediaFeedScreenState extends ConsumerState<UserMediaFeedScreen> {
  late PageController _pageController;
  late int _currentIndex;
  bool _initialized = false;
  bool _poolUpdateQueued = false;
  String? _currentTweetId;

  /// Own scope in the shared player pool, so this screen and the home feed
  /// cannot dispose each other's live players.
  String get poolScope => 'user:${widget.screenName}';

  /// Captured at init: touching `ref` inside `dispose()` is unsafe in Riverpod.
  late final PlayerPoolNotifier _pool;

  @override
  void initState() {
    super.initState();
    // Resolve the notifier up front: a lazily-initialised field would first be
    // read inside dispose(), where touching `ref` is unsafe in Riverpod.
    _pool = ref.read(playerPoolProvider.notifier);
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _pageController.removeListener(_handleScroll);
    _pageController.dispose();
    _pool.releaseScope(poolScope);
    super.dispose();
  }

  void _handleScroll() {
    if (!_pageController.hasClients) return;
    final page = _pageController.page?.round() ?? 0;
    if (page != _currentIndex) {
      setState(() {
        _currentIndex = page;
        _currentTweetId = _tweetIdAt(page);
      });
      _managePool();

      final state =
          ref.read(userMediaNotifierProvider(widget.screenName)).value;
      if (state != null) {
        final settings = ref.read(settingsProvider);
        if (page >= state.tweets.length - settings.lazyLoadThreshold &&
            !state.isLoadingMore &&
            state.hasMore) {
          ref
              .read(userMediaNotifierProvider(widget.screenName).notifier)
              .fetchMore();
        }
      }
    }
  }

  String? _tweetIdAt(int page) {
    final state = ref.read(userMediaNotifierProvider(widget.screenName)).value;
    if (state == null || page < 0 || page >= state.tweets.length) return null;
    return state.tweets[page].id;
  }

  /// Index the full-screen feed should open at, or null when the tapped tweet
  /// has not arrived yet (so the caller keeps waiting for the next page).
  int? _resolveInitialIndex(List<Tweet> tweets, {required bool stillLoading}) {
    if (widget.initialTweetId != null) {
      final found =
          tweets.indexWhere((t) => t.id == widget.initialTweetId);
      if (found != -1) return found;
      if (stillLoading) return null;
    }
    return widget.initialIndex.clamp(0, tweets.length - 1);
  }

  void _jumpTo(int index, List<Tweet> tweets) {
    if (_pageController.hasClients) _pageController.jumpToPage(index);
    setState(() {
      _currentIndex = index;
      _currentTweetId = index < tweets.length ? tweets[index].id : null;
    });
  }

  /// Keeps the same tweet on screen when the list grew or was re-sorted.
  void _reanchorIfNeeded(List<Tweet> tweets) {
    final id = _currentTweetId;
    if (id == null) return;
    if (_currentIndex < tweets.length &&
        tweets[_currentIndex].id == id) {
      return;
    }
    final idx = tweets.indexWhere((t) => t.id == id);
    if (idx == -1) {
      _currentIndex = _currentIndex.clamp(0, tweets.length - 1);
      _currentTweetId = _tweetIdAt(_currentIndex);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpTo(idx, tweets);
    });
  }

  void _managePool() {
    if (_poolUpdateQueued) return;
    _poolUpdateQueued = true;
    // Use a microtask to avoid building-phase conflicts
    Future.microtask(() {
      _poolUpdateQueued = false;
      if (!mounted) return;
      final feedAsync = ref.read(userMediaNotifierProvider(widget.screenName));
      final state = feedAsync.value;
      if (state == null) return;
      final tweets = state.tweets;

      final pool = ref.read(playerPoolProvider.notifier);
      final activeIds = <String>{};

      for (int i = _currentIndex - 1; i <= _currentIndex + 3; i++) {
        if (i >= 0 && i < tweets.length) {
          final tweet = tweets[i];
          activeIds.add(tweet.id);

          if (tweet.isVideo && tweet.mediaUrls.isNotEmpty) {
            pool.warmup(tweet.id, tweet.mediaUrls.first, scope: poolScope);
          } else if (tweet.mediaUrls.isNotEmpty) {
            for (final url in tweet.mediaUrls) {
              precacheImage(NetworkImage(url), context);
            }
          }
        }
      }
      pool.cleanupExcept(poolScope, activeIds);
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(userMediaNotifierProvider(widget.screenName));
    final appActive = ref.watch(lifecycleProvider) == AppLifecycle.resumed;

    // Listen for data arrival to handle initial index adjustment if list shifted
    ref.listen(userMediaNotifierProvider(widget.screenName), (prev, next) {
      final state = next.value;
      if (state == null) return;
      final tweets = state.tweets;
      if (tweets.isEmpty) {
        _managePool();
        return;
      }
      if (!_initialized) {
        final target = _resolveInitialIndex(tweets, stillLoading: state.isRefreshing);
        if (target != null) {
          _initialized = true;
          _jumpTo(target, tweets);
        }
        // Not found yet: keep waiting for the fresh page instead of locking onto
        // the cache-only list, which shifted every index once new tweets merged
        // in — the user tapped post #40 and got a different one.
      } else {
        _reanchorIfNeeded(tweets);
      }
      _managePool();
    });
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => ref.read(navigationProvider.notifier).back(),
        ),
        title: Text('@${widget.screenName}',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () => ref
                .read(userMediaNotifierProvider(widget.screenName).notifier)
                .refresh(),
          ),
          Consumer(
            builder: (context, ref, child) {
              final settings = ref.watch(settingsProvider);
              return IconButton(
                icon: Icon(
                  settings.userDetailAvoidWatchedContent
                      ? Icons.filter_alt
                      : Icons.filter_alt_off,
                  color: Colors.white,
                ),
                tooltip: settings.userDetailAvoidWatchedContent
                    ? '已开启过滤已看内容'
                    : '未过滤已看内容',
                onPressed: () {
                  ref
                      .read(settingsProvider.notifier)
                      .updateUserDetailAvoidWatchedContent(
                          !settings.userDetailAvoidWatchedContent);
                  ref.invalidate(userMediaNotifierProvider(widget.screenName));
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: feedAsync.when(
        data: (state) {
          final tweets = state.tweets;
          if (tweets.isEmpty) {
            if (state.isRefreshing) {
              return const Center(child: CircularProgressIndicator());
            }
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('未找到媒体内容',
                      style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => ref
                        .read(userMediaNotifierProvider(widget.screenName)
                            .notifier)
                        .refresh(),
                    child: const Text('刷新'),
                  ),
                ],
              ),
            );
          }

          // Ensure pool is warmed up for current view
          _managePool();

          return Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: tweets.length,
                itemBuilder: (context, index) {
                  final settings = ref.read(settingsProvider);
                  final tweet = tweets[index];
                  return UserMediaFeedItem(
                    key: ValueKey('user_feed_${tweet.id}'),
                    tweet: tweet,
                    poolScope: poolScope,
                    isVisible: index == _currentIndex && appActive,
                    onPlaybackError: () {
                      if (index == _currentIndex && mounted) {
                        Future.delayed(
                            Duration(seconds: settings.autoSkipDelaySeconds),
                            () {
                          if (mounted && _currentIndex == index) {
                            _pageController.nextPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut,
                            );
                          }
                        });
                      }
                    },
                  );
                },
              ),
              if (state.isRefreshing)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('错误：$e', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref
                    .read(userMediaNotifierProvider(widget.screenName).notifier)
                    .refresh(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class UserMediaFeedItem extends StatelessWidget {
  final Tweet tweet;
  final bool isVisible;
  final bool autoFullscreen;
  final String poolScope;
  final VoidCallback? onPlaybackError;

  const UserMediaFeedItem({
    super.key,
    required this.tweet,
    required this.isVisible,
    this.autoFullscreen = false,
    this.poolScope = 'user',
    this.onPlaybackError,
  });

  @override
  Widget build(BuildContext context) {
    return TiktokMediaContainer(
      tweet: tweet,
      isVisible: isVisible,
      autoFullscreen: autoFullscreen,
      poolScope: poolScope,
      overlayBuilder: (context, onFullscreen, isFullscreen) => TweetTextOverlay(
        tweet: tweet,
        onFullscreen: onFullscreen,
        isFullscreen: isFullscreen,
      ),
      onPlaybackError: onPlaybackError,
    );
  }
}
