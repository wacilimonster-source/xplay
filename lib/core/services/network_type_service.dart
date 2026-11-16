import 'dart:io';

import 'package:flutter/services.dart';

/// Answers "are we on an unmetered connection?" without adding a plugin.
/// The Android side queries [ConnectivityManager]; other platforms are treated
/// as unmetered (desktop/web have no mobile data concept).
class NetworkTypeService {
  static const MethodChannel _channel = MethodChannel('com.xplay.app/network');
  static const Duration _cacheTtl = Duration(seconds: 30);

  static DateTime? _checkedAt;
  static bool? _lastResult;

  static Future<bool> isUnmetered() async {
    if (!Platform.isAndroid) return true;

    final now = DateTime.now();
    final checked = _checkedAt;
    final cached = _lastResult;
    if (cached != null &&
        checked != null &&
        now.difference(checked) < _cacheTtl) {
      return cached;
    }

    bool result;
    try {
      result = await _channel.invokeMethod<bool>('isWifiConnected') ?? true;
    } catch (_) {
      // A missing channel must not disable offline caching on devices/ROMs
      // where the query is unavailable.
      result = true;
    }
    _checkedAt = now;
    _lastResult = result;
    return result;
  }
}
