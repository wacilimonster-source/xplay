import 'package:flutter_riverpod/flutter_riverpod.dart';

enum MainTab { media, subscriptions, trending }

class NavigationState {
  final MainTab currentTab;
  final String? selectedUser; // If not null, show UserDetails or UserMediaFeed
  final int? userMediaInitialIndex;
  final String? userMediaInitialTweetId;
  final String? selectedHashtag;

  /// The topic feed the user was viewing when they opened a profile.
  /// Selecting a user used to clear `selectedHashtag` as well, so pressing back
  /// dumped the user on the main feed and the topic (with its scroll position)
  /// was simply gone.
  final String? originHashtag;

  NavigationState({
    this.currentTab = MainTab.media,
    this.selectedUser,
    this.userMediaInitialIndex,
    this.userMediaInitialTweetId,
    this.selectedHashtag,
    this.originHashtag,
  });

  NavigationState copyWith({
    MainTab? currentTab,
    String? selectedUser,
    int? userMediaInitialIndex,
    String? userMediaInitialTweetId,
    String? selectedHashtag,
    String? originHashtag,
    bool clearUser = false,
    bool clearMediaIndex = false,
    bool clearHashtag = false,
    bool clearOriginHashtag = false,
  }) {
    return NavigationState(
      currentTab: currentTab ?? this.currentTab,
      selectedUser: clearUser ? null : (selectedUser ?? this.selectedUser),
      userMediaInitialIndex: (clearUser || clearMediaIndex)
          ? null
          : (userMediaInitialIndex ?? this.userMediaInitialIndex),
      userMediaInitialTweetId: (clearUser || clearMediaIndex)
          ? null
          : (userMediaInitialTweetId ?? this.userMediaInitialTweetId),
      selectedHashtag:
          clearHashtag ? null : (selectedHashtag ?? this.selectedHashtag),
      originHashtag: clearOriginHashtag
          ? null
          : (originHashtag ?? this.originHashtag),
    );
  }
}

class NavigationNotifier extends Notifier<NavigationState> {
  @override
  NavigationState build() => NavigationState();

  void setTab(MainTab tab) {
    state = state.copyWith(
        currentTab: tab,
        clearUser: true,
        clearHashtag: true,
        clearOriginHashtag: true);
  }

  void selectUser(String screenName) {
    state = state.copyWith(
        selectedUser: screenName,
        clearMediaIndex: true,
        clearHashtag: true,
        originHashtag: state.selectedHashtag);
  }

  void openUserMedia(String screenName, int index, {String? tweetId}) {
    state = state.copyWith(
        selectedUser: screenName,
        userMediaInitialIndex: index,
        userMediaInitialTweetId: tweetId,
        clearHashtag: true,
        originHashtag: state.selectedHashtag);
  }

  void selectHashtag(String hashtag) {
    state = state.copyWith(selectedHashtag: hashtag);
  }

  void back() {
    if (state.selectedHashtag != null) {
      state = state.copyWith(clearHashtag: true);
    } else if (state.userMediaInitialIndex != null) {
      state = state.copyWith(clearMediaIndex: true);
    } else if (state.selectedUser != null) {
      final origin = state.originHashtag;
      state = state.copyWith(
        clearUser: true,
        clearOriginHashtag: true,
        // Reopen the topic feed we came from (explicit assignment, because
        // `clearUser` also nulls `selectedHashtag`).
        selectedHashtag: origin,
      );
    }
  }
}

final navigationProvider =
    NotifierProvider<NavigationNotifier, NavigationState>(
  NavigationNotifier.new,
);
