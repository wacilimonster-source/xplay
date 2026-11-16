import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xplay/core/client/twitter_client.dart';
import 'package:xplay/core/models/tweet.dart';
import 'package:xplay/features/feed/feed_provider.dart';
import 'package:xplay/features/search/search_provider.dart';
import 'package:xplay/features/settings/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('SearchNotifier', () {
    late _FakeTwitterClient mockClient;
    late ProviderContainer container;

    setUp(() {
      mockClient = _FakeTwitterClient();
      container = ProviderContainer(
        overrides: [
          twitterClientProvider.overrideWithValue(mockClient),
          settingsProvider.overrideWith(() => _TestSettingsNotifier()),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('empty keyword never hits the API', () async {
      await container.read(searchProvider.notifier).search('   ');
      final state = container.read(searchProvider).value!;
      expect(state.tweets, isEmpty);
      expect(state.hasMore, isFalse);
      expect(mockClient.calls, isEmpty);
    });

    test('builds media filter operators from chips', () {
      final notifier = container.read(searchProvider.notifier);
      expect(notifier.buildQuery('cat', const {}),
          'cat (filter:images OR filter:videos)');
      expect(notifier.buildQuery('cat', {MediaFilter.video}),
          'cat filter:videos');
      expect(notifier.buildQuery('cat', {MediaFilter.image}),
          'cat filter:images');
      expect(notifier.buildQuery('cat', {MediaFilter.text}), 'cat');
    });

    test('search uses latest sort and stores the cursor', () async {
      final tweet = Tweet(
        id: 'search_1',
        text: 'a cat',
        userHandle: '@user',
        mediaUrls: ['https://example.com/cat.jpg'],
        createdAt: DateTime(2025, 1, 1),
      );
      mockClient.stub(
        query: 'cat (filter:images OR filter:videos)',
        sort: FeedSort.latest,
        cursor: null,
        response: TweetResponse(
          tweets: [tweet],
          cursorBottom: 'cursor_1',
        ),
      );

      await container.read(searchProvider.notifier).search('cat');

      final state = container.read(searchProvider).value!;
      expect(state.tweets.map((t) => t.id), ['search_1']);
      expect(state.cursorBottom, 'cursor_1');
      expect(state.hasMore, isTrue);
      expect(mockClient.calls.single.sort, FeedSort.latest);
    });

    test('fetchMore dedupes and advances the cursor', () async {
      final first = Tweet(
        id: 'search_1',
        text: 'first',
        userHandle: '@user',
        mediaUrls: ['https://example.com/1.jpg'],
      );
      final second = Tweet(
        id: 'search_2',
        text: 'second',
        userHandle: '@user',
        mediaUrls: ['https://example.com/2.jpg'],
      );
      mockClient.stub(
        query: 'cat (filter:images OR filter:videos)',
        sort: FeedSort.latest,
        cursor: null,
        response: TweetResponse(tweets: [first], cursorBottom: 'cursor_1'),
      );
      mockClient.stub(
        query: 'cat (filter:images OR filter:videos)',
        sort: FeedSort.latest,
        cursor: 'cursor_1',
        response: TweetResponse(
          // Repeated id must not be appended again.
          tweets: [first, second],
          cursorBottom: null,
        ),
      );

      await container.read(searchProvider.notifier).search('cat');
      await container.read(searchProvider.notifier).fetchMore();

      final state = container.read(searchProvider).value!;
      expect(state.tweets.map((t) => t.id), ['search_1', 'search_2']);
      expect(state.cursorBottom, isNull);
      expect(state.hasMore, isFalse);
    });
  });
}

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  SettingsState build() => SettingsState(
        timelineBatchSize: 20,
        loadBatchSize: 20,
        cooldownDuration: 15,
      );
}

class _FakeTwitterClient extends TwitterClient {
  final Map<({String? query, FeedSort? sort, String? cursor}), TweetResponse>
      _responses = {};
  final List<({String? query, FeedSort? sort, String? cursor})> calls = [];

  void stub({
    required String? query,
    required FeedSort? sort,
    String? cursor,
    required TweetResponse response,
  }) {
    _responses[(query: query, sort: sort, cursor: cursor)] = response;
  }

  @override
  Future<TweetResponse> fetchTrendingMedia({
    String? cursor,
    String? query,
    FeedSort? sort,
    Set<MediaFilter>? filters,
    int count = 20,
    int cooldownMinutes = 15,
    int? minFaves,
    int timeoutSeconds = 15,
  }) async {
    final key = (query: query, sort: sort, cursor: cursor);
    calls.add(key);
    return _responses[key] ??
        (throw StateError('Missing stub for $key'));
  }
}
