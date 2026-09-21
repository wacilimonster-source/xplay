import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../player/player_pool_provider.dart';
import 'feed_provider.dart';
import '../player/widgets/media_container.dart';
import '../../core/models/tweet.dart';
import '../../core/database/repository.dart';
import '../../core/utils/lifecycle_provider.dart';
import '../settings/settings_screen.dart';
import '../settings/settings_provider.dart';
import '../auth/login_screen.dart';
import '../../core/client/account_provider.dart';
import '../../core/client/twitter_client.dart';
import '../../core/navigation/navigation_provider.dart';
import 'widgets/tweet_text_overlay.dart';

class TiktokFeedScreen extends ConsumerStatefulWidget {
  const TiktokFeedScreen({super.key});

  @override
  ConsumerState<TiktokFeedScreen> createState() => _TiktokFeedScreenState();
}

class _TiktokFeedScreenState extends ConsumerState<TiktokFeedScreen> {
  static const String poolScope = 'home';

  final PageController _pageController = PageController();
  int _currentIndex = 0;
  bool _poolUpdateQueued = false;

  /// Id of the tweet currently on screen. Kept so that a background refresh that
  /// reorders the list can move us back onto the same item instead of leaving us
  /// watching something else.
  String? _currentTweetId;

  /// Marks a page as watched only once the user has actually *stopped* on it.
  /// Marking on every `round()` change meant a fast fling through five posts
  /// silently burned all five as "already seen" (and the ones really watched
  /// were not marked), which with "避开已看" on makes content disappear.
  Timer? _settleMarkTimer;

  /// Pool notifier captured at init: Riverpod forbids touching `ref` from
  /// `dispose()` (the widget element is already being torn down).
  late final PlayerPoolNotifier _pool;

  @override
  void initState() {
    super.initState();
    // Resolve the notifier up front: a lazily-initialised field would first be
    // read inside dispose(), where touching `ref` is unsafe in Riverpod.
    _pool = ref.read(playerPoolProvider.notifier);
    _pageController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _settleMarkTimer?.cancel();
    _pageController.removeListener(_handleScroll);
    _pageController.dispose();
    _pool.releaseScope(poolScope);
    super.dispose();
  }

  void _handleScroll() {
    if (!_pageController.hasClients) return;
    final raw = _pageController.page;
    if (raw == null) return;
    final page = raw.round();

    if (page != _currentIndex) {
      setState(() {
        _currentIndex = page;
        _currentTweetId = _tweetIdAt(page);
      });
      ref.read(feedNotifierProvider.notifier).setActiveTweet(_currentTweetId);
      _managePool();
      _scheduleWatchedMark(page);

      final feedAsync = ref.read(feedNotifierProvider);
      final state = feedAsync.value;
      if (state != null) {
        final settings = ref.read(settingsProvider);
        if (page >= state.tweets.length - settings.lazyLoadThreshold &&
            !state.isRefreshing &&
            state.hasMore) {
          ref.read(feedNotifierProvider.notifier).fetchMore();
        }
      }
      return;
    }

    // Same index, but the swipe may have landed exactly on it: that is when the
    // "settled" mark fires for a user who stops without changing page.
    if (raw == raw.roundToDouble()) {
      _scheduleWatchedMark(page);
    }
  }

  String? _tweetIdAt(int page) {
    final state = ref.read(feedNotifierProvider).value;
    if (state == null || page < 0 || page >= state.tweets.length) return null;
    return state.tweets[page].id;
  }

  void _scheduleWatchedMark(int page) {
    _settleMarkTimer?.cancel();
    final tweetId = _tweetIdAt(page);
    if (tweetId == null) return;
    _settleMarkTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      // Still on the same page? Then the user really saw it.
      if (_pageController.hasClients &&
          (_pageController.page?.round() ?? -1) == page &&
          _tweetIdAt(page) == tweetId) {
        Repository.markMediaAsPlayed(tweetId);
        Repository.markWatched(tweetId,
            mediaKey: _mediaKeyAt(page));
      }
    });
  }

  String? _mediaKeyAt(int page) {
    final state = ref.read(feedNotifierProvider).value;
    if (state == null || page < 0 || page >= state.tweets.length) return null;
    return state.tweets[page].mediaKey;
  }

  /// Re-anchors the page after the list changed underneath the user.
  void _reanchorIfNeeded(List<Tweet> tweets) {
    final id = _currentTweetId;
    if (id == null || tweets.isEmpty) return;
    if (_currentIndex < tweets.length && tweets[_currentIndex].id == id) return;
    final idx = tweets.indexWhere((t) => t.id == id);
    if (idx == -1) {
      // The watched item is gone (e.g. filtered out); adopt whatever is there now.
      _currentIndex = _currentIndex.clamp(0, tweets.length - 1);
      _currentTweetId = _tweetIdAt(_currentIndex);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) _pageController.jumpToPage(idx);
      setState(() {
        _currentIndex = idx;
        _currentTweetId = id;
      });
    });
  }

  void _managePool() {
    if (_poolUpdateQueued) return;
    _poolUpdateQueued = true;
    Future.microtask(() {
      _poolUpdateQueued = false;
      if (!mounted) return;
      try {
        final feedAsync = ref.read(feedNotifierProvider);
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
      } catch (e) {
        debugPrint('XFLOW: Error in _managePool: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () {
            _pageController.jumpToPage(0);
            ref.read(feedNotifierProvider.notifier).refresh();
          },
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/app_icon.svg',
              height: 24,
              width: 24,
            ),
            const Text(
              "XPlay",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: _buildMediaFeed(),
    );
  }

  Widget _buildMediaFeed() {
    final feedAsync = ref.watch(feedNotifierProvider);
    final nav = ref.watch(navigationProvider);
    final appActive = ref.watch(lifecycleProvider) == AppLifecycle.resumed;
    final isScreenActive = nav.selectedUser == null &&
        nav.selectedHashtag == null &&
        nav.currentTab == MainTab.media;

    return feedAsync.when(
      data: (state) {
        final tweets = state.tweets;
        if (_currentTweetId == null && tweets.isNotEmpty) {
          _currentTweetId = _tweetIdAt(_currentIndex);
          ref.read(feedNotifierProvider.notifier).setActiveTweet(_currentTweetId);
        }
        if (tweets.isEmpty) {
          if (state.isRefreshing) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在获取最新媒体...', style: TextStyle(color: Colors.white70)),
                ],
              ),
            );
          }
          return _buildNoItemsState(state);
        }
        // Keep the item under the user's eyes even though the pipeline reshuffled
        // everything after it.
        _reanchorIfNeeded(tweets);
        // Defer pool management past the build phase to avoid disposing
        // native players / mutating provider state during layout.
        Future.microtask(() {
          if (mounted) _managePool();
        });
        return Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: tweets.length,
              itemBuilder: (context, index) {
                final settings = ref.read(settingsProvider);
                return TiktokFeedItem(
                  // Without a key the element is reused positionally: after a
                  // refresh the new tweet inherited the old one's error panel,
                  // image page and retry counter.
                  key: ValueKey('home_feed_${tweets[index].id}'),
                  tweet: tweets[index],
                  poolScope: poolScope,
                  isVisible: index == _currentIndex && isScreenActive && appActive,
                  onPlaybackError: () {
                    if (index == _currentIndex && mounted) {
                      Future.delayed(
                          Duration(seconds: settings.autoSkipDelaySeconds), () {
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
                ),
              ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => _buildErrorState(e),
    );
  }

  Widget _buildNoItemsState(FeedState state) {
    final account = ref.watch(accountProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              account == null
                  ? '未找到媒体内容'
                  : (state.rateLimited
                      ? '访问过于频繁，稍后会自动重试'
                      : '未找到媒体内容，请稍后重试'),
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            if (account != null && state.rateLimited) ...[
              const SizedBox(height: 6),
              Text(
                _cooldownHint(),
                style: const TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            if (account == null)
              FilledButton.tonal(
                onPressed: () => _goToLogin(),
                child: const Text('登录 X'),
              )
            else
              FilledButton.tonal(
                onPressed: () {
                  ref.read(feedNotifierProvider.notifier).refresh();
                },
                child: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }

  String _cooldownHint() {
    final until = TwitterClient.cooldownUntilFor('SearchTimeline') ??
        TwitterClient.cooldownUntilFor('HomeLatestTimeline');
    if (until == null) return '请等待几分钟后再刷新';
    final left = until.difference(DateTime.now());
    final minutes = (left.inSeconds / 60).ceil();
    return minutes <= 0 ? '即将自动恢复' : '约 $minutes 分钟后自动恢复';
  }

  Widget _buildErrorState(Object e) {
    final account = ref.watch(accountProvider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('错误：$e',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (account == null)
            FilledButton.tonal(
              onPressed: () => _goToLogin(),
              child: const Text('登录 X'),
            ),
          TextButton(
            onPressed: () => ref.invalidate(feedNotifierProvider),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Future<void> _goToLogin() async {
    final success = await Navigator.push(
      context,
      MaterialPageRoute(builder: (c) => const LoginScreen()),
    );
    if (success == true) {
      ref.invalidate(feedNotifierProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('登录成功，正在拉取关注列表与媒体内容，请稍候…'),
        ),
      );
    }
  }
}

class TiktokFeedItem extends ConsumerWidget {
  final Tweet tweet;
  final bool isVisible;
  final bool autoFullscreen;
  final String poolScope;
  final VoidCallback? onPlaybackError;

  const TiktokFeedItem({
    super.key,
    required this.tweet,
    required this.isVisible,
    this.autoFullscreen = false,
    this.poolScope = 'home',
    this.onPlaybackError,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return RepaintBoundary(
      child: Stack(
        children: [
          TiktokMediaContainer(
            tweet: tweet,
            isVisible: isVisible,
            autoFullscreen: autoFullscreen,
            poolScope: poolScope,
            overlayBuilder: (context, onFullscreen, isFullscreen) =>
                TweetTextOverlay(
              tweet: tweet,
              onFullscreen: onFullscreen,
              isFullscreen: isFullscreen,
            ),
            onPlaybackError: onPlaybackError,
          ),
          if (settings.showDebugInfo) DiscoveryDebugOverlay(tweet: tweet),
        ],
      ),
    );
  }
}

class DiscoveryDebugOverlay extends ConsumerWidget {
  final Tweet tweet;
  const DiscoveryDebugOverlay({super.key, required this.tweet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Positioned(
      top: 100,
      left: 10,
      child: FutureBuilder<(int, int)>(
        future: Future.wait([
          Repository.getMediaPlayedCount(tweet.id),
          Repository.getUserPlayedCount(tweet.userHandle),
        ]).then((v) => (v[0], v[1])),
        builder: (context, snapshot) {
          final stats = snapshot.data ?? (0, 0);
          return Card(
            color: Colors.black.withOpacity(0.6),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _debugLine('类型', tweet.isVideo ? '视频' : '图片'),
                  _debugLine('来源', tweet.source ?? '未知'),
                  _debugLine(
                    '编号',
                    tweet.id.length >= 8
                        ? tweet.id.substring(tweet.id.length - 8)
                        : tweet.id),
                  _debugLine('媒体', '${tweet.mediaUrls.length} 个地址'),
                  _debugLine('已看', '${stats.$1} 次'),
                  _debugLine('账号已看', '${stats.$2} 次'),
                  if (tweet.createdAt != null)
                    _debugLine(
                        '时间',
                        tweet.createdAt!
                            .toLocal()
                            .toString()
                            .split(' ')
                            .last
                            .split('.')
                            .first),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _debugLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
