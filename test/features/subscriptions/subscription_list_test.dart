import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xplay/features/subscriptions/subscription_list_screen.dart';
import 'package:xplay/core/database/entities.dart';

void main() {
  group('SubscriptionListScreen Widget Tests', () {
    testWidgets('renders empty state when no subscriptions',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subscriptionListProvider
                .overrideWith(() => MockSubscriptionListNotifier([])),
          ],
          child: const MaterialApp(
            home: SubscriptionListScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('未找到订阅内容'), findsOneWidget);
    });

    testWidgets('renders list of subscriptions', (WidgetTester tester) async {
      final mockSubs = [
        Subscription(
          id: '1',
          screenName: 'user1',
          name: 'User One',
          profileImageUrl: 'https://test.com/u1.jpg',
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subscriptionListProvider
                .overrideWith(() => MockSubscriptionListNotifier(mockSubs)),
          ],
          child: const MaterialApp(
            home: SubscriptionListScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('User One'), findsOneWidget);
      expect(find.text('@user1'), findsOneWidget);

      // The search + sort block used to live in the AppBar's `bottom:` with a
      // declared height (80) smaller than its real content (~112), so Flutter
      // centred the overflow and the search box painted over the title row.
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.byType(SearchBar)),
          findsNothing,
          reason: '搜索条不应再塞进 AppBar 的 bottom 槽位');
      expect(tester.getRect(find.byType(SearchBar)).top,
          greaterThanOrEqualTo(tester.getRect(find.text('订阅')).bottom),
          reason: '搜索条不得压住标题行');
      expect(tester.takeException(), isNull, reason: '不允许出现 RenderFlex 溢出');
    });

    testWidgets('大字号下仍然不重叠', (WidgetTester tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subscriptionListProvider.overrideWith(() =>
                MockSubscriptionListNotifier([
                  Subscription(id: '1', screenName: 'user1', name: 'User One'),
                ])),
          ],
          child: const MaterialApp(
              home: SubscriptionListScreen(isStandalone: false)),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byType(SearchBar)).top,
          greaterThanOrEqualTo(tester.getRect(find.text('订阅')).bottom));
      final chipsBottom = tester.getBottomRight(find.text('名称')).dy;
      final firstCardTop = tester.getTopLeft(find.byType(Card)).dy;
      expect(firstCardTop, greaterThanOrEqualTo(chipsBottom),
          reason: '排序条与列表重叠（chipsBottom=$chipsBottom cardTop=$firstCardTop）');
      expect(tester.takeException(), isNull);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    testWidgets('作为底部标签页时不显示无效的返回按钮', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subscriptionListProvider
                .overrideWith(() => MockSubscriptionListNotifier([])),
          ],
          child: const MaterialApp(
            // 主界面 IndexedStack 里的用法
            home: SubscriptionListScreen(isStandalone: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // navigationProvider.back() has nothing to pop on a plain tab, so the
      // arrow was dead weight and crowded the centred title.
      expect(find.widgetWithIcon(AppBar, Icons.arrow_back), findsNothing);
    });
  });
}

class MockSubscriptionListNotifier extends SubscriptionListNotifier {
  final List<Subscription> initialSubs;
  MockSubscriptionListNotifier(this.initialSubs);

  @override
  SubscriptionListState build() {
    return SubscriptionListState(
      allSubscriptions: initialSubs,
      isLoading: false,
    );
  }

  @override
  Future<void> refresh() async {}
}
