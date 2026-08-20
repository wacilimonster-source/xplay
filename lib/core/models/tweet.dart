class Tweet {
  final String id;
  final String text;
  final String userHandle;
  final String? userAvatarUrl;
  final String? mediaKey;
  final List<String> mediaUrls;
  final String? thumbnailUrl;
  final bool isVideo;
  final DateTime? createdAt;
  final String? source; // "API" or "Cache" or other metadata
  final bool isLiked;
  final int favoriteCount;
  final int replyCount;
  /// Original media width (pixels), parsed from Twitter CDN URL or API response.
  final int? mediaWidth;
  /// Original media height (pixels), parsed from Twitter CDN URL or API response.
  final int? mediaHeight;

  Tweet({
    required this.id,
    required this.text,
    required this.userHandle,
    this.userAvatarUrl,
    this.mediaKey,
    required this.mediaUrls,
    this.thumbnailUrl,
    this.isVideo = false,
    this.createdAt,
    this.source,
    this.isLiked = false,
    this.favoriteCount = 0,
    this.replyCount = 0,
    this.mediaWidth,
    this.mediaHeight,
  });

  String? get userAvatarUrlHighRes {
    if (userAvatarUrl == null) return null;
    return userAvatarUrl!.replaceAll('_normal', '');
  }

  /// Extracts width/height from a Twitter CDN URL (e.g.
  /// https://pbs.twimg.com/media/Fxxx.jpg?format=jpg&name=600x600)
  /// or https://pbs.twimg.com/media/Fxxx.jpg:small
  static (int?, int?) parseTwitterMediaSize(String? url) {
    if (url == null) return (null, null);
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      // Pattern: ?format=jpg&name=600x600
      final name = uri.queryParameters['name'];
      if (name != null && name.contains('x')) {
        final parts = name.split('x');
        if (parts.length == 2) {
          final w = int.tryParse(parts[0]);
          final h = int.tryParse(parts[1]);
          if (w != null && h != null && w > 0 && h > 0) return (w, h);
        }
      }
      // Pattern: :small, :large, :medium, :thumb
      final colon = path.lastIndexOf(':');
      if (colon > 0) {
        final size = path.substring(colon + 1);
        return switch (size) {
          'small' => (680, null),
          'large' => (2048, null),
          'medium' => (1200, null),
          'thumb' => (150, null),
          _ => (null, null),
        };
      }
    } catch (_) {}
    return (null, null);
  }

  Tweet copyWith({
    String? id,
    String? text,
    String? userHandle,
    String? userAvatarUrl,
    String? mediaKey,
    List<String>? mediaUrls,
    String? thumbnailUrl,
    bool? isVideo,
    DateTime? createdAt,
    String? source,
    bool? isLiked,
    int? favoriteCount,
    int? replyCount,
    int? mediaWidth,
    int? mediaHeight,
  }) {
    return Tweet(
      id: id ?? this.id,
      text: text ?? this.text,
      userHandle: userHandle ?? this.userHandle,
      userAvatarUrl: userAvatarUrl ?? this.userAvatarUrl,
      mediaKey: mediaKey ?? this.mediaKey,
      mediaUrls: mediaUrls ?? this.mediaUrls,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      isVideo: isVideo ?? this.isVideo,
      createdAt: createdAt ?? this.createdAt,
      source: source ?? this.source,
      isLiked: isLiked ?? this.isLiked,
      favoriteCount: favoriteCount ?? this.favoriteCount,
      replyCount: replyCount ?? this.replyCount,
      mediaWidth: mediaWidth ?? this.mediaWidth,
      mediaHeight: mediaHeight ?? this.mediaHeight,
    );
  }
}
