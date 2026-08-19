import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/models/tweet.dart';
import '../../../core/utils/media_cache_manager.dart';
import '../../../core/utils/app_logger.dart';
import '../../feed/widgets/text_tweet_card.dart';
import '../player_pool_provider.dart';
import '../../settings/settings_provider.dart';
import '../../feed/feed_provider.dart';

class TiktokMediaContainer extends ConsumerStatefulWidget {
  final Tweet tweet;
  final bool isVisible;
  final bool autoFullscreen;
  final Widget Function(
          BuildContext context, VoidCallback? onFullscreen, bool isFullscreen)?
      overlayBuilder;
  final VoidCallback? onPlaybackError;

  const TiktokMediaContainer({
    super.key,
    required this.tweet,
    required this.isVisible,
    this.autoFullscreen = false,
    this.overlayBuilder,
    this.onPlaybackError,
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
  StreamSubscription? _durationSubscription;
  PlayerInstance? _subscribedInstance;
  bool _resumeRestored = false;

  static const String _resumePrefix = 'xplay_resume_pos_';

  void _clearSubscriptions() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _durationSubscription?.cancel();
    _errorSubscription = null;
    _completedSubscription = null;
    _durationSubscription = null;
    _subscribedInstance = null;
  }

  void _bindSubscriptions(PlayerInstance instance) {
    if (identical(_subscribedInstance, instance)) return;
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _durationSubscription?.cancel();
    _errorSubscription = instance.player.stream.error.listen(_handleError);
    _completedSubscription =
        instance.player.stream.completed.listen((completed) {
      if (completed) _handleCompleted();
    });
    _resumeRestored = false;
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
        prefs.setInt(
            '$_resumePrefix${widget.tweet.id}', pos.inMilliseconds);
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
    }
  }

  @override
  void dispose() {
    if (_subscribedInstance != null) {
      _savePosition(_subscribedInstance!);
    }
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _durationSubscription?.cancel();
    super.dispose();
  }

  void _handleCompleted() async {
    if (!mounted || !widget.isVisible) return;

    // Exit fullscreen if active when video completes
    final state = _videoKey.currentState;
    if (state != null && state.isFullscreen()) {
      await state.exitFullscreen();
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
    final settings = ref.read(settingsProvider);

    // Exit fullscreen on error
    final state = _videoKey.currentState;
    if (state != null && state.isFullscreen()) {
      await state.exitFullscreen();
    }

    if (_retryCount < settings.playbackRetryLimit) {
      _retryCount++;
      AppLogger.log(
          'XFLOW: Video playback error. Retrying ($_retryCount/${settings.playbackRetryLimit})... Error: $error');

      final pool = ref.read(playerPoolProvider);
      final instance = pool[widget.tweet.id];
      if (instance != null) {
        // Re-open media to retry
        instance.player
            .open(Media(widget.tweet.mediaUrls.first), play: widget.isVisible);
      }
    } else {
      AppLogger.log('XFLOW: Video playback failed after retry. Skipping item.');
      widget.onPlaybackError?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tweet.mediaUrls.isEmpty) {
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
                children: List.generate(widget.tweet.mediaUrls.length, (index) {
                  return Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _imageIndex == index
                          ? Colors.white
                          : Colors.white.withOpacity(0.4),
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

    final pool = ref.watch(playerPoolProvider);
    final instance = pool[widget.tweet.id];

    if (instance == null) {
      _clearSubscriptions();
      return const Center(child: CircularProgressIndicator());
    }

    final settings = ref.watch(settingsProvider);

    // Re-bind event subscriptions whenever the pool hands out a new instance
    // for this tweet id (the old one was disposed by the pool).
    _bindSubscriptions(instance);

    if (widget.isVisible) {
      if (settings.autoplay) {
        instance.player.play();
      }
    } else {
      _savePosition(instance);
      instance.player.pause();
    }
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) async {
        final state = _videoKey.currentState;
        if (state != null && state.isFullscreen()) {
          await state.exitFullscreen();
        }
      },
      child: StreamBuilder(
        stream: instance.player.stream.error,
        builder: (context, snapshot) {
          if (snapshot.hasData && _retryCount >= settings.playbackRetryLimit) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.white70, size: 48),
                  const SizedBox(height: 16),
                  const Text('播放失败，正在切换到下一条...',
                      style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  Text('错误：${snapshot.data}',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            );
          }

          // Determine orientation based on current player state
          Future<void> onFullscreen() async {
            final state = _videoKey.currentState;
            if (state != null) {
              try {
                if (state.isFullscreen()) {
                  await state.exitFullscreen();
                } else {
                  // 1. Get latest dimensions
                  final width = instance.player.state.width;
                  final height = instance.player.state.height;

                  // Use aspect ratio for better detection.
                  // Default to portrait (isLandscape = false) if dimensions are missing or invalid.
                  final double aspectRatio =
                      (width != null && height != null && height != 0)
                          ? width / height
                          : 0.0;
                  final isLandscape = aspectRatio > 1.0;

                  AppLogger.log(
                      'XFLOW: Fullscreen toggle. ID: ${widget.tweet.id} W: $width H: $height AR: $aspectRatio Landscape: $isLandscape');

                  // 2. Start orientation change immediately
                  if (isLandscape) {
                    await SystemChrome.setPreferredOrientations([
                      DeviceOrientation.landscapeLeft,
                      DeviceOrientation.landscapeRight,
                    ]);
                  } else {
                    await SystemChrome.setPreferredOrientations([
                      DeviceOrientation.portraitUp,
                    ]);
                  }

                  // 3. Enter fullscreen
                  await state.enterFullscreen();
                }
              } catch (e) {
                AppLogger.log('XFLOW: Error toggling fullscreen: $e');
              }
            }
          }

          // Handle auto-fullscreen if requested
          if (widget.isVisible &&
              widget.autoFullscreen &&
              !_isAutoFullscreenDone) {
            _isAutoFullscreenDone = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                final state = _videoKey.currentState;
                if (state != null && !state.isFullscreen()) {
                  onFullscreen();
                }
              }
            });
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
                              color: Colors.black.withOpacity(0.5),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0, vertical: 8.0),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  const MaterialSeekBar(),
                                  Row(
                                    children: [
                                      const MaterialPositionIndicator(),
                                      const Spacer(),
                                      // Like Button
                                      MaterialCustomButton(
                                        onPressed: () {
                                          ref
                                              .read(
                                                  feedNotifierProvider.notifier)
                                              .toggleLike(widget.tweet.id);
                                        },
                                        icon: Consumer(
                                          builder: (context, ref, child) {
                                            final isLiked = ref.watch(
                                                feedNotifierProvider.select(
                                                    (s) =>
                                                        s.value?.tweets
                                                            .firstWhere((t) =>
                                                                t.id ==
                                                                widget.tweet.id)
                                                            .isLiked ??
                                                        false));
                                            return Icon(
                                              isLiked
                                                  ? Icons.favorite
                                                  : Icons.favorite_border,
                                              color: isLiked
                                                  ? Colors.red
                                                  : Colors.white,
                                            );
                                          },
                                        ),
                                      ),
                                      // Exit Fullscreen Button
                                      MaterialCustomButton(
                                        onPressed: onFullscreen,
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
                        controls: (state) {
                          if (state.isFullscreen()) {
                            return MaterialVideoControls(state);
                          }
                          return Stack(
                            children: [
                              GestureDetector(
                                onTap: () {
                                  if (instance.player.state.playing) {
                                    instance.player.pause();
                                  } else {
                                    instance.player.play();
                                  }
                                },
                                behavior: HitTestBehavior.opaque,
                              ),
                              if (widget.overlayBuilder != null)
                                Positioned.fill(
                                  child: widget.overlayBuilder!(
                                    context,
                                    onFullscreen,
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
        },
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
    if (widget.tweet.mediaUrls.length == 1) {
      return SizedBox.expand(
        child: Center(
          child: CachedNetworkImage(
            cacheManager: CustomMediaCacheManager.getInstance(),
            imageUrl: widget.tweet.mediaUrls.first,
            fit: BoxFit.contain,
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
