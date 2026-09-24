import 'package:flutter_test/flutter_test.dart';
import 'package:xplay/features/player/player_pool_provider.dart';

/// The doc's P0-2 check ("scroll 50 on, look back at the first 10, count player
/// re-creations") does not need a device for the part that is bookkeeping: the
/// pool is an LRU with a scope rule, so the churn can be simulated exactly. What
/// still needs a device is only whether mpv itself behaves (buffering, memory).
void main() {
  test('a 50-item scroll keeps the last maxPoolSize ids resident', () {
    final sim = Sim();
    for (var i = 0; i < 50; i++) {
      sim.warm('t$i', 'home');
    }

    expect(sim.lastUsed.length, PlayerPoolNotifier.maxPoolSize);
    // The doc asks about "looking back at the first 10 of the last 50". Those
    // are t40..t49: all present, so scrolling back costs zero re-warmups.
    for (var i = 40; i < 50; i++) {
      expect(sim.lastUsed.containsKey('t$i'), isTrue, reason: 't$i was evicted');
    }
    expect(sim.lastUsed.containsKey('t39'), isTrue,
        reason: 't39 is the 11th item back and must still be resident');
  });

  test('the eviction boundary is exactly maxPoolSize items back', () {
    final sim = Sim();
    for (var i = 0; i < 50; i++) {
      sim.warm('t$i', 'home');
    }
    // 20 slots means the 20 most recent survive; the 21st back is a miss.
    expect(sim.lastUsed.containsKey('t30'), isTrue);
    expect(sim.lastUsed.containsKey('t29'), isFalse);
  });

  test('the gain over the old cap of 12 is 8 items of look-back', () {
    // Stated precisely, because the doc's own scenario ("50 on, back 10") would
    // have passed even at the old limit — the difference only shows up past 12.
    final old = Sim(cap: 12);
    final now = Sim();
    for (var i = 0; i < 50; i++) {
      old.warm('t$i', 'home');
      now.warm('t$i', 'home');
    }
    expect(old.lastUsed.length, 12);
    expect(now.lastUsed.length, 20);
    expect(old.lastUsed.containsKey('t38'), isTrue);
    expect(old.lastUsed.containsKey('t37'), isFalse,
        reason: '13 items back used to mean a fresh player and a re-buffer');
    expect(now.lastUsed.containsKey('t37'), isTrue);
  });

  test('another scope\'s visible player is never the first victim', () {
    final t = DateTime(2026);
    final victim = PlayerPoolNotifier.evictionVictim(
      lastUsed: {
        'old_home': t, // older, but owned by the requesting scope
        'old_other': t.add(const Duration(milliseconds: -1)), // oldest, other scope
      },
      owners: {
        'old_home': {'home'},
        'old_other': {'hashtag'},
      },
      scope: 'home',
      skip: 'incoming',
    );
    expect(victim, 'old_home',
        reason: 'the hashtag feed may be rendering old_other right now');
  });

  test('falls back to the global LRU when this scope has nothing droppable',
      () {
    final t = DateTime(2026);
    final victim = PlayerPoolNotifier.evictionVictim(
      lastUsed: {'a': t, 'b': t.add(const Duration(minutes: 1))},
      owners: {
        'a': {'hashtag'},
        'b': {'hashtag'}
      },
      scope: 'home',
      skip: 'incoming',
    );
    expect(victim, 'a');
  });

  test('the newly warmed id is never itself the victim', () {
    final t = DateTime(2026);
    final victim = PlayerPoolNotifier.evictionVictim(
      lastUsed: {'incoming': t.subtract(const Duration(hours: 1))},
      owners: {
        'incoming': {'home'}
      },
      scope: 'home',
      skip: 'incoming',
    );
    expect(victim, isNull);
  });

  test('memory pressure shrinks to the documented conservative size', () {
    // The doc suggested "drop back to 12"; the pool keeps 8, which is the
    // 5-wide preload window plus a little slack in each direction.
    expect(PlayerPoolNotifier.comfortablePoolSize, 8);
    expect(PlayerPoolNotifier.maxPoolSize,
        greaterThan(PlayerPoolNotifier.comfortablePoolSize));
  });
}

/// Mirrors what `warmup` does to its maps, minus the native player: the pool is
/// an LRU with a scope rule, so the eviction bookkeeping is testable without
/// loading mpv.
class Sim {
  final lastUsed = <String, DateTime>{};
  final owners = <String, Set<String>>{};
  final int cap;
  var _now = DateTime(2026, 9, 24);

  Sim({this.cap = PlayerPoolNotifier.maxPoolSize});

  void warm(String id, String scope) {
    _now = _now.add(const Duration(milliseconds: 1));
    if (lastUsed.containsKey(id)) {
      lastUsed[id] = _now;
      owners[id]!.add(scope);
      return;
    }
    if (lastUsed.length + 1 > cap) {
      final victim = PlayerPoolNotifier.evictionVictim(
        lastUsed: Map.of(lastUsed),
        owners: Map.of(owners),
        scope: scope,
        skip: id,
      );
      if (victim != null) {
        lastUsed.remove(victim);
        owners.remove(victim);
      }
    }
    lastUsed[id] = _now;
    owners[id] = {scope};
  }
}
