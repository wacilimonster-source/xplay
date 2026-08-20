import 'dart:async';
import 'package:flutter/foundation.dart';
import 'twitter_client.dart';
import '../database/repository.dart';
import '../../features/settings/settings_provider.dart';
import '../utils/media_cache_manager.dart';

class BackgroundSync {
  static Timer? _syncTimer;
  static bool _isSyncing = false;
  static bool _syncRequested = false;
  static bool enabled = true;
  static TwitterClient? _client;
  static SettingsState? _settings;
  static int _generation = 0;

  static void start(TwitterClient client, SettingsState settings) {
    if (!enabled) return;
    _client = client;
    _settings = settings;
    if (_syncTimer != null) return;

    final generation = _generation;
    _sync(client, settings, generation);

    _syncTimer = Timer.periodic(
      Duration(minutes: settings.syncInterval),
      (_) {
        final latestSettings = _settings;
        final latestClient = _client;
        if (latestSettings != null && latestClient != null) {
          _sync(latestClient, latestSettings, _generation);
        }
      },
    );

    _schedulePrune(settings, generation);
  }

  /// Updates the settings snapshot used by the next sync without forcing a
  /// restart for every unrelated preference change.
  static void updateSettings(TwitterClient client, SettingsState settings) {
    final previous = _settings;
    final intervalChanged = previous?.syncInterval != settings.syncInterval;
    final settingsChanged = previous != null && !identical(previous, settings);
    if (settingsChanged) {
      // Invalidate an in-flight task so it cannot commit using an old snapshot.
      _generation++;
      if (_isSyncing) _syncRequested = true;
    }
    _client = client;
    _settings = settings;
    if (_syncTimer == null) {
      start(client, settings);
    } else if (intervalChanged) {
      final wasSyncing = _isSyncing;
      restart(client, settings);
      if (wasSyncing) _syncRequested = true;
    } else if (settingsChanged) {
      _schedulePrune(settings, _generation);
    }
  }
  static void restart(TwitterClient client, SettingsState settings) {
    stop();
    start(client, settings);
  }

  static void stop() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _generation++;
    _syncRequested = false;
  }

  static void _schedulePrune(SettingsState settings, int generation) {
    Future.delayed(const Duration(minutes: 1), () {
      if (generation != _generation) return;
      Repository.pruneCachedMedia(threshold: settings.pruneThreshold);
    });
  }

  static Future<void> _sync(
      TwitterClient client, SettingsState settings, int generation) async {
    if (_isSyncing) {
      _syncRequested = true;
      return;
    }
    _isSyncing = true;

    try {
      final subs = await Repository.getSubscriptions();
      if (generation != _generation) return;
      if (subs.isEmpty) return;

      subs.shuffle();
      final targets = subs.take(settings.syncBatchSize);
      final usersQuery =
          targets.map((s) => 'from:${s.screenName}').join(' OR ');
      final query = "include:nativeretweets ($usersQuery) -filter:replies";

      final response = await client.fetchTrendingMedia(
        query: query,
        count: settings.loadBatchSize,
        cooldownMinutes: settings.cooldownDuration,
      );

      if (generation != _generation) return;
      if (response.tweets.isNotEmpty) {
        await Repository.insertCachedMedia(response.tweets);
        await CustomMediaCacheManager.enforceLimit(
            settings.mediaCacheSizeMB);
      }
    } catch (e) {
      debugPrint('Background sync error: $e');
    } finally {
      _isSyncing = false;
      if (_syncRequested) {
        _syncRequested = false;
        final latestClient = _client;
        final latestSettings = _settings;
        if (latestClient != null && latestSettings != null) {
          Future<void>.microtask(() =>
              _sync(latestClient, latestSettings, _generation));
        }
      }
    }
  }
}
