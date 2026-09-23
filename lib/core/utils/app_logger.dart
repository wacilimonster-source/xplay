import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, error }

class AppLogger {
  AppLogger._();

  static final List<String> _logs = [];
  static const int _maxLogs = 1000;

  /// Entries below this level are dropped entirely (not even kept).
  static LogLevel minLevel = LogLevel.debug;

  /// Console output is a debug-build affordance: in release the ring buffer is
  /// still kept (the in-app log viewer is how bug reports reach us), but every
  /// line no longer goes through `debugPrint`'s throttling machinery.
  static bool consoleOutput = kDebugMode;

  static List<String> get logs => List.unmodifiable(_logs);

  static void log(String message, {LogLevel level = LogLevel.info}) {
    if (level.index < minLevel.index) return;
    final timestamp = DateTime.now().toString().split('.').first;
    final logEntry = '[$timestamp] $message';

    _logs.add(logEntry);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    if (consoleOutput) debugPrint(logEntry);
  }

  /// Hot-path, purely diagnostic lines. Skipped in release builds by default.
  static void debug(String message) => log(message, level: LogLevel.debug);

  static void error(String message) => log(message, level: LogLevel.error);

  static void clear() {
    _logs.clear();
  }
}
