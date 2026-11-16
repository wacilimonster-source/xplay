import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/tweet.dart';
import 'media_cache_manager.dart';

/// One place for "warm the images around the current feed item".
///
/// The three full-screen feeds used to duplicate this loop, and all three
/// warmed only the tweet images - avatars (default cache manager) and video
/// thumbnails were still downloaded when the item came into view.
class FeedMediaPreloader {
  const FeedMediaPreloader._();

  /// Needs a [BuildContext] because `precacheImage` decodes into the nearest
  /// image cache. Call from a feed screen's `_managePool()`.
  static void precacheFrame(
    BuildContext context,
    List<Tweet> tweets,
    int currentIndex, {
    int behind = 1,
    required int ahead,
    bool includeAvatars = true,
  }) {
    if (tweets.isEmpty) return;
    final cacheManager = CustomMediaCacheManager.getInstance();

    final start = currentIndex - behind < 0 ? 0 : currentIndex - behind;
    final end = currentIndex + ahead > tweets.length - 1
        ? tweets.length - 1
        : currentIndex + ahead;

    for (int i = start; i <= end; i++) {
      final tweet = tweets[i];
      for (final url in tweet.mediaUrls) {
        unawaited(precacheImage(
          CachedNetworkImageProvider(url, cacheManager: cacheManager),
          context,
        ));
      }
      // A video's first frame is shown while the player buffers.
      final thumb = tweet.thumbnailUrl;
      if (tweet.isVideo && thumb != null && thumb.isNotEmpty) {
        unawaited(precacheImage(
          CachedNetworkImageProvider(thumb, cacheManager: cacheManager),
          context,
        ));
      }
      if (includeAvatars) {
        final avatar = tweet.userAvatarUrlHighRes;
        if (avatar != null && avatar.isNotEmpty) {
          // The overlay reads avatars with the DEFAULT cache manager.
          unawaited(precacheImage(
            CachedNetworkImageProvider(avatar),
            context,
          ));
        }
      }
    }
  }
}
