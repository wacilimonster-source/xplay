import '../models/tweet.dart';
import '../utils/app_logger.dart';

/// The core intelligence of XFlow's feed.
///
/// Handles interleaving fresh/cached content, promoting new accounts,
/// and enforcing diversity via saturation thresholds for handles and media.
class DiscoveryEngine {
  /// Interleaves fresh API items and cached items based on a ratio (0.0 to 1.0).
  ///
  /// [ratio] represents the target percentage of fresh items in the result.
  /// Logic ensures that if we have a 0.3 ratio, roughly 3 out of every 10 items
  /// are from the [fresh] pool, while maintaining relative order within each pool.
  static List<Tweet> interleave(
      List<Tweet> fresh, List<Tweet> cached, double ratio) {
    AppLogger.log(
        'Discovery: Interleaving ${fresh.length} fresh and ${cached.length} cached items with ratio $ratio');
    final result = <Tweet>[];
    int freshIdx = 0;
    int cacheIdx = 0;

    int currentFreshCount = 0;

    while (freshIdx < fresh.length || cacheIdx < cached.length) {
      int nextCount = result.length + 1;
      int targetFreshCount = (nextCount * ratio).floor();

      // Determine if the next slot should be fresh based on the target ratio
      bool shouldPickFresh = freshIdx < fresh.length &&
          (currentFreshCount < targetFreshCount || cacheIdx >= cached.length);

      if (shouldPickFresh) {
        final item = fresh[freshIdx++];
        result.add(item);
        currentFreshCount++;
      } else if (cacheIdx < cached.length) {
        result.add(cached[cacheIdx++]);
      } else {
        // Fallback for trailing items
        if (freshIdx < fresh.length) {
          result.add(fresh[freshIdx++]);
          currentFreshCount++;
        } else {
          break;
        }
      }
    }
    AppLogger.log('Discovery: Interleaving complete. Total: ${result.length}');
    return result;
  }

  /// Ensures handles are compared consistently regardless of '@' prefix or case.
  static String _normalizeHandle(String handle) {
    final trimmed = handle.trim();
    if (trimmed.startsWith('@')) {
      return trimmed.substring(1).toLowerCase();
    }
    return trimmed.toLowerCase();
  }

  /// Promotes tweets from accounts the user has interacted with the least.
  ///
  /// [playedCountByUser] maps handles to total views.
  /// [lookahead] defines how far down the list we search for a "better" candidate
  /// to swap into the current position.
  ///
  /// Should be run BEFORE saturation so saturation can "fix" any clumps
  /// created by the boost.
  static List<Tweet> applyUnseenSubscriptionBoost(
    List<Tweet> tweets,
    Map<String, int> playedCountByUser, {
    int lookahead = 6,
    int startIndex = 0,
  }) {
    if (tweets.length < 2 || playedCountByUser.isEmpty) return tweets;

    final result = List<Tweet>.from(tweets);
    int boosts = 0;

    for (int i = startIndex; i < result.length - 1; i++) {
      final end = (i + lookahead).clamp(i + 1, result.length);
      int bestIdx = i;
      int bestScore =
          playedCountByUser[_normalizeHandle(result[i].userHandle)] ?? 0;

      final prevHandle =
          i > 0 ? _normalizeHandle(result[i - 1].userHandle) : null;

      // Find the account in the lookahead window with the lowest view count
      for (int j = i + 1; j < end; j++) {
        final candHandle = _normalizeHandle(result[j].userHandle);

        // Safety: Don't pull an item up if it would create a consecutive duplicate
        if (candHandle == prevHandle) continue;

        final candScore = playedCountByUser[candHandle] ?? 0;
        if (candScore < bestScore) {
          bestScore = candScore;
          bestIdx = j;
        }
      }

      // Swap the best candidate into the current position
      if (bestIdx != i) {
        final temp = result[i];
        result[i] = result[bestIdx];
        result[bestIdx] = temp;
        boosts++;
      }
    }

    if (boosts > 0) {
      AppLogger.log(
          'Discovery: Applied $boosts unseen subscription boosts (Lookahead: $lookahead, StartIndex: $startIndex)');
    }
    return result;
  }

  /// Enforces feed diversity by separating clumps of the same user or media.
  ///
  /// [threshold] - Max times a handle can appear in [windowSize].
  /// [mediaThreshold] - Max times a specific media URL can appear in [windowSize].
  /// [maxPasses] - Enables multiple sweeps of the list. Essential because
  /// a swap made to fix index 5 might create a new clump at index 8.
  ///
  /// The algorithm lookahead search ensures that the item we pull UP to break
  /// a clump is itself a "valid" fit for the new position.
  static List<Tweet> applySaturation(List<Tweet> tweets,
      {int threshold = 2,
      int mediaThreshold = 1,
      int windowSize = 10,
      int startIndex = 0,
      int maxSaturationSwaps = 1000,
      int maxPasses = 3}) {
    if (tweets.isEmpty) return tweets;
    final result = List<Tweet>.from(tweets);
    final length = result.length;

    // Handle/media identity is normalised once per item and then kept in sync
    // with `result` on every swap. Previously each position re-normalised the
    // whole preceding window (`window.where((t) => _normalizeHandle(...)`) for
    // itself *and* for every swap candidate, which is O(n x windowSize x
    // lookahead) work per pass.
    final handles = List<String?>.generate(
        length, (i) => _normalizeHandle(result[i].userHandle));
    final mediaUrls = List<String?>.generate(
        length,
        (i) =>
            result[i].mediaUrls.isNotEmpty ? result[i].mediaUrls.first : null);

    final handleCounts = <String, int>{};
    final mediaCounts = <String, int>{};

    void windowAdd(int index) {
      final handle = handles[index];
      if (handle != null) {
        handleCounts[handle] = (handleCounts[handle] ?? 0) + 1;
      }
      final media = mediaUrls[index];
      if (media != null) {
        mediaCounts[media] = (mediaCounts[media] ?? 0) + 1;
      }
    }

    void windowRemove(int index) {
      final handle = handles[index];
      if (handle != null) {
        final left = (handleCounts[handle] ?? 1) - 1;
        if (left <= 0) {
          handleCounts.remove(handle);
        } else {
          handleCounts[handle] = left;
        }
      }
      final media = mediaUrls[index];
      if (media != null) {
        final left = (mediaCounts[media] ?? 1) - 1;
        if (left <= 0) {
          mediaCounts.remove(media);
        } else {
          mediaCounts[media] = left;
        }
      }
    }

    int totalSwaps = 0;

    // Multi-pass sweep: Subsequent passes resolve clumps created by previous swaps.
    for (int pass = 0; pass < maxPasses; pass++) {
      int passSwaps = 0;
      handleCounts.clear();
      mediaCounts.clear();
      // Seed the window with whatever precedes startIndex (the original counted
      // from max(0, i - windowSize), so items before startIndex do count).
      final seedFrom = (startIndex - windowSize).clamp(0, length);
      for (int k = seedFrom; k < startIndex && k < length; k++) {
        windowAdd(k);
      }

      int windowLeft = seedFrom;

      for (int i = startIndex;
          i < length && totalSwaps < maxSaturationSwaps;
          i++) {
        final handle = handles[i];
        final mediaUrl = mediaUrls[i];

        final handleCount = handle == null ? 0 : (handleCounts[handle] ?? 0);
        final mediaCount = mediaUrl == null ? 0 : (mediaCounts[mediaUrl] ?? 0);

        // Hard rule: No consecutive duplicates (even if threshold > 1)
        final isConsecutive = i > 0 && handles[i - 1] == handle;
        final isMediaConsecutive =
            i > 0 && mediaUrl != null && mediaUrls[i - 1] == mediaUrl;

        // If any diversity rule is violated, search forward for a valid swap candidate
        if (handleCount >= threshold ||
            isConsecutive ||
            mediaCount >= mediaThreshold ||
            isMediaConsecutive) {
          int swapIdx = -1;

          // First pass: lookahead search for a perfect candidate
          final lookahead = windowSize + 10;
          for (int j = i + 1; j < length && j < i + lookahead; j++) {
            if (_isValidCached(handles, mediaUrls, handleCounts, mediaCounts,
                result, i, j, threshold, mediaThreshold)) {
              swapIdx = j;
              break;
            }
          }

          // Second pass: if no perfect candidate in lookahead, search the entire remaining list
          if (swapIdx == -1) {
            for (int j = i + 1; j < length; j++) {
              if (_isValidCached(handles, mediaUrls, handleCounts, mediaCounts,
                  result, i, j, threshold, mediaThreshold)) {
                swapIdx = j;
                break;
              }
            }
          }

          if (swapIdx != -1) {
            final temp = result[i];
            result[i] = result[swapIdx];
            result[swapIdx] = temp;
            // Keep the cached identity in step with the swap. Index i has not
            // been added to the window yet and swapIdx is ahead of it, so the
            // window maps stay correct without further edits.
            final h = handles[i];
            handles[i] = handles[swapIdx];
            handles[swapIdx] = h;
            final m = mediaUrls[i];
            mediaUrls[i] = mediaUrls[swapIdx];
            mediaUrls[swapIdx] = m;
            passSwaps++;
            totalSwaps++;
          }
        }

        windowAdd(i);
        if (i - windowLeft + 1 > windowSize) {
          windowRemove(windowLeft);
          windowLeft++;
        }
      }
      // If a full pass resulted in zero swaps, the list is perfectly diverse.
      if (passSwaps == 0) break;
    }

    if (totalSwaps > 0) {
      AppLogger.log(
          'Discovery: Applied $totalSwaps saturation swaps (Threshold: $threshold, MediaThreshold: $mediaThreshold, StartIndex: $startIndex)');
    }
    return result;
  }

  /// Reads the pre-computed identity arrays and the live sliding-window
  /// counters instead of re-scanning the window.
  static bool _isValidCached(
      List<String?> handles,
      List<String?> mediaUrls,
      Map<String, int> handleCounts,
      Map<String, int> mediaCounts,
      List<Tweet> result,
      int i,
      int j,
      int threshold,
      int mediaThreshold) {
    final candHandle = handles[j];
    final candMedia = mediaUrls[j];
    final prevHandle = i > 0 ? handles[i - 1] : null;
    final prevMedia = i > 0 ? mediaUrls[i - 1] : null;

    // Must not create a consecutive duplicate
    if (candHandle == prevHandle) return false;
    if (candMedia != null && candMedia == prevMedia) return false;

    // Must not violate saturation rules in its new window at position i
    final candHandleCount =
        candHandle == null ? 0 : (handleCounts[candHandle] ?? 0);
    final candMediaCount =
        candMedia == null ? 0 : (mediaCounts[candMedia] ?? 0);

    return candHandleCount < threshold && candMediaCount < mediaThreshold;
  }
}
