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
        maxNrOfCacheObjects: 200,
        repo: JsonCacheInfoRepository(databaseName: key),
        fileService: HttpFileService(),
      ),
    );
    return _instance!;
  }

  static Future<int> getCacheSize() async {
    try {
      final tempDir = await getTemporaryDirectory();

      // flutter_cache_manager typically stores files in a directory named after the key.
      // On some platforms/versions, it might be inside 'libCachedImageData' or 'flutter_cache_manager'.
      final possiblePaths = {
        p.join(tempDir.path, key),
        p.join(tempDir.path, 'libCachedImageData', key),
        p.join(tempDir.path, 'flutter_cache_manager', key),
      };

      int totalSize = 0;
      final processedFiles = <String>{};

      for (final path in possiblePaths) {
        final dir = Directory(path);
        if (await dir.exists()) {
          await for (var entity
              in dir.list(recursive: true, followLinks: false)) {
            if (entity is File && !processedFiles.contains(entity.path)) {
              totalSize += await entity.length();
              processedFiles.add(entity.path);
            }
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
      final tempDir = await getTemporaryDirectory();
      final possiblePaths = {
        p.join(tempDir.path, key),
        p.join(tempDir.path, 'libCachedImageData', key),
        p.join(tempDir.path, 'flutter_cache_manager', key),
      };

      final allFiles = <File>[];
      final seen = <String>{};
      int totalSize = 0;
      for (final path in possiblePaths) {
        final dir = Directory(path);
        if (!await dir.exists()) continue;
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

      for (final file in allFiles) {
        if (totalSize <= limitBytes) break;
        try {
          final len = await file.length();
          await file.delete();
          totalSize -= len;
        } catch (_) {}
      }

      debugPrint(
          'XFLOW: Cache enforced to $limitMB MB. Now ${totalSize ~/ (1024 * 1024)} MB');
      return totalSize;
    } catch (e) {
      debugPrint('Error enforcing cache limit: $e');
      return await getCacheSize();
    }
  }

  static Future<void> clearCache() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final possiblePaths = {
        p.join(tempDir.path, key),
        p.join(tempDir.path, 'libCachedImageData', key),
        p.join(tempDir.path, 'flutter_cache_manager', key),
      };

      for (final path in possiblePaths) {
        final dir = Directory(path);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }

      // Also empty the manager instance
      await getInstance().emptyCache();
    } catch (e) {
      debugPrint('Error clearing physical cache: $e');
    }
  }
}
