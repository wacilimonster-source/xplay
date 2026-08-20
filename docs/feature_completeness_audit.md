# XPlay 全功能完整性审计

> 审计时间：2026-08-20 ｜ 范围：XPlay（X/Twitter 视频客户端）全部 37 个 Dart 源文件
> 方法：4 路并行静态探查（设置接线 / 取数策略 / 订阅·资料·登录·更新·后台 / 播放器与播放体验）+ 关键发现人工复核

---

## 〇、重要前提（已复核）

**「避免已看内容」缺口已被另一 agent 按 `docs/avoid_watched_content_plan.md` 落地并验证正确：**
- `repository.dart` 新增独立表 `watched_media` + `markWatched` / `getWatchedIdentifiers` / `filterUnwatched`（:531-568）。
- `feed_provider.dart` 的 `_refreshInBackground`（:214）和 `fetchMore`（:321/372）对 fresh/local 都按 `watched` 过滤。
- `hashtag_provider.dart` 的 `build()`（:85）和 `fetchMore()`（:124）对 `response.tweets` 过滤。
- `tiktok_feed_screen.dart:56`、`hashtag_feed_screen.dart:180` 滑到新页时写 `markWatched`。

→ **该项（之前的部分实现缺口）现已闭合，不再列入问题清单。**

---

## 一、完整实现、无缺口的功能

| 功能 | 说明 |
|------|------|
| 登录/认证核心流程 | 已知 3 个老问题（硬编码 query id / ct0 unguarded / 空 restId 写账户）已修复 |
| 订阅导入→列表→删除→信息流消费 | 整条链路打通（导入写库、列表展示、删除生效、fetchSubscribedMedia 真实消费） |
| 用户资料页 + 用户媒体流 | 缓存优先 + 后台拉新 + 分页预热，完整 |
| 更新检查 + 下载安装 | 真发请求、解析、弹窗、流式下载、MethodChannel 安装，完整 |
| 后台同步 | `Timer.periodic(Duration(minutes: syncInterval))` 真正读取设置；无订阅时 no-op（设计如此） |
| 发现引擎 | `interleave` / `applyUnseenSubscriptionBoost` / `applySaturation` 三件套实现完整 |
| 取数策略（videomixer/algorithmic/chronological/subscribed） | 三个显式分支 + 订阅搜索分支均实现，11 个参数无摆设 |
| 过滤器（video/image/text） | SQL 本地候选 + 搜索 API 均生效（时间线端点为客户端后置 `_applyFilters`） |
| 播放完行为 / 重试 / 错误自动跳过 | `videoEndAction`、`playbackRetryLimit`、`autoSkipDelaySeconds` 均接线 |
| `isListView` | 个人主页网格/列表切换生效（注：非 PageView 沉浸播放，属设计） |
| `cooldownDuration` 等其余 30+ 设置项 | 均被真实读取并产生行为，持久化无漏读/漏写 |

---

## 二、存在缺口 / 部分实现的功能（按严重度）

### 🔴 高严重度（设置项"有 UI、有持久化、但行为未真正生效"——与避免已看缺口同类）

**G1. `autoplay`（自动播放）形同虚设**
- 证据：`settings_provider.dart:20,273,500-501` 定义+持久化；`settings_screen.dart:346-347` 仅显示开关。全 `lib` 无任何播放代码读取 `settings.autoplay`。
- 行为：`media_container.dart:195-199` 仅用 `widget.isVisible` 决定 `play()/pause()`，从不读 autoplay。
- 影响：用户关掉"自动播放"后，视频随页面可见仍照播，开关纯摆设。

**G2. `mediaCacheSizeMB`（缓存上限）形同虚设**
- 证据：`settings_provider.dart:22,224,317-318` 定义+持久化；`settings_screen.dart:585-592` 显示"已用 X MB / 限制 Y MB"滑块。但 `media_cache_manager.dart:16` 硬编码 `maxNrOfCacheObjects: 200`、`stalePeriod: 7 days`，全文件零引用 `mediaCacheSizeMB`。
- 影响：把上限设成 500 或 5000，磁盘/内存实际占用不变；"限制 Y MB"是虚假承诺。且视频本就不走缓存（见 M4）。

### 🟠 中严重度

**M1. `popular` / `trending` 取数策略伪实现（语义误导）**
- 证据：`settings_screen.dart:308/310` 把两枚举标成"订阅：热门/趋势"，下拉框 `:334` 暴露全部 6 个值；但 `feed_provider.dart:184-211` 只显式处理 videomixer/algorithmic/chronological，其余全落 `else → fetchSubscribedMedia(sort: settings.fetchStrategy)`。
- 影响：`popular`/`trending` 不是"全站热门/趋势发现"，而是"订阅账号搜索 + min_faves/Top 微调"。UI 暗示全局发现，实际行为不符；订阅为空且 `strictSubscriptionsOnly` 时直接返回空。

**M2. 发现算法（freshMixRatio / unseenSubscriptionBoost / unseenBoostLookahead）仅"刷新/冷启动"生效**
- 证据：`_runDiscoveryPipeline`（`feed_provider.dart:43`）只在 `_refreshInBackground`（:251）调用；`fetchMore`（:272-438）只做 `shuffle` + `applySaturation`，**不进发现管线**。
- 影响：调整这三个设置，对下滑"加载更多"追加的内容无效（追加内容是随机 shuffle，不按混合比/未看加权编排）。

**M3. `cooldownMinutes` 不是真正的"冷却闸门"**
- 证据：它只在 `fetchFollowing`/`fetchTrendingMedia` 遇 429 时作限流回退（`twitter_client.dart:71-73,372,538`）；分块轮换延迟是硬编码 `300ms`（`feed_provider.dart:387`），非 `cooldownDuration` 驱动。
- 影响：设置项语义（降低取数频率）未满足，仅限流时有意义。

**M4. 视频完全不读本地缓存（无离线/秒开）**
- 证据：图片走 `media_cache_manager`（CachedNetworkImage）；视频走 `Media(url)` 直接 HTTP 流式（`player_pool_provider.dart:40`、`media_container.dart:128`），不读取任何本地缓存。
- 影响：无离线播放、重复播放重复下载、流量与卡顿。

**M5. 播放器池无硬上限（内存风险）**
- 证据：`player_pool_provider.dart:30-43` `warmup()` 直接塞进 state，无 MAX 常量；靠每个调用方 `cleanupExcept` 兜底。池为全局单例（:58-61），导航到非 feed 页（如设置）时不触发 cleanup，实例残留至返回。
- 影响：调用方若漏 cleanup 则实例只增不减；跨页导航累积内存。

**M6. 进度续播（断点续播）缺失**
- 证据：`media_container.dart` 仅 `seek(Duration.zero)` 用于 replay；无任何 position 持久化/恢复。
- 影响：退出再进入同一条视频，从头播放。

**M7. 订阅主键约定不一致 → 重复行**
- 证据：`subscriptions` 表 `id` 为 PRIMARY KEY（`repository.dart`）；`twitter_client.dart:422` 写 `id: restId`（数字），`user_details_screen.dart:443` 与 `tweet_text_overlay.dart:227` 写 `id: screenName`（无 @）。
- 影响：同一用户"手动订阅"与"导入关注"会因主键不同写两行，列表重复展示、信息流重复拼 `from:`、删除只能按 `screen_name` 清其一。

### 🟡 低严重度

**L1. 自然播完也走 `autoSkipDelaySeconds` 延迟**
- `videoEndAction.playNext` 复用 `onPlaybackError`（`media_container.dart:104-105`），故播完切换也等 `autoSkipDelaySeconds` 秒，与"错误才延迟"预期略有偏差。

**L2. 双击缩放 / 亮度调节未实现**
- grep `scale/zoom/brightness` 仅命中主题 `Brightness.dark`；无运行时缩放手势、无屏幕亮度/音量调节（体验增强缺失）。

**L3. 刷新路径缺参不一致**
- `_refreshInBackground` 的 `fetchSubscribedMedia`（`feed_provider.dart:200-210`）未传 `maxQueryLength`/`timeoutSeconds`，绕过了用户配置；`fetchMore`（:348-361）传了。两路径行为不一致。

**L4. 浮层手动订阅写入字段不全**
- `tweet_text_overlay.dart:226-229` 只设 `id`/`screenName`，`name`/`profileImageUrl` 为 null，列表该项显示空名称。

**L5. 认证头外部依赖脆弱（中危，归 auth）**
- `twitter_account.dart:137-167` txId 强依赖隐藏 WebView 实时捕获 + 第三方兜底站；`x-xp-forwarded-for` 依赖 `guest_id` cookie（`twitter_account.dart:200-214`）。游客态/离线/旧账户缺这些头时，部分请求可能被 X 拒绝。

---

## 三、修复优先级建议

| 优先级 | 项 | 说明 |
|--------|-----|------|
| P0 | G1 autoplay、G2 mediaCacheSizeMB | 纯"设置未接线"，影响用户信任，改动小 |
| P1 | M7 订阅主键统一 | 数据正确性，避免重复与信息流污染 |
| P1 | M1 popular/trending 语义 | 要么加专属分支，要么 UI 改名避免误导 |
| P1 | M4 视频缓存复用 | 体验与流量，改动中等 |
| P2 | M2 发现算法覆盖 fetchMore | 让设置对翻页也生效 |
| P2 | M5 播放器池硬上限 | 内存安全 |
| P2 | M6 断点续播 | 体验增强 |
| P3 | M3/L1/L2/L3/L4/L5 | 语义修正、体验增强、一致性 |

> 说明：本报告所有"缺口"均指**功能层面未达设置/UI 承诺**，非崩溃性 bug。完整实现的功能已单独列出，项目主体功能可用。
