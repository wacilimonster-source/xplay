import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xplay/features/settings/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('provider builds once, not once per watcher', () {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // The report assumed `build()` (and its 60+ preference reads) ran for every
    // watcher. It does not: a Notifier is built once per container, so repeated
    // `ref.watch` from the settings pages costs no preference reads. This pins
    // that down so the claim stays checkable instead of "optimised" blindly.
    final firstState = container.read(settingsProvider);
    final againState = container.read(settingsProvider);
    expect(identical(firstState, againState), isTrue);
    expect(identical(container.read(settingsProvider.notifier),
        container.read(settingsProvider.notifier)), isTrue);
  });

  group('SettingsNotifier Persistence Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'loadBatchSize': 30,
        'syncInterval': 10,
        'cooldownDuration': 5,
        'userDetailAvoidWatchedContent': true,
      });
    });

    test('initializes with values from SharedPreferences', () async {
      final container = ProviderContainer();

      // Riverpod Notifiers initialize lazily. Read it once to trigger build,
      // then await the preference load instead of sleeping a fixed 100ms
      // (that raced the platform channel under load and flaked).
      await container.read(settingsProvider.notifier).flush();

      final state = container.read(settingsProvider);

      expect(state.loadBatchSize, 30);
      expect(state.syncInterval, 10);
      expect(state.cooldownDuration, 5);
      expect(state.userDetailAvoidWatchedContent, isTrue);
      expect(state.syncBatchSize, 10); // Default
    });

    test('defaults user detail watched filter to disabled', () async {
      // This group's setUp seeds a value for this very key, so reset the store
      // first or the test asserts "default" while reading a persisted true.
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      await container.read(settingsProvider.notifier).flush();

      expect(
        container.read(settingsProvider).userDetailAvoidWatchedContent,
        isFalse,
      );
    });

    test('updates and persists values', () async {
      final container = ProviderContainer();
      await container.read(settingsProvider.notifier).flush();

      final notifier = container.read(settingsProvider.notifier);
      notifier.updateLoadBatchSize(50);

      final state = container.read(settingsProvider);
      expect(state.loadBatchSize, 50);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('loadBatchSize'), 50);

      notifier.updateUserDetailAvoidWatchedContent(true);
      expect(
        container.read(settingsProvider).userDetailAvoidWatchedContent,
        isTrue,
      );
      expect(prefs.getBool('userDetailAvoidWatchedContent'), isTrue);
    });
  });
}
