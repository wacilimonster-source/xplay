# XPlay 全面代码评审报告

**评审时间：** 2026-08-20 18:xx  
**评审范围：** `lib/**`、`test/**`、`pubspec.yaml`、`analysis_options.yaml`、Android 构建与安装更新配置  
**评审方式：** 静态走读、调用链核对、历史修复对照、测试文件与当前源码一致性检查；并对本轮修改执行定向 Dart 分析、关键 Flutter 测试尝试和 `git diff --check`。  
**重要说明：** 本报告已同步本轮修复后的工作区状态，不直接沿用旧报告结论。当前源码改动尚未提交 Git；Flutter 命令在本环境仍无法输出可采信结果。

---

## 一、结论摘要

当前项目主体架构可用，上一轮明确的 S1/M2/G2 修复已落到源码中；本轮没有发现新的 P0/P1 崩溃级缺陷。但仍有以下值得处理的真实问题和验证风险：

| 编号 | 严重度 | 当前结论 | 主要影响 |
|---|---|---|---|
| R1 | 已修复 | **已确认** | 话题分页沿用首屏实际的 Trending/Latest 排序 |
| R2 | 已处理 | **按产品需求落地** | 用户详情页新增独立“过滤已看内容”开关，默认关闭；开启后过滤已看内容 |
| R3 | 已修复 | **已确认** | 主页/话题/用户页加入 `_poolUpdateQueued` 合并调度，避免同一微任务周期重复管理播放器池 |
| R4 | 已修复 | **已确认** | 后台同步保存最新设置/客户端，generation 使旧任务结果失效；设置变化期间会合并触发新同步 |
| R5 | 部分修复 | **语义仍需注意** | 后台同步与用户详情写入后触发图片缓存容量收敛；该限制仍只管理图片文件，不包含视频流和 SQLite 元数据 |
| R6 | 部分修复 | **下载链路已增强** | APK 同版本临时文件复用、下载互斥、响应体流超时和页面生命周期保护已加入；页面销毁时取消 HTTP 下载仍未实现 |
| R7 | 已修复 | **已确认** | TweetDetail/收藏/取消收藏均使用 query ID 候选路径，并对 404/GraphQL 错误体重试 |
| R8 | 已修复 | **已确认** | 测试包名、mock 签名和 query ID 文档测试已同步当前生产 API |
| R9 | 低 | **验证阻塞** | 定向 Dart 分析已通过；Flutter analyze/test 在本环境仍无输出并返回 1，尚未获得自动化测试通过证据 |

> 其中 R1/R2/R7 是功能正确性问题；R3/R4/R5/R6 是边界、生命周期或语义一致性问题；R8 是测试代码与生产代码漂移；R9 是验证结论限制，不是产品 bug 本身。

---

## 二、确认存在的问题

### R1：话题流首屏排序与分页排序不一致（已修复）

**严重度：中**  
**状态：已修复并完成定向静态分析**  
**定位：** `lib/features/feed/hashtag_provider.dart`

话题流首屏请求按当前设置先调用：

```dart
sort: FeedSort.trending
```

如果首屏为空，再降级为 `FeedSort.latest`；最终仍为空时，使用普通话题查询。首屏实际采用的查询保存在 `_activeQuery`，但 `fetchMore()` 分页请求固定写成：

```dart
sort: FeedSort.latest
```

当前实现新增 `_activeSort`，首屏按 Trending 成功或降级到 Latest 时同步记录；`fetchMore()` 使用该状态发起分页请求。因此该问题已修复。

---

### R2：用户详情页已看内容过滤策略已按产品需求拆分

**状态：已处理**  
**定位：** `lib/features/settings/settings_provider.dart`、`lib/features/profile/profile_provider.dart`、`lib/features/profile/user_details_screen.dart`、`lib/features/profile/user_media_feed_screen.dart`

用户详情页现在使用独立设置 `userDetailAvoidWatchedContent`，持久化键同名，默认值为 `false`。因此默认行为是不过滤已看内容，不再隐式复用主页的 `avoidWatchedContent`。

当用户在用户详情页点击过滤图标，或从“设置 → 用户详情页”打开开关后，用户详情页的缓存首屏、刷新合并和加载更多都会读取 `watched_media` 标识，并通过 `Repository.filterUnwatched()` 同时按推文 ID 与 `mediaKey` 过滤。切换开关会使当前用户详情 provider 失效并重新加载；主页和话题页的全局设置不受影响。

---

### R3：多个页面在 build/data 阶段反复调度 `_managePool`（已修复）

**严重度：中**  
**状态：已修复并完成定向静态分析**  
**定位：**
- `lib/features/feed/hashtag_feed_screen.dart`
- `lib/features/profile/user_media_feed_screen.dart`
- `lib/features/feed/tiktok_feed_screen.dart`

主页已将 build 阶段管理推迟到 `Future.microtask`，但话题页和用户页仍在 `when(data:)` 中直接调用 `_managePool()`；这两个页面的 `_managePool()` 自身又会继续创建 microtask。每次 provider 状态变化或 build 重建，都会再次排队。

用户页、话题页和主页现在均通过 `_poolUpdateQueued` 合并同一微任务周期内的调度，重复 build/监听只会保留一次播放器池更新。因此该问题已修复。

---

### R4：BackgroundSync 任务使用旧设置快照（已修复）

**严重度：中**  
**状态：已修复并完成定向静态分析**  
**定位：** `lib/core/client/background_sync.dart`、`lib/main.dart`

`BackgroundSync.start(client, settings)` 将调用时的 `SettingsState` 捕获到：

- 立即 `_sync(client, settings)` 一次；
- `Timer.periodic(..., (_) => _sync(client, settings))` 后续一直使用同一个旧 settings；
- 延迟 1 分钟的 `pruneCachedMedia(threshold: settings.pruneThreshold)` 也使用旧阈值。

`main.dart` 只在 `syncInterval`、`syncBatchSize`、`pruneThreshold` 变化时调用 `restart`。其他会影响后台同步的设置，如 `loadBatchSize`、`cooldownDuration`、过滤条件、订阅策略、`apiTimeoutSeconds` 等变化时，后台同步仍会继续使用旧值。

当前实现保存最新 client/settings，Timer 每次读取最新快照；`_generation` 使设置变化后的旧任务无法提交结果，并用 `_syncRequested` 合并触发一次最新配置同步。`syncInterval` 变化会重建 Timer，其他设置变化会更新快照和清理任务。因此该问题已修复；网络 Future 本身仍不主动取消，但其结果不会继续写入。

---

### R5：缓存限制只覆盖图片文件，数据库元数据仍按另一套规则清理

**严重度：低**  
**定位：** `lib/core/utils/media_cache_manager.dart:11-21,61-110`、`lib/features/feed/feed_provider.dart:234-240`、`lib/core/database/repository.dart:622-649`

本轮确认 G2 的图片缓存设置已经接线：后台刷新每累计 5 次 API 元数据写入后，会异步调用 `enforceLimit(settings.mediaCacheSizeMB)`。因此旧报告中“设置完全未接线”的结论已不再成立。

但目前存在两个语义和实现边界：

1. `CustomMediaCacheManager` 只管理 `CachedNetworkImage` 的图片文件；视频仍是流式播放，不受该容量设置影响，这本身可以是设计选择，但 UI 文案“本地媒体缓存”容易让用户理解为所有媒体。
2. 后台同步和用户详情页在 `cached_media` 写入后已主动调用 `enforceLimit`；主页仍使用每 5 次写入触发一次的节流。该限制仍只管理图片文件，不管理 SQLite 元数据，且话题页当前没有独立的图片容量触发点。

**当前结论：** 已完成主要路径补齐，但建议后续把容量收敛下沉到统一缓存写入服务，并明确 UI 文案为“图片缓存”。

---

### R6：自动更新异步流程存在生命周期竞态（部分修复）

**严重度：低**  
**状态：下载链路已增强；取消下载仍未实现**  
**定位：** `lib/features/settings/update_dialog.dart`、`lib/core/services/update_service.dart`

`UpdateService` 现在按版本复用有效临时 APK，下载期间使用互斥状态，响应体读取也有超时；`UpdateDialog` 在异步权限检查和页面状态更新前增加 `mounted` 保护，权限返回不会因重复生命周期回调而并发下载。

剩余边界是：`_downloadAndInstall()` 进行长时间下载期间如果页面离开，`UpdateService.downloadApk()` 仍继续执行；页面销毁时不会取消底层 HTTP 请求，只能放弃 UI 更新。这属于低优先级后续增强，不影响已下载文件复用和当前安装流程。

---

### R7：部分 GraphQL 操作仍没有 query ID 候选重试（已修复）

**严重度：低**  
**状态：已修复并完成定向静态分析**  
**定位：** `lib/core/client/twitter_client.dart`

`SearchTimeline`、`UserByScreenName`、`UserTweets` 已使用 `candidatePaths()`，但 `fetchTweetDetail()` 和 `favoriteTweet()` / `unfavoriteTweet()` 使用单个 `pathFor()`：

```dart
QueryIdResolver.pathFor('TweetDetail')
QueryIdResolver.pathFor('FavoriteTweet')
QueryIdResolver.pathFor('UnfavoriteTweet')
```

当前实现已统一使用 `QueryIdResolver.candidatePaths()`；详情接口在 404 或 GraphQL 错误体时继续尝试，收藏/取消收藏的 POST body 也从当前候选 path 提取匹配的 `queryId`。因此该问题已修复。

---

## 三、测试与构建审查结果

### R8：测试代码与当前生产代码漂移（已修复）

**严重度：低（但会阻塞 CI）**  
**状态：测试源码已同步；本环境 Flutter 执行仍阻塞**  
**定位：** `test/**`

测试已删除对 `TwitterClient.graphqlSearchTimelineUriPath` 的依赖，改测 `QueryIdResolver.candidatePaths('SearchTimeline')`；`FeedNotifier.fetchMore()` mock 已移除过时的 `retryCount` 参数；全局旧包名引用检查为 0。测试源码漂移问题已修复，仍需在可运行的 Flutter 环境中执行套件确认。

### R9：自动化命令本轮无法完成

本轮结果：

- 内置 Dart 对关键源码执行 `analyze --format=machine`：**通过**；初始仅有的 `withOpacity` 弃用提示已清理。
- 通过 Flutter wrapper 执行定向 `flutter test`：进程无 stdout/stderr，返回码 1。
- 通过 Flutter wrapper 执行全量 `flutter analyze --no-pub`：进程无 stdout/stderr，返回码 1。
- `git diff --check`：通过；仅有 Git 关于 LF/CRLF 的提示。

因此本报告不能宣称 Flutter 测试或全量分析通过；R9 仍是验证环境/命令执行问题，不等同于源码错误。

---

## 四、已确认修复或不计为 bug 的项目

以下项目已经在当前代码中看到修复证据，或经前序复核属于设计选择，本轮不重复列为开放缺陷：

- S1 的首屏空结果已有 `fetchSubscribedMedia` 的 HomeTimeline fallback，且当前代码对有无 cursor 都尝试降级；但“捕获完成后再更新 ID”的全链路真机效果仍未通过本轮静态代码证明。
- M2 的 `fetchMore` 已补充 `applyUnseenSubscriptionBoost`，并保留尾部 `applySaturation`；不再是完全只在刷新生效。是否与完整 refresh 的 `interleave` 语义完全一致，仍属于一致性增强而非本轮确认的崩溃 bug。
- G2 已在 Feed 后台刷新每 5 次元数据写入后调用 `enforceLimit`，不再是零引用摆设。
- txId 脚本页面重载后的重装问题已通过 `reinstallScriptOnPageLoaded()` 处理。
- B1–B12 已有历史复测证据，当前主要路径已修复。
- 主页 autoplay、断点续播、播放器池硬上限、订阅主键统一、避免已看内容的主页/话题路径已接线。
- M1/M3/M4/L1/L2/L5 按用户确认属于取数策略、限流策略、流式视频设计、回调复用、未承诺增强或外部必需依赖，不作为本轮 bug。

---

## 五、当前剩余工作与建议

1. **R9：恢复 Flutter 命令可执行性**，在本机 Flutter SDK/依赖环境正常后重新运行 `flutter analyze`、定向测试和全量测试。
2. **R6：更新下载取消机制**，为 `http.Client` 增加可取消句柄，并在 dialog `dispose` 时失效或取消任务。
3. **R5：统一图片缓存容量收敛入口**，并将 UI 文案明确为“图片缓存”；SQLite 元数据继续由 `pruneCachedMedia` 单独管理。
4. 对 R1–R8 做真机回归：话题分页、播放器池快速滑动、设置中途变化、权限页返回、query ID 轮换和离线/弱网下载。

---

## 六、评审边界

- 本轮已修改源码、测试和本报告；当前均未提交 Git。
- 未进行真实 X 账号网络请求、真机播放、后台切换、安装更新和长时间压力测试。
- 定向 Dart 分析通过；Flutter analyze/test 在本环境无输出并返回 1，不能视为通过或失败。
- R1/R2/R3/R4/R7/R8 已根据源码修复；R5 为部分修复，R6 为部分修复；R9 仍是自动化验证阻塞。
- 上线前仍建议用模拟 API 响应、真机生命周期、弱网下载和分页场景进行回归。
