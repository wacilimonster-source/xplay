package com.xplay.app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.xplay.app/update"
    private val apkMimeType = "application/vnd.android.package-archive"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_PATH", "APK 路径为空", null)
                            return@setMethodCallHandler
                        }
                        if (!canRequestInstallPackages()) {
                            result.error(
                                "INSTALL_PERMISSION_DENIED",
                                "未授予安装未知应用权限",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(File(path))
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("INSTALL_FAILED", error.message, null)
                        }
                    }
                    "canRequestInstallPackages" -> {
                        result.success(canRequestInstallPackages())
                    }
                    "openInstallPermissionSettings" -> {
                        openInstallPermissionSettings()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun canRequestInstallPackages(): Boolean =
        packageManager.canRequestPackageInstalls()

    private fun openInstallPermissionSettings() {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
        )
        try {
            startActivity(intent)
        } catch (e: Exception) {
            // 部分 ROM 不支持定向入口,退回应用信息页
            val fallback = Intent(Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS)
            startActivity(fallback)
        }
    }

    private fun installApk(apk: File) {
        require(apk.exists()) { "APK 文件不存在" }
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "${BuildConfig.APPLICATION_ID}.fileprovider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, apkMimeType)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
            return
        } catch (_: ActivityNotFoundException) {
            // 部分 ROM 不响应 ACTION_VIEW + package-archive，回落到标准安装器 action
        }
        val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            data = uri
            type = apkMimeType
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(installIntent)
        } catch (_: ActivityNotFoundException) {
            val message = "系统未找到可安装 APK 的应用，请手动打开已下载的 APK"
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
            // 回传给 Dart 侧（update_dialog）以文本形式展示
            throw ActivityNotFoundException(message)
        }
    }
}
