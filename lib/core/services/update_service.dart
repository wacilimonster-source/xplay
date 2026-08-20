import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateService {
  static const String updateManifestUrl =
      'https://raw.githubusercontent.com/wacilimonster-source/xplay/main/update.json';
  static const String _lastCheckedKey = 'last_update_check';
  static const String _ignoredVersionsKey = 'ignored_update_versions';
  static const String _downloadFileName = 'xplay-update.apk';
  static File? _downloadedApk;
  static String? _downloadedVersion;
  static bool _downloadInProgress = false;

  /// 拉取轻量更新清单。时间戳和 no-cache 用于绕过 GitHub/CDN 的旧缓存。
  static Future<UpdateInfo?> checkForUpdate({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      final manifestUri = Uri.parse(updateManifestUrl).replace(
        queryParameters: {
          'ts': DateTime.now().millisecondsSinceEpoch.toString()
        },
      );
      final response = await http.get(
        manifestUri,
        headers: const {
          'Accept': 'application/json',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
        },
      ).timeout(timeout);

      if (response.statusCode != HttpStatus.ok) return null;

      final rawData = jsonDecode(utf8.decode(response.bodyBytes));
      if (rawData is! Map<String, dynamic>) return null;

      final version = _cleanVersion(rawData['version']?.toString() ?? '');
      if (version.isEmpty) return null;

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = _cleanVersion(packageInfo.version);
      if (!_isNewerVersion(version, currentVersion)) {
        await _markChecked();
        return null;
      }
      if (await isVersionIgnored(version)) {
        await _markChecked();
        return null;
      }

      final urls = _parseDownloadUrls(rawData, version);
      await _markChecked();
      return UpdateInfo(
        version: version,
        releaseNotes: rawData['notes']?.toString().trim().isNotEmpty == true
            ? rawData['notes'].toString()
            : '暂无更新说明',
        apkUrls: urls,
        publishedAt: rawData['publishedAt']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 按配置顺序尝试下载 APK，并报告 0.0 到 1.0 的进度。
  static Future<File> downloadApk(
    UpdateInfo updateInfo, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (updateInfo.apkUrls.isEmpty) {
      throw const UpdateDownloadException('更新清单没有可用的 APK 地址');
    }
    if (_downloadInProgress) {
      throw const UpdateDownloadException('更新正在下载中');
    }

    // Reserve the download slot before any asynchronous file checks so two
    // callers cannot pass the guard at the same time.
    _downloadInProgress = true;
    try {
      final cached = _downloadedApk;
      if (_downloadedVersion == updateInfo.version &&
          cached != null &&
          await cached.exists() &&
          await cached.length() > 0) {
        final length = await cached.length();
        onProgress?.call(length, length);
        return cached;
      }

      final directory = await getTemporaryDirectory();
      final target = File('${directory.path}/$_downloadFileName');
      Object? lastError;

      for (var index = 0; index < updateInfo.apkUrls.length; index++) {
        final url = updateInfo.apkUrls[index];
        try {
          await _downloadFromUrl(
            url,
            target,
            onProgress: onProgress,
            timeout: timeout,
          );
          _downloadedApk = target;
          _downloadedVersion = updateInfo.version;
          return target;
        } catch (error) {
          lastError = error;
          if (await target.exists()) {
            await target.delete();
          }
          if (index < updateInfo.apkUrls.length - 1) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      }

      throw UpdateDownloadException('所有下载源均失败：$lastError');
    } finally {
      _downloadInProgress = false;
    }
  }

  static Future<void> _downloadFromUrl(
    String url,
    File target, {
    required void Function(int received, int total)? onProgress,
    required Duration timeout,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['Cache-Control'] = 'no-cache';
      final streamed = await client.send(request).timeout(timeout);
      if (streamed.statusCode != HttpStatus.ok) {
        throw UpdateDownloadException('下载源返回 HTTP ${streamed.statusCode}');
      }

      final sink = target.openWrite();
      var received = 0;
      try {
        // Apply the timeout to the stream as well as the initial headers;
        // otherwise a stalled connection can leave the dialog downloading
        // forever after the request itself has already completed.
        await for (final chunk in streamed.stream.timeout(timeout)) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, streamed.contentLength ?? -1);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (received == 0) {
        throw const UpdateDownloadException('下载内容为空');
      }
    } finally {
      client.close();
      if (await target.exists()) {
        final length = await target.length();
        if (length == 0) await target.delete();
      }
    }
  }

  static List<String> _parseDownloadUrls(
    Map<String, dynamic> data,
    String version,
  ) {
    final urls = <String>[];
    final configuredUrls = data['apkUrls'];
    if (configuredUrls is List) {
      for (final value in configuredUrls) {
        final url = value.toString().trim();
        if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
      }
    }

    final apkUrl = data['apkUrl']?.toString().trim() ?? '';
    if (apkUrl.isNotEmpty && !urls.contains(apkUrl)) urls.add(apkUrl);

    // 清单没有地址时，按约定补上 Release asset 地址。
    if (urls.isEmpty) {
      final tag = 'v$version';
      urls.add(
        'https://github.com/wacilimonster-source/xplay/releases/download/$tag/app-release.apk',
      );
    }
    return urls;
  }

  static String _cleanVersion(String version) {
    return version.trim().replaceFirst(RegExp(r'^[vV]'), '');
  }

  static bool _isNewerVersion(String newVersion, String currentVersion) {
    final newParts = _versionParts(newVersion);
    final currentParts = _versionParts(currentVersion);
    final length = newParts.length > currentParts.length
        ? newParts.length
        : currentParts.length;

    for (var i = 0; i < length; i++) {
      final newPart = i < newParts.length ? newParts[i] : 0;
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      if (newPart != currentPart) return newPart > currentPart;
    }
    return false;
  }

  static List<int> _versionParts(String version) {
    return version
        .split('.')
        .map(
            (part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  static Future<void> _markChecked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastCheckedKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<void> ignoreVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final ignored = prefs.getStringList(_ignoredVersionsKey) ?? <String>[];
    if (!ignored.contains(version)) {
      ignored.add(version);
      await prefs.setStringList(_ignoredVersionsKey, ignored);
    }
  }

  static Future<bool> isVersionIgnored(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final ignored = prefs.getStringList(_ignoredVersionsKey) ?? <String>[];
    return ignored.contains(version);
  }

  static Future<DateTime?> getLastCheckedTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastCheckedKey);
    return timestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(timestamp);
  }
}

class UpdateInfo {
  final String version;
  final String releaseNotes;
  final List<String> apkUrls;
  final String publishedAt;

  const UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.apkUrls,
    required this.publishedAt,
  });

  String? get apkUrl => apkUrls.isEmpty ? null : apkUrls.first;

  @override
  String toString() {
    return 'UpdateInfo(version: $version, urls: ${apkUrls.length})';
  }
}

class UpdateDownloadException implements Exception {
  final String message;

  const UpdateDownloadException(this.message);

  @override
  String toString() => message;
}
