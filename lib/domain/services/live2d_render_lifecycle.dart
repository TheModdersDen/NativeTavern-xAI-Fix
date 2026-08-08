typedef Live2DRenderingPauseApplier = Future<void> Function(bool paused);

/// Serializes app lifecycle changes before they reach a native render loop.
///
/// A platform view can attach after the app has already entered the
/// background, and pause/resume platform calls can complete out of order.
/// This coordinator preserves the latest requested state across both cases.
class Live2DRenderingLifecycle {
  final Live2DRenderingPauseApplier _applyPaused;

  Future<void> _tail = Future<void>.value();
  bool _attached = false;
  bool _disposed = false;
  bool _desiredPaused;
  bool? _appliedPaused;
  int _attachmentGeneration = 0;
  Object? _lastError;

  Live2DRenderingLifecycle({
    required Live2DRenderingPauseApplier applyPaused,
    bool initialPaused = false,
  })  : _applyPaused = applyPaused,
        _desiredPaused = initialPaused;

  bool get isAttached => _attached;
  bool get desiredPaused => _desiredPaused;
  bool? get appliedPaused => _appliedPaused;
  Object? get lastError => _lastError;

  Future<void> setAttached(bool attached) {
    if (_disposed || _attached == attached) return _tail;
    _attached = attached;
    _appliedPaused = null;
    _attachmentGeneration++;
    return attached ? _scheduleSynchronization() : Future<void>.value();
  }

  Future<void> setAppActive(bool active) {
    if (_disposed) return Future<void>.value();
    _desiredPaused = !active;
    return _scheduleSynchronization();
  }

  Future<void> _scheduleSynchronization() {
    final operation = _tail.then<void>(
      (_) => _synchronize(),
      onError: (_, __) => _synchronize(),
    );
    _tail = operation;
    return operation;
  }

  Future<void> _synchronize() async {
    if (_disposed || !_attached || _appliedPaused == _desiredPaused) return;

    final target = _desiredPaused;
    final attachmentGeneration = _attachmentGeneration;
    try {
      await _applyPaused(target);
    } catch (error, stackTrace) {
      _lastError = error;
      Error.throwWithStackTrace(error, stackTrace);
    }

    if (_disposed ||
        !_attached ||
        attachmentGeneration != _attachmentGeneration) {
      return;
    }
    _appliedPaused = target;
    _lastError = null;
  }

  void dispose() {
    _disposed = true;
    _attached = false;
    _appliedPaused = null;
    _attachmentGeneration++;
  }
}
