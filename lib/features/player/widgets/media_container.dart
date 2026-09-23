import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/models/tweet.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/lifecycle_provider.dart';
import '../../../core/utils/media_cache_manager.dart';
import '../../feed/widgets/text_tweet_card.dart';
import '../player_pool_provider.dart';
import '../../settings/settings_provider.dart';
import '../../feed/feed_provider.dart';

class TiktokMediaContainer extends ConsumerStatefulWidget {
  final Tweet tweet;

  /// True when this item is the one currently on screen *and* its screen is the
  /// active one (the feed screens fold "app is foregrounded" into this too).
  final bool isVisible;
  final bool autoFullscreen;
  final Widget Function(
          BuildContext context, VoidCallback? onFullscreen, bool isFullscreen)?
      overlayBuilder;
  final VoidCallback? onPlaybackError;

  /// Which feed screen owns this item's player, so a clean-up on one screen
  /// cannot dispose another screen's live player.
  final String poolScope;

  const TiktokMediaContainer({
    super.key,
    required this.tweet,
    required this.isVisible,
    this.autoFullscreen = false,
    this.overlayBuilder,
    this.onPlaybackError,
    this.poolScope = 'home',
  });

  @override
  ConsumerState<TiktokMediaContainer> createState() =>
      _TiktokMediaContainerState();
}

class _TiktokMediaContainerState extends ConsumerState<TiktokMediaContainer> {
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  int _imageIndex = 0;
  int _retryCount = 0;
  bool _isAutoFullscreenDone = false;
  StreamSubscription? _errorSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  PlayerInstance? _subscribedInstance;
  bool _resumeRestored = false;

  /// Set when the user taps to pause; cleared when a new item becomes visible.
  bool _userPaused = false;

  /// Last playback error. Kept in state (not in a `StreamBuilder` snapshot) so
  /// it disappears once playback recovers: the old code showed the *first*
  /// error forever, so a retried video kept displaying "播放失败".
  String? _playbackError;

  static const String _resumePrefix = 'xplay_resume_pos_';

  void _clearSubscriptions() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _errorSubscription = null;
    _completedSubscription = null;
    _positionSubscription = null;
    _durationSubscription = null;
    _subscribedInstance = null;
  }

  void _bindSubscriptions(PlayerInstance instance) {
    if (identical(_subscribedInstance, instance)) return;
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _errorSubscription = instance.player.stream.error.listen(_handleError);
    _completedSubscription =
        instance.player.stream.completed.listen((completed) {
      if (completed) _handleCompleted();
    });
    // Progressing means the stream is healthy: drop the stale error and give the
    // retry budget back. Otherwise one early hiccup marked the item as failed
    // for the rest of its life and the next error skipped without retrying.
    _positionSubscription = instance.player.stream.position.listen((pos) {
      if (pos > Duration.zero &&
          (_playbackError != null || _retryCount != 0) &&
          mounted) {
        setState(() {
          _playbackError = null;
          _retryCount = 0;
        });
      }
    });
    _resumeRestored = false;
    _playbackError = null;
    _retryCount = 0;
    _durationSubscription = instance.player.stream.duration.listen((d) {
      if (_resumeRestored || d <= Duration.zero) return;
      _resumeRestored = true;
      _restorePosition(instance);
    });
    _subscribedInstance = instance;
  }

  /// Persists the current playback position so the video can resume later.
  void _savePosition(PlayerInstance instance) {
    final pos = instance.player.state.position;
    final dur = instance.player.state.duration;
    SharedPreferences.getInstance().then((prefs) {
      if (dur > Duration.zero &&
          pos > const Duration(seconds: 5) &&
          dur - pos > const Duration(seconds: 3)) {
        prefs.setInt('$_resumePrefix${widget.tweet.id}', pos.inMilliseconds);
      } else {
        prefs.remove('$_resumePrefix${widget.tweet.id}');
      }
    });
  }

  /// Seeks to the saved position (if any) and clears it.
  Future<void> _restorePosition(PlayerInstance instance) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt('$_resumePrefix${widget.tweet.id}');
      final dur = instance.player.state.duration;
      if (saved != null &&
          saved > 0 &&
          dur > Duration.zero &&
          saved < dur.inMilliseconds - 3000) {
        AppLogger.log(
            'XFLOW: Resuming ${widget.tweet.id} at ${Duration(milliseconds: saved)}');
        await instance.player.seek(Duration(milliseconds: saved));
      }
      await prefs.remove('$_resumePrefix${widget.tweet.id}');
    } catch (e) {
      AppLogger.log('XFLOW: Resume failed: $e');
    }
  }

  @override
  void didUpdateWidget(TiktokMediaContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isVisible && widget.isVisible) {
      _isAutoFullscreenDone = false;
      _userPaused = false;
    }
    if (oldWidget.tweet.id != widget.tweet.id) {
      // This element is showing a different tweet (no key on the widget): never
      // inherit the previous item's error panel, page index or pause state.
      _imageIndex = 0;
      _retryCount = 0;
      _playbackError = null;
      _userPaused = false;
      _resumeRestored = false;
    }
  }

  @override
  void dispose() {
    if (_subscribedInstance != null) {
      _savePosition(_subscribedInstance!);
    }
    _clearSubscriptions();
    super.dispose();
  }

  /// Starts or stops playback *outside* of `build()`, and only when the desired
  /// state actually differs from the player's.
  ///
  /// The old code called `play()`/`pause()`/`_savePosition()` inline while
  /// building: every rebuild (pool change, tab switch, like) resumed a video the
  /// user had paused, and every off-screen item wrote to SharedPreferences per
  /// frame — visible as stutter while scrolling.
  void _syncPlayback(bool appActive) {
    final pool = ref.read(playerPoolProvider);
    final instance = pool[widget.tweet.id];
    if (instance == null) return;

    final shouldPlay = widget.isVisible &&
        appActive &&
        !_userPaused &&
        ref.read(settingsProvider).autoplay &&
        _playbackError == null;
    final isPlaying = instance.player.state.playing;
    if (shouldPlay == isPlaying) return;

    if (shouldPlay) {
      instance.player.play();
    } else {
      _savePosition(instance);
      instance.player.pause();
    }
  }

  void _handleCompleted() async {
    if (!mounted || !widget.isVisible) return;

    // Exit fullscreen if active when video completes
    final state = _videoKey.currentState;
    if (state != null && state.isFullscreen()) {
      await state.exitFullscreen();
      if (!mounted) return;
    }

    final settings = ref.read(settingsProvider);
    switch (settings.videoEndAction) {
      case VideoEndAction.pause:
        // Already stopped at the end
        break;
      case VideoEndAction.replay:
        final pool = ref.read(playerPoolProvider);
        final instance = pool[widget.tweet.id];
        instance?.player.seek(Duration.zero);
        instance?.player.play();
        break;
      case VideoEndAction.playNext:
        widget.onPlaybackError
            ?.call(); // Re-use the same callback for auto-advance
        break;
    }
  }

  void _handleError(dynamic error) async {
    if (!mounted) return;
    final settings = ref.read(settingsProvider);

    // Exit fullscreen on error
    final state = _videoKey.currentState;
    if (state != null && state.isFullscreen()) {
      await state.exitFullscreen();
      if (!mounted) return;
    }

    if (_retryCount < settings.playbackRetryLimit) {
      _retryCount++;
      AppLogger.log(
          'XFLOW: Video playback error. Retrying ($_retryCount/${settings.playbackRetryLimit})... Error: $error');
      if (mounted) setState(() => _playbackError = null);

      final pool = ref.read(playerPoolProvider);
      final instance = pool[widget.tweet.id];
      if (instance != null) {
        // Re-open media to retry
        await instance.player.open(Media(widget.tweet.mediaUrls.first),
            play: widget.isVisible);
      }
      return;
    }

    AppLogger.log('XFLOW: Video playback failed after retry. Skipping item.');
    if (!mounted) return;
    setState(() => _playbackError = error.toString());
    widget.onPlaybackError?.call();
  }

  Future<void> _toggleUserPause(PlayerInstance instance) async {
    final playing = instance.player.state.playing;
    if (!mounted) return;
    setState(() => _userPaused = playing);
    if (playing) {
      await instance.player.pause();
    } else {
      if (mounted) setState(() => _playbackError = null);
      await instance.player.play();
    }
  }

  /// Fullscreen toggle for the button/overlay path. Orientation itself is
  /// applied by the `Video.onEnterFullscreen` handler, which media_kit runs
  /// *after* pushing the fullscreen route — the default implementation there
  /// forces landscape, which is why portrait videos used to flip sideways.
  Future<void> _enterFullscreen(PlayerInstance instance) async {
    final state = _videoKey.currentState;
    if (state == null) return;
    if (state.isFullscreen()) {
      await state.exitFullscreen();
    } else {
      await state.enterFullscreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watching a derived bool (not the enum) keeps this unconditional and still
    // lets a background/lock transition pause playback, while `inactive` ->
    // `hidden` transitions no longer rebuild every visible video.
    final appActive = ref.watch(
        lifecycleProvider.select((l) => l == AppLifecycle.resumed));

    if (widget.tweet.mediaUrls.isEmpty) {
      _scheduleSync(appActive);
      return Stack(
        children: [
          TextTweetCard(text: widget.tweet.text),
          if (widget.overlayBuilder != null)
            Positioned.fill(
                child: widget.overlayBuilder!(context, null, false)),
        ],
      );
    }

    if (!widget.tweet.isVideo) {
      _scheduleSync(appActive);
      return Stack(
        children: [
          _buildImageGallery(),
          if (widget.tweet.mediaUrls.length > 1)
            Positioned(
              bottom: 120, // Above the text overlay
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children:
                    List.generate(widget.tweet.mediaUrls.length, (index) {
                  return Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _imageIndex == index
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.4),
                    ),
                  );
                }),
              ),
            ),
          if (widget.overlayBuilder != null)
            Positioned.fill(
                child: widget.overlayBuilder!(context, null, false)),
        ],
      );
    }

    // Select this tweet's player only: the whole pool map changes whenever any
    // item is warmed or released, and rebuilding every video on that was both
    // wasted work and the reason a paused video could flicker back to playing.
    final instance =
        ref.watch(playerPoolProvider.select((p) => p[widget.tweet.id]));

    if (instance == null) {
      _clearSubscriptions();
      // The pool released this player (another screen's clean-up, an LRU
      // eviction, or scrolling back into range). Re-create it after the frame
      // instead of spinning forever with no way out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(playerPoolProvider.notifier).warmup(
              widget.tweet.id,
              widget.tweet.mediaUrls.first,
              scope: widget.poolScope,
            );
      });
      return const Center(child: CircularProgressIndicator());
    }

    // Re-bind event subscriptions whenever the pool hands out a new instance
    // for this tweet id (the old one was disposed by the pool).
    _bindSubscriptions(instance);
    _scheduleSync(appActive);

    if (widget.isVisible &&
        widget.autoFullscreen &&
        !_isAutoFullscreenDone) {
      _isAutoFullscreenDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final state = _videoKey.currentState;
        if (state != null && !state.isFullscreen()) {
          _enterFullscreen(instance);
        }
      });
    }

    final error = _playbackError;
    if (error != null) {
      return _buildErrorPanel(instance, error);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Center(
            child: RepaintBoundary(
              child: MaterialVideoControlsTheme(
                normal: const MaterialVideoControlsThemeData(
                  displaySeekBar: false,
                  automaticallyImplySkipNextButton: false,
                  automaticallyImplySkipPreviousButton: false,
                ),
                fullscreen: MaterialVideoControlsThemeData(
                  displaySeekBar: false, // Custom layout below
                  automaticallyImplySkipNextButton: false,
                  automaticallyImplySkipPreviousButton: false,
                  buttonBarHeight: 100.0,
                  bottomButtonBarMargin: EdgeInsets.zero,
                  primaryButtonBar: [
                    const Spacer(),
                    const MaterialPlayOrPauseButton(iconSize: 64),
                    const Spacer(),
                  ],
                  bottomButtonBar: [
                    Expanded(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.5),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            const MaterialSeekBar(),
                            Row(
                              children: [
                                const MaterialPositionIndicator(),
                                const Spacer(),
                                MaterialCustomButton(
                                  onPressed: () {
                                    ref
                                        .read(feedNotifierProvider.notifier)
                                        .toggleLike(widget.tweet.id);
                                  },
                                  icon: TweetLikeIcon(tweetId: widget.tweet.id),
                                ),
                                MaterialCustomButton(
                                  onPressed: () => _enterFullscreen(instance),
                                  icon: const Icon(Icons.fullscreen_exit),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                child: Video(
                  key: _videoKey,
                  controller: instance.controller,
                  fit: BoxFit.contain,
                  onEnterFullscreen: () => _enterFullscreenNoDefault(instance),
                  controls: (state) {
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: () => _toggleUserPause(instance),
                            behavior: HitTestBehavior.opaque,
                            // A GestureDetector with no child has zero size, so
                            // its onTap could never be hit and tapping to pause
                            // did nothing at all.
                            child: const SizedBox.expand(),
                          ),
                        ),
                        if (widget.overlayBuilder != null)
                          Positioned.fill(
                            child: widget.overlayBuilder!(
                              context,
                              () => _enterFullscreen(instance),
                              false,
                            ),
                          ),
                      ],
                    );
                  },
                  onExitFullscreen: () async {
                    await SystemChrome.setPreferredOrientations([
                      DeviceOrientation.portraitUp,
                    ]);
                  },
                ),
              ),
            ),
          ),
        ),
        // Progress Bar at the very bottom
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _buildProgressBar(instance),
        ),
      ],
    );
  }

  void _scheduleSync(bool appActive) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPlayback(appActive);
    });
  }

  /// `Video.onEnterFullscreen` runs *in addition to* media_kit pushing the
  /// fullscreen route, so it must only fix the orientation/immersive state and
  /// not call `enterFullscreen()` again.
  Future<void> _enterFullscreenNoDefault(PlayerInstance instance) async {
    final width = instance.player.state.width ?? widget.tweet.mediaWidth;
    final height = instance.player.state.height ?? widget.tweet.mediaHeight;
    final aspectRatio =
        (width != null && height != null && height > 0) ? width / height : 0.0;
    final isLandscape = aspectRatio > 1.0;
    AppLogger.log(
        'XFLOW: Fullscreen orientation. ID: ${widget.tweet.id} W: $width H: $height Landscape: $isLandscape');
    try {
      await SystemChrome.setPreferredOrientations(isLandscape
          ? [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight
            ]
          : [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky,
          overlays: []);
    } catch (e) {
      AppLogger.log('XFLOW: Error applying fullscreen orientation: $e');
    }
  }

  Widget _buildErrorPanel(PlayerInstance instance, String error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 48),
          const SizedBox(height: 16),
          const Text('播放失败，正在切换到下一条...',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text('错误：$error',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              setState(() {
                _playbackError = null;
                _retryCount = 0;
                _userPaused = false;
              });
              instance.player
                  .open(Media(widget.tweet.mediaUrls.first), play: true);
            },
            child:
                const Text('重试', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(PlayerInstance instance) {
    return StreamBuilder<Duration>(
      stream: instance.player.stream.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final duration = instance.player.state.duration;

        if (duration == Duration.zero) return const SizedBox.shrink();

        final progress = position.inMilliseconds / duration.inMilliseconds;

        String fmt(Duration d) {
          final h = d.inHours;
          final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
          final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
          return h > 0 ? '$h:$m:$s' : '$m:$s';
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final width = context.size?.width ?? 1;
            if (width <= 0) return;
            final ratio = (details.localPosition.dx / width).clamp(0.0, 1.0);
            final target = Duration(
                milliseconds: (duration.inMilliseconds * ratio).round());
            instance.player.seek(target);
          },
          onHorizontalDragUpdate: (details) {
            final width = context.size?.width ?? 1;
            if (width <= 0) return;
            final ratio = (details.localPosition.dx / width).clamp(0.0, 1.0);
            final target = Duration(
                milliseconds: (duration.inMilliseconds * ratio).round());
            instance.player.seek(target);
          },
          child: Container(
            height: 28,
            color: Colors.transparent,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 2,
                  width: double.infinity,
                  color: Colors.white12,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(color: Colors.white),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      fmt(position),
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          shadows: [
                            Shadow(
                                offset: Offset(0, 1),
                                blurRadius: 2,
                                color: Colors.black54),
                          ]),
                    ),
                    const Spacer(),
                    Text(
                      fmt(duration),
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          shadows: [
                            Shadow(
                                offset: Offset(0, 1),
                                blurRadius: 2,
                                color: Colors.black54),
                          ]),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildImageGallery() {
    // Decode at roughly twice the on-screen width. Without a downscale target a
    // 4096px photo is decoded full-size per item, which drops frames or kills
    // low-memory devices. Only the width is capped so the aspect ratio (and thus
    // BoxFit.contain) stays intact.
    final targetWidth =
        (MediaQuery.of(context).size.width * 2).clamp(600, 1600).round();

    if (widget.tweet.mediaUrls.length == 1) {
      return SizedBox.expand(
        child: Center(
          child: CachedNetworkImage(
            cacheManager: CustomMediaCacheManager.getInstance(),
            imageUrl: widget.tweet.mediaUrls.first,
            fit: BoxFit.contain,
            memCacheWidth: targetWidth,
            placeholder: (context, url) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (context, url, error) => const Icon(Icons.error),
          ),
        ),
      );
    }

    return PageView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: widget.tweet.mediaUrls.length,
      onPageChanged: (index) {
        if (!mounted) return;
        setState(() {
          _imageIndex = index;
        });
      },
      itemBuilder: (context, index) {
        return SizedBox.expand(
          child: Center(
            child: CachedNetworkImage(
              cacheManager: CustomMediaCacheManager.getInstance(),
              imageUrl: widget.tweet.mediaUrls[index],
              fit: BoxFit.contain,
              memCacheWidth: targetWidth,
              placeholder: (context, url) =>
                  const Center(child: CircularProgressIndicator()),
              errorWidget: (context, url, error) => const Icon(Icons.error),
            ),
          ),
        );
      },
    );
  }
}

/// Heart icon for the fullscreen control bar. Shows the state the feed actually
/// holds for this tweet (including an optimistic like and its revert).
class TweetLikeIcon extends ConsumerWidget {
  const TweetLikeIcon({super.key, required this.tweetId});
  final String tweetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLiked = ref.watch(tweetIsLikedProvider(tweetId));
    return Icon(
      isLiked ? Icons.favorite : Icons.favorite_border,
      color: isLiked ? Colors.red : Colors.white,
    );
  }
}
