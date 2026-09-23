# 数据库迁移记录（xflow / XPlay）

> 唯一事实来源：`lib/core/database/repository.dart`
> 当前版本：`Repository.schemaVersion`（见下表最后一行）

新增版本时三件事一起做，缺一项就会被 `test/core/database/schema_migration_test.dart` 问住：

1. `Repository.schemaVersion` +1；
2. 在 `Repository.upgradeSchema` 末尾加一个 `if (oldVersion < N) { await _migrateVN(db); }` 分支，
   迁移体写成幂等（`CREATE INDEX IF NOT EXISTS` / `_addColumnIfMissing`）；
3. 全新安装路径 `Repository.createSchema` 里同步补上同样的列/索引，
   否则新库和升级上来的库结构不一致。

规则：
- 不删列、不重命名旧列（SQLite 的 `DROP COLUMN` 在低版本 Android 上不可用）；要废弃就停止读写。
- 迁移里不做网络、不做 UI，只做 SQL。
- 每条迁移必须能安全重跑（测试里有一条专门验证"升级两次无害"）。

---

## v1 → v2
- `accounts` 加 `rest_id TEXT`。
- 起因：GraphQL 调用需要数字 userId。

## v2 → v3
- 新建 `subscriptions`（id/screen_name/name/profile_image_url）。

## v3 → v4
- `subscriptions` 加 `description`、`followers_count`、`following_count`。

## v4 → v5
- 新建 `cached_media`（媒体元数据表，含 `played_count`、`last_played_at`、`duration_watched`）。
- 新建 `hashtags`。

## v5 → v6
- `cached_media` 加索引 `idx_discovery_lookup (played_count, created_at DESC)`：发现池按"没播过 + 新"取候选。

## v6 → v7
- `cached_media` 加 `media_key`，索引 `idx_media_key`：同一媒体跨推文去重。

## v7 → v8
- 补建 `hashtags`（IF NOT EXISTS，兼容早期跳版）。

## v8 → v9
- `cached_media` 加 `last_suggested_at`，索引 `idx_suggested`：候选池轮转，避免同批内容反复出现。

## v9 → v10
- 新建 `watched_media`（id/media_key/watched_at）：与 `cached_media` 隔离的"已看"名单，
  话题流等不写元数据的场景也能记录观看。

## v10 → v11
- `cached_media` 加 `media_width`、`media_height`：布局按真实宽高比，减少跳动。

## v11 → v12
- `subscriptions` 加 `profile_synced_at`：详情页资料同步节流。

## v12 → v13
（缺陷修复版本，2026-09-21 全量审查后引入）
- `cached_media` 加 `inserted_at`：入库时间兜底。此前清理条件写作
  `created_at < ? OR created_at IS NULL`，而时间解析对**所有**推文都返回 null，
  于是每次清理等于清空整表。现在清理用 `COALESCE(created_at, inserted_at)`，
  且两者都为空的遗留行不再被当成垃圾删除。
- `cached_media` 加 `is_liked`、`favorite_count`、`reply_count`：点赞状态与计数此前
  只在内存里，内容从缓存回读后红心和数字都会丢。
- 索引 `idx_created_at (created_at DESC)`：用户页/话题页按时间取缓存。
- 数据修复：`subscriptions` 按 `LOWER(screen_name)` 收敛为一句柄一行，并建
  `UNIQUE INDEX idx_subs_screen`。此前同步关注列表用 screen_name 当主键、
  抓资料用 rest_id 当主键，同一个人会存成两行且越用越多。

## v13 → v14
（性能项，见 docs/optimization_recommendations_2026-09-24.md 的 P0-3）
- 索引 `idx_watched_media_key (media_key)`、`idx_watched_at (watched_at)`。
- 配套：`getWatchedIdentifiers()` 之前每次信息流请求都全表读进内存；
  现在按 `watched_at DESC` 有界读取，并新增 `filterUnwatchedInDb()` 用
  一次带索引的 `IN` 查询完成过滤；`pruneWatchedMedia()` 把该表稳定在最近
  20000 行（由 `pruneCachedMedia` 调用）。
