import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/update_service.dart';

class UpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;

  const UpdateDialog({super.key, required this.updateInfo});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  static const _channel = MethodChannel('com.xplay.app/update');
  double? _progress;
  bool _downloading = false;
  String? _error;

  String _publishedDate(String value) {
    if (value.isEmpty) return '未知';
    return value.length >= 10 ? value.substring(0, 10) : value;
  }

  Future<void> _downloadAndInstall() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });

    try {
      final file = await UpdateService.downloadApk(
        widget.updateInfo,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _progress = total > 0 ? received / total : null;
          });
        },
      );

      if (!mounted) return;
      if (!Platform.isAndroid) {
        setState(() {
          _downloading = false;
          _error = '当前平台不支持自动安装，请使用下载地址手动安装';
        });
        return;
      }

      await _channel.invokeMethod<bool>('installApk', {'path': file.path});
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '下载或安装失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.updateInfo;
    return AlertDialog(
      title: Text('发现新版本 v${info.version}'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('发布时间：${_publishedDate(info.publishedAt)}'),
            const SizedBox(height: 12),
            const Text('更新说明：', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(info.releaseNotes),
            if (_downloading) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(
                _progress == null
                    ? '正在下载更新…'
                    : '正在下载 ${(100 * _progress!).toStringAsFixed(0)}%',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        if (info.apkUrls.isNotEmpty)
          FilledButton(
            onPressed: _downloading ? null : _downloadAndInstall,
            child: Text(_error == null ? '下载并安装' : '重试'),
          ),
      ],
    );
  }
}
