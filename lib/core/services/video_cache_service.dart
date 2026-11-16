import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Downloads video files to disk so a re-watched tweet can be opened from a
/// local path instead of streaming from X's CDN again.
///
/// Videos are cached under `<documents>/xplay_video_cache` with a deterministic
/// md5(url) filename. That is what makes [localPathSync] possible: the player
/// pool is synchronous, so it can decide "local or remote" without an await.
class VideoCacheService {
  VideoCacheService._();

  static final VideoCacheService instance = VideoCacheService._();

  static const String _directoryName = 'xplay_video_cache';
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  /// Retrying a failed URL on every scroll burns quota and floods the log.
  static const Duration _failureCooldown = Duration(minutes: 2);

  String? _directoryPath;
  final Map<String, Future<bool>> _inFlight = {};
  final Map<String, DateTime> _failedUntil = {};

  /// Resolves the cache directory once, during startup. Call from `main()`.
  Future<void> init() async {
    if (_directoryPath != null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cache = Directory('${dir.path}${Platform.pathSeparator}$_directoryName');
      if (!await cache.exists()) await cache.create(recursive: true);
      _directoryPath = cache.path;
    } catch (e) {
      debugPrint('VideoCacheService.init: $e');
    }
  }

  String _fileName(String url) => '${md5.convert(utf8.encode(url))}.mp4';

  String _partName(String url) => '${_fileName(url)}.part';

  bool _isCacheable(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    // HLS playlists are not a single file - downloading one would be useless.
    return !uri.path.toLowerCase().endsWith('.m3u8');
  }

  /// Synchronous lookup used by the player pool / player container. Safe to
  /// call on every scroll: only `statSync` on a local file is involved.
  String? localPathSync(String url) {
    final dir = _directoryPath;
    if (dir == null || !_isCacheable(url)) return null;
    try {
      final file = File('$dir${Platform.pathSeparator}${_fileName(url)}');
      if (!file.existsSync()) return null;
      return file.lengthSync() > 0 ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> localPath(String url) async {
    await init();
    return localPathSync(url);
  }

  /// Starts (or joins) a download. Returns whether a usable local file exists
  /// afterwards. Failures are swallowed after logging so callers can fire and
  /// forget this from a build/scroll callback.
  Future<bool> cache(String url) async {
    if (!_isCacheable(url)) return false;
    await init();
    if (_directoryPath == null) return false;

    final local = localPathSync(url);
    if (local != null) return true;

    final until = _failedUntil[url];
    if (until != null && DateTime.now().isBefore(until)) return false;

    final existing = _inFlight[url];
    if (existing != null) return existing;

    final future = _download(url);
    _inFlight[url] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(url);
    }
  }

  Future<bool> _download(String url) async {
    final dir = _directoryPath;
    if (dir == null) return false;
    final finalFile = File('$dir${Platform.pathSeparator}${_fileName(url)}');
    final partFile = File('$dir${Platform.pathSeparator}${_partName(url)}');

    IOSink? sink;
    http.StreamedResponse? response;
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..headers['User-Agent'] = _userAgent
        ..headers['Accept'] = 'video/mp4,*/*';
      response = await request.send();
      if (response.statusCode != 200) {
        _failedUntil[url] = DateTime.now().add(_failureCooldown);
        debugPrint('VideoCacheService: HTTP ${response.statusCode} for $url');
        return false;
      }

      // Write to a .part first so an interrupted download never looks cached.
      if (await partFile.exists()) await partFile.delete();
      sink = partFile.openWrite();
      // Do not use `stream.pipe(sink)`: pipe closes the sink itself, and the
      // flush/close below would then throw on an already-closed IOSink.
      await for (final chunk in response.stream) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (!await partFile.exists() || await partFile.length() == 0) {
        _failedUntil[url] = DateTime.now().add(_failureCooldown);
        await partFile.delete();
        return false;
      }

      if (await finalFile.exists()) await finalFile.delete();
      await partFile.rename(finalFile.path);
      _failedUntil.remove(url);
      return true;
    } catch (e) {
      _failedUntil[url] = DateTime.now().add(_failureCooldown);
      debugPrint('VideoCacheService: failed to cache $url: $e');
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      // Drain the response so the connection can be reused.
      try {
        await response?.stream.drain<void>();
      } catch (_) {}
      return false;
    }
  }

  Future<int> sizeBytes() async {
    await init();
    final dir = _directoryPath;
    if (dir == null) return 0;
    try {
      var total = 0;
      await for (final entity
          in Directory(dir).list(recursive: false, followLinks: false)) {
        if (entity is File && !entity.path.endsWith('.part')) {
          total += await entity.length();
        }
      }
      return total;
    } catch (e) {
      debugPrint('VideoCacheService.sizeBytes: $e');
      return 0;
    }
  }

  Future<int> fileCount() async {
    await init();
    final dir = _directoryPath;
    if (dir == null) return 0;
    try {
      var count = 0;
      await for (final entity
          in Directory(dir).list(recursive: false, followLinks: false)) {
        if (entity is File && !entity.path.endsWith('.part')) count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// Deletes oldest-first until the cache is under [limitMB].
  Future<int> enforceLimit(int limitMB) async {
    await init();
    final dir = _directoryPath;
    if (dir == null) return 0;
    try {
      final files = <File>[];
      await for (final entity
          in Directory(dir).list(recursive: false, followLinks: false)) {
        if (entity is File) files.add(entity);
      }
      final limitBytes = limitMB * 1024 * 1024;
      var total = await sizeBytes();
      if (total <= limitBytes) return total;

      files.sort((a, b) {
        final am = a.statSync().modified;
        final bm = b.statSync().modified;
        return am.compareTo(bm);
      });
      for (final file in files) {
        if (total <= limitBytes) break;
        try {
          final length = file.lengthSync();
          if (await file.exists()) {
            await file.delete();
            total -= length;
          }
        } catch (_) {}
      }
      return total < 0 ? 0 : total;
    } catch (e) {
      debugPrint('VideoCacheService.enforceLimit: $e');
      return sizeBytes();
    }
  }

  Future<void> clear() async {
    await init();
    final dir = _directoryPath;
    if (dir == null) return;
    try {
      await for (final entity
          in Directory(dir).list(recursive: false, followLinks: false)) {
        if (entity is File) await entity.delete();
      }
    } catch (e) {
      debugPrint('VideoCacheService.clear: $e');
    }
    _failedUntil.clear();
  }
}
