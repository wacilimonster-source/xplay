# 关注列表获取 实现文档

## 整体流程图

```
App启动
  │
  ├─ TwitterAccount.init()          ← 从SQLite加载已登录Account
  ├─ QueryIdResolver.init()         ← 加载GraphQL Query ID缓存
  ├─ Repository.database            ← 打开/创建SQLite数据库
  │
  ├─ BackgroundSync.start()         ← 周期性推文同步(读订阅列表, 不触发拉关注)
  │
  └─ FeedNotifier.build()           ← 加载缓存推文, 然后:
        _refreshInBackground()
          fetchSubscribedMedia()
            读取订阅列表 ──→ 为空?
                               │
                               └─ YES: fetchFollowing(restId)  ← 首次触发
                                      │  GraphQL: /graphql/{id}/Following
                                      │  每页100人, 最多2000人
                                      │  提取: screenName/name/avatar/description/followers/following
                                      │
                                      └─ insertSubscriptions(subs) ← SQLite批量写入

订阅列表页展示
  SubscriptionListNotifier._load()
    ├─ getSubscriptions()            ← 从SQLite读取全部订阅
    └─ getPlayedCountsByUser()       ← 从cached_media统计播放次数
        → UI渲染(排序/筛选/搜索)
```

---

## 1. 登录与Account存储

### 登录流程 (`login_screen.dart`)

1. WebView打开 `https://x.com/i/flow/login`
2. 页面加载到 `x.com/home` 后:
   - JS提取 `screen_name`
   - JS提取Cookie: `guest_id`, `gt`, `att`, `auth_token`, `ct0`
3. 调用 `UserByScreenName` GraphQL 解析 `restId` (数字用户ID)
4. 构造Account对象:
   ```dart
   Account(
     id: ct0,           // 作为主键
     screenName: screenName,
     restId: restId,
     authHeader: jsonEncode({'Cookie': ..., 'authorization': ..., 'x-csrf-token': ...}),
   )
   ```
5. `Repository.insertAccount(account)` → SQLite存储 (ConflictAlgorithm.replace)
6. `ref.read(accountProvider.notifier).login(account)` → Riverpod状态更新

### Account数据结构 (`entities.dart:1-29`)

```
Account {
  id: String          ← ct0 cookie值, 作为主键
  screenName: String  ← 用户名
  restId: String      ← 数字用户ID
  authHeader: String  ← JSON编码的认证信息
}
```

---

## 2. 关注列表获取触发时机

有 **3个入口** 会触发 `fetchFollowing`:

### 入口A: 信息流首次加载 (`twitter_client.dart:659-684`)

```
FeedNotifier.build()
  → _refreshInBackground()
    → client.fetchSubscribedMedia()
      → Repository.getSubscriptions()
      → 如果列表为空: 调用 fetchFollowing(restId)
      → 写入DB
```

**这是最常见的首次触发方式** — 用户打开信息流时自动触发。

### 入口B: 手动同步按钮 (`subscription_list_screen.dart:222-244`)

订阅列表页显示 "同步关注列表" 按钮, 点击后:
```dart
final client = TwitterClient();
final subs = await client.fetchFollowing(current.restId, cooldownMinutes: 1);
await Repository.insertSubscriptions(subs);
ref.invalidate(subscriptionListProvider);
```

### 入口C: 导入其他用户关注 (`subscription_import_screen.dart:20-61`)

```dart
final user = await client.fetchProfile(_fromScreenName!);  // 先解析userId
final following = await client.fetchFollowing(user.id);     // 拉取该用户关注列表
await Repository.insertSubscriptions(following);            // 存入DB
```

---

## 3. GraphQL API调用细节

### API端点

```
GET https://x.com/i/api/graphql/{queryId}/Following
```

- Query ID通过 `QueryIdResolver.pathFor('Following')` 解析
- 默认bundled ID: `OLm4oHZBfqWx8jbcEhWoFw`

### 请求变量

```json
{
  "userId": "<restId>",
  "count": 100,
  "includePromotedContent": false,
  "withGrokTranslatedBio": false
}
```

翻页时追加:
```json
{ "cursor": "<nextCursor>" }
```

### 特性标志

使用 `defaultFeatures` — 约80个GraphQL feature flags (`twitter_client.dart:79-160`)。

---

## 4. 分页与容错

### 分页循环 (`twitter_client.dart:378-517`)

- 每页请求100个用户
- 循环直到: `allSubs.length >= maxCount`(默认2000) 或无更多页
- **Cursor去重**: `seenCursors` 防止无限循环
- **用户去重**: `seenHandles`(小写) 跨页去重

### 并发控制

- `_waitForTurn()` 确保同一时刻只有一个请求在飞
- `_followingInFlight` 复用同一个Future, 防止并发重复请求
- `_handleRateLimit(cooldownMinutes)` 收到429时暂停所有请求

### HTTP缓存

每次请求带15分钟HTTP缓存:
```dart
TwitterAccount.fetch(uri, cacheDuration: Duration(minutes: 15))
```

### 速率限制处理

```
收到HTTP 429
  → _handleRateLimit(cooldownMinutes): 置 _waitUntil = now + cooldown
  → break退出循环
```

---

## 5. 响应解析 — 提取字段

响应结构:
```
data.user.result.timeline.timeline.instructions
  → [TimelineAddEntries]
    → entries[] → content.itemContent.user_results.result
```

### 支持多种响应shape

Twitter API返回的用户数据有多种嵌套格式, 解析器依次尝试:

| 字段 | 尝试路径 |
|---|---|
| `screenName` | `userResult.screen_name` → `.legacy.screen_name` → `.core.screen_name` → `.core.user_results.result.legacy.screen_name` |
| `name` | `userResult.name` → `.legacy.name` → `.core.name` |
| `avatar` | `userResult.avatar.image_url` → `.legacy.profile_image_url_https` → `.core.user_results.result.legacy.profile_image_url_https` |
| `description` | `legacy.description` |
| `followersCount` | `legacy.followers_count` |
| `followingCount` | `legacy.friends_count` |

### 构造Subscription对象

```dart
Subscription(
  id: screenName,
  screenName: screenName,
  name: name,
  profileImageUrl: avatar,
  description: description,
  followersCount: followersCount,
  followingCount: followingCount,
)
```

---

## 6. 数据库存储

### subscriptions表结构 (`repository.dart:39-40`)

```sql
CREATE TABLE subscriptions (
  id TEXT PRIMARY KEY,              -- screenName
  screen_name TEXT,
  name TEXT,
  profile_image_url TEXT,
  description TEXT,
  followers_count INTEGER,
  following_count INTEGER
)
```

### 写入方式

- **单条写入** `insertSubscription(sub)`: `ConflictAlgorithm.replace` — 同ID覆盖
- **批量写入** `insertSubscriptions(subs)`: `db.batch()` + `ConflictAlgorithm.replace`

### 读取方式

```dart
static Future<List<Subscription>> getSubscriptions() async {
  final db = await database;
  final maps = await db.query('subscriptions');
  return maps.map((m) => Subscription.fromMap(m)).toList();
}
```

---

## 7. fetchProfile 与 fetchFollowing 的区别

| | `fetchFollowing` | `fetchProfile` |
|---|---|---|
| **用途** | 批量拉取关注列表 | 查询单个用户资料 |
| **GraphQL** | `Following` | `UserByScreenName` |
| **返回** | `List<Subscription>` | `Subscription?` |
| **字段** | 取决于API返回的legacy数据 | 全量返回所有字段 |
| **调用时机** | 首次加载信息流 / 手动同步 / 导入 | 查看用户详情页 / 解析screenName→userId |

**注意**: `fetchProfile` **不会**被调用来"补充" `fetchFollowing` 遗漏的字段。两个方法是独立的, 各自从不同GraphQL端点获取数据。

---

## 8. 应用启动时同步链路

```
main.dart
  └─ BackgroundSync.start()
       └─ _sync() (周期性)
            └─ getSubscriptions()
            └─ 如果为空: return (不触发fetchFollowing)
            └─ 随机选取syncBatchSize个订阅 → 拉取推文

main.dart (同时)
  └─ FeedNotifier.build() (懒加载)
       └─ _refreshInBackground()
            └─ fetchSubscribedMedia()
                 └─ getSubscriptions()
                 └─ 如果为空: fetchFollowing(restId) → insertSubscriptions(subs)
                 └─ 拉取推文
```

**结论**: 没有显式的"启动时同步关注"步骤。关注列表在信息流首次加载且发现列表为空时**隐式触发**拉取。
