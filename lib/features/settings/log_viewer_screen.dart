import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/utils/app_logger.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  static const _refreshInterval = Duration(seconds: 2);

  /// AppLogger 只是静态 List，没有变更通知能力，只能定时轮询刷新。
  Timer? _refreshTimer;
  List<String> _logs = const [];

  @override
  void initState() {
    super.initState();
    _logs = AppLogger.logs;
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _syncLogs());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _syncLogs() {
    final logs = AppLogger.logs;
    if (!mounted) return;
    // 内容没变化就不重建列表，避免每两秒无谓刷新。
    if (logs.length == _logs.length &&
        (logs.isEmpty || logs.last == _logs.last)) {
      return;
    }
    setState(() => _logs = logs);
  }

  Future<void> _copyAll() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _logs.join('\n')));
    messenger.showSnackBar(
      SnackBar(content: Text('已复制 ${_logs.length} 条日志到剪贴板')),
    );
  }

  Future<void> _confirmClear() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定要清空当前全部日志吗？清空后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    AppLogger.clear();
    if (!mounted) return;
    setState(() => _logs = AppLogger.logs);
    messenger.showSnackBar(const SnackBar(content: Text('日志已清空')));
  }

  @override
  Widget build(BuildContext context) {
    final logs = _logs;

    return Scaffold(
      appBar: AppBar(
        title: Text('应用日志 (${logs.length})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '立即刷新',
            onPressed: _syncLogs,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制全部',
            onPressed: logs.isEmpty ? null : _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: logs.isEmpty ? null : _confirmClear,
          ),
        ],
      ),
      body: logs.isEmpty
          ? const Center(
              child: Text('暂无日志', style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final log = logs[logs.length - 1 - index]; // Show latest logs first
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: SelectableText(
                    log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
