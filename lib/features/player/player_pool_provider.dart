import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  static const int maxPoolSize = 12;

  /// Mirror of the live instances. `ref.onDispose` must not read `state`
  /// (Riverpod 3 forbids touching providers from lifecycle callbacks), so the
  /// cleanup walks this snapshot instead.
  Map<String, PlayerInstance> _tracked = const {};

  @override
  Map<String, PlayerInstance> build() {
    _tracked = const {};
    ref.onDispose(() {
      for (final instance in _tracked.values) {
        instance.dispose();
      }
      _tracked = const {};
    });
    return {};
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
      // Evict the least recently used entry, preferring ones this scope owns:
      // another screen's currently visible player must not be dropped.
      String? victim;
      DateTime? oldest;
      for (final e in newState.entries) {
        if (e.key == id) continue;
        final heldByOtherScope = !e.value.owners.contains(scope);
        if (heldByOtherScope) continue;
        final current = oldest;
        if (current == null || e.value.lastUsed.isBefore(current)) {
          oldest = e.value.lastUsed;
          victim = e.key;
        }
      }
      if (victim == null) {
        // Everything in this scope is in use: fall back to the global LRU.
        for (final e in newState.entries) {
          if (e.key == id) continue;
          final current = oldest;
          if (current == null || e.value.lastUsed.isBefore(current)) {
            oldest = e.value.lastUsed;
            victim = e.key;
          }
        }
      }
      if (victim != null) {
        newState.remove(victim)?.dispose();
      }
    }
    _publish(newState);
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
