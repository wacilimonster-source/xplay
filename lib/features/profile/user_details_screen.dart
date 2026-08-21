import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/navigation/navigation_provider.dart';
import '../../core/utils/media_cache_manager.dart';
import '../settings/settings_provider.dart';
import '../settings/settings_screen.dart';
import '../subscriptions/subscription_list_screen.dart';
import '../../core/database/entities.dart';
import 'profile_provider.dart';

class UserDetailsScreen extends ConsumerWidget {
  final String screenName;

  const UserDetailsScreen({super.key, required this.screenName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(userProfileProvider(screenName));
    final tweetsAsync = ref.watch(userMediaNotifierProvider(screenName));
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      body: profileAsync.when(
        data: (profile) {
          if (profile == null) {
            return const Center(child: Text('未找到用户'));
          }
          return CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverAppBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => ref.read(navigationProvider.notifier).back(),
                ),
                title: Text(profile.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () => ref
                        .read(userMediaNotifierProvider(screenName).notifier)
                        .refresh(),
                  ),
                  IconButton(
                    icon: Icon(settings.userDetailAvoidWatchedContent
                        ? Icons.filter_alt
                        : Icons.filter_alt_off),
                    tooltip: settings.userDetailAvoidWatchedContent
                        ? '已开启过滤已看内容'
                        : '未过滤已看内容',
                    onPressed: () {
                      settingsNotifier.updateUserDetailAvoidWatchedContent(
                          !settings.userDetailAvoidWatchedContent);
                      ref.invalidate(userMediaNotifierProvider(screenName));
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (c) => const SettingsScreen()),
                    ),
                  ),
                ],
                floating: true,
                pinned: true,
                snap: true,
                centerTitle: true,
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 2),
                            ),
                            child: CircleAvatar(
                              radius: 40,
                              backgroundImage: profile.profileImageUrlHighRes !=
                                      null
                                  ? CachedNetworkImageProvider(
                                      profile.profileImageUrlHighRes!,
                                      cacheManager:
                                          CustomMediaCacheManager.getInstance(),
                                    )
                                  : null,
                              child: profile.profileImageUrlHighRes == null
                                  ? const Icon(Icons.person, size: 40)
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  profile.name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                                Text(
                                  '@${profile.screenName}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyLarge
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          _SubscribeButton(profile: profile),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (profile.description != null &&
                          profile.description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16.0),
                          child: Text(
                            profile.description!,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      Row(
                        children: [
                          _buildStat(
                              context,
                              _formatCount(profile.followingCount ?? 0),
                              '正在关注'),
                          const SizedBox(width: 24),
                          _buildStat(context,
                              _formatCount(profile.followersCount ?? 0), '粉丝'),
                        ],
                      ),
                      const Divider(height: 32),
                    ],
                  ),
                ),
              ),
              tweetsAsync.when(
                data: (state) {
                  final tweets = state.tweets;
                  final isRefreshing = state.isRefreshing;

                  if (tweets.isEmpty && !isRefreshing) {
                    return const SliverToBoxAdapter(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(32.0),
                          child: Text('未找到媒体内容'),
                        ),
                      ),
                    );
                  }

                  return SliverMainAxisGroup(
                    slivers: [
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 2,
                          child: isRefreshing
                              ? const LinearProgressIndicator(
                                  backgroundColor: Colors.transparent,
                                  minHeight: 2,
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                      if (tweets.isEmpty && isRefreshing)
                        const SliverToBoxAdapter(
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.all(64.0),
                              child: Column(
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 16),
                                  Text('正在获取最新内容...',
                                      style: TextStyle(color: Colors.white70)),
                                ],
                              ),
                            ),
                          ),
                        )
                      else
                        SliverToBoxAdapter(
                          child: ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: tweets.length + (tweets.isNotEmpty ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == tweets.length) {
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  ref.read(userMediaNotifierProvider(screenName).notifier).fetchMore();
                                });
                                return const SizedBox(height: 16);
                              }
                              final tweet = tweets[index];
                              return Card(
                                elevation: 0,
                                color: Theme.of(context).colorScheme.surfaceContainerLow,
                                margin: const EdgeInsets.only(bottom: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () {
                                    ref.read(navigationProvider.notifier).openUserMedia(screenName, index, tweetId: tweet.id);
                                  },
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (tweet.mediaUrls.isNotEmpty)
                                        AspectRatio(
                                          aspectRatio: tweet.mediaWidth != null && tweet.mediaHeight != null && tweet.mediaWidth! > 0 && tweet.mediaHeight! > 0
                                              ? tweet.mediaWidth! / tweet.mediaHeight!
                                              : 16 / 9,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              CachedNetworkImage(
                                                cacheManager: CustomMediaCacheManager.getInstance(),
                                                imageUrl: tweet.thumbnailUrl ?? tweet.mediaUrls.first,
                                                fit: BoxFit.cover,
                                                memCacheWidth: 600,
                                                placeholder: (context, url) => Container(color: Colors.black12),
                                                errorWidget: (context, url, error) => const Icon(Icons.error),
                                              ),
                                              if (tweet.isVideo)
                                                Positioned(
                                                  left: 8, bottom: 8,
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        const Icon(Icons.play_circle_fill, color: Colors.white70, size: 18),
                                                        if (tweet.mediaUrls.length > 1)
                                                          Padding(
                                                            padding: const EdgeInsets.only(left: 4),
                                                            child: Text(tweet.mediaUrls.length.toString(), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        )
                                      else
                                        Container(
                                          padding: const EdgeInsets.all(16),
                                          alignment: Alignment.centerLeft,
                                          child: Text(tweet.text, maxLines: 4, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
                                        ),
                                      Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            if (tweet.mediaUrls.isNotEmpty && tweet.text.isNotEmpty)
                                              Text(tweet.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                                            Row(
                                              children: [
                                                if (tweet.favoriteCount > 0) ...[
                                                  Icon(Icons.favorite_outline, size: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                                  const SizedBox(width: 3),
                                                  Text(tweet.favoriteCount.toString(), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                                  const SizedBox(width: 12),
                                                ],
                                                if (tweet.replyCount > 0) ...[
                                                  Icon(Icons.chat_bubble_outline, size: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                                  const SizedBox(width: 3),
                                                  Text(tweet.replyCount.toString(), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                                  const SizedBox(width: 12),
                                                ],
                                                const Spacer(),
                                                Text(_formatDate(tweet.createdAt), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
                loading: () => const SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(64.0),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
                error: (e, st) => SliverToBoxAdapter(
                  child: Center(child: Text('错误：$e')),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('加载用户资料失败：$e')),
      ),
    );
  }

  Widget _buildStat(BuildContext context, String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return '';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

class _SubscribeButton extends ConsumerWidget {
  final Subscription profile;
  const _SubscribeButton({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subscriptionState = ref.watch(subscriptionListProvider);
    final isSubscribed = subscriptionState.isSubscribed(profile.screenName);

    return IconButton.filledTonal(
      style: IconButton.styleFrom(
        visualDensity: VisualDensity.compact,
        backgroundColor: isSubscribed ? Colors.transparent : null,
        side: isSubscribed
            ? BorderSide(color: Theme.of(context).colorScheme.outline)
            : null,
      ),
      onPressed: () {
        ref.read(subscriptionListProvider.notifier).toggleSubscription(
              Subscription(
                id: profile.screenName,
                screenName: profile.screenName,
                name: profile.name,
                profileImageUrl: profile.profileImageUrl,
                description: profile.description,
                followersCount: profile.followersCount,
                followingCount: profile.followingCount,
              ),
            );
      },
      icon: Icon(isSubscribed ? Icons.check : Icons.add, size: 20),
      tooltip: isSubscribed ? '已订阅' : '订阅',
    );
  }
}
