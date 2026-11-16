import 'package:flutter_test/flutter_test.dart';
import 'package:xplay/core/client/twitter_client.dart';
import 'package:xplay/core/utils/avatar_url.dart';

void main() {
  group('highest quality media policy', () {
    test('prefers the mp4 variant with the highest bitrate', () {
      final variants = [
        {
          'content_type': 'video/mp4',
          'bitrate': 832000,
          'url': 'https://video.twimg.com/low.mp4',
        },
        {
          'content_type': 'video/mp4',
          'bitrate': 2560000,
          'url': 'https://video.twimg.com/high.mp4',
        },
      ];
      expect(pickHighestQualityVideoUrl(variants),
          'https://video.twimg.com/high.mp4');
    });

    test('uses resolution to break a bitrate tie', () {
      final variants = [
        {
          'content_type': 'video/mp4',
          'bitrate': 2000000,
          'url': 'https://video.twimg.com/v.mp4?name=720x1280',
        },
        {
          'content_type': 'video/mp4',
          'bitrate': 2000000,
          'url': 'https://video.twimg.com/v.mp4?name=1080x1920',
        },
      ];
      expect(pickHighestQualityVideoUrl(variants),
          'https://video.twimg.com/v.mp4?name=1080x1920');
    });

    test('ignores HLS playlists unless there is no mp4', () {
      final variants = [
        {'content_type': 'application/x-mpegURL', 'url': 'https://x/stream.m3u8'},
        {
          'content_type': 'video/mp4',
          'bitrate': 1000,
          'url': 'https://x/video.mp4',
        },
      ];
      expect(pickHighestQualityVideoUrl(variants), 'https://x/video.mp4');
      expect(pickHighestQualityVideoUrl([variants.first]),
          'https://x/stream.m3u8');
    });

    test('avatar URLs drop all common size suffixes', () {
      expect(
        highResAvatarUrl(
            'https://pbs.twimg.com/profile_images/1/abc_normal.jpg'),
        'https://pbs.twimg.com/profile_images/1/abc.jpg',
      );
      expect(
        highResAvatarUrl(
            'https://pbs.twimg.com/profile_images/1/abc_400x400.jpg'),
        'https://pbs.twimg.com/profile_images/1/abc.jpg',
      );
      expect(highResAvatarUrl(null), isNull);
    });
  });
}
