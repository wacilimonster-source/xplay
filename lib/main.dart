import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'core/utils/app_logger.dart';
import 'features/feed/tiktok_feed_screen.dart';
import 'features/feed/hashtag_feed_screen.dart';
import 'features/subscriptions/subscription_list_screen.dart';
import 'features/profile/user_details_screen.dart';
import 'features/profile/user_media_feed_screen.dart';
import 'core/navigation/navigation_provider.dart';
import 'core/client/background_sync.dart';
import 'core/client/transaction_id_service.dart';
import 'core/client/twitter_client.dart';
import 'features/settings/settings_provider.dart';
import 'core/client/twitter_account.dart';
import 'core/client/query_id_resolver.dart';
import 'core/database/repository.dart';
import 'core/utils/lifecycle_provider.dart';
import 'core/services/update_service.dart';
import 'features/settings/update_dialog.dart';

Object? _startupError;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  try {
    await Future.wait([
      TwitterAccount.init(),
      QueryIdResolver.init(),
      Repository.database,
    ]);
  } catch (e, st) {
    // A failed init used to leave the process before `runApp`, so the user saw
    // nothing but a black screen with no way out and no log.
    _startupError = e;
    debugPrint('XFLOW: Startup initialisation failed: $e\n$st');
  }

  runApp(ProviderScope(child: XFlowApp(error: _startupError)));
}

class XFlowApp extends ConsumerWidget {
  const XFlowApp({super.key, this.error});

  final Object? error;

  static final navigatorKey = GlobalKey<NavigatorState>();
  static bool _startupUpdateCheckStarted = false;

  /// One client instance for the background services. Building a fresh
  /// `TwitterClient()` on every settings change threw away its per-instance
  /// state (in-flight follow-list requests) and left BackgroundSync holding a
  /// different object than the rest of the app.
  static final TwitterClient _serviceClient = TwitterClient();

  /// Settings that BackgroundSync actually reacts to.
  static bool _syncRelevantChange(SettingsState? a, SettingsState b) {
    if (a == null) return true;
    return a.fetchSnapshot != b.fetchSnapshot ||
        a.syncInterval != b.syncInterval ||
        a.syncBatchSize != b.syncBatchSize ||
        a.cooldownDuration != b.cooldownDuration ||
        a.pruneThreshold != b.pruneThreshold ||
        a.mediaCacheSizeMB != b.mediaCacheSizeMB;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (error != null) {
      return MaterialApp(
        title: 'XPlay',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.dark,
            surface: Colors.black,
          ),
          scaffoldBackgroundColor: Colors.black,
        ),
        home: _StartupErrorScreen(error: error!),
      );
    }

    // Listen to lifecycle changes
    ref.listen(lifecycleProvider, (previous, next) {
      if (next == AppLifecycle.resumed) {
        debugPrint('XFLOW: App resumed. Ensuring BackgroundSync is active.');
        TwitterClient.resetQueue();
        BackgroundSync.updateSettings(
            _serviceClient, ref.read(settingsProvider));
      }
    });

    ref.listen(settingsProvider, (prev, next) {
      // Skip unrelated preferences: every change used to invalidate the running
      // sync generation and re-schedule a prune.
      if (!_syncRelevantChange(prev, next)) return;
      BackgroundSync.updateSettings(_serviceClient, next);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      BackgroundSync.start(_serviceClient, ref.read(settingsProvider));
      if (!_startupUpdateCheckStarted) {
        _startupUpdateCheckStarted = true;
        _checkForStartupUpdate();
      }
    });

    return MaterialApp(
      title: 'XPlay',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
          surface: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          centerTitle: true,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.black,
          indicatorColor: Colors.blue.withValues(alpha: 0.2),
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ),
      ),
      home: const MainScaffold(),
    );
  }

  Future<void> _checkForStartupUpdate() async {
    final updateInfo = await UpdateService.checkForUpdate();
    if (updateInfo == null) return;
    final dialogContext = navigatorKey.currentState?.overlay?.context;
    if (dialogContext == null || !dialogContext.mounted) return;
    await showDialog<void>(
      context: dialogContext,
      builder: (_) => UpdateDialog(updateInfo: updateInfo),
    );
  }
}

/// Shown when the database or stored session cannot be initialised at all.
/// Previously this path ended the process before `runApp`, so the app icon
/// produced a black screen with no message and no log.
class _StartupErrorScreen extends StatefulWidget {
  const _StartupErrorScreen({required this.error});
  final Object error;

  @override
  State<_StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<_StartupErrorScreen> {
  bool _busy = false;

  Future<void> _resetAndExit() async {
    setState(() => _busy = true);
    try {
      await Repository.resetLocalData();
    } catch (e) {
      AppLogger.log('XFLOW: resetLocalData failed: $e');
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('本地数据已清除，请重新打开 XPlay')));
    setState(() => _busy = false);
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.white70),
              const SizedBox(height: 16),
              const Text('启动失败',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 8),
              Text(
                  '本地数据或登录信息无法读取。\n可以清除本地数据后重新打开应用（已缓存的内容与订阅会被移除）。',
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(8)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Text(
                      '${widget.error}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white38),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _resetAndExit,
                child: Text(_busy ? '正在清除...' : '清除本地数据并退出'),
              ),
              TextButton(
                onPressed: () => setState(() {}),
                child: const Text('重试启动'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MainScaffold extends ConsumerWidget {
  const MainScaffold({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav = ref.watch(navigationProvider);
    final navNotifier = ref.read(navigationProvider.notifier);

    final mainScreens = IndexedStack(
      index: nav.currentTab.index,
      children: const [
        TiktokFeedScreen(),
        SubscriptionListScreen(isStandalone: false),
        HashtagListScreen(),
      ],
    );

    Widget? overlayScreen;
    if (nav.selectedHashtag != null) {
      overlayScreen = HashtagMediaFeedScreen(hashtag: nav.selectedHashtag!);
    } else if (nav.selectedUser != null) {
      if (nav.userMediaInitialIndex != null) {
        overlayScreen = UserMediaFeedScreen(
          screenName: nav.selectedUser!,
          initialIndex: nav.userMediaInitialIndex!,
          initialTweetId: nav.userMediaInitialTweetId,
        );
      } else {
        overlayScreen = UserDetailsScreen(screenName: nav.selectedUser!);
      }
    }

    final body = Stack(
      children: [
        Visibility(
          visible: overlayScreen == null,
          maintainState: true,
          child: mainScreens,
        ),
        const Positioned(
          left: 0,
          top: 0,
          child: TransactionIdWebViewHost(),
        ),
        if (overlayScreen != null)
          Container(
            color: Colors.black,
            child: overlayScreen,
          ),
      ],
    );

    return PopScope(
      canPop: nav.selectedUser == null && nav.selectedHashtag == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          navNotifier.back();
        }
      },
      child: Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: nav.currentTab.index,
          onDestinationSelected: (index) {
            navNotifier.setTab(MainTab.values[index]);
            if (index == 1) {
              ref.invalidate(subscriptionListProvider);
            }
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              selectedIcon: Icon(Icons.video_library, color: Colors.blue),
              label: '媒体',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people, color: Colors.blue),
              label: '订阅',
            ),
            NavigationDestination(
              icon: Icon(Icons.trending_up_outlined),
              selectedIcon: Icon(Icons.trending_up, color: Colors.blue),
              label: '话题',
            ),
          ],
        ),
      ),
    );
  }
}
