part of 'component_3d.dart';

/// {@template shadow_caster_tracker}
/// The change tracking of the shadow casters of a [World3D] that
/// `ShadowSettings.cacheStillCasters` relies on: which casters stand still,
/// and when the kept layer of still casters must be rendered again.
///
/// The renders of the world's shadows are counted ([clock]). Each [Object3D]
/// notes the render in which it last changed in a way that can move its
/// shadow; the casters whose last change is at or before [cutoff] are the
/// still ones, kept in the layer, the others are drawn in every frame (see
/// [Object3D.shadowMotion] for the casters that decide themselves).
/// [version] increases when the layer no longer holds what the still
/// casters draw: one of them changed, was hidden or removed, or casters that
/// stopped moving are to join it. The cutoff only moves when [version]
/// does, so that every tile of a map rendered with one version holds the
/// same casters.
/// {@endtemplate}
@internal
class ShadowCasterTracker() {
  static const int _unmounted = 0x7fffffffffff;

  /// The number of renders of the world's shadows so far.
  int get clock => _clock;
  int _clock = 0;

  /// The casters whose last change is at or before this render are still.
  int get cutoff => _cutoff;
  int _cutoff = -1;

  /// Increases when the kept layer of still casters is to be rendered again.
  int get version => _version;
  int _version = 0;
  int _cutoffVersion = -1;

  int _stillFrames = 30;
  bool _joinPending = false;
  // The render in which a caster last changed.
  int _lastChange = -1;

  /// The number of mounted casters whose [Object3D.shadowMotion] is
  /// [ShadowCasterMotion.moving].
  int get alwaysMoving => _alwaysMoving;
  int _alwaysMoving = 0;

  // Mounted casters that are not currently settled in the kept still layer,
  // allowing ShadowCasterLayer.moving passes to iterate O(M) active movers.
  final List<Object3D> _movers = [];
  int _maxPrunedClock = -1;

  /// Active non-still mounted casters in this world.
  List<Object3D> get movers => _movers;

  /// Whether any auto-tracked shadow caster is still waiting to settle into
  /// the kept still-shadow layer.
  bool get hasUnsettledAutoCasters {
    for (var i = 0; i < _movers.length; i++) {
      final caster = _movers[i];
      if (caster.shadowMotion == ShadowCasterMotion.auto &&
          caster.castsShadows) {
        return true;
      }
    }
    return false;
  }

  /// Whether [movers] is guaranteed to contain every mounted non-still
  /// [Object3D] in the world.
  bool get moversComplete => _cutoff >= _maxPrunedClock;

  void _addMover(Object3D caster) {
    if (caster.shadowMoverIndex >= 0 ||
        caster.shadowMotion == ShadowCasterMotion.still) {
      return;
    }
    caster.shadowMoverIndex = _movers.length;
    _movers.add(caster);
  }

  void _removeMover(Object3D caster) {
    final idx = caster.shadowMoverIndex;
    if (idx < 0) {
      return;
    }
    _removeMoverAt(idx);
  }

  void _removeMoverAt(int idx) {
    final caster = _movers[idx];
    final last = _movers.removeLast();
    if (idx < _movers.length) {
      _movers[idx] = last;
      last.shadowMoverIndex = idx;
    }
    caster.shadowMoverIndex = -1;
  }

  /// Whether [caster] is kept with the still casters.
  bool isStill(Object3D caster) {
    return switch (caster.shadowMotion) {
      ShadowCasterMotion.auto => caster._shadowChangeClock <= _cutoff,
      ShadowCasterMotion.still => true,
      ShadowCasterMotion.moving => false,
    };
  }

  /// Notes that [caster] changed in a way that can move its shadow.
  void changed(Object3D caster) {
    if (isStill(caster)) {
      _version++;
    }
    caster._shadowChangeClock = _clock;
    _noteMover(caster);
  }

  /// Notes that [caster] was mounted.
  void added(Object3D caster) {
    caster._shadowChangeClock = _clock;
    _noteMover(caster);
    switch (caster.shadowMotion) {
      case ShadowCasterMotion.still:
        _version++;
      case ShadowCasterMotion.moving:
        _alwaysMoving++;
      case ShadowCasterMotion.auto:
        break;
    }
  }

  /// Notes that [caster] was shown: it was not drawn into the kept layer.
  void shown(Object3D caster) {
    caster._shadowChangeClock = _clock;
    _noteMover(caster);
    if (caster.shadowMotion == ShadowCasterMotion.still) {
      _version++;
    }
  }

  /// Notes that [caster] is being removed.
  void removed(Object3D caster) {
    if (isStill(caster)) {
      _version++;
    }
    if (caster.shadowMotion == ShadowCasterMotion.moving) {
      _alwaysMoving--;
    }
    _removeMover(caster);
    caster._shadowChangeClock = _unmounted;
  }

  /// Notes that the [Object3D.shadowMotion] of a mounted [caster] changes
  /// from [from] to [to].
  void motionChanged(
    Object3D caster,
    ShadowCasterMotion from,
    ShadowCasterMotion to,
  ) {
    if (from == ShadowCasterMotion.moving) {
      _alwaysMoving--;
    }
    if (to == ShadowCasterMotion.moving) {
      _alwaysMoving++;
    }
    caster._shadowChangeClock = _clock;
    if (to == ShadowCasterMotion.still) {
      _removeMover(caster);
    } else {
      _noteMover(caster);
    }
    _version++;
  }

  // Notes that [caster], which just changed, is now drawn as a moving
  // caster when the engine decides for it.
  void _noteMover(Object3D caster) {
    if (caster.shadowMotion == ShadowCasterMotion.auto) {
      _lastChange = _clock;
    }
    _addMover(caster);
  }

  /// Notes that [caster] is drawn as a moving caster: once it stayed
  /// unchanged long enough, the still casters are kept again with it.
  void drawnMoving(Object3D caster) {
    if (caster.shadowMotion == ShadowCasterMotion.auto &&
        _clock - caster._shadowChangeClock >= _stillFrames) {
      _joinPending = true;
    }
  }

  /// Notes that every caster must be drawn again into the kept layer.
  void invalidate() {
    _version++;
  }

  /// Prepares a render of the shadows whose casters stay unchanged for
  /// [stillFrames] renders before they are kept: the casters that stopped
  /// moving join the still ones (all of them once none changed for that
  /// long, or those drawn as moving casters that did not), and the cutoff
  /// follows [version].
  void prepare(int stillFrames) {
    _stillFrames = stillFrames;
    if (_cutoff < _lastChange && _clock - _lastChange >= stillFrames) {
      _joinPending = true;
    }
    if (_joinPending) {
      _joinPending = false;
      _version++;
    }
    if (_version != _cutoffVersion) {
      _cutoffVersion = _version;
      _cutoff = _clock - stillFrames;
    }
    for (var i = _movers.length - 1; i >= 0; i--) {
      final caster = _movers[i];
      if (caster.shadowMotion == ShadowCasterMotion.auto &&
          caster._shadowChangeClock <= _cutoff) {
        if (caster._shadowChangeClock > _maxPrunedClock) {
          _maxPrunedClock = caster._shadowChangeClock;
        }
        _removeMoverAt(i);
      }
    }
  }

  /// Counts a render of the shadows.
  void advance() {
    _clock++;
  }
}
