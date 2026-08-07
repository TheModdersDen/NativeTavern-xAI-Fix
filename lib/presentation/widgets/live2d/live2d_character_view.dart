import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_live2d/flutter_live2d.dart';
import 'package:native_tavern/core/utils/path_utils.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/presentation/widgets/live2d/macos_live2d_view.dart';

abstract interface class _NativeLive2DController {
  ValueListenable<Live2DViewState> get listenable;
  Live2DViewState get value;
  Future<void> get whenAttached;
  Future<bool> loadModel({
    required String modelDir,
    required String modelFileName,
  });
  Future<void> setRenderingPaused(bool paused);
  Future<void> startMotion({
    required String group,
    int index,
    int priority,
  });
  Future<void> setParameter(String parameterId, double value);
  Future<void> setMotionSpeed(double speed);
  Widget buildView();
  void dispose();
}

class _MobileLive2DController implements _NativeLive2DController {
  final Live2DViewController _controller = Live2DViewController();

  @override
  ValueListenable<Live2DViewState> get listenable => _controller;

  @override
  Live2DViewState get value => _controller.value;

  @override
  Future<void> get whenAttached => _controller.whenAttached;

  @override
  Future<bool> loadModel({
    required String modelDir,
    required String modelFileName,
  }) =>
      _controller.loadModel(
        modelDir: modelDir,
        modelFileName: modelFileName,
      );

  @override
  Future<void> setRenderingPaused(bool paused) =>
      _controller.setRenderingPaused(paused);

  @override
  Future<void> startMotion({
    required String group,
    int index = 0,
    int priority = 2,
  }) =>
      _controller.startMotion(
        group: group,
        index: index,
        priority: priority,
      );

  @override
  Future<void> setParameter(String parameterId, double value) =>
      _controller.setParameter(parameterId, value);

  @override
  Future<void> setMotionSpeed(double speed) =>
      _controller.setMotionSpeed(speed);

  @override
  Widget buildView() => Live2DView(controller: _controller);

  @override
  void dispose() => _controller.dispose();
}

class _MacOSLive2DController implements _NativeLive2DController {
  final MacOSLive2DViewController _controller = MacOSLive2DViewController();

  @override
  ValueListenable<Live2DViewState> get listenable => _controller;

  @override
  Live2DViewState get value => _controller.value;

  @override
  Future<void> get whenAttached => _controller.whenAttached;

  @override
  Future<bool> loadModel({
    required String modelDir,
    required String modelFileName,
  }) =>
      _controller.loadModel(
        modelDir: modelDir,
        modelFileName: modelFileName,
      );

  @override
  Future<void> setRenderingPaused(bool paused) =>
      _controller.setRenderingPaused(paused);

  @override
  Future<void> startMotion({
    required String group,
    int index = 0,
    int priority = 2,
  }) =>
      _controller.startMotion(
        group: group,
        index: index,
        priority: priority,
      );

  @override
  Future<void> setParameter(String parameterId, double value) =>
      _controller.setParameter(parameterId, value);

  @override
  Future<void> setMotionSpeed(double speed) =>
      _controller.setMotionSpeed(speed);

  @override
  Widget buildView() => MacOSLive2DView(controller: _controller);

  @override
  void dispose() => _controller.dispose();
}

/// A stable app-level controller for motion playback and future TTS lip sync.
class Live2DCharacterController {
  _NativeLive2DController? _nativeController;
  String _lipSyncParameter = 'ParamMouthOpenY';

  bool get isReady => _nativeController?.value.isLoaded ?? false;

  void _attach(
    _NativeLive2DController controller,
    String lipSyncParameter,
  ) {
    _nativeController = controller;
    _lipSyncParameter = lipSyncParameter;
  }

  void _detach(_NativeLive2DController controller) {
    if (identical(_nativeController, controller)) _nativeController = null;
  }

  Future<bool> playMotion(Live2DMotionRef? motion, {int priority = 2}) async {
    final controller = _nativeController;
    if (controller == null || !controller.value.isLoaded || motion == null) {
      return false;
    }
    try {
      await controller.startMotion(
        group: motion.group,
        index: motion.index,
        priority: priority,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Values are clamped to the standard Cubism mouth-open range.
  Future<bool> setMouthOpen(double value) async {
    final controller = _nativeController;
    if (controller == null || !controller.value.isLoaded) return false;
    try {
      await controller.setParameter(_lipSyncParameter, value.clamp(0, 1));
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Transparent Live2D stage with lifecycle, motion, and graceful fallback.
class Live2DStageTransform {
  final double scale;
  final double offsetX;
  final double offsetY;

  const Live2DStageTransform({
    required this.scale,
    required this.offsetX,
    required this.offsetY,
  });
}

class Live2DCharacterView extends StatefulWidget {
  final Live2DConfig config;
  final bool isSpeaking;
  final Live2DCharacterController? controller;
  final Widget? fallback;
  final bool showStatus;
  final bool interactive;
  final ValueChanged<Live2DStageTransform>? onTransformChanged;

  const Live2DCharacterView({
    super.key,
    required this.config,
    this.isSpeaking = false,
    this.controller,
    this.fallback,
    this.showStatus = false,
    this.interactive = false,
    this.onTransformChanged,
  });

  static bool get isPlatformSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  State<Live2DCharacterView> createState() => _Live2DCharacterViewState();
}

class _Live2DCharacterViewState extends State<Live2DCharacterView>
    with WidgetsBindingObserver {
  static const double _minScale = 0.1;
  static const double _maxScale = 10;
  static const double _maxOffset = 10;

  late final _NativeLive2DController _nativeController;
  Timer? _returnToIdleTimer;
  Timer? _scrollSaveTimer;
  String? _loadError;
  int _loadGeneration = 0;
  double _stageScale = 1;
  double _offsetX = 0;
  double _offsetY = 0;
  double _gestureStartScale = 1;
  bool _transformDirty = false;

  @override
  void initState() {
    super.initState();
    _nativeController =
        Platform.isMacOS ? _MacOSLive2DController() : _MobileLive2DController();
    _stageScale = widget.config.scale.clamp(_minScale, _maxScale);
    _offsetX = widget.config.offsetX.clamp(-_maxOffset, _maxOffset);
    _offsetY = widget.config.offsetY.clamp(-_maxOffset, _maxOffset);
    WidgetsBinding.instance.addObserver(this);
    if (Live2DCharacterView.isPlatformSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadModel());
    }
  }

  @override
  void didUpdateWidget(Live2DCharacterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldConfig = oldWidget.config;
    final config = widget.config;
    if (oldConfig.scale != config.scale ||
        oldConfig.offsetX != config.offsetX ||
        oldConfig.offsetY != config.offsetY) {
      _stageScale = config.scale.clamp(_minScale, _maxScale);
      _offsetX = config.offsetX.clamp(-_maxOffset, _maxOffset);
      _offsetY = config.offsetY.clamp(-_maxOffset, _maxOffset);
    }
    if (oldConfig.modelDirectory != config.modelDirectory ||
        oldConfig.modelFileName != config.modelFileName) {
      _loadModel();
      return;
    }
    if (oldConfig.motionSpeed != config.motionSpeed &&
        _nativeController.value.isLoaded) {
      unawaited(_nativeController.setMotionSpeed(config.motionSpeed));
    }
    if (oldWidget.isSpeaking != widget.isSpeaking) {
      _handleSpeakingChanged();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_nativeController.value.isAttached) return;
    final paused = state != AppLifecycleState.resumed;
    unawaited(_nativeController.setRenderingPaused(paused).catchError((_) {}));
  }

  @override
  void reassemble() {
    super.reassemble();
    if (Live2DCharacterView.isPlatformSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadModel());
    }
  }

  Future<void> _loadModel() async {
    if (!Live2DCharacterView.isPlatformSupported) return;
    final generation = ++_loadGeneration;
    _returnToIdleTimer?.cancel();
    if (mounted) setState(() => _loadError = null);

    try {
      await _nativeController.whenAttached;
      if (!mounted || generation != _loadGeneration) return;
      final modelDirectory = await _resolveModelDirectory();
      final loaded = await _nativeController.loadModel(
        modelDir: modelDirectory,
        modelFileName: widget.config.modelFileName,
      );
      if (!mounted || generation != _loadGeneration) return;
      if (!loaded) {
        setState(() {
          _loadError = _nativeController.value.lastError?.message ??
              'The model could not be loaded.';
        });
        return;
      }
      await _nativeController.setMotionSpeed(widget.config.motionSpeed);
      widget.controller?._attach(
        _nativeController,
        widget.config.lipSyncParameter,
      );
      if (widget.isSpeaking) {
        await _play(widget.config.speakingMotion, priority: 2);
      } else {
        await _play(widget.config.idleMotion, priority: 1);
      }
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loadError = error.toString());
      }
    }
  }

  Future<String> _resolveModelDirectory() async {
    if (widget.config.source != Live2DModelSource.appData) {
      return widget.config.modelDirectory;
    }
    final dataPath = await PathUtils.getDataPath();
    return '$dataPath/${widget.config.modelDirectory}';
  }

  void _handleSpeakingChanged() {
    _returnToIdleTimer?.cancel();
    if (widget.isSpeaking) {
      unawaited(_play(widget.config.speakingMotion, priority: 2));
      return;
    }

    unawaited(_play(widget.config.responseMotion, priority: 2));
    _scheduleIdle(const Duration(milliseconds: 2200));
  }

  Future<void> _play(Live2DMotionRef? motion, {required int priority}) async {
    if (motion == null || !_nativeController.value.isLoaded) return;
    try {
      await _nativeController.startMotion(
        group: motion.group,
        index: motion.index,
        priority: priority,
      );
    } catch (_) {
      // A failed optional motion should not replace a successfully loaded model.
    }
  }

  void _handleTap() {
    _returnToIdleTimer?.cancel();
    unawaited(_play(widget.config.tapMotion, priority: 3));
    _scheduleIdle(const Duration(milliseconds: 2600));
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _scrollSaveTimer?.cancel();
    _gestureStartScale = _stageScale;
    _transformDirty = false;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final size = context.size;
    if (!widget.interactive || size == null || size.isEmpty) return;

    final previousScale = _stageScale;
    final nextScale =
        (_gestureStartScale * details.scale).clamp(_minScale, _maxScale);
    var translation = Offset(
      _offsetX * size.width,
      _offsetY * size.height,
    );

    if (nextScale != previousScale) {
      final scaleRatio = nextScale / previousScale;
      final focalFromCenter =
          details.localFocalPoint - size.center(Offset.zero);
      translation = translation * scaleRatio +
          focalFromCenter * (1 - scaleRatio) +
          details.focalPointDelta * scaleRatio;
    } else {
      translation += details.focalPointDelta;
    }

    setState(() {
      _stageScale = nextScale;
      _offsetX = (translation.dx / size.width).clamp(-_maxOffset, _maxOffset);
      _offsetY = (translation.dy / size.height).clamp(-_maxOffset, _maxOffset);
      _transformDirty = true;
    });
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    if (_transformDirty) _notifyTransformChanged();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!widget.interactive || event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final scrollEvent = event as PointerScrollEvent;
      final size = context.size;
      if (size == null || size.isEmpty) return;
      final scaleFactor = math.exp(-scrollEvent.scrollDelta.dy * 0.0015);
      _scaleAroundPoint(
        (_stageScale * scaleFactor).clamp(_minScale, _maxScale),
        scrollEvent.localPosition,
        size,
      );
      _scrollSaveTimer?.cancel();
      _scrollSaveTimer = Timer(
        const Duration(milliseconds: 250),
        _notifyTransformChanged,
      );
    });
  }

  void _scaleAroundPoint(double nextScale, Offset focalPoint, Size size) {
    if (nextScale == _stageScale) return;
    final scaleRatio = nextScale / _stageScale;
    final translation = Offset(
      _offsetX * size.width,
      _offsetY * size.height,
    );
    final focalFromCenter = focalPoint - size.center(Offset.zero);
    final nextTranslation =
        translation * scaleRatio + focalFromCenter * (1 - scaleRatio);
    setState(() {
      _stageScale = nextScale;
      _offsetX =
          (nextTranslation.dx / size.width).clamp(-_maxOffset, _maxOffset);
      _offsetY =
          (nextTranslation.dy / size.height).clamp(-_maxOffset, _maxOffset);
    });
  }

  void _resetTransform() {
    _scrollSaveTimer?.cancel();
    setState(() {
      _stageScale = 1;
      _offsetX = 0;
      _offsetY = 0;
    });
    _notifyTransformChanged();
  }

  void _notifyTransformChanged() {
    _transformDirty = false;
    widget.onTransformChanged?.call(
      Live2DStageTransform(
        scale: _stageScale,
        offsetX: _offsetX,
        offsetY: _offsetY,
      ),
    );
  }

  void _scheduleIdle(Duration delay) {
    _returnToIdleTimer = Timer(delay, () {
      if (!mounted || widget.isSpeaking) return;
      unawaited(_play(widget.config.idleMotion, priority: 1));
    });
  }

  @override
  void dispose() {
    _loadGeneration++;
    _returnToIdleTimer?.cancel();
    _scrollSaveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?._detach(_nativeController);
    _nativeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Live2DCharacterView.isPlatformSupported) {
      return widget.fallback ??
          _StatusMessage(
            icon: Icons.phone_android,
            message: 'Live2D is available on Android, iOS, and macOS.',
            visible: widget.showStatus,
          );
    }

    return ClipRect(
      child: ValueListenableBuilder<Live2DViewState>(
        valueListenable: _nativeController.listenable,
        builder: (context, state, _) {
          final error = _loadError ?? state.lastError?.message;
          if (error != null) {
            return widget.fallback ??
                _StatusMessage(
                  icon: Icons.broken_image_outlined,
                  message: error,
                  visible: widget.showStatus,
                );
          }

          Widget live2DView = _nativeController.buildView();
          final opacity = widget.config.opacity.clamp(0.0, 1.0);
          if (opacity < 1.0) {
            live2DView = Opacity(opacity: opacity, child: live2DView);
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              Listener(
                onPointerSignal: _handlePointerSignal,
                child: MouseRegion(
                  cursor: widget.interactive
                      ? SystemMouseCursors.grab
                      : MouseCursor.defer,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _handleTap,
                    onDoubleTap: widget.interactive ? _resetTransform : null,
                    onScaleStart: widget.interactive ? _handleScaleStart : null,
                    onScaleUpdate:
                        widget.interactive ? _handleScaleUpdate : null,
                    onScaleEnd: widget.interactive ? _handleScaleEnd : null,
                    child: FractionalTranslation(
                      translation: Offset(_offsetX, _offsetY),
                      child: Transform.scale(
                        scale: _stageScale,
                        child: live2DView,
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.showStatus &&
                  (state.isLoadingModel || !state.isLoaded))
                const Center(child: CircularProgressIndicator()),
            ],
          );
        },
      ),
    );
  }
}

class _StatusMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final bool visible;

  const _StatusMessage({
    required this.icon,
    required this.message,
    required this.visible,
  });

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
