import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/repository.dart';
import '../../core/models/tweet.dart';
import '../../core/utils/feed_media_preloader.dart';
import '../../core/utils/lifecycle_provider.dart';
import '../feed/widgets/tweet_text_overlay.dart';
import '../player/player_pool_provider.dart';
import '../player/widgets/media_container.dart';
import '../settings/settings_provider.dart';
import '../settings/settings_screen.dart';
import 'search_provider.dart';

/// Standalone keyword search tab. Results use the same full-screen player as
/// the other feeds, so clicking through to a user or hashtag keeps working
/// through the shared navigation overlay.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _inputController = TextEditingController();
  final PageController _pageController = PageController();
  final Set<MediaFilter> _selectedFilters = <MediaFilter>{};

  String _keyword = '';
  int _currentIndex = 0;
  String? _currentTweetId;
  bool _poolUpdateQueued = false;
  Timer? _settleMarkTimer;

  late final PlayerPoolNotifier _pool;

  String get poolScope => 'search:$_keyword';

  @override
  void initState() {
    super.initState();
    _pool = ref.read(playerPoolProvider.notifier);
    _pageController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _settleMarkTimer?.cancel();
    _pageController.removeListener(_handleScroll);
    _pageController.dispose();
    _inputController.dispose();
    _pool.releaseScope(poolScope);
    super.dispose();
  }

  void _submit(String value) {
    final keyword = value.trim();
    if (keyword.isEmpty) return;
    final scopeChanged = keyword != _keyword;
    if (scopeChanged) {
      _pool.releaseScope(poolScope);
      _currentIndex = 0;
      _currentTweetId = null;
      if (_pageController.hasClients) _pageController.jumpToPage(0);
    }
    setState(() => _keyword = keyword);
    ref.read(searchProvider.notifier).search(keyword, filters: _selectedFilters);
    FocusScope.of(context).unfocus();
  }

  void _toggleFilter(MediaFilter filter) {
    setState(() {
      if (_selectedFilters.contains(filter)) {
        _selectedFilters.remove(filter);
      } else {
        _selectedFilters.add(filter);
      }
    });
    if (_keyword.isNotEmpty) {
      ref.read(searchProvider.notifier).search(_keyword,
          filters: _selectedFilters);
    }
  }

  String _filterLabel(MediaFilter filter) {
    switch (filter) {
      case MediaFilter.video:
        return '视频';
      case MediaFilter.image:
        return '图片';
      case MediaFilter.text:
        return '文字';
    }
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

      final state = ref.read(searchProvider).value;
      final settings = ref.read(settingsProvider);
      if (state != null &&
          page >= state.tweets.length - settings.lazyLoadThreshold &&
          !state.isLoadingMore &&
          state.hasMore) {
        ref.read(searchProvider.notifier).fetchMore();
      }
      return;
    }
    if (raw == raw.roundToDouble()) _scheduleWatchedMark(page);
  }

  String? _tweetIdAt(int page) {
    final tweets = ref.read(searchProvider).value?.tweets;
    if (tweets == null || page < 0 || page >= tweets.length) return null;
    return tweets[page].id;
  }

  String? _mediaKeyAt(int page) {
    final tweets = ref.read(searchProvider).value?.tweets;
    if (tweets == null || page < 0 || page >= tweets.length) return null;
    return tweets[page].mediaKey;
  }

  void _scheduleWatchedMark(int page) {
    _settleMarkTimer?.cancel();
    final tweetId = _tweetIdAt(page);
    if (tweetId == null) return;
    _settleMarkTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      if (_pageController.hasClients &&
          (_pageController.page?.round() ?? -1) == page &&
          _tweetIdAt(page) == tweetId) {
        Repository.markWatched(tweetId, mediaKey: _mediaKeyAt(page));
      }
    });
  }

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
      final tweets = ref.read(searchProvider).value?.tweets;
      if (tweets == null || tweets.isEmpty) return;

      final activeIds = <String>{};
      final ahead = ref.read(settingsProvider).imagePreloadAhead;
      for (int i = _currentIndex - 1; i <= _currentIndex + ahead; i++) {
        if (i >= 0 && i < tweets.length) {
          final tweet = tweets[i];
          activeIds.add(tweet.id);
          if (tweet.isVideo && tweet.mediaUrls.isNotEmpty) {
            _pool.warmup(tweet.id, tweet.mediaUrls.first, scope: poolScope);
          }
        }
      }
      FeedMediaPreloader.precacheFrame(
        context, tweets, _currentIndex,
        ahead: ahead,
      );
      _pool.cleanupExcept(poolScope, activeIds);
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(searchProvider);
    final appActive = ref.watch(
        lifecycleProvider.select((l) => l == AppLifecycle.resumed));

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('搜索', style: TextStyle(color: Colors.white)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white),
            tooltip: '设置',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SearchBar(
              controller: _inputController,
              hintText: '搜索推文、话题或用户...',
              leading: const Icon(Icons.search),
              elevation: const WidgetStatePropertyAll(0),
              backgroundColor: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.surfaceContainerHigh),
              onSubmitted: _submit,
              trailing: [
                if (feedAsync.isLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () => _submit(_inputController.text),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: MediaFilter.values
                  .map((f) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(_filterLabel(f)),
                          selected: _selectedFilters.contains(f),
                          onSelected: (_) => _toggleFilter(f),
                        ),
                      ))
                  .toList(),
            ),
          ),
          Expanded(
            child: _keyword.isEmpty
                ? const Center(
                    child: Text('输入关键词开始搜索',
                        style: TextStyle(color: Colors.white54)),
                  )
                : feedAsync.when(
                    data: (state) {
                      final tweets = state.tweets;
                      if (_currentTweetId == null && tweets.isNotEmpty) {
                        _currentTweetId = _tweetIdAt(_currentIndex);
                      }
                      if (tweets.isEmpty) {
                        return Center(
                          child: Text(
                            state.rateLimited
                                ? '访问过于频繁，请稍后自动重试'
                                : '没有找到与“$_keyword”相关的结果',
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
                              return _SearchFeedItem(
                                key: ValueKey('search_${tweets[index].id}'),
                                tweet: tweets[index],
                                poolScope: poolScope,
                                isVisible: index == _currentIndex && appActive,
                                onPlaybackError: () {
                                  if (index != _currentIndex || !mounted) {
                                    return;
                                  }
                                  Future.delayed(
                                    Duration(
                                        seconds:
                                            settings.autoSkipDelaySeconds),
                                    () {
                                    if (mounted && _currentIndex == index) {
                                      _pageController.nextPage(
                                        duration:
                                            const Duration(milliseconds: 300),
                                        curve: Curves.easeInOut,
                                      );
                                    }
                                  },
                                  );
                                },
                              );
                            },
                          ),
                          if (state.isLoadingMore)
                            const Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: LinearProgressIndicator(
                                minHeight: 2,
                                backgroundColor: Colors.transparent,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.blue),
                              ),
                            ),
                        ],
                      );
                    },
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, st) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('错误：$e',
                              style: const TextStyle(color: Colors.white70)),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () => ref
                                .read(searchProvider.notifier)
                                .refresh(),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SearchFeedItem extends StatelessWidget {
  final Tweet tweet;
  final bool isVisible;
  final String poolScope;
  final VoidCallback? onPlaybackError;

  const _SearchFeedItem({
    super.key,
    required this.tweet,
    required this.isVisible,
    required this.poolScope,
    this.onPlaybackError,
  });

  @override
  Widget build(BuildContext context) {
    return TiktokMediaContainer(
      tweet: tweet,
      isVisible: isVisible,
      poolScope: poolScope,
      onPlaybackError: onPlaybackError,
      overlayBuilder: (context, onFullscreen, isFullscreen) => TweetTextOverlay(
        tweet: tweet,
        onFullscreen: onFullscreen,
        isFullscreen: isFullscreen,
      ),
    );
  }
}
