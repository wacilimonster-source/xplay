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

class _UpdateDialogState extends State<UpdateDialog>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.xplay.app/update');
  double? _progress;
  bool _downloading = false;
  bool _waitingForPermission = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户从"安装未知应用"设置页返回后自动继续安装流程。
    if (state == AppLifecycleState.resumed && _waitingForPermission) {
      _waitingForPermission = false;
      _downloadAndInstall();
    }
  }

  String _publishedDate(String value) {
    if (value.isEmpty) return '未知';
    return value.length >= 10 ? value.substring(0, 10) : value;
  }

  Future<bool> _checkInstallPermission() async {
    try {
      final allowed =
          await _channel.invokeMethod<bool>('canRequestInstallPackages');
      return allowed == true;
    } catch (_) {
      return true; // 非 Android 或通道异常时放行,交由后续报错
    }
  }

  Future<void> _promptInstallPermission() async {
    if (!mounted) return;
    final granted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('需要安装权限'),
        content: const Text('安装更新需要允许「安装未知应用」。\n请在跳转的页面中为本应用开启该权限。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (granted != true || !mounted) return;

    try {
      await _channel.invokeMethod<bool>('openInstallPermissionSettings');
    } catch (_) {}
    setState(() {
      _waitingForPermission = true;
      _error = '请在系统设置中允许「安装未知应用」，返回后将自动继续安装。';
    });
  }

  Future<void> _downloadAndInstall() async {
    if (_downloading) return;
    if (!await _checkInstallPermission()) {
      await _promptInstallPermission();
      return;
    }
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

      try {
        await _channel.invokeMethod<bool>('installApk', {'path': file.path});
        if (mounted) Navigator.of(context).pop();
      } on PlatformException catch (e) {
        if (e.code == 'INSTALL_PERMISSION_DENIED') {
          setState(() {
            _downloading = false;
          });
          await _promptInstallPermission();
          return;
        }
        rethrow;
      }
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
