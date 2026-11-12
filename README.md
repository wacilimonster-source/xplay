# XPlay

> X/Twitter 媒体播放器，支持 TikTok 风格浏览

---

## 项目概要

XPlay 是一个用 Flutter 编写的 TikTok 风格 X/Twitter 客户端，专注于视频和图片内容的沉浸式浏览。本项目基于 [XFlow](https://github.com/Alchemist-Aloha/xflow) 修改，修复了媒体加载问题并进行了全面汉化。

### 核心功能

- **TikTok 式信息流**：上下滑动浏览媒体内容（视频/图片）
- **关注列表媒体聚合**：自动抓取关注用户的媒体内容
- **视频播放器**：基于 media-kit (libmpv) 的原生视频播放
- **下载管理**：离线下载和阅读
- **收藏功能**：通过 X API 收藏/取消收藏推文
- **搜索**：全文搜索推文内容
- **检查更新**：通过 GitHub 仓库自动检查新版本

### 技术栈

| 组件 | 技术 |
|------|------|
| 框架 | Flutter 3.44.9 / Dart 3.12.2 |
| 状态管理 | Riverpod |
| 视频播放 | media-kit (libmpv) |
| 数据库 | SQLite (sqflite) |
| WebView | webview_flutter |
| 网络 | http + 自定义 Twitter API 客户端 |
| 更新检查 | package_info_plus + GitHub API |

### 版本历史

| 版本 | 日期 | 更新内容 |
|------|------|----------|
| 0.01 | 2026-08-19 | 初始汉化版本，添加检查更新功能 |

---

## 构建说明

### 前置条件

- **Flutter SDK**：3.44.9+（Dart 3.12.2+）
- **Android SDK**：API 36，Build Tools 33-36
- **NDK**：28.2.13676358
- **Java**：OpenJDK 21（Android Studio JBR）
- **Gradle**：8.14（通过 wrapper 自动下载）

### 构建步骤

```bash
# 1. 进入项目目录
cd G:\game\新建文件夹\xplay

# 2. 如果首次构建，先安装依赖
flutter pub get

# 3. 构建 arm64 release APK
flutter build apk --release --target-platform android-arm64

# APK 输出位置：
# build/app/outputs/flutter-apk/app-release.apk
```

### 如果遇到 Gradle Lint 错误

在 `~/.gradle/init.d/` 下创建 `disable-lint-vital.gradle.kts`：

```kotlin
subprojects {
    afterEvaluate {
        tasks.matching { it.name.contains("lintVital") && it.name.contains("Release") }.configureEach {
            enabled = false
        }
    }
}
```

### 如果 media-kit JAR 下载超时

手动下载并放到缓存目录：

```bash
DEST="build/media_kit_libs_android_video/v1.1.7"
mkdir -p "$DEST"

for jar in default-arm64-v8a.jar default-armeabi-v7a.jar default-x86_64.jar default-x86.jar; do
  curl -L -o "$DEST/$jar" \
    "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/$jar"
done
```

### 签名

仓库内 `android/app/xplay-release.jks` 为固定 release 签名（`android/key.properties` 已 gitignore，本地构建时自行创建）。
CI 从 Secrets 读取密码并生成 `key.properties`；若配置了 `ANDROID_KEYSTORE_BASE64`，会用其覆盖仓库内的 `.jks`。
缺签名时 `android/app/build.gradle.kts` 回退到 debug 签名，**这类 APK 无法覆盖安装正式版**，发版请以 CI 产物为准。

---

## 发版（全程 GitHub Actions，本地无需 Flutter）

发版不再手工改版本、打 tag、改 `update.json`，只需在 GitHub 上点一次：

1. 仓库 → **Actions** → **Release** → **Run workflow**（分支选 `main`）
2. 两个输入都可留空：
   - `version` 留空 → 自动在 `pubspec.yaml` 当前版本上 patch +1（`0.1.33+33` → `0.1.34+34`）；也可填 `0.2.0` 或 `0.2.0+40`
   - `notes` 留空 → 自动用上个 tag 以来的 commit 标题生成更新说明；也可手填（支持多行）
   - `prerelease` 勾选 → 只发 Release，不写 `update.json`
3. 点 Run 后 CI 自动完成：

```
改 pubspec 版本 → 提交 main → 构建签名 arm64 APK → 打 tag v{版本}
→ 发 GitHub Release（资产 xplay-v{版本}.apk）→ 校验资产可访问
→ 回写 update.json 并提交 main
```

**需要的 Secrets**（Repository settings → Secrets and variables → Actions）：

| Secret | 必填 | 说明 |
|---|---|---|
| `KEYSTORE_PASSWORD` | 是 | keystore 密码 |
| `KEYSTORE_KEY_PASSWORD` | 是 | key 密码 |
| `KEYSTORE_KEY_ALIAS` | 是 | key 别名 |
| `ANDROID_KEYSTORE_BASE64` | 否 | 用 `base64 -w0 android/app/xplay-release.jks` 生成；不配则用仓库内的 .jks |

**兼容旧方式**：`git tag v0.1.34 && git push origin v0.1.34` 仍会触发同样的流程，只是要求 tag 与 `pubspec.yaml` 里的版本已经一致（不一致会直接失败并提示），版本号不会自动 +1。

**注意事项**

- 💡 `update.json` 走 `raw.githubusercontent.com`，提交后 CDN 有几分钟缓存；应用侧已带时间戳参数绕过，但刚发版后立刻检查更新仍可能拿到旧清单。
- ⚠️ 分析（`flutter analyze`）与测试（`flutter test`）目前是「提示不阻塞」：失败会在日志里标红但不拦发版。等测试稳定后可去掉 `continue-on-error` 改成硬门禁。
- ⚠️ 构建失败时版本号提交已经推上 main（可追溯），下次发版会继续 +1，不会重复占用 tag。

---

## 项目结构

```
xplay/
├── android/                    # Android 原生配置
├── assets/                     # 应用图标等资源
├── lib/
│   ├── core/
│   │   ├── client/
│   │   │   ├── query_id_resolver.dart    # 运行时 query ID 解析器
│   │   │   ├── twitter_client.dart       # Twitter API 客户端
│   │   │   ├── twitter_account.dart      # 账户管理和 HTTP 请求
│   │   │   ├── transaction_id_service.dart # 事务ID + WebView捕获
│   │   │   ├── discovery_engine.dart     # 内容发现和混合算法
│   │   │   └── x_api_constants.dart      # API 常量
│   │   ├── database/                     # SQLite 数据层
│   │   ├── models/                       # 数据模型
│   │   ├── services/                     # 服务层
│   │   │   └── update_service.dart       # 检查更新服务
│   │   └── utils/                        # 工具类
│   ├── features/
│   │   ├── auth/                         # 登录
│   │   ├── feed/                         # 信息流（TikTok式）
│   │   ├── player/                       # 视频播放器
│   │   ├── profile/                      # 用户资料
│   │   ├── settings/                     # 设置
│   │   └── subscriptions/               # 订阅管理
│   └── main.dart                         # 应用入口
├── web/
├── test/
├── pubspec.yaml
└── pubspec.lock
```

---

## 已知限制

- 事务ID生成器在部分设备上会失败（WebRTC/CSS 不可用），但不影响核心功能
- 首次启动需要等待 WebView 捕获序列完成（约10-15秒）才能正常加载媒体
- Query ID 可能再次过期，届时需要重新安装或更新 `query_id_resolver.dart` 中的备选 ID

---

## 许可证

本项目基于 XFlow 修改，原项目许可证请参阅上游仓库。
