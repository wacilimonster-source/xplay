import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/repository.dart';
import '../../core/navigation/navigation_provider.dart';
import '../../core/utils/lifecycle_provider.dart';
import '../player/player_pool_provider.dart';
import '../player/widgets/media_container.dart';
import '../../core/models/tweet.dart';
import '../settings/settings_provider.dart';
import '../settings/settings_screen.dart';
import 'hashtag_provider.dart';
import 'widgets/tweet_text_overlay.dart';

class HashtagListScreen extends ConsumerWidget {
  const HashtagListScreen({super.key});

  void _showAddHashtagDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加话题'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '例如：#自然 或 自然',
            prefixText: '#',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final tag = controller.text.trim();
              if (tag.isNotEmpty) {
                ref.read(hashtagListProvider.notifier).addHashtag(tag);
              }
              Navigator.pop(context);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hashtagsAsync = ref.watch(hashtagListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('话题'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddHashtagDialog(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: hashtagsAsync.when(
        data: (tags) => tags.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.tag, size: 64, color: Colors.white24),
                    const SizedBox(height: 16),
                    const Text('还没有添加话题',
                        style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => _showAddHashtagDialog(context, ref),
                      child: const Text('添加第一个话题'),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: tags.length,
                itemBuilder: (context, index) {
                  final tag = tags[index];
                  return ListTile(
                    leading: const Icon(Icons.tag, color: Colors.blue),
                    title: Text(tag, style: const TextStyle(fontSize: 16)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => _confirmDelete(context, ref, tag),
                    ),
                    onTap: () {
                      ref.read(navigationProvider.notifier).selectHashtag(tag);
                    },
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('错误：$e')),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, String tag) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除话题'),
        content: Text('确定要删除 $tag 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              ref.read(hashtagListProvider.notifier).removeHashtag(tag);
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class HashtagMediaFeedScreen extends ConsumerStatefulWidget {
  final String hashtag;

  const HashtagMediaFeedScreen({super.key, required this.hashtag});

  @override
  ConsumerState<HashtagMediaFeedScreen> createState() =>
      _HashtagMediaFeedScreenState();
}

class _HashtagMediaFeedScreenState
    extends ConsumerState<HashtagMediaFeedScreen> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;
  bool _poolUpdateQueued = false;
  Timer? _settleMarkTimer;
  String? _currentTweetId;

  /// Per-topic pool scope, so opening topic B cannot release topic A's live
  /// player and vice versa (the pool itself is shared app-wide).
  String get poolScope => 'hashtag:${widget.hashtag}';

  /// Captured at init: touching `ref` inside `dispose()` is unsafe in Riverpod.
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
  void didUpdateWidget(covariant HashtagMediaFeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hashtag != widget.hashtag) {
      // The State object is reused when the topic changes (the overlay reuses
      // this screen), so the old page index has to go: it used to leave
      // `isVisible` false for every page and the feed looked frozen.
      _pool.releaseScope('hashtag:${oldWidget.hashtag}');
      _currentTweetId = null;
      _settleMarkTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _currentIndex = 0);
        if (_pageController.hasClients) _pageController.jumpToPage(0);
        _managePool();
      });
    }
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
      _managePool();
      _scheduleWatchedMark(page);

      final state = ref.read(hashtagMediaProvider(widget.hashtag)).value;
      if (state != null) {
        final settings = ref.read(settingsProvider);
        if (page >= state.tweets.length - settings.lazyLoadThreshold &&
            !state.isLoadingMore &&
            state.hasMore) {
          ref.read(hashtagMediaProvider(widget.hashtag).notifier).fetchMore();
        }
      }
      return;
    }

    if (raw == raw.roundToDouble()) {
      _scheduleWatchedMark(page);
    }
  }

  String? _tweetIdAt(int page) {
    final state = ref.read(hashtagMediaProvider(widget.hashtag)).value;
    if (state == null || page < 0 || page >= state.tweets.length) return null;
    return state.tweets[page].id;
  }

  /// Only marks content as watched once the user has settled on it, so a quick
  /// fling through several posts no longer hides all of them forever.
  void _scheduleWatchedMark(int page) {
    _settleMarkTimer?.cancel();
    final tweetId = _tweetIdAt(page);
    if (tweetId == null) return;
    _settleMarkTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      if (_pageController.hasClients &&
          (_pageController.page?.round() ?? -1) == page &&
          _tweetIdAt(page) == tweetId) {
        // 话题流不写 cached_media，只写 watched_media
        Repository.markWatched(tweetId, mediaKey: _mediaKeyAt(page));
      }
    });
  }

  String? _mediaKeyAt(int page) {
    final state = ref.read(hashtagMediaProvider(widget.hashtag)).value;
    if (state == null || page < 0 || page >= state.tweets.length) return null;
    return state.tweets[page].mediaKey;
  }

  /// Keeps the same tweet under the user's eyes if the list changed.
  void _reanchorIfNeeded(List<Tweet> tweets) {
    final id = _currentTweetId;
    if (id == null || tweets.isEmpty) return;
    if (_currentIndex < tweets.length && tweets[_currentIndex].id == id) return;
    final idx = tweets.indexWhere((t) => t.id == id);
    if (idx == -1) {
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
      final feedAsync = ref.read(hashtagMediaProvider(widget.hashtag));
      final state = feedAsync.value;
      if (state == null) return;
      final tweets = state.tweets;

      final pool = _pool;
      final activeIds = <String>{};

      for (int i = _currentIndex - 1; i <= _currentIndex + 3; i++) {
        if (i >= 0 && i < tweets.length) {
          final tweet = tweets[i];
          activeIds.add(tweet.id);
          if (tweet.isVideo && tweet.mediaUrls.isNotEmpty) {
            pool.warmup(tweet.id, tweet.mediaUrls.first, scope: poolScope);
          }
        }
      }
      pool.cleanupExcept(poolScope, activeIds);
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(hashtagMediaProvider(widget.hashtag));
    final appActive = ref.watch(lifecycleProvider) == AppLifecycle.resumed;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => ref.read(navigationProvider.notifier).back(),
        ),
        title: Text(widget.hashtag,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () {
              _pageController.jumpToPage(0);
              ref.read(hashtagMediaProvider(widget.hashtag).notifier).refresh();
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
          if (_currentTweetId == null && tweets.isNotEmpty) {
            _currentTweetId = _tweetIdAt(_currentIndex);
          }
          if (tweets.isEmpty) {
            return Center(
              child: Text(
                state.rateLimited
                    ? '访问过于频繁，请稍后重试'
                    : '未找到媒体内容',
                style: const TextStyle(color: Colors.white70),
              ),
            );
          }

          _reanchorIfNeeded(tweets);
          _managePool();

          return Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: tweets.length,
                itemBuilder: (context, index) {
                  final settings = ref.read(settingsProvider);
                  return HashtagFeedItem(
                    key: ValueKey('hash_feed_${tweets[index].id}'),
                    tweet: tweets[index],
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
              if (state.isLoadingMore || state.isRefreshing)
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
                    .read(hashtagMediaProvider(widget.hashtag).notifier)
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

class HashtagFeedItem extends StatelessWidget {
  final Tweet tweet;
  final bool isVisible;
  final bool autoFullscreen;
  final String poolScope;
  final VoidCallback? onPlaybackError;

  const HashtagFeedItem({
    super.key,
    required this.tweet,
    required this.isVisible,
    this.autoFullscreen = false,
    this.poolScope = 'hashtag',
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
