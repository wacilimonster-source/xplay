# XPlay Bug 评审报告

> 评审范围：`lib/**` 全部 37 个 Dart 源文件
> 评审方式：静态代码走读（未运行、未修改任何代码）
> 结论：**发现 3 个高严重度缺陷、5 个中严重度缺陷、若干低严重度/健壮性隐患**。
> 下面每个问题均给出「位置 / 现象 / 影响 / 修复建议」，修复建议仅描述，未落地代码。

---

## 一、严重度总览

| 编号 | 位置 | 严重度 | 一句话描述 |
|------|------|--------|------------|
| B1 | `twitter_client.dart:281-325` | 🔴 高 | `fetchProfile` 的「新/旧」两套 query ID 实际相同，fallback 永远无法恢复过期 ID |
| B2 | `twitter_client.dart:513-543` | 🔴 高 | `fetchTrendingMedia` 在无订阅+无过滤的发现路径把查询串清空，丢失 `-filter:replies` 且产生空 `rawQuery` |
| B3 | `tiktok_feed_screen.dart:169` / `hashtag_feed_screen.dart:253` | 🔴 高 | 在 `build()` 内直接调用 `_managePool()`，于构建阶段 dispose/create 播放器实例 |
| B4 | `media_container.dart:170-174` | 🟠 中 | 错误/播放完成事件订阅绑定到首个 Player 实例，实例被回收重建后不再被处理 |
| B5 | `login_screen.dart:36-104` | 🟠 中 | 登录用硬编码过期 query ID；ct0 缺失抛异常无捕获；profile 拉取失败仍创建空 `restId` 账户 |
| B6 | `tweet_text_overlay.dart:227` / `user_details_screen.dart:443` | 🟠 中 | 同一用户的 Subscription `id` 不一致（`@name` vs `name`），可能写出重复订阅行 |
| B7 | `twitter_client.dart:466-481` | 🟠 中 | `fetchFollowing` 用 `core.screen_name` 是否存在来决定把 `core` 当 `legacy`，解析脆弱易取错字段 |
| B8 | `twitter_client.dart:21-34,250-251` / `query_id_resolver.dart` | 🟡 低 | 大量未使用、相互矛盾的 query ID 常量 + `pathFor` 冗余参数 |
| B9 | `tiktok_feed_screen.dart:333` | 🟡 低 | `tweet.id.substring(id.length - 8)` 在 id 短于 8 字符时抛 `RangeError` |
| B10 | `login_screen.dart:51` | 🟡 低 | `ct0` 缺失时 `firstWhere` 抛异常未被 try/catch 包裹 |
| B11 | `repository.dart:548-558` | 🟡 低 | `pruneCachedMedia` 按年龄清理时 `created_at` 为 null 的行永不被清理 |
| B12 | `twitter_client.dart:760-779` | 🟡 低 | `fetchSubscribedMedia` 的 HomeTimeline fallback 不返回 `cursorBottom`，fallback 后分页中断 |

---

## 二、详细分析

### 🔴 B1 — `fetchProfile` 新旧 query ID 相同，fallback 失效
**位置**：`lib/core/client/twitter_client.dart` 第 281-325 行（`fetchProfile`）

**现象**：
```dart
// 1) “新”查询
final newUri = Uri.https('x.com', '/i/api${QueryIdResolver.pathFor('UserByScreenName')}', ...);
// 2) “旧”fallback
final oldUri = Uri.https('x.com', '/i/api${QueryIdResolver.pathFor('UserByScreenName', 'UserByScreenName')}', ...);
```
- `QueryIdResolver.pathFor('UserByScreenName')` → 解析为 `Gb-d6r0vxPOADdG62OEBpQ`
- `QueryIdResolver.pathFor('UserByScreenName', 'UserByScreenName')` → 同样解析为 `Gb-d6r0vxPOADdG62OEBpQ`（第二个参数仅在主 key 为 null 时作兜底，此处主 key 非 null）

两条查询 URL **完全一致**。而代码注释里写的「new = `IGgvgiOx4QZndDHuD3x9TQ`」「old = `oUZZZ8Oddwxs8Cd3iW3x9TQ`」在代码中根本没有被使用——`QueryIdResolver` 的 `UserByScreenName` 绑定值是 `Gb-d6r0vxPOADdG62OEBpQ`。

同时，文件顶部 `graphqlUserByScreenNameUriPath` 与 `graphqlUserByScreenNameNewUriPath` **两个常量字符串完全相同**（`/graphql/Gb-d6r0vxPOADdG62OEBpQ/UserByScreenName`），且从未被 `fetchProfile` 引用（死代码）。

**影响**：X 会定期轮换 GraphQL query ID。当 `Gb-d6r0vxPOADdG62OEBpQ` 过期返回 404 时，第一步失败；进入 fallback，用的是**同一个已过期 ID**，必然再次失败。所谓「双路容错」完全失效，导致资料拉取/订阅导入/个人媒体流全部拿不到 `rest_id`，进而整个「订阅」feed 为空。

**修复建议**：
- 让 fallback 真正指向一个**不同的** query ID（应使用注释中规划的 `IGgvgiOx4QZndDHuD3x9TQ` 或 `QueryIdResolver._alternates['UserByScreenName']` 中的备用值），而不是再次调用 `pathFor('UserByScreenName')`。
- 或者直接复用 `QueryIdResolver.candidatePaths('UserByScreenName')` 做 404 重试，与 `fetchTrendingMedia` 的容错方式保持一致。
- 删除顶部两个相同且未使用的 `graphqlUserByScreenName*UriPath` 常量，消除误导。

---

### 🔴 B2 — `fetchTrendingMedia` 清空查询串，丢失 replies 过滤
**位置**：`lib/core/client/twitter_client.dart` 第 513-543 行

**现象**：
```dart
String finalQuery = query ?? "";
if (!finalQuery.contains("-filter:replies")) {
  finalQuery = finalQuery.isEmpty ? "-filter:replies" : "$finalQuery -filter:replies";
}
if (filters != null && filters.isNotEmpty) {
  // 拼接 filter:videos / filter:images
} else if (query == null) {
  finalQuery = "";   // ← 这里把上面的 -filter:replies 也清掉了
}
```
函数开头特意给 `finalQuery` 追加 `-filter:replies`（注释明确说“Always exclude replies”），但紧接着 `else if (query == null)` 分支把整串重置成 `""`，于是：
1. 丢失了 replies 排除（与注释意图相反）；
2. 最终 `rawQuery` 为空字符串，且因 `filters` 为空也不会走 `combinedFilter` 分支。

**触发路径**：`fetchSubscribedMedia` 在「无订阅 + `strictSubscriptionsOnly=false` + 无激活 filter」时调用 `fetchTrendingMedia()`（无 `query`、无 `filters`）（第 667、724 行），正好命中该分支 → 发送空 `rawQuery` 的搜索请求，结果异常/返回无关内容。

**影响**：对应场景下发现流退化为空查询或包含大量回复噪音，feed 质量与稳定性下降。

**修复建议**：把 `else if (query == null) finalQuery = "";` 改为「仅当没有任何过滤附加时才清空」，或干脆**始终保留 `-filter:replies`**（即使是默认全部流）。推荐做法：把 replies 排除作为最后一步无条件追加，而不是在中间分支覆盖。

---

### 🔴 B3 — 在 `build()` 中 dispose / create 播放器实例
**位置**：
- `lib/features/feed/tiktok_feed_screen.dart:169`（`if (tweets.isNotEmpty) _managePool();` 直接写在 `build` 内）
- `lib/features/feed/hashtag_feed_screen.dart:253`（同样直接调用 `_managePool()`）

**现象**：`_managePool()` 内部：
```dart
final pool = ref.read(playerPoolProvider.notifier);
... pool.warmup(...)          // 创建 Player + VideoController（native 资源）
... pool.cleanupExcept(activeIds);  // 对不在窗口内的实例调用 player.dispose()
```
而 `playerPoolProvider` 是 `Notifier`，`warmup`/`cleanupExcept` 会修改其 `state`，并在 `cleanupExcept` 中**同步 dispose 原生播放器**。

**问题**：`build()` 在渲染管线/布局阶段被调用，此时：
- 调用 `dispose()` 释放正在被其它 widget 引用的 Player，可能触发 `setState()/markNeedsBuild() called during build` 或原生资源在布局期间被释放的异常；
- 修改 Provider 状态会立刻触发依赖该 Provider 的 widget 重 build，与当前正在进行的 build 形成重入。

**对照**：`UserMediaFeedScreen._managePool` 正确地用 `Future.microtask(() {...})` 把副作用推迟到构建之后（见 `user_media_feed_screen.dart:75`），而上面两个屏没有这样做，行为不一致。

**影响**：偶发崩溃、播放卡顿/黑屏、列表滑动时播放器被误回收。

**修复建议**：与 `UserMediaFeedScreen` 对齐，将 `TiktokFeedScreen` 与 `HashtagMediaFeedScreen` 中的 `_managePool()` 调用改为 `Future.microtask(() => _managePool())`，或放到 `addPostFrameCallback` 中，避免在 `build` 阶段产生副作用。

---

### 🟠 B4 — 错误/完成事件订阅绑定到首个实例，重建后失效
**位置**：`lib/features/player/widgets/media_container.dart:170-174`

**现象**：
```dart
_errorSubscription ??= instance.player.stream.error.listen(_handleError);
_completedSubscription ??= instance.player.stream.completed.listen((c){ if(c) _handleCompleted(); });
```
`??=` 只在**第一次**为某个 widget 实例绑定订阅，且该订阅绑定的是**当时那个 Player 实例的 stream**。当 `PlayerPoolNotifier.cleanupExcept` 把当前实例 dispose、又 `warmup` 出同 id 的**新**实例时：
- widget 仍持有旧的非空 `_errorSubscription`/`_completedSubscription`，不会再为**新实例**订阅；
- 旧实例的 stream 已被 dispose，订阅变成悬挂引用（只在整个 widget dispose 时才取消）。

**影响**：视频实例被回收重建后，新视频的播放错误**不再触发重试/自动跳过**，播放完成**不再触发播放下一/重播**——用户看到的是卡在当前条无法自动前进。

**修复建议**：在 `_managePool`/`didUpdateWidget` 检测到实例变化时，先 `cancel()` 旧订阅，再为当前 `pool[widget.tweet.id]` 重新订阅；或在 `dispose` 之外、实例切换时也清理并重建订阅。

---

### 🟠 B5 — 登录流程多处隐患
**位置**：`lib/features/auth/login_screen.dart:36-104`

问题点：
1. **硬编码过期 query ID**：拉取 `rest_id` 时用 `/i/api/graphql/oUZZZ8Oddwxs8Cd3iW3x9TQ/UserByScreenName`，与 `QueryIdResolver` 使用的 `Gb-d6r0vxPOADdG62OEBpQ` 不一致。若 `oUZZZ8...` 已过期 → `profileRes` 非 200 → `restId=''`。
2. **即使 profile 失败仍写库**：`restId=''` 时仍 `Repository.insertAccount(account)`，且 `Account.restId` 为空。后续 `fetchSubscribedMedia` → `fetchFollowing(currentAccount.restId)` 用空 id 请求 → 失败 → 订阅为空 → feed 为空。
3. **ct0 缺失抛异常无捕获**：`cookies.firstWhere((c) => c.name == 'ct0', orElse: () => throw Exception('ct0 not found'))` 位于 `onPageFinished` 异步回调内，未包裹 try/catch，登录态不完整时会抛未捕获异常。

**影响**：登录成功但 `rest_id` 为空，导致订阅/个人媒体流无法工作；极端情况下登录回调崩溃。

**修复建议**：
- 复用 `QueryIdResolver.pathFor('UserByScreenName')` 而非硬编码；若 404 则走 `candidatePaths` 重试。
- `restId` 为空时视为登录失败，提示用户重试，不写入账户。
- 用 `firstWhere` 的安全写法（先 `where`+判空）替代 `orElse: () => throw`。

---

### 🟠 B6 — 同一用户 Subscription 的 `id` 不一致，可能重复入库
**位置**：
- `lib/features/feed/widgets/tweet_text_overlay.dart:227` → `Subscription(id: widget.tweet.userHandle, ...)`（`@screenName`）
- `lib/features/profile/user_details_screen.dart:443` → `Subscription(id: profile.screenName, ...)`（`screenName`，无 `@`）

**现象**：`insertSubscription` 以 `id` 为主键（`conflictAlgorithm.replace`）。从 feed 浮层「+」订阅写入 `id='@name'`，从资料页「+」订阅写入 `id='name'`。两者 `screen_name` 实际相同，但主键不同 → 同一用户可能出现**两行**订阅。

**影响**：订阅列表重复显示、发现引擎对同一个人重复加权、缓存/清理逻辑按 `screen_name` 删除时可能只删到一行。

**修复建议**：统一 `Subscription.id` 的规范（例如统一用 `screenName`，或在构造处 `replaceFirst('@','')` 归一化），保证对同一用户主键一致。

---

### 🟠 B7 — `fetchFollowing` 的 legacy 解析脆弱
**位置**：`lib/core/client/twitter_client.dart:466-481`

**现象**：
```dart
final legacy = userResult["core"]?["screen_name"] != null
    ? userResult["core"]
    : userResult["legacy"];
```
`Following` 时间线的 `user_results.result` 结构中，`core` 一般形如 `{ user_results: { result: { legacy, ... } } }`，**顶层 `core` 通常没有 `screen_name` 字段**。因此 `core["screen_name"]` 几乎总是 null → 退化使用 `legacy`（正确路径）。但逻辑建立在「`core.screen_name` 是否存在」这一不稳定假设上，且紧接着读取 `legacy["screen_name"]`、`legacy["name"]`、`userResult["avatar"]?["image_url"]`。

**影响**：一旦 X 的 `core` 结构变化（出现/不出现 `screen_name`），`screenName`/`name`/`avatar` 取错或取到 null 的概率显著上升，订阅项的展示信息异常。

**修复建议**：明确按真实结构取值：先用 `userResult["legacy"]`（或 `userResult["core"]?["user_results"]?["result"]?["legacy"]`），不要以 `core.screen_name` 是否存在作为切换条件；对 `avatar` 同样优先取 `legacy["profile_image_url_https"]`。

---

### 🟡 B8 — 未使用且相互矛盾的 query ID 常量 + `pathFor` 冗余参数
**位置**：
- `twitter_client.dart:21-34`（`graphqlSearchTimelineUriPath='BGd0T_j7oVwlW5U79tO_0A'`、`graphqlUserByScreenNameUriPath`/`graphqlUserByScreenNameNewUriPath` 等）
- `twitter_client.dart:250-251`（再次定义一份相同的 `graphqlUserByScreenNameNewUriPath`）
- `twitter_client.dart:324-325` 中 `QueryIdResolver.pathFor('UserByScreenName', 'UserByScreenName')` 第二个参数冗余

**现象**：这些常量与 `QueryIdResolver` 内 `_bundled`/`_alternates` 的 ID 并不一致（如 SearchTimeline 常量用 `BGd0T_j7oVwlW5U79tO_0A`，而实际运行时走 `GcXk9vN_d1jUfHNqLacXQA`）。且 `pathFor(op, fallbackOp)` 当主 key 非 null 时 fallback 永不生效，传两次相同字符串无意义。

**影响**：维护者极易被这些“看起来是配置”的常量误导，以为改这里就能换 query ID（实际运行时根本没用到）。

**修复建议**：删掉 `twitter_client.dart` 中所有重复的 query ID 常量，统一以 `QueryIdResolver` 为唯一真相来源；清理 `pathFor` 的冗余传参。

---

### 🟡 B9 — `tweet.id.substring(id.length - 8)` 可能越界
**位置**：`lib/features/feed/tiktok_feed_screen.dart:333`（`DiscoveryDebugOverlay`）

**现象**：`tweet.id.substring(tweet.id.length - 8)`。Twitter 推文 ID 通常很长，但 `id` 可能来自本地/缓存/异常数据而短于 8 字符，此时抛 `RangeError`。

**修复建议**：`final id = tweet.id; if (id.length >= 8) id.substring(id.length-8) else id;`。

---

### 🟡 B10 — 登录回调中 ct0 缺失抛异常未捕获
**位置**：`lib/features/auth/login_screen.dart:51`

**现象**：见 B5 第 3 点。`cookies.firstWhere(..., orElse: () => throw Exception('ct0 not found'))` 在 `onPageFinished` 异步回调内，无 try/catch。

**修复建议**：改用 `cookies.where((c) => c.name == 'ct0').firstOrNull`，为空时 `return` 并在 UI 提示“登录态不完整，请重试”。

---

### 🟡 B11 — `pruneCachedMedia` 不清理 `created_at` 为 null 的数据
**位置**：`lib/core/database/repository.dart:548-558`

**现象**：按年龄清理用 `WHERE created_at < ?`，`created_at` 为 null 的行不会被选中；后续按数量清理时用 `ORDER BY COALESCE(last_played_at, created_at) ASC`，null 会排在最前被优先删除——两个策略对 null 处理相反，且前者会让无日期的脏数据长期滞留。

**修复建议**：对 `created_at` 为 null 的行直接视为可清理（或赋予插入时兜底时间戳）。

---

### 🟡 B12 — HomeTimeline fallback 丢失分页游标
**位置**：`lib/core/client/twitter_client.dart:760-779`

**现象**：`fetchSubscribedMedia` 在 SearchTimeline 返回 0 条时调用 `fetchAlgorithmicTimeline` 作为降级，但其返回的 `TweetResponse` 未携带 `cursorBottom`，调用方直接用 `response.cursorBottom`（null）继续。一旦走到这条降级路径，后续“加载更多”分页游标即中断（只能一次性拿一页）。

**修复建议**：fallback 路径要么也返回可用的 `cursorBottom`，要么在 UI 层把“已降级”状态标记出来，避免用户误以为还能无限下拉。

---

## 三、额外观察（非 bug，但建议留意）

1. **`main.dart` 的 `XFlowApp` 是 `ConsumerWidget`，但其 `build` 内通过 `WidgetsBinding.instance.addPostFrameCallback` 启动 `BackgroundSync` 并拉起更新检查**——`build` 在每次 `settingsProvider`/`lifecycleProvider` 变化时都会执行，`addPostFrameCallback` 会被反复注册（用 `_startupUpdateCheckStarted` 静态标志避免重复检查，但 `BackgroundSync.start` 内部用 `_syncTimer != null` 去重，逻辑可用，仅略显隐晦）。
2. **`SettingsNotifier.build()` 先返回默认 `SettingsState(isInitialized:false)`，再异步 `_init()` 覆盖**——首帧会使用默认值；若 `BackgroundSync.start` 在 settings 尚未初始化时运行，会采用默认策略（syncInterval=15 等），属可接受降级。
3. **`Repository.insertCachedMedia` 使用 `conflictAlgorithm.ignore`**——已有推文不会被刷新 `created_at`/媒体地址；如果同一条推文的媒体后续变化，缓存不会更新（设计取舍，非缺陷）。
4. **`MediaContainer` 对同一 `player.stream.error` 同时存在 `_errorSubscription`（build 内订阅）与 `StreamBuilder`（同名 stream）两个监听**——功能上不冲突，但 `build` 内订阅属于 B3/B4 讨论范畴，建议统一到 widget 生命周期管理。

---

## 四、优先级修复建议

1. **立即修（高）**：B1（fallback 失效）、B2（空查询）、B3（build 内副作用）。
2. **尽快修（中）**：B4（事件订阅失效）、B5（登录空 restId）、B6（重复订阅）、B7（legacy 解析）。
3. **排期清理（低）**：B8~B12 及第三节观察项。

> 本报告为纯静态评审，未运行应用、未改动任何源文件。以上问题均基于代码走读推断，建议在真机/模拟器上针对 B1/B3/B5 做回归验证。

---

## 五、二次复查 + 修复安全性确认（2026-08-20）

逐条重新核对源码后，**原报告所有问题均属实**。下方对每条给出「是否真实」与「修复是否影响业务主逻辑」的结论。

| 编号 | 真实性 | 修复安全性 | 说明 |
|------|--------|-----------|------|
| B1 | ✅ 真实 | ✅ 不影响主流程（仅扩大成功面） | `fetchProfile` 两路均走 `QueryIdResolver.pathFor('UserByScreenName')`→`Gb-d6r0vxPOADdG62OEBpQ`，与注释声称的 `IGgvgi…`/`oUZZZ…` 不符；fallback 与主路 ID 完全相同。修复只用不同备用 ID（如 `_alternates` 里的 `IGgvgiOx4QZndDHuD3x9TQ`），当前 ID 有效时行为不变，仅在过期时从「双路必败」变为「可恢复」。注：若已登录 WebView 成功捕获到 live ID，该问题被缓解，但 fallback 仍形同虚设。 |
| B2 | ✅ 真实 | ✅ 不影响主流程（仅修复空查询） | `fetchTrendingMedia` 第 540-543 行 `else if (query==null) finalQuery=""` 会把刚加的 `-filter:replies` 清空。仅当 `query=null` 且 `filters` 为空时触发——正是 `fetchSubscribedMedia` 的「无订阅+非严格+无过滤」发现路径。所有 `fetchTrendingMedia` 调用方（hashtag 传非空 query、用户时间线传 `from:`，均无此分支影响）。删除该重置分支即可，符合第 515 行注释意图，不改变成功路径行为。 |
| B3 | ✅ 真实 | ✅ 不影响业务（仅延迟一帧副作用） | `tiktok_feed_screen.dart:169`、`hashtag_feed_screen.dart:253` 在 `build()` 内直接调用 `_managePool()`，而 `_managePool` 会 `dispose()` 原生 Player 并改写 Provider 状态。修复改为 `Future.microtask`（与 `UserMediaFeedScreen` 已验证可用的写法一致），warmup/cleanup 仍照常发生，仅推迟到本帧之后，无逻辑差异。 |
| B4 | ✅ 真实 | ✅ 不影响正常路径 | `media_container.dart:170` 用 `??=` 把错误/完成事件绑到首个实例；实例被回收重建后新实例事件无人处理。修复在检测到 `instance` 变化时 cancel 旧订阅、重新订阅。仅当同一 widget 存活期间实例被回收（滑出活跃窗口但未卸载）时才相关，属恢复应有行为。 |
| B5 | ✅ 真实 | ✅ 不影响成功登录路径 | `login_screen.dart` 硬编码 `oUZZZ8…`（与 `QueryIdResolver` 的 `Gb-d6r…` 不一致），且 `ct0` 缺失抛未捕获异常，且 profile 失败仍写空 `restId` 账户。修复改用 `pathFor`+空值保护；当前硬编码 ID 有效时行为不变，仅避免「登录成功却拿不到 rest_id→订阅流全空」的坏结果。 |
| B6 | ✅ 真实 | ✅ 不影响（属数据完整性修复） | feed 浮层用 `id:'@name'`、资料页用 `id:'name'`，主键不一致可能写出重复订阅行（按 `screen_name` 删除时只删一行）。修复归一化 `id` 即可，不改变展示/拉取逻辑。 |
| B7 | ✅ 真实但当前“侥幸可用” | ✅ 不影响当前行为 | `fetchFollowing` 用 `userResult["core"]?["screen_name"] != null` 决定取 `core` 还是 `legacy`。当前 X 的 `core` 顶层无 `screen_name`，故落到正确的 `legacy` 分支；一旦结构变化取到 `core` 则会读不到字段。修复直接取 `legacy`（并保留 `core.user_results.result.legacy` 兜底），与当前实际走向一致。 |
| B8 | ✅ 真实 | ✅ 仅清理死代码 | grep 确认 `graphql*UriPath` 常量**仅定义、无任何引用**，全部请求实际都走 `QueryIdResolver.pathFor`。删除不影响任何运行路径。 |
| B9 | ✅ 真实 | ✅ 仅防越界崩溃 | `id.substring(id.length-8)` 仅在 id<8 字符时抛异常（调试浮层）。加长度保护即可，不改变正常展示。 |
| B10 | ✅ 真实 | ✅ 仅避免未捕获异常 | `ct0` 缺失时 `firstWhere(orElse: throw)` 在登录回调中未被 try/catch 包裹。改为安全取值即可。 |
| B11 | ✅ 真实 | ✅ 仅优化清理 | `pruneCachedMedia` 按年龄清理时 `created_at` 为 null 的行不被选中；给 null 兜底时间戳即可正常清理。 |
| B12 | ✅ 真实 | ✅ 仅改善分页 | HomeTimeline 降级路径不返回 `cursorBottom`，导致 fallback 后无法继续「加载更多」。补上 cursor 即可，不影响首屏。 |

### 综合结论
- **全部 12 项 bug 均为真实问题**，无任何误报。
- **任何一项修复都属于「恢复应有行为 / 扩大成功面 / 防崩溃 / 清理死代码」，不会让当前正常工作的业务路径产生回归**。唯一会改变「可见行为」的是 B1/B2/B5 的失败/降级分支：从不工作变为可工作——这是修复的预期方向，而非逻辑破坏。
- 建议回归重点：B1（query ID 过期容错）、B3（快速滑动时是否仍偶发 dispose 异常）、B5（空 restId 账户是否消失）。
