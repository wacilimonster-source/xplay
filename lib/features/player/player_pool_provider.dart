import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/lifecycle_provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlayerInstance {
  final Player player;
  final VideoController controller;
  DateTime lastUsed;

  /// Feed screens that currently claim this player ("home", "hashtag", ...).
  ///
  /// The home feed, the hashtag feed and the user media feed all share this one
  /// pool. Each of them used to call `cleanupExcept(自己的五个 id)`, which freed
  /// whichever player the *other* screens were actively rendering — the visible
  /// result was a video that suddenly stops and spins forever. A player is now
  /// only disposed once its last owner releases it.
  final Set<String> owners = {};

  PlayerInstance(this.player, this.controller) : lastUsed = DateTime.now();

  void dispose() {
    // VideoController is disposed implicitly when Player is disposed
    // (media_kit manages the lifecycle). Explicit dispose not needed.
    player.dispose();
  }
}

class PlayerPoolNotifier extends Notifier<Map<String, PlayerInstance>> {
  /// Preparing the next 5 videos plus room to scroll back without re-creating a
  /// native player (the previous 12 was hit constantly on a 50-item run).
  static const int maxPoolSize = 20;

  /// Pool size to fall back to when the OS reports memory pressure.
  static const int comfortablePoolSize = 8;

  VoidCallback? _unregisterMemoryPressure;

  /// Mirror of the live instances. `ref.onDispose` must not read `state`
  /// (Riverpod 3 forbids touching providers from lifecycle callbacks), so the
  /// cleanup walks this snapshot instead.
  Map<String, PlayerInstance> _tracked = const {};

  @override
  Map<String, PlayerInstance> build() {
    _tracked = const {};
    _unregisterMemoryPressure =
        LifecycleNotifier.addMemoryPressureListener(shrinkForMemoryPressure);
    ref.onDispose(() {
      _unregisterMemoryPressure?.call();
      _unregisterMemoryPressure = null;
      for (final instance in _tracked.values) {
        instance.dispose();
      }
      _tracked = const {};
    });
    return {};
  }

  /// Drops the least recently used players until [comfortablePoolSize] remain.
  ///
  /// A disposed player is not a broken UI: [TiktokMediaContainer] re-warms an
  /// id it finds missing, so even the visible item recovers on the next frame.
  void shrinkForMemoryPressure({int keep = comfortablePoolSize}) {
    if (state.length <= keep) return;
    final ordered = state.entries.toList()
      ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));
    final drop = ordered.take(state.length - keep).toList();
    final newState = Map<String, PlayerInstance>.of(state);
    for (final entry in drop) {
      newState.remove(entry.key)?.dispose();
    }
    _publish(newState);
  }

  void _publish(Map<String, PlayerInstance> next) {
    _tracked = next;
    state = next;
  }

  /// Registers [id] as claimed by [scope], creating the player if needed.
  void warmup(String id, String url,
      {required String scope, bool isLandscape = false}) {
    final existing = state[id];
    if (existing != null) {
      // Refresh LRU time and ownership *in place*: reassigning `state` here
      // notified every watching video widget on every scroll, which rebuilt the
      // whole feed and restarted playback that the user had just paused.
      existing.lastUsed = DateTime.now();
      if (existing.owners.add(scope)) {
        _publish(Map.of(state)); // ownership changed -> publish
      }
      return;
    }

    final player = Player();
    final controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    player.open(Media(url), play: false);

    final instance = PlayerInstance(player, controller)..owners.add(scope);
    var newState = Map<String, PlayerInstance>.of(state)..[id] = instance;

    if (newState.length > maxPoolSize) {
      final victim = evictionVictim(
        lastUsed: {
          for (final e in newState.entries) e.key: e.value.lastUsed
        },
        owners: {
          for (final e in newState.entries) e.key: e.value.owners
        },
        scope: scope,
        skip: id,
      );
      if (victim != null) newState.remove(victim)?.dispose();
    }
    _publish(newState);
  }

  /// Which player to drop when the pool is over capacity.
  ///
  /// Prefers the least recently used player *this* scope owns: another screen's
  /// currently visible player must not be dropped just because it is older. Only
  /// when everything this scope owns is still in use does it fall back to the
  /// global LRU.
  @visibleForTesting
  static String? evictionVictim({
    required Map<String, DateTime> lastUsed,
    required Map<String, Set<String>> owners,
    required String scope,
    required String skip,
  }) {
    String? pick(bool Function(String key) eligible) {
      String? victim;
      DateTime? oldest;
      for (final entry in lastUsed.entries) {
        if (entry.key == skip || !eligible(entry.key)) continue;
        final current = oldest;
        if (current == null || entry.value.isBefore(current)) {
          oldest = entry.value;
          victim = entry.key;
        }
      }
      return victim;
    }

    return pick((key) => owners[key]!.contains(scope)) ?? pick((_) => true);
  }

  /// Drops everything [scope] claims except [activeIds]. Other scopes are left
  /// strictly alone.
  void cleanupExcept(String scope, Set<String> activeIds) {
    var changed = false;
    final newState = <String, PlayerInstance>{};
    for (final entry in state.entries) {
      final instance = entry.value;
      final owned = instance.owners.remove(scope);
      if (owned && !activeIds.contains(entry.key)) {
        if (instance.owners.isEmpty) {
          instance.dispose();
          changed = true;
          continue;
        }
        changed = true; // ownership shrank, keep the instance
      }
      newState[entry.key] = instance;
    }
    if (changed || newState.length != state.length) {
      _publish(newState);
    }
  }

  /// Called when a feed screen goes away for good: releases everything it owns.
  void releaseScope(String scope) {
    cleanupExcept(scope, const {});
  }
}

final playerPoolProvider =
    NotifierProvider<PlayerPoolNotifier, Map<String, PlayerInstance>>(
  PlayerPoolNotifier.new,
);
