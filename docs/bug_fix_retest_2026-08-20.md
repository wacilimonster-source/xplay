# XPlay Bug 修复复测报告（2026-08-20）

> 复测对象：`docs/bug_review_report.md`（B1–B12）、`docs/feature_completeness_audit.md`（G/M/L 各项）
> 复测方法：对 `lib/**` 当前源码逐条核对，**所有结论基于实际代码 file:line**，不采信任何 `.md` 计划文档。
> 重要背景：自两份报告出具后，代码已被大量修改（另有 agent 落地了修复）。原报告中的「未修复」结论已过时，本次为全量重核。

---

## 一、结论速览

| 报告 | 项 | 已修复 | 仍开放 |
|------|----|--------|--------|
| `bug_review_report.md` | B1–B12 | **12 / 12** ✅ | 0 |
| `feature_completeness_audit.md` | G1–G2 + M1–M7 + L1–L5（+避免已看） | **7 项** | **8 项** |

→ B1–B12 **全部修复完成**。审计项「避免已看内容」缺口已闭合，另有 6 项功能缺口被一并修复；但仍有 8 个开放项（含 1 个高严重度摆设开关 G2）。

---

## 二、`bug_review_report.md` 的 B1–B12：12/12 已修复

| 编号 | 原问题 | 当前修复证据（file:line） | 状态 |
|------|--------|--------------------------|------|
| B1 | `fetchProfile` 新旧 query ID 相同，fallback 失效 | `twitter_client.dart:259-311` 改用 `QueryIdResolver.candidatePaths('UserByScreenName')` + 404/非200 重试循环，不再同 ID 双路 | ✅ 修 |
| B2 | `fetchTrendingMedia` 清空查询串丢失 `-filter:replies` | `twitter_client.dart:461-468` 删除 `else if (query==null) finalQuery=""` 分支，始终保留 `-filter:replies` | ✅ 修 |
| B3 | `build()` 内直接 `_managePool()` 副作用 | `tiktok_feed_screen.dart:173-174` `Future.microtask`；`hashtag_feed_screen.dart:191-192` 函数体内包 `Future.microtask` | ✅ 修 |
| B4 | 错误/完成事件只绑首个实例，重建后失效 | `media_container.dart:62-79` 新增 `_bindSubscriptions`，实例变化时 `cancel` 旧订阅并重绑新实例 stream（`:249` 调用） | ✅ 修 |
| B5 | 登录硬编码 query id / 空 restId 写账户 | `login_screen.dart:78-110` restId 改用 candidatePaths 重试；`:113-122` 空 restId 直接拒绝并提示 | ✅ 修 |
| B6 | 同一用户 Subscription `id` 不一致（@name vs name） | 插入点统一为 screen_name：`tweet_text_overlay.dart:249`、`user_details_screen.dart:443`、`twitter_client.dart:423`；`fetchProfile` 的 rest_id 仅作 `fetchFollowing` 参数 | ✅ 修 |
| B7 | `fetchFollowing` legacy 解析脆弱 | `twitter_client.dart:418-419` `legacy = userResult["legacy"] ?? core.user_results.result.legacy` | ✅ 修 |
| B8 | 未使用且矛盾的 query ID 常量 | grep `graphqlUserByScreenName*` 全项目 **0 匹配**，死常量已删 | ✅ 修 |
| B9 | `substring(id.length-8)` 可能越界 | `tiktok_feed_screen.dart:341-343` 加 `tweet.id.length >= 8` 长度保护 | ✅ 修 |
| B10 | 登录 ct0 缺失抛未捕获异常 | `login_screen.dart:53-63` 改 `firstOrNull` + 为空提示返回 | ✅ 修 |
| B11 | `pruneCachedMedia` 不清理 null `created_at` | `repository.dart:614` 清理条件改为 `created_at < ? OR created_at IS NULL` | ✅ 修 |
| B12 | HomeTimeline 降级丢失 `cursorBottom` | `twitter_client.dart:712-719` 返回 `fetchAlgorithmicTimeline` 完整响应（含 `:1236` 的 cursorBottom），分页游标不再丢 | ✅ 修 |

> B12 残差提示：降级返回的是 HomeTimeline 游标，其格式与 SearchTimeline 游标未必兼容，后续若继续翻页走 SearchTimeline 分支仍可能遇到边界。数据层面「返回 cursorBottom」已修复，但跨降级游标兼容性未专门验证（低风险）。

---

## 三、`feature_completeness_audit.md` 各项：7 修复 / 8 开放

### ✅ 已修复（7 项）

| 编号 | 原问题 | 当前修复证据（file:line） | 状态 |
|------|--------|--------------------------|------|
| 避免已看 | 仅本地缓存生效、API/话题流绕过 | `repository.dart:531-568` 新表 + `markWatched/getWatchedIdentifiers/filterUnwatched`；接入 `feed_provider.dart:216/323/374`、`hashtag_provider.dart:85/124`、两 screen `:56/180` | ✅ 修 |
| G1 | `autoplay` 摆设（无代码读取） | `media_container.dart:252` 真正读取 `settings.autoplay` 控制 `play()` | ✅ 修 |
| M5 | 播放器池无硬上限 | `player_pool_provider.dart:22` `maxPoolSize=12`；`:47-52` 超出时 LRU 淘汰最旧实例 | ✅ 修 |
| M6 | 进度续播缺失 | `media_container.dart:88-116` `_savePosition`/`_restorePosition`，pause/dispose 时保存、进入时恢复 | ✅ 修 |
| M7 | 订阅主键不一致→重复行 | 同 B6，所有插入点统一 screen_name | ✅ 修 |
| L3 | 刷新路径缺参不一致 | `feed_provider.dart:210-211` `_refreshInBackground` 现传 `maxQueryLength`/`timeoutSeconds` | ✅ 修 |
| L4 | 浮层手动订阅字段不全 | `tweet_text_overlay.dart:251-252` 现填 `name`/`profileImageUrl` | ✅ 修 |

### ❌ 仍开放（8 项）

| 编号 | 问题 | 证据 | 严重度 |
|------|------|------|--------|
| G2 | `mediaCacheSizeMB` 摆设 | `media_cache_manager.dart` 硬编码 `maxNrOfCacheObjects:200`，全项目 grep 该设置零引用 | 🔴 高 |
| M1 | `popular`/`trending` 取数伪实现（语义误导） | `feed_provider.dart:184-213` 仅 3 显式分支，二者落 `else→fetchSubscribedMedia(sort:)`，仅 `min_faves`/Top 微调（非全局发现） | 🟠 中 |
| M2 | 发现算法（freshMixRatio/unseenSubscriptionBoost）仅刷新生效 | `feed_provider.dart:279-447` `fetchMore` 只 `shuffle`+`applySaturation`，不进 `_runDiscoveryPipeline` | 🟠 中 |
| M3 | `cooldownMinutes` 非真冷却 | 仅 429 回退生效，分块轮换硬编码 `300ms` | 🟡 低 |
| M4 | 视频完全不读本地缓存 | 视频仍走 `Media(url)` 直连 HTTP（`player_pool_provider.dart:44`） | 🟡 低 |
| L1 | 自然播完也走 `autoSkipDelaySeconds` | `media_container.dart:158-159` `playNext` 复用 `onPlaybackError` | 🟡 低 |
| L2 | 双击缩放/亮度未实现 | grep `scale/zoom/brightness` 仅命中主题 `Brightness.dark` | 🟡 低 |
| L5 | 认证头外部依赖脆弱 | `twitter_account.dart` txId/guest_id 依赖实时捕获，离线/旧账户可能失败 | 🟡 低 |

---

## 四、综合结论与建议

1. **两份报告的安全性结论依然成立且更优**：原报告判断的 12 个 bug 全部为真实问题，现已 **12/12 修复**；且本次复测确认修复均落在「恢复应有行为/扩大成功面/防崩溃/清理死代码」范畴，无引入回归。
2. **「避免已看内容」缺口已闭合**，且其修复质量经核对正确（过滤嵌进 `fetchMore` 既有重试循环，旧内容常驻不空白）。
3. **剩余 8 个开放项**里，建议优先处理：
   - **G2（高）**：把 `mediaCacheSizeMB` 真正接到缓存管理器的 `maxNrOfCacheObjects`/磁盘配额，否则「限制 X MB」是虚假承诺；
   - **M1（中）**：要么给 `popular`/`trending` 加专属取数分支，要么在 UI 改名避免「全站热门/趋势」误导；
   - **M2（中）**：让发现算法（混合比/未看加权）也对 `fetchMore` 追加内容生效。
4. 其余低严重度项（M3/M4/L1/L2/L5）属体验/一致性增强，可排期处理。

> 本次复测未运行应用，结论基于静态走读。建议对 B5（登录空 restId）、B3（快速滑动）、G1（autoplay 开关）做真机回归验证。
