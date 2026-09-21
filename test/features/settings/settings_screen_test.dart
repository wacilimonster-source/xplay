import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xplay/features/settings/settings_screen.dart';
import 'package:xplay/features/settings/settings_provider.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('SettingsScreen Widget Tests', () {
    testWidgets('user detail setting defaults to disabled', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => MockSettingsNotifier()),
          ],
          child: const MaterialApp(
            home: UserDetailSettingsPage(),
          ),
        ),
      );

      await tester.pumpAndSettle();
      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(tile.value, isFalse);
    });
    testWidgets('renders all settings options', (WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(() => MockSettingsNotifier()),
            ],
            child: const MaterialApp(
              home: SettingsScreen(),
            ),
          ),
        );

        await tester.pumpAndSettle();

        expect(find.text('播放与信息流'), findsOneWidget);
        expect(find.text('发现与多样性'), findsOneWidget);

        // Scroll to find Data & Storage
        await tester.scrollUntilVisible(find.text('数据与存储'), 100);
        expect(find.text('后台获取'), findsOneWidget);
      });
    });

    testWidgets('navigation to storage works', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => MockSettingsNotifier()),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('存储与缓存'), 100);

      await tester.tap(find.text('存储与缓存'));
      await tester.pumpAndSettle();

      expect(find.text('本地媒体缓存'), findsOneWidget);
      expect(find.byType(Slider), findsAtLeastNWidgets(1));
    });

    testWidgets('diagnostics page only exposes app logs', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => MockSettingsNotifier()),
          ],
          child: const MaterialApp(
            home: DiagnosticSettingsPage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('查看应用日志'), findsOneWidget);
      expect(find.text('Debug Timeline'), findsNothing);
    });
  });
}

class MockSettingsNotifier extends SettingsNotifier {
  @override
  SettingsState build() {
    return SettingsState(
      fetchStrategy: FeedSort.latest,
      autoplay: true,
      mediaCacheSizeMB: 500,
    );
  }

  @override
  void updateMediaCacheSize(int megabytes) {
    state = state.copyWith(mediaCacheSizeMB: megabytes);
  }

  @override
  void updateUserDetailAvoidWatchedContent(bool enabled) {
    state = state.copyWith(userDetailAvoidWatchedContent: enabled);
  }

  @override
  void toggleAutoplay(bool value) {}

  @override
  void toggleFilter(MediaFilter filter) {}

  @override
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
  }) {}
}
