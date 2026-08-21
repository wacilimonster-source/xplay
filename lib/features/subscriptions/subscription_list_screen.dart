import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/database/repository.dart';
import '../../core/database/entities.dart';
import '../../core/utils/media_cache_manager.dart';
import '../../core/utils/app_logger.dart';
import '../profile/user_details_screen.dart';
import '../../core/navigation/navigation_provider.dart';
import '../settings/settings_screen.dart';
import '../../core/client/account_provider.dart';
import '../../core/client/twitter_client.dart';
import '../../core/client/twitter_account.dart';
import '../auth/login_screen.dart';

enum SubscriptionSort {
  name,
  handle,
  followers,
  views,
}

class SubscriptionListState {
  final List<Subscription> allSubscriptions;
  final Map<String, int> userViews;
  final String searchQuery;
  final SubscriptionSort sort;
  final bool isAscending;
  final bool isLoading;
  final bool isEnriching;
  final int enrichedCount;
  final int totalToEnrich;
  final bool showHistoryPrompt;

  SubscriptionListState({
    this.allSubscriptions = const [],
    this.userViews = const {},
    this.searchQuery = '',
    this.sort = SubscriptionSort.name,
    this.isAscending = true,
    this.isLoading = true,
    this.isEnriching = false,
    this.enrichedCount = 0,
    this.totalToEnrich = 0,
    this.showHistoryPrompt = false,
  });

  List<Subscription> get filteredSubscriptions {
    List<Subscription> filtered = List.from(allSubscriptions);
    if (searchQuery.isNotEmpty) {
      final query = searchQuery.toLowerCase();
      filtered = filtered.where((sub) {
        return sub.name.toLowerCase().contains(query) ||
            sub.screenName.toLowerCase().contains(query);
      }).toList();
    }

    int multiplier = isAscending ? 1 : -1;

    switch (sort) {
      case SubscriptionSort.name:
        filtered.sort((a, b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()) * multiplier);
        break;
      case SubscriptionSort.handle:
        filtered.sort((a, b) =>
            a.screenName.toLowerCase().compareTo(b.screenName.toLowerCase()) *
            multiplier);
        break;
      case SubscriptionSort.followers:
        filtered.sort((a, b) =>
            (a.followersCount ?? 0).compareTo(b.followersCount ?? 0) *
            multiplier);
        break;
      case SubscriptionSort.views:
        filtered.sort((a, b) {
          final viewsA = userViews[a.screenName.toLowerCase()] ?? 0;
          final viewsB = userViews[b.screenName.toLowerCase()] ?? 0;
          return viewsA.compareTo(viewsB) * multiplier;
        });
        break;
    }
    return filtered;
  }

  bool isSubscribed(String screenName) {
    final normalized =
        screenName.startsWith('@') ? screenName.substring(1) : screenName;
    final lower = normalized.toLowerCase();
    return allSubscriptions.any((sub) => sub.screenName.toLowerCase() == lower);
  }

  int get unsyncedMissingCount => allSubscriptions
      .where((s) =>
          s.description == null &&
          s.followersCount == null &&
          s.profileSyncedAt == null)
      .length;

  SubscriptionListState copyWith({
    List<Subscription>? allSubscriptions,
    Map<String, int>? userViews,
    String? searchQuery,
    SubscriptionSort? sort,
    bool? isAscending,
    bool? isLoading,
    bool? isEnriching,
    int? enrichedCount,
    int? totalToEnrich,
    bool? showHistoryPrompt,
  }) {
    return SubscriptionListState(
      allSubscriptions: allSubscriptions ?? this.allSubscriptions,
      userViews: userViews ?? this.userViews,
      searchQuery: searchQuery ?? this.searchQuery,
      sort: sort ?? this.sort,
      isAscending: isAscending ?? this.isAscending,
      isLoading: isLoading ?? this.isLoading,
      isEnriching: isEnriching ?? this.isEnriching,
      enrichedCount: enrichedCount ?? this.enrichedCount,
      totalToEnrich: totalToEnrich ?? this.totalToEnrich,
      showHistoryPrompt: showHistoryPrompt ?? this.showHistoryPrompt,
    );
  }
}

class SubscriptionListNotifier extends Notifier<SubscriptionListState> {
  @override
  SubscriptionListState build() {
    _load().then((_) => _enrichMissing());
    return SubscriptionListState();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      Repository.getSubscriptions(),
      Repository.getPlayedCountsByUser(),
    ]);

    state = state.copyWith(
      allSubscriptions: results[0] as List<Subscription>,
      userViews: results[1] as Map<String, int>,
      isLoading: false,
    );

    final unsyncedMissing = await Repository.getUnsyncedMissingCount();
    state = state.copyWith(showHistoryPrompt: unsyncedMissing > 0);
  }

  List<Subscription> get _missingSubs =>
      state.allSubscriptions
          .where((s) =>
              s.description == null &&
              s.followersCount == null)
          .toList();

  DateTime? _enrichPauseUntil;
  static const Duration _rateLimitCooldown = Duration(seconds: 60);

  Future<void> _enrichMissing() async {
    final missing = _missingSubs;
    if (missing.isEmpty) return;

    await _doEnrich(missing.take(20).toList(), isManual: false);
  }

  Future<void> enrichAll() async {
    if (state.isEnriching) return;

    final missing = _missingSubs;
    if (missing.isEmpty) {
      return;
    }

    await _doEnrich(missing, isManual: true);
  }

  Future<void> _doEnrich(List<Subscription> batch, {required bool isManual}) async {
    if (batch.isEmpty) return;

    state = state.copyWith(
      isEnriching: true,
      enrichedCount: 0,
      totalToEnrich: batch.length,
    );

    final client = TwitterClient();
    const concurrency = 3;
    const chunkDelay = Duration(milliseconds: 500);
    int completed = 0;

    for (int i = 0; i < batch.length; i += concurrency) {
      if (_enrichPauseUntil != null) {
        final wait = _enrichPauseUntil!.difference(DateTime.now());
        if (wait > Duration.zero) {
          AppLogger.log(
              'Enrichment paused for rate limit, waiting ${wait.inSeconds}s');
          await Future.delayed(wait);
        }
        _enrichPauseUntil = null;
      }

      final end = (i + concurrency < batch.length)
          ? i + concurrency
          : batch.length;
      final chunk = batch.sublist(i, end);

      await Future.wait(chunk.map((sub) => _fetchOneProfile(client, sub)));

      completed = end;
      state = state.copyWith(enrichedCount: completed);

      if (end < batch.length) {
        await Future.delayed(chunkDelay);
      }
    }

    _enrichPauseUntil = null;
    await _load();

    if (isManual) {
      await Repository.markAllSubscriptionsSynced();
      state = state.copyWith(
        isEnriching: false,
        enrichedCount: 0,
        totalToEnrich: 0,
        showHistoryPrompt: false,
      );
    } else {
      state = state.copyWith(
        isEnriching: false,
        enrichedCount: 0,
        totalToEnrich: 0,
      );
    }
  }

  Future<void> _fetchOneProfile(TwitterClient client, Subscription sub) async {
    try {
      final profile = await client.fetchProfile(
        sub.screenName,
        onRateLimit: () {
          _enrichPauseUntil = DateTime.now().add(_rateLimitCooldown);
        },
      );
      if (profile != null &&
          (profile.description != null || profile.followersCount != null)) {
        await Repository.mergeSubscription(profile);
      }
    } catch (_) {
      // Individual failures are skipped and retried on the next run.
    }
  }

  Future<void> dismissHistoryPrompt() async {
    await Repository.markAllSubscriptionsSynced();
    state = state.copyWith(showHistoryPrompt: false);
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  void setSort(SubscriptionSort sort) {
    state = state.copyWith(sort: sort);
  }

  void toggleOrder() {
    state = state.copyWith(isAscending: !state.isAscending);
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true);
    await _load();
  }

  Future<void> toggleSubscription(Subscription sub) async {
    final exists = isSubscribed(sub.screenName);

    // Optimistic update for immediate UI feedback
    final currentSubs = List<Subscription>.from(state.allSubscriptions);
    if (exists) {
      currentSubs.removeWhere(
          (s) => s.screenName.toLowerCase() == sub.screenName.toLowerCase());
    } else {
      currentSubs.add(sub);
    }
    state = state.copyWith(allSubscriptions: currentSubs);

    try {
      if (exists) {
        final db = await Repository.database;
        await db.delete('subscriptions',
            where: 'LOWER(screen_name) = ?',
            whereArgs: [sub.screenName.toLowerCase()]);
        // Bidirectional: also unfollow on X so the next sync won't re-add it.
        _applyFollow(sub, true);
      } else {
        await Repository.insertSubscription(sub);
        // Bidirectional: also follow on X so it appears in the following list
        // (and therefore survives "sync following" delete-diff).
        _applyFollow(sub, false);
      }
    } catch (e) {
      AppLogger.log('XFLOW: Error toggling subscription: $e');
      // Rollback on error
      await _load();
      return;
    }

    // Refresh to ensure everything (including views) is in sync
    await _load();
  }

  /// Fire-and-forget, best-effort X follow/unfollow. The local subscription
  /// state is the source of truth for the feed; the X follow is a side effect
  /// that makes manual subscriptions survive "sync following" delete-diff.
  void _applyFollow(Subscription sub, bool unfollow) {
    TwitterClient()
        .followUser(sub.screenName, unfollow: unfollow)
        .catchError((_) => false);
  }

  bool isSubscribed(String screenName) {
    return state.isSubscribed(screenName);
  }
}

final subscriptionListProvider =
    NotifierProvider<SubscriptionListNotifier, SubscriptionListState>(
  SubscriptionListNotifier.new,
);

class SubscriptionListScreen extends ConsumerWidget {
  final bool isStandalone;

  const SubscriptionListScreen({super.key, this.isStandalone = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(subscriptionListProvider);
    final account = ref.watch(accountProvider);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final subs = state.filteredSubscriptions;

    Widget content = subs.isEmpty
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  state.searchQuery.isEmpty
                      ? '未找到订阅内容'
                      : '没有匹配“${state.searchQuery}”的结果',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Colors.white70),
                ),
                if (account == null) ...[
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (c) => const LoginScreen())),
                    child: const Text('登录 X'),
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: () async {
                      final current = TwitterAccount.currentAccount;
                      if (current == null || current.restId.isEmpty) return;
                      final messenger = ScaffoldMessenger.of(context);
                      final client = TwitterClient();
                      final (subs, complete) = await client.fetchFollowing(
                        current.restId,
                        cooldownMinutes: 1,
                      );
                      if (subs.isNotEmpty) {
                        await Repository.syncFollowingFromList(subs,
                            deleteMissing: complete);
                      }
                      ref.invalidate(subscriptionListProvider);
                      messenger.showSnackBar(SnackBar(
                        content: Text(
                            subs.isEmpty ? '同步失败，请稍后重试' : '已同步 ${subs.length} 个关注账号'),
                      ));
                    },
                    child: const Text('同步关注列表'),
                  ),
                ],
              ],
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: subs.length,
            itemBuilder: (context, index) {
              final sub = subs[index];
              final views = state.userViews[sub.screenName.toLowerCase()] ?? 0;

              return Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                margin: const EdgeInsets.symmetric(vertical: 4),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    if (isStandalone) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              UserDetailsScreen(screenName: sub.screenName),
                        ),
                      );
                    } else {
                      ref
                          .read(navigationProvider.notifier)
                          .selectUser(sub.screenName);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 24,
                          backgroundImage: sub.profileImageUrl != null
                              ? CachedNetworkImageProvider(
                                  sub.profileImageUrl!,
                                  cacheManager:
                                      CustomMediaCacheManager.getInstance(),
                                )
                              : null,
                          child: sub.profileImageUrl == null
                              ? const Icon(Icons.person, size: 24)
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                sub.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '@${sub.screenName}',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (sub.description != null &&
                                  sub.description!.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  sub.description!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontSize: 12),
                                ),
                              ],
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  if (sub.followersCount != null) ...[
                                    Text(
                                      '粉丝 ${_formatCount(sub.followersCount!)}',
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                          fontSize: 12),
                                    ),
                                    const SizedBox(width: 16),
                                  ],
                                  Text(
                                    '观看 ${_formatCount(views)}',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );

    return Scaffold(
      appBar: AppBar(
        leading: isStandalone
            ? null
            : IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () =>
                    ref.read(subscriptionListProvider.notifier).refresh(),
              ),
        title: const Text('订阅'),
        actions: [
          if (!isStandalone)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (c) => const SettingsScreen()),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(130),
          child: _buildSearchAndSort(context, ref),
        ),
      ),
      body: content,
    );
  }

  String _formatCount(int count) {
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    } else if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}K';
    }
    return count.toString();
  }

  Widget _buildSearchAndSort(BuildContext context, WidgetRef ref) {
    final state = ref.watch(subscriptionListProvider);
    final notifier = ref.read(subscriptionListProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        children: [
          if (state.showHistoryPrompt && !state.isEnriching)
            _HistoryUpdateBanner(
              count: state.unsyncedMissingCount,
              onUpdate: () => notifier.enrichAll(),
              onLater: () => notifier.dismissHistoryPrompt(),
            ),
          SearchBar(
            hintText: '搜索订阅...',
            onChanged: notifier.setSearchQuery,
            leading: const Icon(Icons.search),
            elevation: WidgetStateProperty.all(0),
            backgroundColor: WidgetStateProperty.all(
                Theme.of(context).colorScheme.surfaceContainerHigh),
            padding: WidgetStateProperty.all(
                const EdgeInsets.symmetric(horizontal: 16)),
          ),
          const SizedBox(height: 8),
          if (state.isEnriching)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: state.totalToEnrich > 0
                        ? state.enrichedCount / state.totalToEnrich
                        : 0,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '正在更新资料 ${state.enrichedCount}/${state.totalToEnrich}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: _SortChip(
                  label: '名称',
                  isSelected: state.sort == SubscriptionSort.name,
                  isAscending: state.isAscending,
                  onTap: () {
                    if (state.sort == SubscriptionSort.name) {
                      notifier.toggleOrder();
                    } else {
                      notifier.setSort(SubscriptionSort.name);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SortChip(
                  label: '用户名',
                  isSelected: state.sort == SubscriptionSort.handle,
                  isAscending: state.isAscending,
                  onTap: () {
                    if (state.sort == SubscriptionSort.handle) {
                      notifier.toggleOrder();
                    } else {
                      notifier.setSort(SubscriptionSort.handle);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SortChip(
                  label: '粉丝数',
                  isSelected: state.sort == SubscriptionSort.followers,
                  isAscending: state.isAscending,
                  onTap: () {
                    if (state.sort == SubscriptionSort.followers) {
                      notifier.toggleOrder();
                    } else {
                      notifier.setSort(SubscriptionSort.followers);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SortChip(
                  label: '观看数',
                  isSelected: state.sort == SubscriptionSort.views,
                  isAscending: state.isAscending,
                  onTap: () {
                    if (state.sort == SubscriptionSort.views) {
                      notifier.toggleOrder();
                    } else {
                      notifier.setSort(SubscriptionSort.views);
                    }
                  },
                ),
              ),
            ],
          ),
          if (!state.isEnriching && !state.showHistoryPrompt)
            FutureBuilder<List<Subscription>>(
              future: Future.value(state.allSubscriptions
                  .where((s) =>
                      s.description == null && s.followersCount == null)
                  .toList()),
              builder: (context, snapshot) {
                final missingCount = snapshot.data?.length ?? 0;
                if (missingCount == 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => notifier.enrichAll(),
                      icon: const Icon(Icons.update, size: 16),
                      label: Text('刷新全部资料 ($missingCount 个待更新)'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final bool isAscending;
  final VoidCallback onTap;

  const _SortChip({
    required this.label,
    required this.isSelected,
    required this.isAscending,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? colorScheme.primary
                : colorScheme.outlineVariant,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurface,
              ),
            ),
            if (isSelected) ...[
              const SizedBox(width: 4),
              Icon(
                isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
                color: colorScheme.onPrimaryContainer,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HistoryUpdateBanner extends StatelessWidget {
  final int count;
  final VoidCallback onUpdate;
  final VoidCallback onLater;

  const _HistoryUpdateBanner({
    required this.count,
    required this.onUpdate,
    required this.onLater,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.secondary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_edu_outlined,
                  size: 18, color: colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '发现 $count 个订阅资料不完整',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '这些订阅缺少简介和粉丝数，点击更新可一次性补全所有资料。',
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: onUpdate,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  child: const Text('立即更新'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: onLater,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  child: const Text('稍后'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
