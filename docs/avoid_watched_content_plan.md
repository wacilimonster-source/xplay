# 实现方案：「避免已看内容」功能补全（主页信息流 + 话题视频流）

> 交接文档。目标：让设置项「发现与多样性 → 避免已看内容」对 **主页实时内容** 和 **话题视频流** 也生效（现状只对本地的 `cached_media` 候选生效，其余两条路径绕过）。
> 本方案不改任何现有业务逻辑，只在既有"标记已看 / 过滤已看"链路上补齐缺口，并引入一张与主缓存隔离的 `watched_media` 表。

---

## 0. 背景（两个缺口）

| 缺口 | 现象 | 根因 |
|------|------|------|
| 缺口 1（主页） | 已看过的视频只要 X 又推回来（API 路径），照样出现 | `_refreshInBackground` / `fetchMore` 里 `freshResponse.tweets` 直接进 `FeedState`，**未按已看过滤**；只有 `getCachedMediaCandidates(avoidWatchedContent)` 返回的本地候选被过滤 |
| 缺口 2（话题流） | 该开关在话题视频流里**完全无效** | `HashtagMediaNotifier` 直接 `fetchTrendingMedia`，从不走 `getCachedMediaCandidates`；`hashtag_feed_screen._handleScroll` 也**没有调用任何"标记已看"** |

## 1. 已确认的设计决策

- **修复范围**：主页信息流 + 话题视频流 都修（完整闭环）。
- **"已看"存储**：新建独立表 `watched_media`，与主 `cached_media` 隔离（话题搜索结果不会污染主页发现池）。
- **空 feed 兜底**：**不加**。依赖 `fetchMore` 现有的有界重试 + 转 chunk 逻辑（`feed_provider.dart:303-398`）。已看内容过滤嵌进该循环，`freshUnique` 为空时循环会继续拉下一页找未看内容，屏幕上的旧内容常驻不会变空白。

## 2. 数据库层 `lib/core/database/repository.dart`

### 2.1 新增表常量（约在 `tableHashtags` 定义后，第 13 行附近）
```dart
const String tableWatchedMedia = 'watched_media';
```

### 2.2 版本升级 `9 → 10`
- 第 33 行 `version: 9` 改为 `version: 10`。

### 2.3 `onCreate` 内建表（在第 70 行 `},` 之前、`onUpgrade` 之前插入）
```dart
await db.execute('''
  CREATE TABLE $tableWatchedMedia (
    id TEXT PRIMARY KEY,
    media_key TEXT,
    watched_at INTEGER
  )
''');
```

### 2.4 `onUpgrade` 内新增迁移（在 `if (oldVersion < 9)` 块之后、第 128 行 `},` 之前插入）
```dart
if (oldVersion < 10) {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $tableWatchedMedia (
      id TEXT PRIMARY KEY,
      media_key TEXT,
      watched_at INTEGER
    )
  ''');
}
```

### 2.5 新增 3 个方法（建议在 `markMediaAsPlayed` 附近，第 510 行之后插入）

```dart
/// 标记一条内容为已看。写入独立的 watched_media 表（与 cached_media 隔离）。
/// 话题流只调这个；主页在保留 markMediaAsPlayed 的同时也调这个，保证跨 feed 一致。
static Future<void> markWatched(String id, {String? mediaKey}) async {
  final db = await database;
  await db.insert(
    tableWatchedMedia,
    {
      'id': id,
      'media_key': mediaKey,
      'watched_at': DateTime.now().millisecondsSinceEpoch,
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}

/// 返回所有已看的标识符集合（id + 非空 media_key），用于过滤。
static Future<Set<String>> getWatchedIdentifiers() async {
  final db = await database;
  final maps = await db.query(
    tableWatchedMedia,
    columns: ['id', 'media_key'],
  );
  final set = <String>{};
  for (final m in maps) {
    set.add(m['id'] as String);
    final mk = m['media_key'];
    if (mk != null) set.add(mk as String);
  }
  return set;
}

/// 从列表中剔除已看项。media_key 为 null 时只按 id 判定。
static List<Tweet> filterUnwatched(List<Tweet> tweets, Set<String> watched) {
  if (watched.isEmpty) return tweets;
  return tweets.where((t) {
    if (watched.contains(t.id)) return false;
    if (t.mediaKey != null && watched.contains(t.mediaKey)) return false;
    return true;
  }).toList();
}
```

> 注意：`Tweet` 已含 `mediaKey` 字段（`lib/core/models/tweet.dart:6`），无需改动模型。

---

## 3. 标记已看（两个 feed 都写 `watched_media`）

### 3.1 主页 `lib/features/feed/tiktok_feed_screen.dart` — `_handleScroll` 第 54 行

当前代码：
```dart
        if (page < tweets.length) {
          Repository.markMediaAsPlayed(tweets[page].id);
        }
```
改为（保留旧逻辑 + 新增 `markWatched`，并用 `mediaKey`）：
```dart
        if (page < tweets.length) {
          final t = tweets[page];
          Repository.markMediaAsPlayed(t.id);
          Repository.markWatched(t.id, mediaKey: t.mediaKey);
        }
```

### 3.2 话题流 `lib/features/feed/hashtag_feed_screen.dart` — `_handleScroll` 第 164-183 行

当前代码中 `if (feedAsync.hasValue)` 块内只有"触发 fetchMore"逻辑，**没有标记已看**。在其内、触发 fetchMore 之前插入：
```dart
      final feedAsync = ref.read(hashtagMediaProvider(widget.hashtag));
      if (feedAsync.hasValue) {
        final tweets = feedAsync.value!.tweets;
        // —— 新增：标记已看（话题流不写 cached_media，只写 watched_media）——
        if (page < tweets.length) {
          final t = tweets[page];
          Repository.markWatched(t.id, mediaKey: t.mediaKey);
        }
        // —— 原有：接近底部时加载更多 ——
        final settings = ref.read(settingsProvider);
        if (page >= tweets.length - settings.lazyLoadThreshold &&
            !feedAsync.value!.isLoadingMore) {
          ref.read(hashtagMediaProvider(widget.hashtag).notifier).fetchMore();
        }
      }
```

---

## 4. 过滤已看（两个 feed 都滤）

> 统一做法：在需要过滤的地方，先 `final watched = settings.avoidWatchedContent ? await Repository.getWatchedIdentifiers() : const <String>{};`，再对"即将进入 feed 的列表"跑 `Repository.filterUnwatched(列表, watched)`。

### 4.1 主页 `lib/features/feed/feed_provider.dart`

**(a) `_refreshInBackground`（第 170-270 行）**
在第 173-174 行拿到 `client` / `settings` 之后，加一行取 watched 集合：
```dart
    final client = ref.read(twitterClientProvider);
    final settings = ref.read(settingsProvider);
    final watched = settings.avoidWatchedContent
        ? await Repository.getWatchedIdentifiers()
        : const <String>{};
```
在第 233-234 行构造完 `localTagged` 之后，对 `freshTagged` 和 `localTagged` 都过滤，再传给 `_runDiscoveryPipeline`（第 246-253 行）：
```dart
      final freshTagged = Repository.filterUnwatched(
        freshPool.map((t) => t.copyWith(source: 'API')).toList(),
        watched,
      );
      // ...（第 223-234 行原 freshTagged/localTagged 构造可保留，但此处以过滤后为准）
      final localTagged = Repository.filterUnwatched(
        localPool.map((t) => t.copyWith(source: 'Cache')).toList(),
        watched,
      );
```
> 说明：`localPool` 来自 `getCachedMediaCandidates(avoidWatchedContent:)`，本身已按 `cached_media.played_count` 过滤；再叠加 `watched_media` 过滤，可挡住"只在话题流看过"的内容回流主页，实现跨 feed 一致。

**(b) `fetchMore`（第 272-437 行）**
在循环前（第 280 行 `try {` 之后、第 281 行取 `seenIds` 之前）取 watched：
```dart
    try {
      final watched = settings.avoidWatchedContent
          ? await Repository.getWatchedIdentifiers()
          : const <String>{};
      final seenIds = state.value!.tweets.map((t) => t.id).toSet();
```
过滤两处新拉内容：
- 第 313-316 行 `localNew`（DB 候选）之后追加 watched 过滤：
  ```dart
  var localNew = Repository.filterUnwatched(dbCandidates.where((t) {
    return !seenIds.contains(t.id) &&
        (t.mediaUrls.isEmpty || !seenMedia.contains(t.mediaUrls.first));
  }).toList(), watched);
  ```
- 第 364-367 行 `freshUnique` 构造后追加 watched 过滤：
  ```dart
  final freshUnique = Repository.filterUnwatched(
    response.tweets.where((t) {
      return !seenIds.contains(t.id) &&
          (t.mediaUrls.isEmpty || !seenMedia.contains(t.mediaUrls.first));
    }).toList(),
    watched,
  );
  ```
> 这样 `freshUnique` 为空时，`allNewTweets` 不增长，循环（第 303 行 `while`）继续拉下一页 / 转下一个 chunk，直到重试上限——符合"不加兜底"决策。

### 4.2 话题流 `lib/features/feed/hashtag_provider.dart`

**(a) `build()`（第 51-87 行）**
在第 54 行拿到 `settings` 后取 watched，并在返回 `FeedState` 前（第 82 行前）过滤 `response.tweets`：
```dart
    final settings = ref.watch(settingsProvider);
    final watched = settings.avoidWatchedContent
        ? await Repository.getWatchedIdentifiers()
        : const <String>{};
    // ...（三次 fetchTrendingMedia 调用保持不变）...
    final filteredTweets = Repository.filterUnwatched(response.tweets, watched);
    return FeedState(
      tweets: filteredTweets,
      cursorBottom: response.cursorBottom,
      isRefreshing: false,
    );
```

**(b) `fetchMore()`（第 94-128 行）**
在第 105 行拿到 `settings` 后取 watched，并在 `uniqueNew` 构造（第 116-118 行）后叠加 watched 过滤：
```dart
    final settings = ref.read(settingsProvider);
    final watched = settings.avoidWatchedContent
        ? await Repository.getWatchedIdentifiers()
        : const <String>{};
    // ...
    final seenIds = currentState.tweets.map((t) => t.id).toSet();
    final uniqueNew = Repository.filterUnwatched(
      response.tweets.where((t) => !seenIds.contains(t.id)).toList(),
      watched,
    );
```

---

## 5. 涉及文件清单

| 文件 | 改动 |
|------|------|
| `lib/core/database/repository.dart` | 常量 + 版本 9→10 + onCreate 建表 + onUpgrade 迁移 + 3 个新方法 |
| `lib/features/feed/tiktok_feed_screen.dart` | `_handleScroll` 第 54 行追加 `markWatched` |
| `lib/features/feed/hashtag_feed_screen.dart` | `_handleScroll` 内新增 `markWatched` |
| `lib/features/feed/feed_provider.dart` | `_refreshInBackground`、`fetchMore` 过滤 fresh/local |
| `lib/features/feed/hashtag_provider.dart` | `build()`、`fetchMore()` 过滤 response.tweets |

共 5 个文件，**无需改动** `tweet.dart`、`settings_provider.dart`、模型或 UI 文案。

---

## 6. 边界与注意事项

1. `media_key` 为 null 时 `filterUnwatched` 只按 `id` 判，已处理（`lib/core/models/tweet.dart` 字段可空）。
2. "已看"判定维持现状语义：**滑到即算已看**（主页在 `_handleScroll` 触发，话题流新增同语义）。此为原设计，非本次引入。
3. `getWatchedIdentifiers` 每次刷新全表读出；个人量级无性能问题。若担心热路径开销，可在 `FeedNotifier`/`HashtagMediaNotifier` 内做一次性缓存，但**非必要**。
4. 旧版数据库（`version < 10`）升级时会执行 `onUpgrade` 的 `if (oldVersion < 10)` 建表，已有数据不受影响。
5. 不要删除主页的 `markMediaAsPlayed`——它被 `getPlayedCountsByUser` / 发现引擎的 `unseenSubscriptionBoost`、`applySaturation` 复用，删除会破坏推荐多样性逻辑。
6. `media_key` 在话题流推文里是否填充，取决于 `twitter_client.fetchTrendingMedia` 的解析；若解析未填 `mediaKey`，则话题流与主页只能靠 `id` 匹配（仍可正确过滤同一推文）。如需按"同一视频多推文"去重，需确认 `fetchTrendingMedia` 解析时带上了 `mediaKey`（可 grep `media_key` 在 `twitter_client.dart` 的赋值确认）。

---

## 7. 验证步骤（落地后手测）

1. 设置 → 发现与多样性 → 打开「避免已看内容」。
2. 主页滑几个视频 → 下拉刷新 / 退出重进 → 确认刚才看过的**不再出现**（验证缺口 1 修复）。
3. 进话题流（底部「话题」Tab → 添加 `#xxx` → 点开）→ 看几个 → 回到主页 → 确认话题流里看过的**不会回流主页**（验证跨 feed 一致 + 独立表隔离）。
4. 话题流里看过的，再次进入同一话题 → 不再出现（验证缺口 2 修复）。
5. 关掉「避免已看内容」开关 → 上述所有内容恢复正常出现（验证开关可逆、无副作用）。
6. 极端：长时间使用后某话题全部看过 → 话题流显示「未找到媒体内容」而非崩溃（验证空态安全、无兜底依赖）。
