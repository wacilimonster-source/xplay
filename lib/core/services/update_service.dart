import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateService {
  static const String _repoUrl = 'https://github.com/wacilimonster-source/xplay';
  static const String _latestReleaseUrl = '$_repoUrl/releases/latest';
  static const String _apiUrl = 'https://api.github.com/repos/wacilimonster-source/xplay/releases/latest';
  static const String _lastCheckedKey = 'last_update_check';
  static const String _ignoredVersionsKey = 'ignored_update_versions';

  /// 检查是否有新版本可用
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final response = await http.get(
        Uri.parse(_apiUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );

      if (response.statusCode != 200) {
        return null;
      }

      final data = json.decode(response.body);
      final tagName = data['tag_name'] ?? '';
      final version = tagName.replaceFirst('v', '');
      
      if (version.isEmpty) return null;

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // 比较版本号
      if (_isNewerVersion(version, currentVersion)) {
        final assets = data['assets'] ?? [];
        String? apkUrl;
        
        for (final asset in assets) {
          final name = asset['name'] ?? '';
          if (name.endsWith('.apk')) {
            apkUrl = asset['browser_download_url'];
            break;
          }
        }

        return UpdateInfo(
          version: version,
          releaseNotes: data['body'] ?? '暂无更新说明',
          apkUrl: apkUrl,
          publishedAt: data['published_at'] ?? '',
        );
      }

      // 更新最后检查时间
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastCheckedKey, DateTime.now().millisecondsSinceEpoch);

      return null;
    } catch (e) {
      return null;
    }
  }

  /// 比较版本号，判断 newVersion 是否比 currentVersion 新
  static bool _isNewerVersion(String newVersion, String currentVersion) {
    try {
      final newParts = newVersion.split('.').map(int.parse).toList();
      final currentParts = currentVersion.split('.').map(int.parse).toList();

      // 确保两个版本号有相同的长度
      while (newParts.length < currentParts.length) {
        newParts.add(0);
      }
      while (currentParts.length < newParts.length) {
        currentParts.add(0);
      }

      for (var i = 0; i < newParts.length; i++) {
        if (newParts[i] > currentParts[i]) return true;
        if (newParts[i] < currentParts[i]) return false;
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// 标记某个版本为已忽略
  static Future<void> ignoreVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final ignored = prefs.getStringList(_ignoredVersionsKey) ?? [];
    if (!ignored.contains(version)) {
      ignored.add(version);
      await prefs.setStringList(_ignoredVersionsKey, ignored);
    }
  }

  /// 检查版本是否已被忽略
  static Future<bool> isVersionIgnored(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final ignored = prefs.getStringList(_ignoredVersionsKey) ?? [];
    return ignored.contains(version);
  }

  /// 获取最后检查时间
  static Future<DateTime?> getLastCheckedTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastCheckedKey);
    if (timestamp != null) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    return null;
  }
}

class UpdateInfo {
  final String version;
  final String releaseNotes;
  final String? apkUrl;
  final String publishedAt;

  UpdateInfo({
    required this.version,
    required this.releaseNotes,
    this.apkUrl,
    required this.publishedAt,
  });

  @override
  String toString() {
    return 'UpdateInfo(version: $version, hasApk: ${apkUrl != null})';
  }
}