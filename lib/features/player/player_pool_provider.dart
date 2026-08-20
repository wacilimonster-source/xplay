import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlayerInstance {
  final Player player;
  final VideoController controller;
  DateTime lastUsed;

  PlayerInstance(this.player, this.controller)
      : lastUsed = DateTime.now();

  void dispose() {
    // VideoController is disposed implicitly when Player is disposed
    // (media_kit manages the lifecycle). Explicit dispose not needed.
    player.dispose();
  }
}

class PlayerPoolNotifier extends Notifier<Map<String, PlayerInstance>> {
  static const int maxPoolSize = 12;

  @override
  Map<String, PlayerInstance> build() {
    ref.onDispose(() {
      for (final instance in state.values) {
        instance.dispose();
      }
    });
    return {};
  }

  void warmup(String id, String url, {bool isLandscape = false}) {
    if (state.containsKey(id)) {
      // Refresh LRU time on re-warmup of an already-loaded instance
      state = {
        ...state,
        id: state[id]!..lastUsed = DateTime.now(),
      };
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

    var newState = {...state, id: PlayerInstance(player, controller)};
    if (newState.length > maxPoolSize) {
      // Evict the least recently used instance (LRU).
      String? lruId;
      DateTime? oldest;
      for (final e in newState.entries) {
        if (oldest == null || e.value.lastUsed.isBefore(oldest)) {
          oldest = e.value.lastUsed;
          lruId = e.key;
        }
      }
      if (lruId != null) {
        newState[lruId]?.dispose();
        newState = Map.from(newState)..remove(lruId);
      }
    }
    state = newState;
  }

  void cleanupExcept(Set<String> activeIds) {
    final newState = <String, PlayerInstance>{};
    for (final entry in state.entries) {
      if (activeIds.contains(entry.key)) {
        newState[entry.key] = entry.value;
      } else {
        entry.value.dispose();
      }
    }
    state = newState;
  }
}

final playerPoolProvider =
    NotifierProvider<PlayerPoolNotifier, Map<String, PlayerInstance>>(
  PlayerPoolNotifier.new,
);
