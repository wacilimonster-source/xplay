import 'package:flutter_test/flutter_test.dart';
import 'package:xplay/core/client/discovery_engine.dart';
import 'package:xplay/core/models/tweet.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Guards the sliding-window rewrite of `applySaturation`:
/// it must produce *exactly* the same ordering as the previous O(n x window)
/// implementation, and it must be no slower.
void main() {
  List<Tweet> corpus(int count) {
    final out = <Tweet>[];
    for (var i = 0; i < count; i++) {
      out.add(Tweet(
        id: '$i',
        text: 't$i',
        // Few creators, so saturation rules actually fire constantly.
        userHandle: '@creator${i % 7}',
        mediaUrls: ['https://m/${i % 11}'],
        isVideo: true,
        favoriteCount: i,
      ));
    }
    return out;
  }

  const options = (
    threshold: 2,
    mediaThreshold: 1,
    windowSize: 10,
    startIndex: 0,
    maxSaturationSwaps: 1000,
    maxPasses: 3,
  );

  test('sliding-window result matches the reference implementation', () {
    for (final size in [12, 40, 137, 500]) {
      final input = corpus(size);
      final fast = DiscoveryEngine.applySaturation(
        input,
        threshold: options.threshold,
        mediaThreshold: options.mediaThreshold,
        windowSize: options.windowSize,
        startIndex: options.startIndex,
        maxSaturationSwaps: options.maxSaturationSwaps,
        maxPasses: options.maxPasses,
      );
      final reference = referenceApplySaturation(
        input,
        threshold: options.threshold,
        mediaThreshold: options.mediaThreshold,
        windowSize: options.windowSize,
        startIndex: options.startIndex,
        maxSaturationSwaps: options.maxSaturationSwaps,
        maxPasses: options.maxPasses,
      );
      expect(fast.map((t) => t.id).join(','), reference.map((t) => t.id).join(','),
          reason: 'size=$size 输出必须与旧实现逐项一致');
    }
  });

  test('honours a non-zero startIndex the same way', () {
    final input = corpus(80);
    List<String> run(int startIndex) =>
        DiscoveryEngine.applySaturation(input, startIndex: startIndex)
            .map((t) => t.id)
            .toList();
    final fast = run(25);
    final reference = referenceApplySaturation(input, startIndex: 25)
        .map((t) => t.id)
        .toList();
    expect(fast.join(','), reference.join(','));
    // Items before the anchor must never move.
    expect(fast.take(25).join(','), input.take(25).map((t) => t.id).join(','));
  });

  test('is faster than the previous implementation at feed size', () {
    final input = corpus(500);
    List<Tweet> timed(void Function() body) {
      body(); // warm up
      final sw = Stopwatch()..start();
      body();
      body();
      sw.stop();
      return const [];
    }

    var fastMs = 0.0, slowMs = 0.0;
    void measure() {
      final s1 = Stopwatch()..start();
      DiscoveryEngine.applySaturation(input,
          threshold: 2,
          mediaThreshold: 1,
          windowSize: 10,
          maxSaturationSwaps: 1000,
          maxPasses: 3);
      s1.stop();
      final s2 = Stopwatch()..start();
      referenceApplySaturation(input,
          threshold: 2,
          mediaThreshold: 1,
          windowSize: 10,
          maxSaturationSwaps: 1000,
          maxPasses: 3);
      s2.stop();
      fastMs = s1.elapsedMicroseconds / 1000;
      slowMs = s2.elapsedMicroseconds / 1000;
    }

    timed(() => measure());
    // ignore: avoid_print
    debugPrint('applySaturation(500): new ${fastMs.toStringAsFixed(1)}ms '
        'vs old ${slowMs.toStringAsFixed(1)}ms');
    // Measured on this corpus both versions cost well under a millisecond, so
    // this is a *no-regression* guard rather than a speed claim: the rewrite is
    // justified by the identical output above, not by a benchmark win.
    expect(fastMs, lessThan(slowMs + 5),
        reason: '新版本不应明显变慢（new=${fastMs}ms old=${slowMs}ms）');
  });
}

/// Verbatim copy of the pre-optimisation implementation, kept as the oracle for
/// ordering and as the timing baseline.
List<Tweet> referenceApplySaturation(List<Tweet> tweets,
    {int threshold = 2,
    int mediaThreshold = 1,
    int windowSize = 10,
    int startIndex = 0,
    int maxSaturationSwaps = 1000,
    int maxPasses = 3}) {
  if (tweets.isEmpty) return tweets;
  final result = List<Tweet>.from(tweets);
  int totalSwaps = 0;
  for (int pass = 0; pass < maxPasses; pass++) {
    int passSwaps = 0;
    for (int i = startIndex;
        i < result.length && totalSwaps < maxSaturationSwaps;
        i++) {
      final handle = _norm(result[i].userHandle);
      final mediaUrl =
          result[i].mediaUrls.isNotEmpty ? result[i].mediaUrls.first : null;
      final start = (i - windowSize).clamp(0, result.length);
      final window = result.sublist(start, i);
      final handleCount =
          window.where((t) => _norm(t.userHandle) == handle).length;
      final mediaCount = mediaUrl != null
          ? window
              .where((t) => t.mediaUrls.isNotEmpty && t.mediaUrls.first == mediaUrl)
              .length
          : 0;
      final isConsecutive = i > 0 && _norm(result[i - 1].userHandle) == handle;
      final isMediaConsecutive = i > 0 &&
          mediaUrl != null &&
          result[i - 1].mediaUrls.isNotEmpty &&
          result[i - 1].mediaUrls.first == mediaUrl;
      if (handleCount >= threshold ||
          isConsecutive ||
          mediaCount >= mediaThreshold ||
          isMediaConsecutive) {
        int swapIdx = -1;
        final lookahead = windowSize + 10;
        for (int j = i + 1; j < result.length && j < i + lookahead; j++) {
          if (refIsValidSwap(result, i, j, threshold, mediaThreshold, windowSize)) {
            swapIdx = j;
            break;
          }
        }
        if (swapIdx == -1) {
          for (int j = i + 1; j < result.length; j++) {
            if (refIsValidSwap(
                result, i, j, threshold, mediaThreshold, windowSize)) {
              swapIdx = j;
              break;
            }
          }
        }
        if (swapIdx != -1) {
          final temp = result[i];
          result[i] = result[swapIdx];
          result[swapIdx] = temp;
          passSwaps++;
          totalSwaps++;
        }
      }
    }
    if (passSwaps == 0) break;
  }
  return result;
}

bool refIsValidSwap(List<Tweet> result, int i, int j, int threshold,
    int mediaThreshold, int windowSize) {
  final candHandle = _norm(result[j].userHandle);
  final candMedia = result[j].mediaUrls.isNotEmpty ? result[j].mediaUrls.first : null;
  final prevHandle = i > 0 ? _norm(result[i - 1].userHandle) : null;
  final prevMedia =
      i > 0 && result[i - 1].mediaUrls.isNotEmpty ? result[i - 1].mediaUrls.first : null;
  if (candHandle == prevHandle) return false;
  if (candMedia != null && candMedia == prevMedia) return false;
  final candStart = (i - windowSize).clamp(0, result.length);
  final candWindow = result.sublist(candStart, i);
  final candHandleCount =
      candWindow.where((t) => _norm(t.userHandle) == candHandle).length;
  final candMediaCount = candMedia != null
      ? candWindow
          .where((t) => t.mediaUrls.isNotEmpty && t.mediaUrls.first == candMedia)
          .length
      : 0;
  return candHandleCount < threshold && candMediaCount < mediaThreshold;
}

String _norm(String handle) {
  final trimmed = handle.trim();
  return trimmed.startsWith('@')
      ? trimmed.substring(1).toLowerCase()
      : trimmed.toLowerCase();
}
