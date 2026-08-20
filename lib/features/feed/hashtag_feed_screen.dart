import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/repository.dart';
import '../../core/navigation/navigation_provider.dart';
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

  @override
  void initState() {
    super.initState();
    _pageController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _pageController.removeListener(_handleScroll);
    _pageController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_pageController.hasClients) return;
    final page = _pageController.page?.round() ?? 0;
    if (page != _currentIndex) {
      setState(() {
        _currentIndex = page;
      });
      _managePool();

      final feedAsync = ref.read(hashtagMediaProvider(widget.hashtag));
      if (feedAsync.hasValue) {
        final tweets = feedAsync.value!.tweets;
        // 标记已看(话题流不写 cached_media,只写 watched_media)
        if (page < tweets.length) {
          final t = tweets[page];
          Repository.markWatched(t.id, mediaKey: t.mediaKey);
        }
        final settings = ref.read(settingsProvider);
        if (page >= tweets.length - settings.lazyLoadThreshold &&
            !feedAsync.value!.isLoadingMore) {
          ref.read(hashtagMediaProvider(widget.hashtag).notifier).fetchMore();
        }
      }
    }
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

      final pool = ref.read(playerPoolProvider.notifier);
      final activeIds = <String>{};

      for (int i = _currentIndex - 1; i <= _currentIndex + 3; i++) {
        if (i >= 0 && i < tweets.length) {
          final tweet = tweets[i];
          activeIds.add(tweet.id);
          if (tweet.isVideo && tweet.mediaUrls.isNotEmpty) {
            pool.warmup(tweet.id, tweet.mediaUrls.first);
          }
        }
      }
      pool.cleanupExcept(activeIds);
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(hashtagMediaProvider(widget.hashtag));

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
          if (tweets.isEmpty) {
            return const Center(
                child:
                    Text('未找到媒体内容', style: TextStyle(color: Colors.white70)));
          }

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
                    isVisible: index == _currentIndex,
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
  final VoidCallback? onPlaybackError;

  const HashtagFeedItem({
    super.key,
    required this.tweet,
    required this.isVisible,
    this.autoFullscreen = false,
    this.onPlaybackError,
  });

  @override
  Widget build(BuildContext context) {
    return TiktokMediaContainer(
      tweet: tweet,
      isVisible: isVisible,
      autoFullscreen: autoFullscreen,
      overlayBuilder: (context, onFullscreen, isFullscreen) => TweetTextOverlay(
        tweet: tweet,
        onFullscreen: onFullscreen,
        isFullscreen: isFullscreen,
      ),
      onPlaybackError: onPlaybackError,
    );
  }
}
