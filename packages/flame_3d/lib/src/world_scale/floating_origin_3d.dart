import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';

/// 64-bit IEEE-754 double-precision 3D world coordinate backed by a
/// [Float64List] of length `3`.
///
/// Preserves sub-nanometer precision even at planetary/open-world coordinates
/// (`1,000,000+` meters), computing camera-relative differences in 64-bit
/// floating point before converting to 32-bit GPU [Vector3] offsets.
class WorldPosition64([double x = 0, double y = 0, double z = 0]) {
  /// Creates a 64-bit world coordinate `(x, y, z)`.
  this {
    storage
      ..[0] = x
      ..[1] = y
      ..[2] = z;
  }

  /// Backing 64-bit coordinate array `[x, y, z]`.
  final Float64List storage = Float64List(3);

  /// Creates a 64-bit world coordinate at `(0, 0, 0)`.
  factory WorldPosition64.zero() => WorldPosition64();

  /// Copies [other] into a new [WorldPosition64].
  factory WorldPosition64.copy(WorldPosition64 other) =>
      WorldPosition64(other.x, other.y, other.z);

  /// Creates a [WorldPosition64] from a 32-bit [Vector3].
  factory WorldPosition64.fromVector3(Vector3 v) =>
      WorldPosition64(v.x, v.y, v.z);

  /// World X coordinate in 64-bit double precision.
  double get x => storage[0];
  set x(double value) => storage[0] = value;

  /// World Y coordinate in 64-bit double precision.
  double get y => storage[1];
  set y(double value) => storage[1] = value;

  /// World Z coordinate in 64-bit double precision.
  double get z => storage[2];
  set z(double value) => storage[2] = value;

  /// Sets all three 64-bit components in place.
  void setValues(double x, double y, double z) {
    storage
      ..[0] = x
      ..[1] = y
      ..[2] = z;
  }

  /// Copies coordinates from [other] in place.
  void setFrom(WorldPosition64 other) {
    storage
      ..[0] = other.storage[0]
      ..[1] = other.storage[1]
      ..[2] = other.storage[2];
  }

  /// Translates this 64-bit world position by `(dx, dy, dz)` in exact double
  /// precision.
  void translate(double dx, double dy, double dz) {
    storage[0] += dx;
    storage[1] += dy;
    storage[2] += dz;
  }

  /// Euclidean distance to [other] computed in 64-bit double precision.
  double distanceTo(WorldPosition64 other) {
    final dx = storage[0] - other.storage[0];
    final dy = storage[1] - other.storage[1];
    final dz = storage[2] - other.storage[2];
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  /// Squared Euclidean distance to [other] in 64-bit double precision.
  double distanceToSquared(WorldPosition64 other) {
    final dx = storage[0] - other.storage[0];
    final dy = storage[1] - other.storage[1];
    final dz = storage[2] - other.storage[2];
    return dx * dx + dy * dy + dz * dz;
  }

  /// Subtracts [origin] in 64-bit double precision before writing the small
  /// local offset into [out] (or a new 32-bit [Vector3]).
  Vector3 toCameraRelativeVector3(WorldPosition64 origin, {Vector3? out}) {
    final dx = storage[0] - origin.storage[0];
    final dy = storage[1] - origin.storage[1];
    final dz = storage[2] - origin.storage[2];
    final result = out ?? Vector3.zero();
    result.setValues(dx, dy, dz);
    return result;
  }

  /// Clones this coordinate.
  WorldPosition64 clone() => WorldPosition64.copy(this);

  @override
  String toString() =>
      'WorldPosition64(${storage[0]}, ${storage[1]}, ${storage[2]})';
}

/// Authoritative 64-bit world transform binding for a [Component3D] managed by
/// [FloatingOriginController3D].
///
/// Can either be registered directly with
/// [FloatingOriginController3D.register] or mounted as a child component of a
/// [Component3D] inside a [World3D] containing a [FloatingOriginController3D].
class FloatingOriginTransform3D({
  required WorldPosition64 worldPosition,

  /// Target [Component3D] whose local `position` is updated relative to the
  /// active floating origin (defaults to `parent as Component3D?` when
  /// mounted).
  var Component3D? target,

  /// Optional explicit controller reference (auto-discovered from `World3D`
  /// when mounted if `null`).
  var FloatingOriginController3D? controller,
}) extends Component {
  /// Authoritative 64-bit world coordinate of [resolvedTarget].
  ///
  /// Moving the target through its local `position` instead of
  /// [translateWorld] or [setWorldValues] works too: at the next rebase the
  /// controller notices that the target is no longer where this binding put
  /// it and takes its world position from there (with the precision of the
  /// 32-bit local position).
  final WorldPosition64 worldPosition = WorldPosition64.copy(worldPosition);

  final Vector3 _scratch = Vector3.zero();
  // The local position this binding last gave its target, to tell whether
  // the target was moved directly since.
  final Vector3 _appliedLocal = Vector3.zero();
  Component3D? _appliedTarget;

  /// Resolved [Component3D] controlled by this binding.
  Component3D? get resolvedTarget {
    final explicit = target;
    if (explicit != null) {
      return explicit;
    }
    final p = parent;
    return p is Component3D ? p : null;
  }

  /// Updates [worldPosition] to `(x, y, z)` in 64-bit precision and refreshes
  /// the local `Component3D.position` if bound to a controller.
  void setWorldValues(double x, double y, double z) {
    worldPosition.setValues(x, y, z);
    final ctrl = controller;
    if (ctrl != null) {
      applyOrigin(ctrl.origin);
    }
  }

  /// Translates [worldPosition] by `(dx, dy, dz)` in 64-bit precision and
  /// refreshes the local `Component3D.position` if bound to a controller.
  void translateWorld(double dx, double dy, double dz) {
    worldPosition.translate(dx, dy, dz);
    final ctrl = controller;
    if (ctrl != null) {
      applyOrigin(ctrl.origin);
    }
  }

  /// Recomputes [resolvedTarget]'s local 32-bit `position` from
  /// `worldPosition - origin` in 64-bit precision.
  void applyOrigin(WorldPosition64 origin) {
    final comp = resolvedTarget;
    if (comp == null) {
      return;
    }
    worldPosition.toCameraRelativeVector3(origin, out: _scratch);
    comp.position.setFrom(_scratch);
    _appliedLocal.setFrom(comp.position);
    _appliedTarget = comp;
  }

  /// Takes [worldPosition] from the target's local position when the target
  /// was moved directly since this binding last placed it, [origin] being the
  /// origin it was placed against.
  void _syncFromTarget(WorldPosition64 origin) {
    final comp = resolvedTarget;
    if (comp == null) {
      return;
    }
    final local = comp.position;
    if (identical(comp, _appliedTarget) &&
        local.x == _appliedLocal.x &&
        local.y == _appliedLocal.y &&
        local.z == _appliedLocal.z) {
      return;
    }
    worldPosition.setValues(
      origin.x + local.x,
      origin.y + local.y,
      origin.z + local.z,
    );
  }

  @override
  void onMount() {
    super.onMount();
    if (controller == null) {
      for (final ancestor in ancestors()) {
        if (ancestor is World3D) {
          for (final sibling in ancestor.children) {
            if (sibling is FloatingOriginController3D) {
              controller = sibling;
              break;
            }
          }
          break;
        }
      }
    }
    // When the controller mounts later, it registers this binding itself.
    controller?.register(this);
  }

  @override
  void onRemove() {
    controller?.unregister(this);
    super.onRemove();
  }
}

/// Callback invoked whenever [FloatingOriginController3D] shifts the local
/// world origin.
///
/// [shiftDelta] is the local-space translation `(-dx, -dy, -dz)` applied to
/// local-space systems (particles, trails, physics bodies) so they stay at the
/// same world location after `origin` advances by `(+dx, +dy, +dz)`.
typedef OriginShiftCallback3D = void Function(Vector3 shiftDelta);

/// Alias matching `FloatingOrigin3D` architectural naming.
typedef FloatingOrigin3D = FloatingOriginController3D;

/// Component attached to a [World3D] (or driven standalone) that maintains a
/// 64-bit world origin `(originX, originY, originZ)` and rebases local 32-bit
/// coordinates whenever the camera moves farther than [rebaseThreshold] from
/// `(0, 0, 0)`.
class FloatingOriginController3D({
  WorldPosition64? initialOrigin,

  /// Optional [CameraComponent3D] monitored each [update] tick and shifted back
  /// to local `(0, 0, 0)` on rebase.
  var CameraComponent3D? camera,

  /// Optional local [Component3D] (e.g. player vehicle/character) monitored
  /// when [camera] is `null`.
  ///
  /// It must be a direct child of the world, so that its `position` is in
  /// the world's local coordinates. On a rebase the controller moves it back
  /// by the shift, unless a registered [FloatingOriginTransform3D] binds it
  /// (the binding then places it).
  var Component3D? trackedTarget,

  /// Maximum local distance from `(0, 0, 0)` before triggering an origin
  /// rebase.
  var double rebaseThreshold = 2048.0,

  /// Whether vertical `Y` coordinates are rebased alongside horizontal `XZ`.
  var bool rebaseY = true,
  OriginShiftCallback3D? onOriginShifted,
}) extends Component with HasWorldRef<World3D> {
  /// Creates a floating-origin controller with `rebaseThreshold` in world
  /// units (`2048.0` by default).
  this : assert(rebaseThreshold > 0, 'rebaseThreshold must be positive') {
    if (onOriginShifted != null) {
      _listeners.add(onOriginShifted);
    }
  }

  /// Current 64-bit world coordinate corresponding to local `(0, 0, 0)`.
  final WorldPosition64 origin = initialOrigin != null
      ? WorldPosition64.copy(initialOrigin)
      : WorldPosition64.zero();

  final List<FloatingOriginTransform3D> _transforms =
      <FloatingOriginTransform3D>[];
  final List<OriginShiftCallback3D> _listeners = <OriginShiftCallback3D>[];
  final Vector3 _lastShiftDelta = Vector3.zero();
  int _rebaseCount = 0;

  /// World X of local `(0, 0, 0)` in 64-bit double precision.
  double get originX => origin.x;

  /// World Y of local `(0, 0, 0)` in 64-bit double precision.
  double get originY => origin.y;

  /// World Z of local `(0, 0, 0)` in 64-bit double precision.
  double get originZ => origin.z;

  /// Total number of origin rebases executed.
  int get rebaseCount => _rebaseCount;

  /// Number of registered [FloatingOriginTransform3D] components.
  int get registeredCount => _transforms.length;

  /// Local shift vector `(-dx, -dy, -dz)` from the most recent rebase.
  Vector3 get lastShiftDelta => _lastShiftDelta;

  @override
  void onMount() {
    super.onMount();
    // Bindings mounted before this controller found no controller: adopt
    // those of the world that have none.
    for (final ancestor in ancestors()) {
      if (ancestor is World3D) {
        for (final binding
            in ancestor.descendants().whereType<FloatingOriginTransform3D>()) {
          if (binding.controller == null) {
            register(binding);
          }
        }
        break;
      }
    }
  }

  /// Registers an additional listener notified on every origin rebase.
  void addOriginShiftListener(OriginShiftCallback3D listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// Removes a previously added origin-shift listener.
  void removeOriginShiftListener(OriginShiftCallback3D listener) {
    _listeners.remove(listener);
  }

  /// Registers [transform] and immediately synchronizes its local
  /// `Component3D.position` relative to [origin].
  void register(FloatingOriginTransform3D transform) {
    transform.controller = this;
    if (!_transforms.contains(transform)) {
      _transforms.add(transform);
    }
    transform.applyOrigin(origin);
  }

  /// Unregisters [transform].
  void unregister(FloatingOriginTransform3D transform) {
    _transforms.remove(transform);
    if (identical(transform.controller, this)) {
      transform.controller = null;
    }
  }

  /// Converts a local 32-bit [localPosition] into an exact 64-bit
  /// [WorldPosition64] by adding [origin].
  WorldPosition64 localToWorld64(
    Vector3 localPosition, {
    WorldPosition64? out,
  }) {
    final res = out ?? WorldPosition64.zero();
    res.setValues(
      origin.x + localPosition.x,
      origin.y + localPosition.y,
      origin.z + localPosition.z,
    );
    return res;
  }

  /// Converts a 64-bit [worldPosition] into local 32-bit coordinates relative
  /// to [origin].
  Vector3 world64ToLocal(WorldPosition64 worldPosition, {Vector3? out}) {
    return worldPosition.toCameraRelativeVector3(origin, out: out);
  }

  /// Computes the exact 64-bit world coordinate of [camera] (when set).
  WorldPosition64 cameraWorldPosition64({WorldPosition64? out}) {
    final cam = camera;
    if (cam == null) {
      final res = out ?? WorldPosition64.zero();
      res.setFrom(origin);
      return res;
    }
    return localToWorld64(cam.position, out: out);
  }

  @override
  void update(double dt) {
    super.update(dt);
    checkAndRebase();
  }

  /// Checks the active [camera] or [trackedTarget] against [rebaseThreshold],
  /// rebasing the origin in 64-bit precision when exceeded. Returns `true` if a
  /// rebase occurred.
  bool checkAndRebase() {
    final cam = camera;
    if (cam != null) {
      return checkAndRebaseForLocalObserver(cam.position);
    }
    final tracked = trackedTarget;
    if (tracked != null) {
      return checkAndRebaseForLocalObserver(tracked.position);
    }
    return false;
  }

  /// Checks an arbitrary local observer position [localObserverPos] against
  /// [rebaseThreshold], shifting [origin], [camera] (if set), and all
  /// registered [FloatingOriginTransform3D]s when exceeded.
  bool checkAndRebaseForLocalObserver(Vector3 localObserverPos) {
    final dx = localObserverPos.x;
    final dy = rebaseY ? localObserverPos.y : 0.0;
    final dz = localObserverPos.z;
    final distSq = dx * dx + dy * dy + dz * dz;
    if (distSq <= rebaseThreshold * rebaseThreshold) {
      return false;
    }
    shiftOriginBy(dx, dy, dz);
    return true;
  }

  /// Rebases [origin] directly to an exact 64-bit [newOrigin] (for example on
  /// world teleport or fast travel) and updates all registered transforms and
  /// listeners.
  void rebaseToWorldOrigin(WorldPosition64 newOrigin) {
    final dx = newOrigin.x - origin.x;
    final dy = rebaseY ? (newOrigin.y - origin.y) : 0.0;
    final dz = newOrigin.z - origin.z;
    if (dx == 0 && dy == 0 && dz == 0) {
      return;
    }
    shiftOriginBy(dx, dy, dz);
  }

  /// Shifts [origin] by `(dx, dy, dz)` in exact 64-bit double precision,
  /// translates [camera] and an unbound [trackedTarget] by
  /// `(-dx, -dy, -dz)`, refreshes all registered
  /// [FloatingOriginTransform3D]s, and notifies origin-shift listeners.
  void shiftOriginBy(double dx, double dy, double dz) {
    // Bound targets moved through their local position since their binding
    // placed them: take their world position from there first.
    var trackedIsBound = false;
    final tracked = trackedTarget;
    for (var i = 0; i < _transforms.length; i++) {
      final binding = _transforms[i];
      binding._syncFromTarget(origin);
      if (tracked != null && identical(binding.resolvedTarget, tracked)) {
        trackedIsBound = true;
      }
    }

    origin.translate(dx, dy, dz);
    _rebaseCount++;

    if (tracked != null && !trackedIsBound) {
      tracked.position.setValues(
        tracked.position.x - dx,
        tracked.position.y - dy,
        tracked.position.z - dz,
      );
    }

    final cam = camera;
    if (cam != null) {
      cam.position.setValues(
        cam.position.x - dx,
        cam.position.y - dy,
        cam.position.z - dz,
      );
      cam.target.setValues(
        cam.target.x - dx,
        cam.target.y - dy,
        cam.target.z - dz,
      );
    }

    for (var i = 0; i < _transforms.length; i++) {
      _transforms[i].applyOrigin(origin);
    }

    _lastShiftDelta.setValues(-dx, -dy, -dz);
    for (var i = 0; i < _listeners.length; i++) {
      _listeners[i](_lastShiftDelta);
    }

    if (isMounted) {
      for (final ancestor in ancestors()) {
        if (ancestor is World3D) {
          ancestor.markSceneDirty();
          break;
        }
      }
    }
  }
}
