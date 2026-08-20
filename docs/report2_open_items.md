# 报告二（全功能完整性审计）未修复项清单

> 提取自：`docs/feature_completeness_audit.md`
> 复测基准时间：2026-08-20（对照 `docs/bug_fix_retest_2026-08-20.md` 当前真实代码逐条 grep 核实）
> 说明：本报告二原始共 15 个缺口（G1–G2、M1–M7、L1–L5）。其中 **7 项已被另一 agent 修复**；**M1（popular/trending 取数）、M4（视频本地缓存）、L1（播完复用跳过）、L2（缩放/亮度）、L5（认证头依赖）经用户复核属设计如此/非缺陷**，已移出。M3（`cooldownMinutes`）经用户复核确认：**当前"限流惩罚器"行为才是合理设计，不应改成"平时也按设置间隔节流"，否则反而拖慢更新**，故亦移出待修。**以下仅 2 项仍为待修**（G2 真 bug、M2 部分实现且用户已决定修复）。

---

## 一、待修项（共 2 项）

### 🔴 G2（P0 真 bug）. `mediaCacheSizeMB` 形同虚设
- **证据**：
  - 定义/持久化：`settings_provider.dart:22,224,317-318`
  - 显示"已用 X MB / 限制 Y MB"滑块：`settings_screen.dart:586,589,593`
  - 但缓存管理器 `lib/core/utils/media_cache_manager.dart:15-16` 硬编码：
    ```dart
    stalePeriod: const Duration(days: 7),
    maxNrOfCacheObjects: 200,
    ```
    全文件**零引用** `mediaCacheSizeMB`。
- **性质**：纯"设置未接线"——UI 显示"限制 Y MB"、改了毫无效果。唯一一个"UI 承诺了、代码完全没接"的真缺陷。
- **建议修复**：将 `mediaCacheSizeMB` 注入 `media_cache_manager` 的 `Config`，用 `maxNrOfCacheObjects`（按 MB 估算对象数）或改用 `flutter_cache_manager` 的容量限制；让"清除缓存/容量上限"这套 UI 不再虚假。与视频缓存无关（视频走流式，见已确认非问题 M4）。

---

### 🟠 M2（P1 部分实现，用户已决定修复）. 发现算法仅"刷新/冷启动"生效
- **证据**：
  - 管线定义：`feed_provider.dart:43` `_runDiscoveryPipeline(...)`，内含：
    - `DiscoveryEngine.interleave(fresh, local, freshMixRatio)`（`:89-90`）—— 新旧内容按 `freshMixRatio` 交织
    - `applyUnseenSubscriptionBoost(...)`（`:94-101`）—— 未看订阅加权
    - `applySaturation(...)`（`:103-111`）—— 多样性保护
  - **整条管线仅一处调用**：`_refreshInBackground` 内 `feed_provider.dart:253`。
  - `fetchMore`（滑到底加载更多，`feed_provider.dart:279-442`）：取候选 → 去重（仅基于已显示窗口）→ `allNewTweets.shuffle()`（`:416`）→ `combined = [...已有, ...新一批]`（`:423`）→ 仅对新尾巴跑一次 `applySaturation`（`:426`，`startIndex` 设成已有长度）。**不进发现管线、不跑 interleave / unseenSubscriptionBoost**。
- **精确机制（一句话）**：
  - **刷新 / 冷启动** = 整条 feed 用完整发现算法**全量重排**（interleave + 未看加权 + 饱和）。
  - **滚动加载更多** = 新一批**洗牌后纯追加**到尾巴，只对新增部分做饱和，不重排已有内容。
- **影响**：`freshMixRatio`（新旧混合比例）、`unseenSubscriptionBoost`、`unseenBoostLookahead` 这三个设置**只对"刷新后重建的那条流"生效**；往下滑加载出来的内容不受它们控制（追加批次随机 shuffle，不按混合比/未看加权编排）。非崩溃、偏设计，但设置覆盖不全。
- **为何仍要改（用户决定）**：让用户调这些设置时，整段会话（含翻页）行为一致，而非只有刷新那一下生效。
- **建议修复**：在 `fetchMore` 追加批次时也跑 `_runDiscoveryPipeline`（或至少复用 `unseenSubscriptionBoost` / `freshMixRatio` 的 interleave），使翻页内容与刷新一致；注意与"避免已看"过滤（已修的 `filterUnwatched`）协同，避免重复逻辑。

---

## 二、已确认非问题（移出待修）

> 经用户复核与代码核实，以下 6 项**不是 bug**（功能未损坏、或属设计/必需依赖/合理取舍），不再计入待修。

| 项 | 内容 | 为何非 bug |
|----|------|-----------|
| M1 | `popular`/`trending` 取数策略 | `min_faves:100` 与 `product:Top` 均真实传入 X 请求并生效，属"订阅搜索的排序/过滤微调"，功能已实现正常；仅命名易与全局流混淆 |
| M3 | `cooldownMinutes` 非"真冷却" | 当前仅作 **429 限流后的惩罚性冻结**（平时全速串行、无固定间隔）。经用户复核确认：这正是合理设计——若改造成"平时也按 `cooldownDuration` 间隔节流"，反而会让更新变慢（如设 5 分钟则 5 分钟才打一次接口）。保持"限流惩罚器"语义、不修 |
| M4 | 视频本地缓存 | 视频 `Media(url)` 直连 X 流式播放，属流式视频客户端**标准设计**；"无离线/秒开"为可选增强。注：`player_pool_provider.warmup` 已做网络预热 |
| L1 | 自然播完也走 `autoSkipDelaySeconds` | `media_container.dart:158-159` 中 `playNext` 复用错误跳过回调，注释明写 *"Re-use the same callback for auto-advance"*——**故意复用**，自然结束与出错走同一条路，属一致性设计 |
| L2 | 双击缩放 / 亮度调节 | grep 设置页 `缩放\|亮度\|zoom\|brightness` **零匹配**——本就无此开关，是"没做的增强"，无 UI 承诺，不算缺陷 |
| L5 | 认证头外部依赖脆弱 | `twitter_account.dart:120` 注释确认 `x-xp-forwarded-for` 是 **X 自 2026 强制要求必带头**，属架构必需依赖；脆弱点在于捕获机制，而非依赖本身为缺陷 |

---

## 三、已修复对照（报告二原始 15 项）

> 7 项已闭合不计入待修；M1、M3、M4、L1、L2、L5 经复核确认**非缺陷**（设计如此/合理取舍/必需依赖），亦移出待修。

| 项 | 内容 | 状态 |
|----|------|------|
| 避免已看内容 | 缺口已按 `docs/avoid_watched_content_plan.md` 落地 | ✅ 已修 |
| G1 | `autoplay` 接线 | ✅ 已修 |
| M5 | 播放器池硬上限 `maxPoolSize=12` | ✅ 已修 |
| M6 | 进度续播（`_savePosition`/`_restorePosition`） | ✅ 已修 |
| M7 | 订阅主键统一（统一为 screen_name） | ✅ 已修 |
| L3 | 刷新路径缺参（现传 `maxQueryLength`/`timeoutSeconds`） | ✅ 已修 |
| L4 | 浮层手动订阅补 `name`/`profileImageUrl` | ✅ 已修 |
| M1 | `popular`/`trending` 取数：经复核确认已实现且正常，属设计如此 | ➖ 移出待修 |
| M3 | `cooldownMinutes`：当前"限流惩罚器"语义合理，改真节流反而拖慢更新，用户决定不修 | ➖ 移出待修 |
| M4 | 视频本地缓存：流式播放标准设计，非缺陷 | ➖ 移出待修 |
| L1 | 播完复用跳过：故意复用，设计如此 | ➖ 移出待修 |
| L2 | 缩放/亮度：无 UI 承诺的增强 | ➖ 移出待修 |
| L5 | 认证头：X 强制必需依赖 | ➖ 移出待修 |

---

## 四、建议修复优先级（针对本清单 2 项待修）

| 优先级 | 项 | 说明 |
|--------|-----|------|
| P0 | G2 `mediaCacheSizeMB` | 纯"设置未接线"真 bug，影响用户信任，改动小 |
| P1 | M2 发现算法覆盖 `fetchMore` | 用户已决定修复；让设置对翻页也生效 |

> 注：本报告"待修项"均指**功能层面未达设置/UI 承诺或仅部分生效**，非崩溃性 bug；项目主体功能可用。其余审计项经逐条复核均已确认非缺陷或已修复。
