# XPlay 缺陷汇总（截至 2026-08-20 17:20，已对照当前代码核实）

> 本文档汇总本轮代码评审与运行日志分析所发现的问题。所有条目均在 2026-08-20 17:xx
> 对照 `lib/**` 当前源码逐条重新核实，**不采信任何旧 md 计划文档的结论**。
> 状态分三类：🔴 开放（确为缺陷）、🟡 潜伏（当前被 X 行为掩盖，一旦收紧即爆发）、✅ 已修复/非问题。

---

## 一、总览

| 编号 | 问题 | 严重度 | 状态 |
|------|------|--------|------|
| S1 | SearchTimeline 全部 query ID 集体过期（404），首页订阅流失效 | 🔴 高 | 开放 |
| G2 | `mediaCacheSizeMB` 仅手动触发，刷流时磁盘缓存不自动收敛 | 🔴 高 | 开放 |
| M2 | 发现算法管线只在刷新跑，滚动翻页纯追加（内容新鲜度不一致） | 🟡 中 | 开放 |
| Q1 | `media_container` 点赞 `firstWhere` 无 `orElse`，可能抛 `StateError` | 🟡 低 | 开放 |
| Q2 | `PlayerInstance.dispose` 未显式 dispose `VideoController`（native 泄漏） | 🟡 低 | 开放 |
| Q3 | 播放器池 warmup LRU 按插入序淘汰，可能回收在用实例 | 🟡 低 | 开放 |
| L5 | 本地+远程 txId 双双失败则**直接省略 txId 头**继续发请求 | 🟡 潜伏 | 开放 |
| xpff | `x-xp-forwarded-for` 单点依赖 `guest_id` cookie | 🟡 潜伏 | 开放 |
| T1 | txId 生成脚本"装一次就废" | — | ✅ 已修复 |
| B1–B12 | 初版评审发现的 12 项 | — | ✅ 已修复（12/12） |
| M1/M3/M4/L1/L2 | 原被标"缺口"，经核实为设计选择 | — | ✅ 非问题 |

---

## 二、🔴 开放缺陷（确为 bug）

### S1. SearchTimeline 全部 query ID 集体过期（404）—— 首页订阅流失效

**严重度：高**　**根因：X 周期性轮换 GraphQL query ID + 冷启动捕获晚于首屏请求**

**现象（来自 2026-08-20 16:56:58 冷启动日志）**
`fetchTrendingMedia` 用 `SearchTimeline` 取订阅流，逐一带入内置 + 6 个备选 ID，
全部返回 HTTP 404，导致首页订阅流首屏取不到内容。对照同次日志 `UserByScreenName`
(`Gb-d6r0vxPOADdG62OEBpQ`) 与 `UserTweets` (`eoJ5zbv51Z_KVl81v9PmLQ`) 均 200，
证明**仅 SearchTimeline 这组 ID 被轮换失效**，与 `QueryIdResolver` 注释
"X rotates these IDs periodically" 吻合。

**代码定位**
- `lib/core/client/query_id_resolver.dart:29-40` —— `_bundled['SearchTimeline'] = 'GcXk9vN_d1jUfHNqLacXQA'`
- `lib/core/client/query_id_resolver.dart:100-107` —— `_alternates['SearchTimeline']` 的 6 个 ID
  正是日志里 404 的那组（`gkjsKepM6gl_HmFWoWKfgg` / `GcXk9vN_d1jUfHNqLacXQA` /
  `lZ0GCEojmtQfiUQa5oJSEw` / `XN_HccZ9SU-miQVvwTAlFQ` / `6AAys3t42mosm_yTI_QENg` /
  `BGd0T_j7oVwlW5U79tO_0A`）。
- `lib/core/client/query_id_resolver.dart:159-166` `candidatePaths()` —— 404 换候选 ID 重试设计存在，
  但**所有候选都已过期**，重试只是把 6 个 404 全跑一遍。
- `lib/core/client/twitter_client.dart:765` —— `fetchSubscribedMedia` 兜底逻辑：
  `if (response.tweets.isEmpty && cursor == null)` 才走 `HomeTimeline` 降级
  （且返回的是算法流而非订阅流）。**翻页（`cursor != null`）无任何兜底，直接空**。
- `lib/core/client/transaction_id_service.dart:153-186` —— 运行时捕获序列
  （`search?q=test&f=live` 应触发 SearchTimeline 捕获）在 `onPageFinished` 后启动，
  **日志显示 WebView ready 于 16:57:00，而订阅请求 16:56:59 已发出 → 首屏用陈旧 bundled ID**。

**影响**：用户冷启动后首页可能空白或降级为算法流；若捕获一直没拿到有效 SearchTimeline ID，
刷新后依然拉不到订阅内容。这是当前最影响可用性的问题。

**修复建议**（按优先级）
1. **冷启动时序**：把首屏取流延迟到 WebView `markReady(true)` + 捕获序列完成之后，
   或首屏先返回 `HomeTimeline` 兜底、捕获到有效 ID 后后台替换订阅流。
2. **翻页兜底**：`twitter_client.dart:765` 的兜底去掉 `cursor == null` 限制
   （或翻页空时也允许降级一次），避免翻页直接空。
3. **ID 刷新**：在 `QueryIdResolver` 内置一组**当前有效**的 SearchTimeline ID，
   或把 `remoteUrl` 指向一份可热更新的 ID 清单（注释已预留该能力，见 `:45-47` / `:69-94`）。
4. **捕获覆盖验证**：确认捕获序列确实能拿到 SearchTimeline 的当季 ID（日志未出现
   `Captured N live query IDs` 包含 SearchTimeline，需确认）。

---

### G2. `mediaCacheSizeMB` 仅手动触发，刷流时磁盘缓存不自动收敛

**严重度：高**　**根因：设置项已接线，但只在"进设置页 / 拖滑块"时执行**

**代码定位**
- `lib/features/settings/settings_screen.dart:32-42` —— `_loadStats()` 在 `initState` 中调用
  `CustomMediaCacheManager.enforceLimit(mediaCacheSizeMB)`。
- `lib/features/settings/settings_screen.dart:610-614` —— 滑块 `onChanged` 中调用
  `CustomMediaCacheManager.enforceLimit(v.round())`。
- 经全仓 grep，**除上述两处外无任何代码在刷流/写入缓存后调用 `enforceLimit`**。

**说明**：早期曾误判为"零引用摆设"，已纠正——**上限逻辑是生效的**，只是触发点只有
手动进入设置页或拖动滑块。用户正常刷流（首页/话题/列表写入 `CustomMediaCacheManager`）
从不触发 `enforceLimit`，磁盘缓存会持续累积直到用户某次进设置页才被清理。

**影响**：长期刷流后图片缓存无限增长，占用设备存储；设置项承诺的"限制 X MB"对用户日常使用形同虚设。

**修复建议**：在缓存写入路径（如 `Repository.insertCachedMedia` 之后，或 `feed_provider`
后台刷新成功后）**周期性**调用 `CustomMediaCacheManager.enforceLimit(mediaCacheSizeMB)`
（如每 N 次写入 / 每次刷新后异步触发一次），使上限真正自动生效。

---

### M2. 发现算法管线只在刷新跑，滚动翻页纯追加

**严重度：中**　**根因：`_runDiscoveryPipeline` 仅被 `_refreshInBackground` 调用**

**代码定位**
- `lib/features/feed/feed_provider.dart:43-114` —— `_runDiscoveryPipeline`（interleave /
  unseenSubscriptionBoost / applySaturation 全量重排）。
- `lib/features/feed/feed_provider.dart:253` —— **唯一调用点**在 `_refreshInBackground`（刷新/后台刷新）。
- `lib/features/feed/feed_provider.dart:279-447` —— `fetchMore`（滚动翻页）：
  仅做"尾巴去重 + `allNewTweets.shuffle()` + 末尾 `applySaturation`"
  （`:426`），**不进 `_runDiscoveryPipeline`**，因此没有 unseen-boost、没有与本地缓存
  interleave、没有首屏保护逻辑。

**影响**：刷新得到的是经过多样性/未看优先重排的高质量流；而用户往下刷时，新追加内容
只是简单洗牌拼接到尾部，体验与刷新不一致（重复率、多样性劣于首屏）。

**修复建议**：将 `_runDiscoveryPipeline` 抽象为可复用方法，`fetchMore` 在拼合新尾巴时
也对"新内容 + 当前尾部窗口"跑一次完整管线（至少包含 saturation + unseen-boost），
使翻页与刷新行为一致。用户此前已决定要修此项。

---

## 三、🟡 开放（稳健性 / 低危）

### Q1. 点赞 `firstWhere` 无 `orElse`

**代码定位**：`lib/features/player/widgets/media_container.dart:399`
```dart
s.value?.tweets
    .firstWhere((t) => t.id == widget.tweet.id)  // 无 orElse
    .isLiked ?? false
```
`?? false` 只兜底 `.isLiked` 为 null 的情况，**无法捕获 `firstWhere` 找不到元素抛出的
`StateError`**。当 widget 引用的 tweet id 已从列表中移除（刷新重排后旧 widget 仍在树中）
时，`Consumer` 重建会抛异常。

**影响**：低——主 feed 中 tweet 一般都在列表里，正常路径不抛；仅异常/竞态路径有风险。
**建议**：加 `.firstWhere(..., orElse: () => /* 默认未点赞的占位 */)` 或在 builder 内先判空。

### Q2. `PlayerInstance.dispose` 未显式 dispose `VideoController`

**代码定位**：`lib/features/player/player_pool_provider.dart:11-16`
```dart
void dispose() {
  // Media-kit documentation says VideoController might not need explicit dispose ...
  player.dispose();   // controller 未 dispose
}
```
`PlayerInstance` 持有 `player` 与 `controller`，但 dispose 只释放 `player`。
注释自认 "might not need explicit dispose"，但仍属 native 资源（纹理/Surface）潜在泄漏。

**影响**：低——长会话 / 频繁导航场景下轻微 native 资源累积；`player.dispose` 多数情况下会级联释放。
**建议**：显式 `controller.dispose()`（确认 media_kit 版本支持后），或在注释中明确"已确认可省略"的依据。

### Q3. 播放器池 warmup 按插入序淘汰，可能回收在用实例

**代码定位**：`lib/features/player/player_pool_provider.dart:47-52`
```dart
if (newState.length > maxPoolSize) {
  final oldestId = newState.keys.first;   // 插入序最旧
  newState[oldestId]?.dispose();
  ...
}
```
`Map` 保持插入序，淘汰的是"最早 warmup"的实例，而非"最久未使用"。若某播放中的视频恰是最早
入池的（如滚动回看早期条目），理论上会被回收导致播放中断。

**影响**：低——`media_container` 在可见时会重新 `warmup`（自恢复），属瞬时中断。
**建议**：改为基于"最后访问时间"的 LRU 淘汰（记录 `lastUsed` 时间戳，淘汰最久未访问）。

---

## 四、🟡 潜伏风险（当前被 X 行为掩盖）

### L5. 本地 + 远程 txId 双双失败则直接省略 txId 头

**代码定位**：`lib/core/client/twitter_account.dart:148-190`
- 先尝试本地生成（WebView 注入 JS）→ 失败则尝试远程
  `x-client-transaction-id-generator.xyz`（`:159-178`，带 `_txIdRemoteCooldownUntil` 冷却）。
- 若本地 `null` **且** 处于远程冷却期，则 `txIdStatus = 'missing:remote-cooldown'`
  （`:184-185`），**最终不写入 `x-client-transaction-id` 头**。

**现状**：日志已证实——即便 `txId=missing:*`，`UserByScreenName` / `UserTweets` 仍 200，
说明 **X 当前不强制 txId**。该路径现在无害。

**风险**：一旦 X 强制要求 `x-client-transaction-id`，双重失败即导致**所有取流请求 401/403**，
全 app 取不到内容。这是单点脆弱性（属外部依赖本质，非代码缺陷，但值得在文档中标注）。

**建议**：保留"裸奔"作为兜底（保证不崩），但监控 txId 缺失率；必要时接入更稳定的
本地 txId 生成（见下方 T1 修复）以降低远程依赖。

### xpff 单点依赖 `guest_id`

**代码定位**：`lib/core/client/twitter_account.dart:137-146`
`x-xp-forwarded-for` 的 AES 密钥派生自 `guest_id` cookie（SearchTimeline/Followers 必需）。
登录已捕获 `guest_id` 故当前 OK，但是单点依赖，cookie 失效/缺失即该头为 null。
**建议**：在 `guest_id` 缺失时有明确降级日志与告警。

---

## 五、✅ 已修复 / 非问题（核实后移除，避免重复处理）

### T1. txId 生成脚本"装一次就废" —— 已修复

**原判定（早前）**：`transaction_id_service.dart` 中 txId 脚本仅 `_ensureScriptInstalled`
注入且受 `_scriptInstalled` 门控；WebView 每次 `onPageFinished` 只重装 queryId 捕获脚本、
不清空 `_scriptInstalled`，导致页面重载后本地 txId 永久 null。

**当前代码核实**：已修复。新增 `reinstallScriptOnPageLoaded()`（`:39-46`）并在
`onPageFinished`（`:134-135`）调用，注释明确 "txId generator must be re-installed too,
or the local txId channel dies silently"。脚本卡死问题已不存在。

### B1–B12（初版 `bug_review_report.md` 的 12 项）—— 已修复 12/12

见 `docs/bug_fix_retest_2026-08-20.md`：逐项对照当前源码确认 B1–B12 全部修复完成，
且修复均在"恢复应有行为/扩大成功面/防崩溃/清理死代码"范畴，无回归。

### 原标"缺口"但核实为设计选择（非 bug，不再处理）

- **M1** `popular`/`trending` 取数：实际 `min_faves`/`product:Top` 真实传入 X 请求并生效，属排序微调。
- **M3** `cooldownMinutes`：当前实现是限流惩罚（429 回退），用户判定改为"平时也节流反而变慢"，不修。
- **M4** 视频不读本地缓存：`Media(url)` 直连流式播放是标准设计（YouTube/TikTok 同理），非缺陷。
- **L1** `playNext` 复用 `autoSkipDelay`：设计正确（三处 feed 均接"翻下一页"回调），注释明示。
- **L2** 双击缩放/亮度：设置页本无对应开关，属未做的增强，非功能损坏。

---

## 六、修复优先级建议

1. **P0 — S1（SearchTimeline 404）**：直接阻断首页，先解决冷启动时序 + 翻页兜底。
2. **P1 — G2（缓存自动收敛）**：改动小、收益明确，加一行周期性 `enforceLimit` 即可。
3. **P1 — M2（翻页进管线）**：用户已决定要修，使翻页与刷新一致。
4. **P2 — Q1/Q2/Q3**：稳健性小补丁，低危可排期。
5. **监控 — L5 / xpff**：当前无害，但应埋点监控 txId 缺失率与 `guest_id` 可用性。

---

*附：本文所有结论均在 2026-08-20 17:xx 对照 `G:\game\nw\xplay\lib/**` 当前源码核实，
区别于历史 md 计划文档。早期两处误判（M1/M4 把设计选择当缺陷）已纠正，T1 已确认在代码中修复。*
