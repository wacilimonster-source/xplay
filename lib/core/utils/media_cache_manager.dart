import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class CustomMediaCacheManager {
  static const key = 'customMediaCacheData';
  static CacheManager? _instance;

  static CacheManager getInstance() {
    _instance ??= CacheManager(
      Config(
        key,
        stalePeriod: const Duration(days: 7),
        // 200 objects is reached within a couple of feeds, so the size limit the
        // user sets was effectively overridden by this cap.
        maxNrOfCacheObjects: 2000,
        repo: JsonCacheInfoRepository(databaseName: key),
        fileService: HttpFileService(),
      ),
    );
    return _instance!;
  }

  /// Folders holding *our* manager's files. `enforceLimit` must stay inside
  /// these: deleting another manager's files behind its back would leave its
  /// index pointing at missing files.
  static List<String> _ownDirs(String tempPath) => [
        p.join(tempPath, key),
        p.join(tempPath, 'libCachedImageData', key),
        p.join(tempPath, 'flutter_cache_manager', key),
      ];

  /// Directories that hold media bytes on disk.
  ///
  /// Avatars and the tweet-detail images use `CachedNetworkImageProvider` with
  /// the *default* cache manager, and cached API responses live in ffcache's
  /// folder — neither was counted or cleared, so "本地媒体缓存 已用 X MB" did not
  /// match reality and "清除媒体缓存" left those behind.
  static List<String> _allDirs(String tempPath) => [
        ..._ownDirs(tempPath),
        p.join(tempPath, 'libCachedImageData'),
        p.join(tempPath, 'flutter_cache_manager'),
        p.join(tempPath, 'ffcache'),
      ];

  static Future<List<Directory>> _existingDirs(
      List<String> Function(String) paths) async {
    final tempDir = await getTemporaryDirectory();
    final out = <Directory>[];
    for (final path in paths(tempDir.path)) {
      final dir = Directory(path);
      if (await dir.exists()) out.add(dir);
    }
    return out;
  }

  /// Bytes held by cache managers other than ours (avatars, detail images).
  /// Reported separately because `enforceLimit` may only delete our own files:
  /// yanking another manager's files off disk would leave its index pointing at
  /// missing entries.
  static Future<int> getOtherCacheSize() async {
    try {
      int total = 0;
      final seen = <String>{};
      final tempDir = await getTemporaryDirectory();
      for (final path in _allDirs(tempDir.path).toSet().difference(_ownDirs(tempDir.path).toSet())) {
        final dir = Directory(path);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File && seen.add(entity.path)) {
            total += await entity.length();
          }
        }
      }
      return total;
    } catch (e) {
      debugPrint('Error measuring other cache: $e');
      return 0;
    }
  }

  static Future<int> getCacheSize() async {
    try {
      int totalSize = 0;
      final processedFiles = <String>{};

      for (final dir in await _existingDirs(_allDirs)) {
        await for (var entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File && !processedFiles.contains(entity.path)) {
            totalSize += await entity.length();
            processedFiles.add(entity.path);
          }
        }
      }
      return totalSize;
    } catch (e) {
      debugPrint('Error calculating cache size: $e');
      return 0;
    }
  }

  /// Enforces the configured size limit (in MB). When the cache exceeds it,
  /// files are deleted oldest-first (by last modified time) until under the
  /// limit. Returns the size (bytes) after enforcement.
  static Future<int> enforceLimit(int limitMB) async {
    try {
      final allFiles = <File>[];
      final seen = <String>{};
      int totalSize = 0;
      for (final dir in await _existingDirs(_ownDirs)) {
        await for (var entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File && !seen.contains(entity.path)) {
            seen.add(entity.path);
            totalSize += await entity.length();
            allFiles.add(entity);
          }
        }
      }

      final limitBytes = limitMB * 1024 * 1024;
      if (totalSize <= limitBytes) return totalSize;

      allFiles.sort((a, b) {
        final am = a.statSync().modified;
        final bm = b.statSync().modified;
        return am.compareTo(bm);
      });

      var failed = 0;
      for (final file in allFiles) {
        if (totalSize <= limitBytes) break;
        try {
          final len = await file.length();
          await file.delete();
          totalSize -= len;
        } catch (_) {
          failed++;
        }
      }

      debugPrint(
          'XFLOW: Cache enforced to $limitMB MB. Now ${totalSize ~/ (1024 * 1024)} MB'
          '${failed > 0 ? " ($failed file(s) could not be deleted)" : ""}');
      return totalSize;
    } catch (e) {
      debugPrint('Error enforcing cache limit: $e');
      return await getCacheSize();
    }
  }

  static Future<void> clearCache() async {
    try {
      for (final dir in await _existingDirs(_allDirs)) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }

      // Empty the managers themselves so their indexes stop pointing at the
      // files just deleted (and so the default manager's avatars go too).
      await getInstance().emptyCache();
      await DefaultCacheManager().emptyCache();
    } catch (e) {
      debugPrint('Error clearing physical cache: $e');
    }
  }
}
