import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xplay/core/utils/lifecycle_provider.dart';
import 'package:xplay/features/settings/settings_provider.dart';

/// The doc's P1-4 verification was "look in DevTools at how far a rebuild
/// spreads". Build counters answer the same question without a device.
///
/// A feed-item-level probe was tried first and dropped: `PageView` keeps its
/// child widgets, so comparing item identity stays "unchanged" even when the
/// screen rebuilds — it could not fail, which makes it worthless here.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('unrelated settings do not reach fetch-scoped watchers',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var selected = 0, whole = 0;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            _SettingsSlice(onBuild: () => selected++),
            _SettingsWhole(onBuild: () => whole++),
          ]),
        ),
      ),
    ));
    // Let the real notifier finish reading preferences.
    await tester.pump();
    await tester.pump();
    final baseSelected = selected, baseWhole = whole;
    final settings = container.read(settingsProvider.notifier);

    settings.updateMediaCacheSize(999);
    await tester.pump();
    settings.toggleDebugInfo(true);
    await tester.pump();
    settings.updateCooldownDuration(11);
    await tester.pump();

    expect(whole - baseWhole, 3,
        reason: 'watching the whole state rebuilds on every one of those');
    expect(selected - baseSelected, 0,
        reason: 'none of them is part of what a feed fetch reads');

    settings.updateLoadBatchSize(80);
    await tester.pump();
    expect(selected - baseSelected, 1,
        reason: 'a field the snapshot carries must still propagate');
  });

  testWidgets('inactive -> hidden does not rebuild the foreground watcher',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var selected = 0, whole = 0;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            _LifecycleSlice(onBuild: () => selected++),
            _LifecycleWhole(onBuild: () => whole++),
          ]),
        ),
      ),
    ));
    final lifecycle = container.read(lifecycleProvider.notifier);

    lifecycle.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await tester.pump();
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump();
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();

    expect(whole, 4, reason: 'three further states were published');
    expect(selected, 3,
        reason: 'the derived bool only flips when leaving and re-entering the '
            'foreground; the whole feed used to rebuild on every step');
  });
}

class _SettingsSlice extends ConsumerWidget {
  const _SettingsSlice({required this.onBuild});
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onBuild();
    ref.watch(settingsProvider.select((s) => s.fetchSnapshot));
    return const SizedBox.shrink();
  }
}

class _SettingsWhole extends ConsumerWidget {
  const _SettingsWhole({required this.onBuild});
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onBuild();
    ref.watch(settingsProvider);
    return const SizedBox.shrink();
  }
}

class _LifecycleSlice extends ConsumerWidget {
  const _LifecycleSlice({required this.onBuild});
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onBuild();
    ref.watch(lifecycleProvider.select((l) => l == AppLifecycle.resumed));
    return const SizedBox.shrink();
  }
}

class _LifecycleWhole extends ConsumerWidget {
  const _LifecycleWhole({required this.onBuild});
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onBuild();
    ref.watch(lifecycleProvider);
    return const SizedBox.shrink();
  }
}
