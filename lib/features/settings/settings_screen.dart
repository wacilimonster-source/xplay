import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'settings_provider.dart';
import '../../core/client/account_provider.dart';
import '../../core/client/twitter_client.dart';
import '../../core/database/repository.dart';
import '../../core/utils/media_cache_manager.dart';
import '../../core/services/update_service.dart';
import 'update_dialog.dart';
import '../feed/feed_provider.dart';
import '../subscriptions/subscription_import_screen.dart';
import '../subscriptions/subscription_list_screen.dart';
import 'log_viewer_screen.dart';
import '../auth/login_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _metadataCount = 0;
  double _cacheSizeMB = 0;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (e) {
      // An unavailable package_info channel used to escape as an unhandled
      // async error (and took the settings page down with it).
      debugPrint('XFLOW: version lookup failed: $e');
    }
  }

  Future<void> _loadStats() async {
    int count = 0;
    int sizeBytes = 0;
    try {
      count = await Repository.getCachedMediaCount();
    } catch (e) {
      debugPrint('XFLOW: cache count unavailable: $e');
    }
    try {
      sizeBytes = await CustomMediaCacheManager.getCacheSize();
    } catch (e) {
      debugPrint('XFLOW: cache size unavailable: $e');
    }
    if (mounted) {
      setState(() {
        _metadataCount = count;
        _cacheSizeMB = sizeBytes / (1024 * 1024);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          _SettingsGroup(
            title: '体验',
            children: [
              _SettingsTile(
                icon: Icons.play_circle_outline,
                title: '播放与信息流',
                subtitle: '排序、自动播放和内容混合',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (c) => const PlaybackSettingsPage())),
              ),
              _SettingsTile(
                icon: Icons.auto_awesome_outlined,
                title: '发现与多样性',
                subtitle: '算法调优和内容多样性',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (c) => const DiscoverySettingsPage())),
              ),
              _SettingsTile(
                icon: Icons.person_search_outlined,
                title: '用户详情页',
                subtitle: '单独控制是否过滤已看内容',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (c) => const UserDetailSettingsPage())),
              ),
            ],
          ),
          _SettingsGroup(
            title: '数据与存储',
            children: [
              _SettingsTile(
                icon: Icons.sync_outlined,
                title: '后台获取',
                subtitle: '同步间隔和后台抓取',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (c) => const SyncSettingsPage())),
              ),
              _SettingsTile(
                icon: Icons.storage_outlined,
                title: '存储与缓存',
                subtitle:
                    '已用 ${_cacheSizeMB.toStringAsFixed(1)} MB • $_metadataCount 条',
                // 统计状态由子页面自己维护，返回时再拉一次，避免把旧数字当参数推过去。
                onTap: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (c) => const StorageSettingsPage()));
                  if (mounted) _loadStats();
                },
              ),
            ],
          ),
          _SettingsGroup(
            title: '内容源',
            children: [
              _SettingsTile(
                icon: Icons.people_outline,
                title: '订阅管理',
                subtitle: '导入、导出或清空关注列表',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (c) => const SubscriptionSettingsPage())),
              ),
              _SettingsTile(
                icon: Icons.search_outlined,
                title: '高级获取',
                subtitle: '高级订阅抓取参数',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (c) => const SearchSettingsPage())),
              ),
            ],
          ),
          _SettingsGroup(
            title: '系统',
            children: [
              _SettingsTile(
                icon: Icons.network_check_outlined,
                title: '网络与性能',
                subtitle: '超时、重试和加载阈值',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (c) => const NetworkSettingsPage())),
              ),
              _SettingsTile(
                icon: Icons.bug_report_outlined,
                title: '诊断与日志',
                subtitle: '调试工具和算法安全上限',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (c) => const DiagnosticSettingsPage())),
              ),
              _SettingsTile(
                icon: Icons.system_update_outlined,
                title: '检查更新',
                subtitle: _appVersion.isNotEmpty
                    ? '当前版本 v$_appVersion'
                    : '检查是否有新版本可用',
                onTap: () => _checkForUpdate(context),
              ),
              _SettingsTile(
                icon: account == null ? Icons.login : Icons.logout,
                title: account == null ? '登录' : '退出登录',
                subtitle: account == null ? '登录 X 账号以同步订阅与内容' : null,
                titleColor: account == null ? null : Colors.redAccent,
                onTap: () async {
                  if (account == null) {
                    final success = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (c) => const LoginScreen()),
                    );
                    if (success == true) {
                      // 换账号后旧的冷却与轮换游标属于上一个账号，必须清零。
                      TwitterClient.clearCooldowns();
                      TwitterClient.resetSubscriptionRotation();
                      ref.invalidate(feedNotifierProvider);
                      ref.invalidate(subscriptionListProvider);
                    }
                    return;
                  }
                  final navigator = Navigator.of(context);
                  await ref.read(accountProvider.notifier).logout();
                  if (!mounted) return;
                  TwitterClient.clearCooldowns();
                  TwitterClient.resetSubscriptionRotation();
                  ref.invalidate(feedNotifierProvider);
                  ref.invalidate(subscriptionListProvider);
                  navigator.pop();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _checkForUpdate(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // 自己持有加载框路由：barrierDismissible=false 的对话框一旦漏掉 pop，
    // 整个页面就再也点不动了，所以放到 finally 里兜底。
    final loadingRoute = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    navigator.push(loadingRoute);

    final UpdateCheckResult result;
    try {
      result = await UpdateService.checkDetailed();
    } finally {
      if (loadingRoute.isActive && navigator.canPop()) {
        navigator.removeRoute(loadingRoute);
      }
    }

    if (!context.mounted) return;
    switch (result.status) {
      case UpdateCheckStatus.updateAvailable:
        await showUpdateDialog(context, result.updateInfo!);
      case UpdateCheckStatus.upToDate:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('当前已是最新版本'),
            backgroundColor: Colors.green,
          ),
        );
      case UpdateCheckStatus.networkError:
        messenger.showSnackBar(
          SnackBar(
            content: Text('检查失败：请检查网络（${result.failureReason}）'),
            backgroundColor: Colors.deepOrange,
          ),
        );
      case UpdateCheckStatus.error:
        messenger.showSnackBar(
          SnackBar(
            content: Text('检查失败：${result.failureReason}'),
            backgroundColor: Colors.redAccent,
          ),
        );
    }
  }

  static Future<void> showUpdateDialog(
    BuildContext context,
    UpdateInfo updateInfo,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => UpdateDialog(updateInfo: updateInfo),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Column(children: children),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? titleColor;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Icon(icon,
          color: titleColor ?? Theme.of(context).colorScheme.onSurfaceVariant),
      title: Text(
        title,
        style: TextStyle(
          color: titleColor,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }
}

// --- SUB PAGES ---

class PlaybackSettingsPage extends ConsumerWidget {
  const PlaybackSettingsPage({super.key});

  String _getVideoEndActionLabel(VideoEndAction action) {
    switch (action) {
      case VideoEndAction.pause:
        return '暂停';
      case VideoEndAction.replay:
        return '重播';
      case VideoEndAction.playNext:
        return '播放下一条';
    }
  }

  String _getMediaFilterLabel(MediaFilter filter) {
    switch (filter) {
      case MediaFilter.video:
        return '视频';
      case MediaFilter.image:
        return '图片';
      case MediaFilter.text:
        return '文字';
    }
  }

  String _getFeedSortLabel(FeedSort sort) {
    switch (sort) {
      case FeedSort.latest:
        return '订阅：最新';
      case FeedSort.popular:
        return '订阅：热门';
      case FeedSort.trending:
        return '订阅：趋势';
      case FeedSort.algorithmic:
        return '为你推荐 (X)';
      case FeedSort.chronological:
        return '关注列表 (X)';
      case FeedSort.videomixer:
        return '视频混音 (X)';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('播放与信息流')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('内容策略'),
            subtitle: Text('当前：${_getFeedSortLabel(settings.fetchStrategy)}'),
            trailing: DropdownButton<FeedSort>(
              value: settings.fetchStrategy,
              items: FeedSort.values
                  .map((sort) => DropdownMenuItem(
                        value: sort,
                        child: Text(_getFeedSortLabel(sort)),
                      ))
                  .toList(),
              onChanged: (val) => val != null
                  ? notifier.updateDiscoveryParam(fetchStrategy: val)
                  : null,
            ),
          ),
          SwitchListTile(
            title: const Text('自动播放'),
            subtitle: const Text('视频可见时自动播放'),
            value: settings.autoplay,
            onChanged: (v) => notifier.toggleAutoplay(v),
          ),
          ListTile(
            title: const Text('视频播放结束后'),
            subtitle:
                Text('操作：${_getVideoEndActionLabel(settings.videoEndAction)}'),
            trailing: DropdownButton<VideoEndAction>(
              value: settings.videoEndAction,
              items: VideoEndAction.values
                  .map((action) => DropdownMenuItem(
                        value: action,
                        child: Text(_getVideoEndActionLabel(action)),
                      ))
                  .toList(),
              onChanged: (val) => val != null
                  ? notifier.updateDiscoveryParam(videoEndAction: val)
                  : null,
            ),
          ),
          _SliderSetting(
            title: '视频加载重试次数',
            subtitle: '视频加载失败时尝试播放的次数',
            value: settings.playbackRetryLimit.toDouble(),
            min: 0,
            max: 5,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(playbackRetryLimit: v.toInt()),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('内容过滤', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('选中 = 只显示选中类型，全不选 = 显示全部',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Wrap(
              spacing: 8.0,
              children: MediaFilter.values
                  .map((f) => FilterChip(
                        label: Text(_getMediaFilterLabel(f)),
                        selected: settings.filters.contains(f),
                        onSelected: (_) => notifier.toggleFilter(f),
                      ))
                  .toList(),
            ),
          ),
          const Divider(),
          _SliderSetting(
            title: '初始信息流大小',
            subtitle: '应用启动时立即加载的视频数',
            value: settings.initialSyncCount.toDouble(),
            min: 1,
            max: 100,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(initialSyncCount: v.toInt()),
          ),
          _SliderSetting(
            title: '滚动加载批次大小',
            subtitle: '到达末尾时加载的新视频数',
            value: settings.loadBatchSize.toDouble(),
            min: 5,
            max: 100,
            onChanged: (v) => notifier.updateLoadBatchSize(v.toInt()),
          ),
          ListTile(
            title: const Text('新旧内容混合比例'),
            subtitle: Text(
                '${(settings.freshMixRatio * 100).toInt()}% 新内容 / ${(100 - settings.freshMixRatio * 100).toInt()}% 已保存'),
          ),
          Slider(
            value: settings.freshMixRatio,
            min: 0.0,
            max: 1.0,
            divisions: 10,
            onChanged: (val) =>
                notifier.updateDiscoveryParam(freshMixRatio: val),
          ),
        ],
      ),
    );
  }
}

class UserDetailSettingsPage extends ConsumerWidget {
  const UserDetailSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('用户详情页设置')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('过滤已看内容'),
            subtitle: const Text('仅影响用户详情页，默认关闭'),
            value: settings.userDetailAvoidWatchedContent,
            onChanged: (value) {
              notifier.updateUserDetailAvoidWatchedContent(value);
            },
          ),
        ],
      ),
    );
  }
}

class DiscoverySettingsPage extends ConsumerWidget {
  const DiscoverySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('发现与多样性')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('避免已看内容'),
            subtitle: const Text('隐藏你已经看过的视频'),
            value: settings.avoidWatchedContent,
            onChanged: (val) =>
                notifier.updateDiscoveryParam(avoidWatchedContent: val),
          ),
          SwitchListTile(
            title: const Text('未见创作者加权'),
            subtitle: const Text('展示更多你很少看到的创作者内容'),
            value: settings.unseenSubscriptionBoost,
            onChanged: (val) =>
                notifier.updateDiscoveryParam(unseenSubscriptionBoost: val),
          ),
          const Divider(),
          _SliderSetting(
            title: '创作者多样性',
            subtitle: '同一创作者连续视频最大数量',
            value: settings.saturationThreshold.toDouble(),
            min: 1,
            max: 10,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(saturationThreshold: v.toInt()),
          ),
          _SliderSetting(
            title: '视频多样性',
            subtitle: '同一视频在窗口内的最大副本数',
            value: settings.mediaSaturationThreshold.toDouble(),
            min: 1,
            max: 5,
            onChanged: (v) => notifier.updateDiscoveryParam(
                mediaSaturationThreshold: v.toInt()),
          ),
          _SliderSetting(
            title: '多样性窗口',
            subtitle: '算法回溯范围以确保内容多样性',
            value: settings.saturationWindow.toDouble(),
            min: 5,
            max: 100,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(saturationWindow: v.toInt()),
          ),
          _SliderSetting(
            title: '严格去重',
            subtitle: '精确媒体键匹配的回溯范围',
            value: settings.mediaDeduplicationWindow.toDouble(),
            min: 10,
            max: 200,
            onChanged: (v) => notifier.updateDiscoveryParam(
                mediaDeduplicationWindow: v.toInt()),
          ),
          _SliderSetting(
            title: '发现范围',
            subtitle: '搜索深度以发现可加权的创作者',
            value: settings.unseenBoostLookahead.toDouble(),
            min: 2,
            max: 50,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(unseenBoostLookahead: v.toInt()),
          ),
          _SliderSetting(
            title: '候选池大小',
            subtitle: '构建多样化信息流的本地搜索空间',
            value: settings.dbCandidateMultiplier.toDouble(),
            min: 1,
            max: 20,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(dbCandidateMultiplier: v.toInt()),
          ),
        ],
      ),
    );
  }
}

class SyncSettingsPage extends ConsumerWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('后台获取')),
      body: ListView(
        children: [
          _SliderSetting(
            title: '刷新频率（分钟）',
            subtitle: '应用检查新视频的频率',
            value: settings.syncInterval.toDouble(),
            min: 1,
            max: 120,
            onChanged: (v) => notifier.updateSyncInterval(v.toInt()),
          ),
          _SliderSetting(
            title: '刷新强度',
            subtitle: '每次刷新会话检查的账户数',
            value: settings.syncBatchSize.toDouble(),
            min: 1,
            max: 50,
            onChanged: (v) => notifier.updateSyncBatchSize(v.toInt()),
          ),
          _SliderSetting(
            title: '账户冷却时间',
            subtitle: '再次检查同一账户前的等待时间',
            value: settings.cooldownDuration.toDouble(),
            min: 0,
            max: 240,
            onChanged: (v) => notifier.updateCooldownDuration(v.toInt()),
          ),
        ],
      ),
    );
  }
}

class StorageSettingsPage extends ConsumerStatefulWidget {
  const StorageSettingsPage({super.key});

  @override
  ConsumerState<StorageSettingsPage> createState() =>
      _StorageSettingsPageState();
}

class _StorageSettingsPageState extends ConsumerState<StorageSettingsPage> {
  int _metadataCount = 0;
  double _cacheSizeMB = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 统计数字由本页持有。以前是父页面 push 进来的构造参数，
  /// 清完缓存后父页面 setState 也刷新不到已经打开的子页面。
  Future<void> _reload() async {
    final count = await Repository.getCachedMediaCount();
    final sizeBytes = await CustomMediaCacheManager.getCacheSize();
    if (!mounted) return;
    setState(() {
      _metadataCount = count;
      _cacheSizeMB = sizeBytes / (1024 * 1024);
    });
  }

  Future<void> _clearCache() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final clearedMB = _cacheSizeMB;
    setState(() => _busy = true);
    await CustomMediaCacheManager.clearCache();
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
      content: Text('已清除 ${clearedMB.toStringAsFixed(1)} MB'),
    ));
  }

  /// 拖动结束时才真正按新上限清理文件。
  Future<void> _applyCacheLimit(int limitMB) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final beforeMB = _cacheSizeMB;
    setState(() => _busy = true);
    final afterBytes = await CustomMediaCacheManager.enforceLimit(limitMB);
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    final freedMB = beforeMB - afterBytes / (1024 * 1024);
    messenger.showSnackBar(SnackBar(
      content: Text(freedMB > 0.05
          ? '缓存上限已调整为 $limitMB MB，已清除 ${freedMB.toStringAsFixed(1)} MB'
          : '缓存未超出 $limitMB MB 上限'),
    ));
  }

  Future<void> _resetWatchedRecords() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置已看记录'),
        content: const Text(
            '将清空「已看过」标记和播放计数，看过的内容会重新出现在信息流里。\n'
            '数据库中的媒体记录和已下载文件不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _busy = true);

    // 先取数量，purgeSeenMetadata() 会连 watched_media 一起清空。
    final watchedCount = await Repository.getWatchedCount();
    await Repository.purgeSeenMetadata();
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
      content: Text('已清除 $watchedCount 条记录，看过的内容会重新出现'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('存储与缓存'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新统计',
            onPressed: _reload,
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          ListTile(
            title: const Text('本地媒体缓存'),
            subtitle: Text(
                '已用 ${_cacheSizeMB.toStringAsFixed(1)} MB / 限制 ${settings.mediaCacheSizeMB} MB • $_metadataCount 条元数据'),
          ),
          Slider(
            value: settings.mediaCacheSizeMB.toDouble().clamp(100.0, 2000.0),
            min: 100,
            max: 2000,
            divisions: 19,
            label: '${settings.mediaCacheSizeMB} MB',
            // 拖动过程中只写设置值：以前每跨一档就 enforceLimit() 真删一次文件，
            // 一次拖动能连带删掉十几档，而且没 await 导致统计互相打架。
            onChanged: (v) => notifier.updateMediaCacheSize(v.round()),
            onChangeEnd: (v) => _applyCacheLimit(v.round()),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services, color: Colors.orange),
            title: const Text('清除媒体缓存', style: TextStyle(color: Colors.orange)),
            enabled: !_busy,
            onTap: _clearCache,
          ),
          const Divider(),
          _SliderSetting(
            title: '数据库记录上限',
            subtitle: '存储中保留的最大视频元数据条目数',
            value: settings.pruneThreshold.toDouble(),
            min: 1000,
            max: 100000,
            divisions: 99,
            onChanged: (v) => notifier.updatePruneThreshold(v.toInt()),
          ),
          ListTile(
            leading: const Icon(Icons.history_toggle_off,
                color: Colors.redAccent),
            title: const Text('重置已看记录',
                style: TextStyle(color: Colors.redAccent)),
            subtitle: const Text('让看过的内容重新出现'),
            enabled: !_busy,
            onTap: _resetWatchedRecords,
          ),
        ],
      ),
    );
  }
}

class SubscriptionSettingsPage extends ConsumerWidget {
  const SubscriptionSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('订阅管理')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.import_export),
            title: const Text('导入订阅'),
            subtitle: const Text('从现有 X 账户同步关注列表'),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (c) => const SubscriptionImportScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep, color: Colors.orange),
            title: const Text('清空所有订阅', style: TextStyle(color: Colors.orange)),
            onTap: () async {
              await Repository.clearSubscriptions();
              if (!context.mounted) return;
              ref.invalidate(feedNotifierProvider);
              // 订阅列表页有自己的 provider，不一起失效的话页面还是旧数据。
              ref.invalidate(subscriptionListProvider);
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('已清空')));
            },
          ),
        ],
      ),
    );
  }
}

class NetworkSettingsPage extends ConsumerWidget {
  const NetworkSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('网络与性能')),
      body: ListView(
        children: [
          _SliderSetting(
            title: '网络超时（秒）',
            value: settings.apiTimeoutSeconds.toDouble(),
            min: 5,
            max: 60,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(apiTimeoutSeconds: v.toInt()),
          ),
          _SliderSetting(
            title: 'API 请求大小',
            subtitle: '每次调用从 X 请求的目标项目数',
            value: settings.timelineBatchSize.toDouble(),
            min: 5,
            max: 200,
            onChanged: (v) => notifier.updateTimelineBatchSize(v.toInt()),
          ),
          _SliderSetting(
            title: '网络重试上限',
            subtitle: '请求失败时每页的尝试次数',
            value: settings.apiRetryLimit.toDouble(),
            min: 1,
            max: 10,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(apiRetryLimit: v.toInt()),
          ),
          _SliderSetting(
            title: '预加载阈值',
            subtitle: '信息流剩余此数量时获取下一批',
            value: settings.lazyLoadThreshold.toDouble(),
            min: 1,
            max: 50,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(lazyLoadThreshold: v.toInt()),
          ),
          _SliderSetting(
            title: '故障跳过延迟',
            subtitle: '跳过损坏媒体前的等待秒数',
            value: settings.autoSkipDelaySeconds.toDouble(),
            min: 1,
            max: 10,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(autoSkipDelaySeconds: v.toInt()),
          ),
        ],
      ),
    );
  }
}

class SearchSettingsPage extends ConsumerWidget {
  const SearchSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('高级获取')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('内容过滤', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('选中 = 只显示选中类型，全不选 = 显示全部',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Wrap(
              spacing: 8.0,
              children: MediaFilter.values
                  .map((f) => FilterChip(
                        label: Text(_getMediaFilterLabel(f)),
                        selected: settings.filters.contains(f),
                        onSelected: (_) => notifier.toggleFilter(f),
                      ))
                  .toList(),
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('严格订阅模式'),
            subtitle: const Text('禁用空查询时的趋势回退'),
            value: settings.strictSubscriptionsOnly,
            onChanged: (val) =>
                notifier.updateDiscoveryParam(strictSubscriptionsOnly: val),
          ),
          SwitchListTile(
            title: const Text('包含转推'),
            value: settings.includeNativeRetweets,
            onChanged: (val) =>
                notifier.updateDiscoveryParam(includeNativeRetweets: val),
          ),
          SwitchListTile(
            title: const Text('分块抓取'),
            subtitle: const Text('按块遍历关注列表'),
            value: settings.useChunkedSubscriptions,
            onChanged: (val) =>
                notifier.updateDiscoveryParam(useChunkedSubscriptions: val),
          ),
          _SliderSetting(
            title: '最低收藏数过滤',
            value: settings.minFavesFilter.toDouble(),
            min: 0,
            max: 1000,
            divisions: 20,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(minFavesFilter: v.toInt()),
          ),
          _SliderSetting(
            title: '搜索查询最大长度',
            value: settings.maxQueryLength.toDouble(),
            min: 100,
            max: 1000,
            divisions: 18,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(maxQueryLength: v.toInt()),
          ),
          _SliderSetting(
            title: '轮换周期',
            subtitle: '重复创作者前跳过的块数',
            value: settings.chunkRotationLimit.toDouble(),
            min: 1,
            max: 10,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(chunkRotationLimit: v.toInt()),
          ),
          _SliderSetting(
            title: '最低产出',
            subtitle: '完成循环前所需的新项目数',
            value: settings.minNewTweetsThreshold.toDouble(),
            min: 1,
            max: 20,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(minNewTweetsThreshold: v.toInt()),
          ),
        ],
      ),
    );
  }

  String _getMediaFilterLabel(MediaFilter filter) {
    switch (filter) {
      case MediaFilter.video:
        return '视频';
      case MediaFilter.image:
        return '图片';
      case MediaFilter.text:
        return '文字';
    }
  }
}

class DiagnosticSettingsPage extends ConsumerWidget {
  const DiagnosticSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('诊断')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('覆盖层来源信息'),
            subtitle: const Text('在视频上显示发现元数据'),
            value: settings.showDebugInfo,
            onChanged: (v) => notifier.toggleDebugInfo(v),
          ),
          _SliderSetting(
            title: '算法安全上限',
            subtitle: '多样性逻辑的最大计算次数',
            value: settings.maxSaturationSwaps.toDouble(),
            min: 100,
            max: 5000,
            divisions: 49,
            onChanged: (v) =>
                notifier.updateDiscoveryParam(maxSaturationSwaps: v.toInt()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.terminal),
            title: const Text('查看应用日志'),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (c) => const LogViewerScreen())),
          ),
        ],
      ),
    );
  }
}

class _SliderSetting extends StatelessWidget {
  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  const _SliderSetting({
    required this.title,
    this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(title),
          subtitle: subtitle != null ? Text(subtitle!) : null,
          trailing: Text(
            value.toInt().toString(),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions ?? (max - min).toInt(),
          label: value.toInt().toString(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
