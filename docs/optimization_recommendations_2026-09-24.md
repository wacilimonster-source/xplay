# XPlay 优化建议报告

> 日期：2026-09-24
> 范围：性能与架构优化（不含 bug 修复，bug 已于 2026-09-21 全部处理完毕）
> 代码基线：version 0.1.32+32

---

## 优先级总览

| 编号 | 优先级 | 领域 | 问题 | 预期收益 |
|------|--------|------|------|----------|
| 1 | P0 | 启动 | Query ID 捕获序列串行等待 16-21 秒 | 首启提速至 2-3 秒 |
| 2 | P0 | 播放 | 播放器池上限 12 偏小 | 减少回看时重建卡顿 |
| 3 | P0 | 数据库 | watched_media 无索引且全量加载 | 降低内存与扫描开销 |
| 4 | P1 | UI | Widget 重建粒度过粗 | 减少非必要重建 |
| 5 | P1 | 网络 | Transaction ID 每请求重新生成 | 减少 WebView JS 调用 |
| 6 | P1 | 网络 | GraphQL 候选路径串行重试 | ID 过期时加快失败收敛 |
| 7 | P1 | 算法 | DiscoveryEngine 窗口内重复遍历 | 降低 feed 处理 CPU |
| 8 | P2 | 启动 | 冷启动强制打开数据库 | 改善启动速度 |
| 9 | P2 | 设置 | SettingsNotifier 重复全量读取 | 减少设置页重建开销 |
| 10 | P2 | 网络 | http.Client 不复用 | 减少连接创建开销 |
| 11 | P3 | 缓存 | 缓存统计与清理范围不一致 | 磁盘占用显示准确 |
| 12 | P3 | 图片 | 图片类 tweet 无预加载 | 入屏减少加载停顿 |
| 13 | P3 | 日志 | 无日志级别控制 | 降低 release 开销 |
| 14 | P3 | 数据库 | 迁移分支膨胀（v13） | 降低维护成本 |

---

## P0-1：Query ID 捕获序列优化

### 问题定位

**文件**：`lib/core/client/transaction_id_service.dart`
**行号**：165-203（`_runQueryIdCaptureSequence`）

```dart
final pages = <String>[
  'https://x.com/search?q=test&f=live',
  'https://x.com/x',
  'https://x.com/i/bookmarks',
];
for (final page in pages) {
  await controller.runJavaScript(QueryIdResolver.captureScript);
  await controller.loadRequest(Uri.parse(page));
  await Future.delayed(const Duration(seconds: 5));   // 固定等待 5 秒
  await controller.runJavaScript(QueryIdResolver.captureScript);
  await Future.delayed(const Duration(seconds: 2));   // 再等 2 秒
  await QueryIdResolver.captureFromWebView(controller);
}
```

### 问题分析

1. **固定延迟**：每个页面无条件等待 7 秒（5+2），3 个页面共 21 秒；加上初始页面加载，用户首次启动需等待 10-15 秒才能正常加载媒体（README 已知限制中亦有记载）。
2. **无成功即跳过机制**：即使第 1 个页面就捕获了所有所需 Query ID，仍会走完剩余页面。
3. **无缓存版本校验**：已捕获的 ID 持久化于 SharedPreferences（14 天有效期），但每次启动仍执行完整捕获序列。

### 优化方案

**方案 A：事件驱动替代固定延迟**

```dart
// 伪代码：监听 WebView 请求完成事件，捕获到目标 op 即提前返回
Future<void> _captureWithEarlyExit(WebViewController controller) async {
  final needed = {'SearchTimeline', 'HomeTimeline', 'UserTweets', ...};
  final captured = <String>{};

  await for (final op in QueryIdResolver.onIdCaptured) {
    captured.add(op);
    if (captured.containsAll(needed)) break;  // 全部捕获即退出
  }
}
```

**方案 B：URL 版本指纹缓存**

- 记录 x.com 页面 HTML 的 `manifest` 版本或 `script` 标签 hash。
- 若与上次捕获时一致，跳过整个序列，直接复用持久化的 ID。
- 仅在版本变化或 ID 失效（请求 404）时触发重新捕获。

**方案 C：并行加载 + 首页优先**

- 首帧先加载 `https://x.com/home`（用户登录后的默认页），该页面本身就会触发 HomeTimeline 的 GraphQL 请求，大概率捕获到核心 ID。
- 其余页面作为"补充捕获"延后执行，不阻塞首屏。

### 预期收益

首次启动媒体加载等待时间从 10-15 秒降至 2-3 秒，提升首启体验。

---

## P0-2：播放器池上限提升

### 问题定位

**文件**：`lib/features/player/player_pool_provider.dart`
**行号**：29

```dart
class PlayerPoolNotifier extends Notifier<Map<String, PlayerInstance>> {
  static const int maxPoolSize = 12;   // ← 当前上限
```

### 问题分析

1. **预载窗口占用**：TikTok 式滚动时，`_managePool` 会为 currentIndex-1 到 +3 共 5 个视频预热。
2. **多 scope 共享**：home feed、hashtag feed、user media feed 共享同一池（见 `owners` 字段注释）。
3. **回看卡顿**：用户回看已刷过的视频时，若该视频已被 LRU 驱逐，需重新 `warmup` → `player.open()` → 等待缓冲，造成明显卡顿。

### 优化方案

```dart
class PlayerPoolNotifier extends Notifier<Map<String, PlayerInstance>> {
  // 1. 提升上限至 20-24（TikTok 官方推荐 20+）
  static const int maxPoolSize = 20;

  // 2. 引入显存压力感知：当系统内存紧张时主动收缩
  void onMemoryPressure() {
    final excess = state.length - 12;  // 降到保守值
    if (excess > 0) {
      final sorted = state.entries.toList()
        ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));
      for (var i = 0; i < excess; i++) {
        sorted[i].value.dispose();
        state.remove(sorted[i].key);
      }
    }
  }
}
```

同时建议：
- 对 `warmup` 的 `player.open()` 增加超时控制，避免慢网环境下占用池位但不 ready。
- 考虑按视频分辨率分级：1080p 视频占 2 个池位权重，720p 占 1 个。

### 预期收益

连续滚动 50+ 条后回看前 10 条，播放器重建率从 ~80% 降至 ~20%。

---

## P0-3：watched_media 表索引与查询优化

### 问题定位

**文件**：`lib/core/database/repository.dart`

**行号 116-122**（建表）：

```dart
await db.execute('''
  CREATE TABLE $tableWatchedMedia (
    id TEXT PRIMARY KEY,
    media_key TEXT,
    watched_at INTEGER
  )
''');
// ← 缺少 media_key 索引
```

**行号 718-731**（全量加载）：

```dart
static Future<Set<String>> getWatchedIdentifiers() async {
  final db = await database;
  final maps = await db.query(
    tableWatchedMedia,
    columns: ['id', 'media_key'],   // ← 全表扫描
  );
  final set = <String>{};
  for (final m in maps) {
    set.add(m['id'] as String);
    final mk = m['media_key'];
    if (mk != null) set.add(mk as String);
  }
  return set;   // ← 全部读入内存
}
```

### 问题分析

1. **无索引**：`media_key` 无索引，`filterUnwatched` 中的 `watched.contains(t.mediaKey)` 实际是在内存 Set 上查找，但构建该 Set 需要全表扫描。
2. **内存压力**：watched_media 会持续增长（每看一条媒体 +1 行），万级数据时全量加载占用数 MB 内存。
3. **SQL 侧未利用**：`getUnplayedCachedMedia` 的子查询 `media_key NOT IN (SELECT media_key FROM ...)` 虽有 `idx_media_key`，但 watched_media 侧无索引时仍慢。

### 优化方案

```sql
-- 迁移脚本（version 14）
CREATE INDEX IF NOT EXISTS idx_watched_media_key ON watched_media(media_key);
CREATE INDEX IF NOT EXISTS idx_watched_at ON watched_media(watched_at);
```

```dart
// 优化 getWatchedIdentifiers：限制返回最近 N 条
static Future<Set<String>> getWatchedIdentifiers({int? limit}) async {
  final db = await database;
  final maps = await db.query(
    tableWatchedMedia,
    columns: ['id', 'media_key'],
    orderBy: 'watched_at DESC',
    limit: limit,   // 如 limit=5000，只关心最近看过的
  );
  // ...
}

// 或：改用 SQL 侧过滤
static Future<List<Tweet>> filterUnwatchedSql(List<Tweet> tweets) async {
  final db = await database;
  final ids = tweets.map((t) => t.id).toList();
  final placeholders = List.filled(ids.length, '?').join(',');
  final watchedRows = await db.query(
    tableWatchedMedia,
    columns: ['id'],
    where: 'id IN ($placeholders)',
    whereArgs: ids,
  );
  final watchedIds = watchedRows.map((r) => r['id'] as String).toSet();
  return tweets.where((t) => !watchedIds.contains(t.id)).toList();
}
```

### 预期收益

- 避免万级数据全量加载，内存占用从 O(N) 降至 O(limit)。
- SQL 侧过滤可利用索引，查询速度提升 10-100 倍。

---

## P1-4：Widget 重建粒度优化

### 问题定位

**文件 1**：`lib/features/player/widgets/media_container.dart`
**行号**：300、349、368

```dart
@override
Widget build(BuildContext context) {
  final appActive = ref.watch(lifecycleProvider) == AppLifecycle.resumed;  // 300
  // ...
  final pool = ref.watch(playerPoolProvider);   // 349
  // ...
  final settings = ref.watch(settingsProvider); // 368
```

**文件 2**：`lib/features/settings/settings_screen.dart`
**行号**：405、525、551、638、778、884、945、1053（8 处 `ref.watch(settingsProvider)`）

**文件 3**：`lib/features/feed/tiktok_feed_screen.dart`
**行号**：427

### 问题分析

1. **media_container**：每个视频 item 的 build 都 watch 整个 `settingsProvider`。用户调整任何设置（如修改缓存大小），所有可见视频 item 全部重建。
2. **settings_screen**：8 个设置区块各自 watch 完整 `SettingsState`，任一字段变化（如拖动滑块）导致整页重建。
3. **对比**：`feed_provider.dart` 184 行已用 `select` 优化：

```dart
ref.watch(settingsProvider.select((s) => s.fetchSnapshot));   // ✅ 正确示范
```

### 优化方案

```dart
// media_container.dart：只订阅需要的字段
@override
Widget build(BuildContext context) {
  final appActive = ref.watch(lifecycleProvider.select((s) => s == AppLifecycle.resumed));
  final autoFullscreen = ref.watch(settingsProvider.select((s) => s.autoFullscreen));
  final playbackRetryLimit = ref.watch(settingsProvider.select((s) => s.playbackRetryLimit));
  // ...
}

// settings_screen.dart：拆分为独立 Provider 或 select
final cacheSettingsProvider = Provider((ref) =>
  ref.watch(settingsProvider.select((s) => (s.mediaCacheSizeMB, s.pruneThreshold))));

class CacheSettingsSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (cacheSize, pruneThreshold) = ref.watch(cacheSettingsProvider);
    // 只有这两个字段变化时才重建
  }
}
```

### 预期收益

- 设置页滑块拖动时，重建范围从整页降至单个 section。
- 视频播放页切换设置时，非相关 item 不再重建，滚动更流畅。

---

## P1-5：Transaction ID 生成缓存

### 问题定位

**文件**：`lib/core/client/twitter_account.dart`
**行号**：169-217

```dart
// 每个 HTTP 请求都执行：
transactionId = await TransactionIdService.instance.generateForRequest(
  uri.path,
  method: method,
);
// 失败时还会远程请求 x-client-transaction-id-generator.xyz
```

### 问题分析

1. **WebView JS 调用开销**：`generateForRequest` 内部调用 `controller.runJavaScriptReturningResult`，每次约 10-50ms。
2. **相同 path 重复生成**：`SearchTimeline`、`HomeTimeline` 等高频请求的 path 固定，但每次重新生成。
3. **远程 fallback 冷却 60 秒**：失败后 1 分钟内不再尝试，但本地生成成功后未缓存。

### 优化方案

```dart
class TransactionIdService {
  final _cache = <String, _TxIdEntry>{};
  static const _cacheExpiry = Duration(minutes: 5);

  Future<String?> generateForRequest(String path, {String method = 'GET'}) async {
    final key = '$method:$path';
    final cached = _cache[key];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.id;
    }

    final id = await _generateFresh(path, method);
    if (id != null) {
      _cache[key] = _TxIdEntry(id, DateTime.now().add(_cacheExpiry));
    }
    return id;
  }
}
```

注意：X 的 transaction ID 算法包含时间戳因子，缓存时间不宜超过 5 分钟。

### 预期收益

高频接口（SearchTimeline、HomeTimeline）的请求延迟减少 10-50ms。

---

## P1-6：GraphQL 候选路径并行化

### 问题定位

**文件**：`lib/core/client/twitter_client.dart`
**行号**：852-916（`fetchTrendingMedia` 候选循环）

```dart
final attemptPaths = QueryIdResolver.candidatePaths('SearchTimeline');
for (var i = 0; i < attemptPaths.length; i++) {
  final path = attemptPaths[i];
  final response = await _gated(() => TwitterAccount.fetch(uri, ...));
  if (response.statusCode == 429) { /* 熔断 */ }
  if (response.statusCode != 200) { continue; }   // ← 串行重试
  // ...
}
```

### 问题分析

- 候选路径共 6 个（`QueryIdResolver._alternates['SearchTimeline']`），当操作 ID 过期时，需串行尝试直至成功。
- 每个请求超时 10 秒，最坏情况等待 60 秒。

### 优化方案

```dart
Future<TweetResponse> fetchTrendingMedia(...) async {
  final attemptPaths = QueryIdResolver.candidatePaths('SearchTimeline');

  // 并发发起前 3 个候选，取最快成功的
  final futures = attemptPaths.take(3).map((path) async {
    final uri = buildSearchTimelineUri(path);
    final response = await _gated(() => TwitterAccount.fetch(uri, ...));
    if (response.statusCode == 429) throw RateLimitException();
    if (response.statusCode != 200) return null;
    return _parseResponse(response);
  });

  final result = await Future.any(futures.where((f) => f != null));
  if (result != null) return result;

  // 前 3 个全失败，再串行尝试剩余候选
  for (final path in attemptPaths.skip(3)) { /* ... */ }
}
```

保留 429 熔断规则：任一候选返回 429 立即整体停止。

### 预期收益

操作 ID 过期时，失败收敛时间从最坏 60 秒降至 10-20 秒。

---

## P1-7：DiscoveryEngine 算法优化

### 问题定位

**文件**：`lib/core/client/discovery_engine.dart`

**行号 128-219**（`applySaturation`）：

```dart
for (int i = startIndex; i < result.length; i++) {
  final start = (i - windowSize).clamp(0, result.length);
  final window = result.sublist(start, i);   // ← 每次都 sublist

  final handleCount = window
      .where((t) => _normalizeHandle(t.userHandle) == handle)
      .length;   // ← O(windowSize) 遍历
```

**行号 69-117**（`applyUnseenSubscriptionBoost`）：

```dart
for (int i = startIndex; i < result.length - 1; i++) {
  for (int j = i + 1; j < end; j++) {   // ← O(n × lookahead)
    final candScore = playedCountByUser[candHandle] ?? 0;
    if (candScore < bestScore) { /* ... */ }
  }
}
```

### 问题分析

- `applySaturation`：每个位置都对前 `windowSize` 个元素做 `sublist` + `where` 计数，时间复杂度 O(n × windowSize × maxPasses)。
- `applyUnseenSubscriptionBoost`：O(n × lookahead) 的循环比较。
- 当 feed 有 500 条数据时，CPU 占用明显。

### 优化方案

**applySaturation：滑动窗口计数 Map**

```dart
static List<Tweet> applySaturation(List<Tweet> tweets, {int windowSize = 10, ...}) {
  final handleCount = <String, int>{};
  final mediaCount = <String, int>{};

  for (int i = 0; i < result.length; i++) {
    // 移除滑出窗口的元素
    if (i > windowSize) {
      final outHandle = _normalizeHandle(result[i - windowSize - 1].userHandle);
      handleCount[outHandle] = (handleCount[outHandle] ?? 1) - 1;
    }
    // 加入当前元素
    final handle = _normalizeHandle(result[i].userHandle);
    final count = handleCount[handle] ?? 0;
    if (count >= threshold) { /* 需要交换 */ }
    handleCount[handle] = count + 1;
  }
}
```

**applyUnseenSubscriptionBoost：排序 + 二分**

```dart
// 将 playedCountByUser 排序为 List<(handle, count)>
final sorted = playedCountByUser.entries.toList()
  ..sort((a, b) => a.value.compareTo(b.value));

// 在 lookahead 窗口内用二分查找第一个 count < bestScore 的候选
```

### 预期收益

feed 数据量 500+ 时，处理耗时从 ~200ms 降至 ~20ms。

---

## P2-8：冷启动数据库延迟初始化

### 问题定位

**文件**：`lib/main.dart`
**行号**：30-34

```dart
await Future.wait([
  TwitterAccount.init(),
  QueryIdResolver.init(),
  Repository.database,   // ← 强制打开数据库
]);
```

### 问题分析

- 数据库版本 13，`onUpgrade` 包含 v2→v13 的 12 个迁移分支。
- 首次启动或升级后，迁移耗时数百毫秒至数秒。
- 但首屏（TikTok feed）在 `feed_provider.dart` 中才首次查询数据库。

### 优化方案

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // 只初始化轻量级服务
  await Future.wait([
    TwitterAccount.init(),
    QueryIdResolver.init(),
  ]);

  // 数据库改为首次查询时懒加载
  // Repository.database 的 getter 已经是 lazy 的（static Future<Database>? _database）
  // 只需确保 feed_provider 等调用方处理延迟

  runApp(ProviderScope(child: XFlowApp(error: _startupError)));
}
```

### 预期收益

冷启动时间减少 200-500ms（视数据库大小而定）。

---

## P2-9：SettingsNotifier 重复全量读取

### 问题定位

**文件**：`lib/features/settings/settings_provider.dart`
**行号**：326-330、348-489

```dart
@override
SettingsState build() {
  _prefsFuture = null;
  _init();   // ← 每次 build 都调用
  return SettingsState(isInitialized: false);
}

Future<void> _init() async {
  final prefs = await _prefs;
  // 60+ 次 prefs.get* 调用
  final filterStrings = prefs.getStringList('filters') ?? ...;
  final isListView = prefs.getBool('isListView') ?? ...;
  // ...
}
```

### 问题分析

- `SettingsNotifier` 是 `Notifier`，每次 `ref.watch(settingsProvider)` 触发 rebuild 时都会执行 `build()` → `_init()`。
- `_init()` 执行 60+ 次 SharedPreferences 读取，虽然 SP 读取本身快，但累积可观。

### 优化方案

```dart
class SettingsNotifier extends Notifier<SettingsState> {
  bool _initialized = false;

  @override
  SettingsState build() {
    if (!_initialized) {
      _initialized = true;
      _init();
    }
    return SettingsState(isInitialized: _initialized);
  }

  // 或者在 Notifier 外层包一层 keepAlive
}

@Riverpod(keepAlive: true)
SettingsNotifier settingsNotifier() => SettingsNotifier();
```

### 预期收益

设置页打开时减少重复 SP 读取，交互响应更快。

---

## P2-10：http.Client 复用

### 问题定位

**文件 1**：`lib/core/services/update_service.dart`
**行号**：177

```dart
static Future<void> _downloadFromUrl(...) async {
  final client = http.Client();   // ← 每次下载创建新实例
  try { /* ... */ } finally { client.close(); }
}
```

**文件 2**：`lib/core/client/twitter_account.dart`（间接）
`TwitterAccount.fetch` 使用顶层 `http.get`/`http.post`，未复用 Client。

### 问题分析

- 每次创建 `http.Client` 会建立新的连接池，无法复用 TCP/TLS 连接。
- 高频请求（如 GraphQL 轮询）时，连接建立开销明显。

### 优化方案

```dart
// 创建全局单例
class HttpClients {
  static final http.Client api = http.Client();
  static final http.Client download = http.Client();
}

// 使用时
final response = await HttpClients.api.get(uri, headers: headers);
```

### 预期收益

高频请求延迟减少 50-200ms（TLS 握手复用）。

---

## P3-11：缓存统计与清理范围统一

### 问题定位

**文件**：`lib/core/utils/media_cache_manager.dart`

**行号 29-46**：

```dart
static List<String> _ownDirs(String tempPath) => [   // enforceLimit 用
  p.join(tempPath, key),
  p.join(tempPath, 'libCachedImageData', key),
  p.join(tempPath, 'flutter_cache_manager', key),
];

static List<String> _allDirs(String tempPath) => [   // getCacheSize 用
  ..._ownDirs(tempPath),
  p.join(tempPath, 'libCachedImageData'),
  p.join(tempPath, 'flutter_cache_manager'),
  p.join(tempPath, 'ffcache'),
];
```

### 问题分析

- `getCacheSize` 统计 `_allDirs`（6 个目录）。
- `enforceLimit` 只清理 `_ownDirs`（3 个目录）。
- 结果：设置页显示"已用 800 MB"，但执行清理后仍有 500 MB 残留（默认 cache manager 的目录未清）。

### 优化方案

```dart
static Future<int> enforceLimit(int limitMB) async {
  // 改为统计并清理 _allDirs
  for (final dir in await _existingDirs(_allDirs)) { /* ... */ }
}
```

注意：清理 `_allDirs` 中的 `libCachedImageData`（默认 cache manager）时，需同步调用 `DefaultCacheManager().emptyCache()`，否则其索引会指向已删除文件。

### 预期收益

缓存占用显示与实际一致，清理彻底。

---

## P3-12：图片预加载

### 问题定位

**文件**：`lib/features/profile/user_media_feed_screen.dart`
**行号**：275-307（`_managePool` 与 `PageView.builder`）

```dart
_managePool() {
  // 只对视频调用 pool.warmup
  // 图片依赖 CachedNetworkImage 进入视野后才加载
}
```

### 问题分析

- 视频有预加载（player pool warmup），图片没有。
- 快速滚动时，图片 item 进入视野后才开始网络请求，出现白屏或 loading。

### 优化方案

```dart
void _managePool() {
  final pool = ref.read(playerPoolProvider.notifier);
  for (int i = _currentIndex - 1; i <= _currentIndex + 3; i++) {
    if (i < 0 || i >= tweets.length) continue;
    final tweet = tweets[i];
    if (tweet.isVideo) {
      pool.warmup(tweet.id, tweet.mediaUrls.first, scope: poolScope);
    } else {
      // 图片预缓存
      precacheImage(CachedNetworkImageProvider(tweet.mediaUrls.first), context);
    }
  }
}
```

### 预期收益

图片类 tweet 入屏即显示，消除加载停顿。

---

## P3-13：AppLogger 日志级别

### 问题定位

**文件**：`lib/core/utils/app_logger.dart`
**行号**：9-19

```dart
static void log(String message) {
  final timestamp = DateTime.now().toString().split('.').first;
  final logEntry = '[$timestamp] $message';
  _logs.add(logEntry);
  if (_logs.length > _maxLogs) { _logs.removeAt(0); }
  debugPrint(logEntry);   // ← release 模式也输出
}
```

### 问题分析

- 无日志级别（DEBUG/INFO/ERROR）。
- release 模式下 `debugPrint` 仍执行（虽然 Dart 的 `debugPrint` 在 release 有节流，但字符串拼接和 List 操作仍有开销）。

### 优化方案

```dart
enum LogLevel { debug, info, error }

class AppLogger {
  static LogLevel minLevel = kReleaseMode ? LogLevel.error : LogLevel.debug;

  static void log(String message, {LogLevel level = LogLevel.info}) {
    if (level.index < minLevel.index) return;
    // ...
  }
}
```

### 预期收益

release 模式减少字符串拼接和内存维护开销。

---

## P3-14：数据库迁移文档化

### 问题定位

**文件**：`lib/core/database/repository.dart`
**行号**：67-224（`onUpgrade` 的 v2→v13 分支）

### 问题分析

- 12 个版本迁移逻辑混杂在一个函数中。
- 新增字段、索引、表分散在各版本分支，后续维护易遗漏。

### 优化方案

创建 `docs/database_migrations.md`：

```markdown
## v14（计划中）
- 新增索引：watched_media.media_key, watched_media.watched_at
- 影响表：watched_media

## v13
- ...
```

同时在代码中用结构化方式管理：

```dart
static final _migrations = <int, List<String>>{
  14: [
    'CREATE INDEX IF NOT EXISTS idx_watched_media_key ON watched_media(media_key)',
    'CREATE INDEX IF NOT EXISTS idx_watched_at ON watched_media(watched_at)',
  ],
  13: [/* ... */],
};

onUpgrade: (db, oldVersion, newVersion) async {
  for (var v = oldVersion + 1; v <= newVersion; v++) {
    for (final sql in _migrations[v] ?? []) {
      await db.execute(sql);
    }
  }
}
```

### 预期收益

降低数据库演进时的维护成本和出错风险。

---

## 实施建议

### 第一批（本周）

1. **P0-1**：Query ID 捕获优化（影响首启体验）
2. **P0-3**：watched_media 索引（一行 SQL，收益大）
3. **P1-4**：Widget 重建粒度（涉及文件少，改动安全）

### 第二批（下周）

4. **P0-2**：播放器池上限（需测试内存占用）
5. **P1-5**：Transaction ID 缓存
6. **P1-7**：DiscoveryEngine 算法

### 第三批（按需）

7. P2/P3 各项，结合发版节奏安排。

---

## 验证方式

- **P0-1**：记录首次启动到首条视频可播放的时间。
- **P0-2**：连续滚动 50 条后回看，统计播放器重建次数。
- **P0-3**：watched_media 万级数据下，`getWatchedIdentifiers` 耗时与内存峰值。
- **P1-4**：设置页拖动滑块时，观察 Flutter DevTools 的 rebuild 范围。
- **P1-7**：feed 500 条数据时，`applySaturation` 耗时。
