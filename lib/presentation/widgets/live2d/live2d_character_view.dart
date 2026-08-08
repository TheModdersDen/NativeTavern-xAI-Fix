import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_live2d/flutter_live2d.dart';
import 'package:native_tavern/core/utils/path_utils.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/emotion_detection_service.dart';
import 'package:native_tavern/domain/services/live2d_action_orchestrator.dart';
import 'package:native_tavern/domain/services/live2d_hit_test_service.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:native_tavern/presentation/widgets/live2d/macos_live2d_view.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_stage_gestures.dart';

export 'package:native_tavern/presentation/widgets/live2d/live2d_stage_gestures.dart'
    show Live2DStageTransform;

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
  Live2DActionOrchestrator? _orchestrator;
  String _lipSyncParameter = 'ParamMouthOpenY';

  bool get isReady => _nativeController?.value.isLoaded ?? false;

  void _attach(
    _NativeLive2DController controller,
    String lipSyncParameter,
    Live2DActionOrchestrator orchestrator,
  ) {
    _nativeController = controller;
    _lipSyncParameter = lipSyncParameter;
    _orchestrator = orchestrator;
  }

  void _detach(_NativeLive2DController controller) {
    if (identical(_nativeController, controller)) {
      _nativeController = null;
      _orchestrator = null;
    }
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

  Future<bool> notifyMessageStarted() =>
      _orchestrator?.onMessageStarted() ?? Future.value(false);

  Future<bool> notifySentenceBoundary() =>
      _orchestrator?.onSentenceBoundary() ?? Future.value(false);

  Future<bool> notifyResponseCompleted({String? emotion}) =>
      _orchestrator?.onResponseCompleted(emotion: emotion) ??
      Future.value(false);
}

class Live2DCharacterView extends StatefulWidget {
  final Live2DConfig config;
  final bool isSpeaking;
  final String responseText;
  final Live2DCharacterController? controller;
  final Widget? fallback;
  final bool showStatus;
  final bool interactive;
  final ValueChanged<Live2DStageTransform>? onTransformChanged;

  const Live2DCharacterView({
    super.key,
    required this.config,
    this.isSpeaking = false,
    this.responseText = '',
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
  late final _NativeLive2DController _nativeController;
  late Live2DActionOrchestrator _orchestrator;
  late Live2DConfig _actionConfig;
  final Live2DHitTestService _hitTestService = const Live2DHitTestService();
  final Live2DSentenceBoundaryTracker _sentenceTracker =
      Live2DSentenceBoundaryTracker();
  final EmotionDetectionService _emotionDetectionService =
      EmotionDetectionService();
  Timer? _scrollSaveTimer;
  String? _loadError;
  int _loadGeneration = 0;
  double _stageScale = 1;
  double _offsetX = 0;
  double _offsetY = 0;
  Live2DStageTransform? _gestureStartTransform;
  Offset? _gestureStartFocalPoint;
  bool _transformDirty = false;

  @override
  void initState() {
    super.initState();
    _nativeController =
        Platform.isMacOS ? _MacOSLive2DController() : _MobileLive2DController();
    _actionConfig = widget.config;
    _orchestrator = _createOrchestrator(_actionConfig);
    _applyConfigTransform(widget.config);
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
      _applyConfigTransform(config);
    }
    if (oldConfig.modelId != config.modelId ||
        oldConfig.modelDirectory != config.modelDirectory ||
        oldConfig.modelFileName != config.modelFileName ||
        oldConfig.source != config.source) {
      _loadModel();
      return;
    }
    if (oldConfig.motionSpeed != config.motionSpeed &&
        _nativeController.value.isLoaded) {
      unawaited(_nativeController.setMotionSpeed(config.motionSpeed));
    }
    if (oldWidget.isSpeaking != widget.isSpeaking) {
      _handleSpeakingChanged();
    } else if (widget.isSpeaking &&
        oldWidget.responseText != widget.responseText) {
      _handleResponseTextChanged();
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
    _orchestrator.reset();
    _sentenceTracker.reset(text: widget.responseText);
    if (mounted) setState(() => _loadError = null);

    try {
      await _nativeController.whenAttached;
      if (!mounted || generation != _loadGeneration) return;
      final actionConfig = await _discoverActionConfig();
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
      _replaceOrchestrator(actionConfig);
      widget.controller?._attach(
        _nativeController,
        actionConfig.lipSyncParameter,
        _orchestrator,
      );
      if (widget.isSpeaking) {
        await _orchestrator.onMessageStarted();
      } else {
        await _orchestrator.onIdleTimeout();
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

  Future<Live2DConfig> _discoverActionConfig() async {
    try {
      final config = widget.config;
      final definition = Live2DModelDefinition(
        id: config.modelId,
        displayName: config.displayName,
        modelDirectory: config.modelDirectory,
        modelFileName: config.modelFileName,
        source: config.source,
      );
      final dataPath = config.source == Live2DModelSource.appData
          ? await PathUtils.getDataPath()
          : null;
      final manifest = await Live2DService(dataPath: dataPath).loadManifest(
        definition,
      );
      return config.withActionDefaults(
        Live2DConfig.fromDefinition(definition, manifest),
      );
    } catch (_) {
      return widget.config;
    }
  }

  Live2DActionOrchestrator _createOrchestrator(Live2DConfig config) {
    return Live2DActionOrchestrator(
      resolver: Live2DActionResolver(config),
      player: _playMotion,
    );
  }

  void _replaceOrchestrator(Live2DConfig config) {
    _orchestrator.dispose();
    _actionConfig = config;
    _orchestrator = _createOrchestrator(config);
  }

  void _handleSpeakingChanged() {
    if (widget.isSpeaking) {
      _sentenceTracker.reset(text: widget.responseText);
      unawaited(_orchestrator.onMessageStarted());
      return;
    }

    final emotion = _emotionDetectionService.detectEmotion(widget.responseText);
    unawaited(
      _orchestrator.onResponseCompleted(emotion: emotion.id),
    );
  }

  void _handleResponseTextChanged() {
    final count = _sentenceTracker.takeNewBoundaries(widget.responseText);
    for (var index = 0; index < count; index++) {
      unawaited(_orchestrator.onSentenceBoundary());
    }
  }

  Future<bool> _playMotion(Live2DMotionRef motion, int priority) async {
    if (!_nativeController.value.isLoaded) return false;
    try {
      await _nativeController.startMotion(
        group: motion.group,
        index: motion.index,
        priority: priority,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void _handleTap(TapUpDetails details) {
    final size = context.size;
    if (size == null || size.isEmpty) return;
    final translatedX = details.localPosition.dx - (_offsetX * size.width);
    final translatedY = details.localPosition.dy - (_offsetY * size.height);
    final normalizedX =
        ((translatedX - size.width / 2) / _stageScale + size.width / 2) /
            size.width;
    final normalizedY =
        ((translatedY - size.height / 2) / _stageScale + size.height / 2) /
            size.height;
    final hit = _hitTestService.hitTest(
      hitAreas: _actionConfig.hitAreas,
      normalizedX: normalizedX,
      normalizedY: normalizedY,
    );
    unawaited(_orchestrator.onTap(hit));
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _scrollSaveTimer?.cancel();
    _gestureStartTransform = _currentTransform;
    _gestureStartFocalPoint = details.localFocalPoint;
    _transformDirty = false;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final size = context.size;
    final startTransform = _gestureStartTransform;
    final startFocalPoint = _gestureStartFocalPoint;
    if (!widget.interactive ||
        size == null ||
        size.isEmpty ||
        startTransform == null ||
        startFocalPoint == null) {
      return;
    }
    final next = Live2DStageTransform.applyGesture(
      start: startTransform,
      startFocalPoint: startFocalPoint,
      currentFocalPoint: details.localFocalPoint,
      scaleDelta: details.scale,
      size: size,
    );

    setState(() {
      _stageScale = next.scale;
      _offsetX = next.offsetX;
      _offsetY = next.offsetY;
      _transformDirty = true;
    });
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _gestureStartTransform = null;
    _gestureStartFocalPoint = null;
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
        (_stageScale * scaleFactor).clamp(
          Live2DStageTransform.minScale,
          Live2DStageTransform.maxScale,
        ),
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
    final next = Live2DStageTransform.applyGesture(
      start: _currentTransform,
      startFocalPoint: focalPoint,
      currentFocalPoint: focalPoint,
      scaleDelta: nextScale / _stageScale,
      size: size,
    );
    setState(() {
      _stageScale = next.scale;
      _offsetX = next.offsetX;
      _offsetY = next.offsetY;
    });
  }

  Live2DStageTransform get _currentTransform =>
      Live2DStageTransform.constrained(
        scale: _stageScale,
        offsetX: _offsetX,
        offsetY: _offsetY,
      );

  void _applyConfigTransform(Live2DConfig config) {
    final transform = Live2DStageTransform.constrained(
      scale: config.scale,
      offsetX: config.offsetX,
      offsetY: config.offsetY,
    );
    _stageScale = transform.scale;
    _offsetX = transform.offsetX;
    _offsetY = transform.offsetY;
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

  @override
  void dispose() {
    _loadGeneration++;
    _scrollSaveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?._detach(_nativeController);
    _orchestrator.dispose();
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
                    onTapUp: _handleTap,
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
