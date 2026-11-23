import 'dart:math' as math;

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:meta/meta.dart';

/// Mixin on [Component3D] receiving 3D collider contact lifecycle callbacks
/// from [CollisionSystem3D].
mixin CollisionCallbacks3D on Component3D {
  /// Invoked on the step when this component's collider begins overlapping
  /// [other].
  ///
  /// `manifold.normal` points from this component's collider toward [other].
  void onCollisionStart3D(Collider3D other, CollisionManifold3D manifold) {}

  /// Invoked on every step while this component's collider continues
  /// overlapping [other].
  void onCollision3D(Collider3D other, CollisionManifold3D manifold) {}

  /// Invoked when this component's collider stops overlapping [other] (or when
  /// either collider is removed).
  void onCollisionEnd3D(Collider3D other) {}
}

/// A 3D collision volume attachable to any [Component3D] (or usable standalone
/// in a [World3D]).
class Collider3D({
  required Shape3D shape,
  Vector3? localOffset,
  var int collisionLayer = 1,
  var int collisionMask = 0xFFFFFFFF,
  var bool isTrigger = false,
  var bool isStatic = false,
  var PhysicsMaterial3D? material,
  super.position,
  super.scale,
  super.rotation,
  super.children,
}) extends Component3D {
  Shape3D _shape = shape;

  /// Geometric collision shape in local space.
  Shape3D get shape => _shape;
  set shape(Shape3D value) {
    if (identical(value, _shape)) {
      return;
    }
    _shape = value;
    markAabbDirty();
  }

  /// Additional local-space translation offset of [shape] relative to this
  /// component's origin.
  final Vector3 localOffset = localOffset?.clone() ?? Vector3.zero();

  final Matrix4 _colliderWorldMatrix = Matrix4.identity();
  final Aabb3 _colliderWorldAabb = Aabb3();
  final Aabb3 _localShapeAabb = Aabb3();

  int _cachedMatrixVersion = -1;
  Component? _cachedMatrixParent;
  double _cachedOffsetX = double.nan;
  double _cachedOffsetY = 0.0;
  double _cachedOffsetZ = 0.0;
  int _colliderMatrixRev = 0;
  Shape3D? _cachedAabbShape;
  int _cachedAabbMatrixRev = -1;

  /// The collision systems this collider registered with when it mounted.
  @internal
  final List<CollisionSystem3D> enclosingCollisionSystems = [];

  @override
  void onMount() {
    super.onMount();
    CollisionSystem3D.attachToEnclosingSystems(this);
  }

  @override
  void onRemove() {
    for (var i = 0; i < enclosingCollisionSystems.length; i++) {
      enclosingCollisionSystems[i].unregisterMountedCollider(this);
    }
    enclosingCollisionSystems.clear();
    super.onRemove();
  }

  /// The logical owner component of this collider: its parent [Component3D] if
  /// attached as a child, or `this` when standalone.
  Component3D get hostComponent {
    final p = parent;
    return p is Component3D ? p : this;
  }

  bool _refreshColliderWorldMatrix() {
    final p = parent;
    final ver = worldTransformVersion;
    final ox = localOffset.x;
    final oy = localOffset.y;
    final oz = localOffset.z;
    if ((isMounted || p == null) &&
        ver == _cachedMatrixVersion &&
        identical(p, _cachedMatrixParent) &&
        ox == _cachedOffsetX &&
        oy == _cachedOffsetY &&
        oz == _cachedOffsetZ) {
      return false;
    }
    _cachedMatrixVersion = ver;
    _cachedMatrixParent = p;
    _cachedOffsetX = ox;
    _cachedOffsetY = oy;
    _cachedOffsetZ = oz;
    final w = worldTransformMatrix;
    final m = w.storage;
    _colliderWorldMatrix.setFrom(w);
    if (ox != 0.0 || oy != 0.0 || oz != 0.0) {
      final out = _colliderWorldMatrix.storage;
      out[12] = m[0] * ox + m[4] * oy + m[8] * oz + m[12];
      out[13] = m[1] * ox + m[5] * oy + m[9] * oz + m[13];
      out[14] = m[2] * ox + m[6] * oy + m[10] * oz + m[14];
    }
    _colliderMatrixRev++;
    return true;
  }

  /// Recomputes [_colliderWorldAabb] only when the collider's transform,
  /// [localOffset], or [shape] changed; returns whether the AABB was refreshed.
  @internal
  bool refreshCachedWorldAabb() {
    final matChanged = _refreshColliderWorldMatrix();
    if (!matChanged &&
        _cachedAabbMatrixRev == _colliderMatrixRev &&
        identical(_cachedAabbShape, _shape)) {
      return false;
    }
    _cachedAabbMatrixRev = _colliderMatrixRev;
    _cachedAabbShape = _shape;
    _shape.computeWorldAabb(_colliderWorldMatrix, _colliderWorldAabb);
    return true;
  }

  /// Last world-space AABB computed by [colliderWorldAabb] or
  /// [refreshCachedWorldAabb].
  @internal
  Aabb3 get cachedWorldAabb => _colliderWorldAabb;

  /// World transformation matrix of [shape], combining [worldTransformMatrix]
  /// with [localOffset].
  Matrix4 get colliderWorldMatrix {
    _refreshColliderWorldMatrix();
    return _colliderWorldMatrix;
  }

  /// Computes and returns the world-space AABB of [shape] at
  /// [colliderWorldMatrix].
  Aabb3 get colliderWorldAabb {
    refreshCachedWorldAabb();
    return _colliderWorldAabb;
  }

  /// Returns `true` when 32-bit layer/mask filtering allows contact with
  /// [other].
  bool canCollideWith(Collider3D other) {
    if (identical(this, other) ||
        identical(hostComponent, other.hostComponent)) {
      return false;
    }
    if (isStatic && other.isStatic) {
      return false;
    }
    return (collisionLayer & other.collisionMask) != 0 &&
        (other.collisionLayer & collisionMask) != 0;
  }

  @override
  Aabb3? computeLocalAabb() {
    _shape.computeLocalAabb(out: _localShapeAabb);
    _localShapeAabb.min.add(localOffset);
    _localShapeAabb.max.add(localOffset);
    return _localShapeAabb;
  }
}

/// Sensor collider (`isTrigger: true`) firing [onEnter3D], [onStay3D], and
/// [onExit3D] callbacks without physical blocking.
class TriggerVolume3D({
  required super.shape,
  super.localOffset,
  super.collisionLayer,
  super.collisionMask,
  super.isStatic,
  super.material,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  final void Function(Collider3D other, CollisionManifold3D manifold)?
  onEnter3D,
  final void Function(Collider3D other, CollisionManifold3D manifold)? onStay3D,
  final void Function(Collider3D other)? onExit3D,
}) extends Collider3D {
  this : super(isTrigger: true);

  /// Called when [other] enters this trigger volume.
  void handleEnter3D(Collider3D other, CollisionManifold3D manifold) {
    onEnter3D?.call(other, manifold);
  }

  /// Called each step while [other] stays inside this trigger volume.
  void handleStay3D(Collider3D other, CollisionManifold3D manifold) {
    onStay3D?.call(other, manifold);
  }

  /// Called when [other] exits this trigger volume.
  void handleExit3D(Collider3D other) {
    onExit3D?.call(other);
  }
}

/// Ray hit result returned by [CollisionSystem3D.raycastColliders] and
/// [CollisionSystem3D.raycastAllColliders].
class ColliderRayHit3D({
  required final Collider3D collider,
  required final double distance,
  required final Vector3 point,
  required final Vector3 normal,
});

/// World-level 3D collision manager backed by an incremental
/// [DynamicAabbTree3D] broadphase, 32-bit layer/mask filtering,
/// [Narrowphase3D] manifold generation, spatial overlap queries, and
/// start/stay/end callback dispatch.
class CollisionSystem3D({
  var bool autoStep = true,
  double fatMargin = 0.12,
  super.priority,
}) extends Component with HasWorldRef<World3D> {
  /// Incremental SAH dynamic AABB broadphase tree over active [Collider3D]s.
  final DynamicAabbTree3D<Collider3D> broadphaseTree =
      DynamicAabbTree3D<Collider3D>(fatMargin: fatMargin);

  final Set<Collider3D> _manualColliders = {};
  final Set<Collider3D> _mountedColliders = {};
  final List<Collider3D> _activeColliders = [];
  final List<Component> _walkStack = [];
  bool _collidersDirty = true;
  final Map<Collider3D, int> _proxyIds = {};
  final Set<Collider3D> _activeSetScratch = {};
  final List<Collider3D> _staleScratch = [];
  Map<_ColliderPairKey, (Collider3D, Collider3D)> _activePairs = {};
  Map<_ColliderPairKey, (Collider3D, Collider3D)> _nextPairs = {};

  Collider3D? _stepQueryCollider;
  int _stepQueryProxy = -1;
  late final void Function(int, Collider3D) _onStepCandidate =
      _handleStepCandidate;

  @override
  void onMount() {
    super.onMount();
    final root = parent;
    if (root != null) {
      _walkStack
        ..clear()
        ..add(root);
      while (_walkStack.isNotEmpty) {
        final comp = _walkStack.removeLast();
        if (comp is Collider3D) {
          registerMountedCollider(comp);
        }
        _walkStack.addAll(comp.children);
      }
    }
  }

  @override
  void onRemove() {
    for (final c in _mountedColliders) {
      c.enclosingCollisionSystems.remove(this);
    }
    _mountedColliders.clear();
    _collidersDirty = true;
    super.onRemove();
  }

  /// Registers [collider] mounted under this system's parent. Called when a
  /// [Collider3D] mounts.
  @internal
  void registerMountedCollider(Collider3D collider) {
    if (_mountedColliders.add(collider)) {
      collider.enclosingCollisionSystems.add(this);
      _collidersDirty = true;
    }
  }

  /// Unregisters a mounted [collider] when removed from the tree.
  @internal
  void unregisterMountedCollider(Collider3D collider) {
    if (_mountedColliders.remove(collider)) {
      _collidersDirty = true;
      if (!_manualColliders.contains(collider)) {
        final proxy = _proxyIds.remove(collider);
        if (proxy != null) {
          broadphaseTree.remove(proxy);
        }
        _flushRemovedCollider(collider);
      }
    }
  }

  /// Registers [collider] with every enclosing [CollisionSystem3D] sibling of
  /// its ancestors.
  @internal
  static void attachToEnclosingSystems(Collider3D collider) {
    var ancestor = collider.parent;
    while (ancestor != null) {
      for (final sibling in ancestor.children) {
        if (sibling is CollisionSystem3D) {
          sibling.registerMountedCollider(collider);
        }
      }
      ancestor = ancestor.parent;
    }
  }

  /// Explicitly registers [collider] for standalone or unmounted simulation.
  void register(Collider3D collider) {
    if (_manualColliders.add(collider)) {
      _collidersDirty = true;
    }
  }

  /// Unregisters a manually registered [collider] and fires any pending end
  /// callbacks for pairs involving it.
  void unregister(Collider3D collider) {
    if (_manualColliders.remove(collider)) {
      _collidersDirty = true;
    }
    if (!_mountedColliders.contains(collider)) {
      final proxy = _proxyIds.remove(collider);
      if (proxy != null) {
        broadphaseTree.remove(proxy);
      }
      _flushRemovedCollider(collider);
    }
  }

  void _refreshColliders() {
    final root = parent;
    final walk = root != null && !isMounted;
    if (!walk && !_collidersDirty) {
      return;
    }
    _collidersDirty = false;
    _activeColliders.clear();
    final seen = _activeSetScratch..clear();

    for (final c in _manualColliders) {
      if (seen.add(c)) {
        _activeColliders.add(c);
      }
    }
    for (final c in _mountedColliders) {
      if (seen.add(c)) {
        _activeColliders.add(c);
      }
    }
    if (walk) {
      _walkStack
        ..clear()
        ..add(root);
      while (_walkStack.isNotEmpty) {
        final comp = _walkStack.removeLast();
        if (comp is Collider3D && seen.add(comp)) {
          _activeColliders.add(comp);
        }
        _walkStack.addAll(comp.children);
      }
    }

    if (_proxyIds.length != _activeColliders.length ||
        _proxyIds.keys.any((c) => !seen.contains(c))) {
      _staleScratch.clear();
      for (final c in _proxyIds.keys) {
        if (!seen.contains(c)) {
          _staleScratch.add(c);
        }
      }
      for (var i = 0; i < _staleScratch.length; i++) {
        final proxy = _proxyIds.remove(_staleScratch[i]);
        if (proxy != null) {
          broadphaseTree.remove(proxy);
        }
      }
    }
  }

  /// Collects all active colliders (both mounted in the enclosing world/parent
  /// tree and manually registered via [register]).
  List<Collider3D> collectColliders([List<Collider3D>? out]) {
    _refreshColliders();
    final result = out ?? <Collider3D>[];
    if (!identical(result, _activeColliders)) {
      result
        ..clear()
        ..addAll(_activeColliders);
    }
    return result;
  }

  /// Synchronizes [broadphaseTree] with all currently active colliders,
  /// returning the active collider list.
  List<Collider3D> syncBroadphase() {
    _refreshColliders();
    for (var i = 0; i < _activeColliders.length; i++) {
      final c = _activeColliders[i];
      final moved = c.refreshCachedWorldAabb();
      final existingProxy = _proxyIds[c];
      if (existingProxy == null) {
        _proxyIds[c] = broadphaseTree.insert(c, c.cachedWorldAabb);
      } else if (moved) {
        broadphaseTree.update(existingProxy, c.cachedWorldAabb);
      }
    }
    return _activeColliders;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (autoStep) {
      step();
    }
  }

  /// Runs one broadphase + narrowphase detection pass and dispatches
  /// [CollisionCallbacks3D] and [TriggerVolume3D] events.
  void step() {
    final colliders = syncBroadphase();
    final nextPairs = _nextPairs..clear();

    for (var i = 0; i < colliders.length; i++) {
      final a = colliders[i];
      if (a.isStatic) {
        continue;
      }
      _stepQueryCollider = a;
      _stepQueryProxy = _proxyIds[a]!;
      broadphaseTree.queryAabbCallback(a.cachedWorldAabb, _onStepCandidate);
    }
    _stepQueryCollider = null;

    for (final entry in _activePairs.entries) {
      if (!nextPairs.containsKey(entry.key)) {
        final (first, second) = entry.value;
        _dispatchEnd(first, second);
        _dispatchEnd(second, first);
      }
    }

    final prev = _activePairs;
    _activePairs = nextPairs;
    _nextPairs = prev..clear();
  }

  void _handleStepCandidate(int proxyB, Collider3D b) {
    final a = _stepQueryCollider!;
    if (!b.isStatic && proxyB <= _stepQueryProxy) {
      return;
    }
    if (!a.canCollideWith(b)) {
      return;
    }
    if (!aabbOverlaps(a.cachedWorldAabb, b.cachedWorldAabb)) {
      return;
    }

    // Canonical pair ordering so manifold A->B direction is deterministic.
    final swap = identityHashCode(a) > identityHashCode(b);
    final first = swap ? b : a;
    final second = swap ? a : b;

    final manifold = Narrowphase3D.test(
      first.shape,
      first.colliderWorldMatrix,
      second.shape,
      second.colliderWorldMatrix,
    );
    if (manifold == null) {
      return;
    }

    final key = _ColliderPairKey(first, second);
    final wasActive = _activePairs.containsKey(key);
    _nextPairs[key] = (first, second);

    final flipped = _hasCollisionReceiver(second) ? manifold.flipped() : null;
    if (!wasActive) {
      _dispatchStart(first, second, manifold);
      if (flipped != null) {
        _dispatchStart(second, first, flipped);
      }
    } else {
      _dispatchStay(first, second, manifold);
      if (flipped != null) {
        _dispatchStay(second, first, flipped);
      }
    }
  }

  static bool _hasCollisionReceiver(Collider3D c) {
    if (c is TriggerVolume3D || c is CollisionCallbacks3D) {
      return true;
    }
    final p = c.parent;
    return p is CollisionCallbacks3D && !identical(p, c);
  }

  /// Queries all colliders overlapping [shape] at [worldTransform].
  List<(Collider3D collider, CollisionManifold3D manifold)> overlapShape(
    Shape3D shape,
    Matrix4 worldTransform, {
    int collisionMask = 0xFFFFFFFF,
    bool includeTriggers = true,
    bool Function(Collider3D collider)? filter,
  }) {
    syncBroadphase();
    shape.computeWorldAabb(worldTransform, _queryAabb);
    final hits = <(Collider3D, CollisionManifold3D)>[];

    broadphaseTree.queryAabbCallback(_queryAabb, (_, c) {
      if (!includeTriggers && c.isTrigger) {
        return;
      }
      if ((c.collisionLayer & collisionMask) == 0) {
        return;
      }
      if (filter != null && !filter(c)) {
        return;
      }
      if (!aabbOverlaps(_queryAabb, c.colliderWorldAabb)) {
        return;
      }
      final manifold = Narrowphase3D.test(
        shape,
        worldTransform,
        c.shape,
        c.colliderWorldMatrix,
      );
      if (manifold != null) {
        hits.add((c, manifold));
      }
    });
    return hits;
  }

  /// Returns all colliders confirmed by narrowphase to overlap the sphere at
  /// [center] with [radius] matching [mask].
  List<Collider3D> overlapSphere(
    Vector3 center,
    double radius, {
    int mask = 0xFFFFFFFF,
    bool includeTriggers = true,
    bool Function(Collider3D collider)? filter,
  }) {
    if (radius <= 0.0) {
      return const [];
    }
    syncBroadphase();
    _candidatesScratch.clear();
    broadphaseTree.querySphere(center, radius, out: _candidatesScratch);
    if (_candidatesScratch.isEmpty) {
      return const [];
    }

    final sphere = SphereShape3D(radius: radius);
    _queryTransform.setIdentity();
    _queryTransform.setTranslation(center);
    sphere.computeWorldAabb(_queryTransform, _queryAabb);

    final hits = <Collider3D>[];
    for (var i = 0; i < _candidatesScratch.length; i++) {
      final c = _candidatesScratch[i];
      if (!includeTriggers && c.isTrigger) {
        continue;
      }
      if ((c.collisionLayer & mask) == 0) {
        continue;
      }
      if (filter != null && !filter(c)) {
        continue;
      }
      if (!aabbOverlaps(_queryAabb, c.colliderWorldAabb)) {
        continue;
      }
      final manifold = Narrowphase3D.test(
        sphere,
        _queryTransform,
        c.shape,
        c.colliderWorldMatrix,
      );
      if (manifold != null) {
        hits.add(c);
      }
    }
    return hits;
  }

  /// Returns all colliders confirmed by narrowphase to overlap an oriented box
  /// at [center] with [halfExtents] and optional [rotation] matching [mask].
  List<Collider3D> overlapBox(
    Vector3 center,
    Vector3 halfExtents, {
    Quaternion? rotation,
    int mask = 0xFFFFFFFF,
    bool includeTriggers = true,
    bool Function(Collider3D collider)? filter,
  }) {
    if (halfExtents.x <= 0.0 || halfExtents.y <= 0.0 || halfExtents.z <= 0.0) {
      return const [];
    }
    final boxShape = BoxShape3D(halfExtents: halfExtents);
    _queryTransform.setFromTranslationRotationScale(
      center,
      rotation ?? _identityQuat,
      _unitScale,
    );
    final raw = overlapShape(
      boxShape,
      _queryTransform,
      collisionMask: mask,
      includeTriggers: includeTriggers,
      filter: filter,
    );
    return [for (final (c, _) in raw) c];
  }

  /// Returns all colliders confirmed by narrowphase to overlap the capsule
  /// sweeping segment `[p0, p1]` with cap [radius] matching [mask].
  List<Collider3D> overlapCapsule(
    Vector3 p0,
    Vector3 p1,
    double radius, {
    int mask = 0xFFFFFFFF,
    bool includeTriggers = true,
    bool Function(Collider3D collider)? filter,
  }) {
    if (radius <= 0.0) {
      return const [];
    }
    final dx = p1.x - p0.x;
    final dy = p1.y - p0.y;
    final dz = p1.z - p0.z;
    final segLen = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (segLen <= 1e-7) {
      return overlapSphere(
        p0,
        radius,
        mask: mask,
        includeTriggers: includeTriggers,
        filter: filter,
      );
    }

    final capsule = CapsuleShape3D(
      radius: radius,
      height: segLen + 2.0 * radius,
    );
    _segMid.setValues(
      0.5 * (p0.x + p1.x),
      0.5 * (p0.y + p1.y),
      0.5 * (p0.z + p1.z),
    );
    _alignYToSegment(dx / segLen, dy / segLen, dz / segLen, _segRot);
    _queryTransform.setFromTranslationRotationScale(
      _segMid,
      _segRot,
      _unitScale,
    );
    final raw = overlapShape(
      capsule,
      _queryTransform,
      collisionMask: mask,
      includeTriggers: includeTriggers,
      filter: filter,
    );
    return [for (final (c, _) in raw) c];
  }

  /// Returns all colliders confirmed by narrowphase to intersect [frustum]
  /// matching [mask].
  List<Collider3D> overlapFrustum(
    Frustum frustum, {
    int mask = 0xFFFFFFFF,
    bool includeTriggers = true,
    bool Function(Collider3D collider)? filter,
  }) {
    syncBroadphase();
    _candidatesScratch.clear();
    broadphaseTree.queryFrustum(frustum, out: _candidatesScratch);
    if (_candidatesScratch.isEmpty) {
      return const [];
    }

    final hits = <Collider3D>[];
    for (var i = 0; i < _candidatesScratch.length; i++) {
      final c = _candidatesScratch[i];
      if (!includeTriggers && c.isTrigger) {
        continue;
      }
      if ((c.collisionLayer & mask) == 0) {
        continue;
      }
      if (filter != null && !filter(c)) {
        continue;
      }
      if (_shapeOverlapsFrustum(
        c.shape,
        c.colliderWorldMatrix,
        c.colliderWorldAabb,
        frustum,
      )) {
        hits.add(c);
      }
    }
    return hits;
  }

  /// Casts [worldRay] against registered/mounted colliders within
  /// [maxDistance], returning the closest [ColliderRayHit3D] or `null`.
  ColliderRayHit3D? raycastColliders(
    Ray worldRay, {
    double maxDistance = double.infinity,
    int collisionMask = 0xFFFFFFFF,
    bool includeTriggers = true,
    bool Function(Collider3D collider)? filter,
  }) {
    if (!(maxDistance > 0.0)) {
      return null;
    }
    final dirLen = worldRay.direction.length;
    if (dirLen <= 1e-12) {
      return null;
    }
    syncBroadphase();

    final treeHit = broadphaseTree.raycast(
      worldRay,
      maxDistance: maxDistance,
      filter: (c) {
        if (!includeTriggers && c.isTrigger) {
          return false;
        }
        if ((c.collisionLayer & collisionMask) == 0) {
          return false;
        }
        return filter == null || filter(c);
      },
      narrowphase: (c, unitRay, limit) {
        if (!rayHitsAabb(unitRay, c.colliderWorldAabb, limit)) {
          return null;
        }
        final hit = c.shape.raycast(
          unitRay,
          c.colliderWorldMatrix,
          maxDistance: limit,
        );
        return hit == null ? null : (hit.$1, hit.$2);
      },
    );
    if (treeHit == null || treeHit.normal == null) {
      return null;
    }

    _unitRay.origin.setFrom(worldRay.origin);
    _unitRay.direction
      ..setFrom(worldRay.direction)
      ..scale(1.0 / dirLen);
    final t = treeHit.distance;
    return ColliderRayHit3D(
      collider: treeHit.item,
      distance: t,
      point: Vector3(
        _unitRay.origin.x + _unitRay.direction.x * t,
        _unitRay.origin.y + _unitRay.direction.y * t,
        _unitRay.origin.z + _unitRay.direction.z * t,
      ),
      normal: treeHit.normal!,
    );
  }

  /// Casts [worldRay] against registered/mounted colliders within
  /// [maxDistance], returning all narrowphase hits sorted by ascending
  /// distance.
  List<ColliderRayHit3D> raycastAllColliders(
    Ray worldRay, {
    double maxDistance = double.infinity,
    int collisionMask = 0xFFFFFFFF,
    bool includeTriggers = true,
    bool Function(Collider3D collider)? filter,
  }) {
    if (!(maxDistance > 0.0)) {
      return const [];
    }
    final dirLen = worldRay.direction.length;
    if (dirLen <= 1e-12) {
      return const [];
    }
    syncBroadphase();

    final treeHits = broadphaseTree.raycastAll(
      worldRay,
      maxDistance: maxDistance,
      filter: (c) {
        if (!includeTriggers && c.isTrigger) {
          return false;
        }
        if ((c.collisionLayer & collisionMask) == 0) {
          return false;
        }
        return filter == null || filter(c);
      },
      narrowphase: (c, unitRay, limit) {
        if (!rayHitsAabb(unitRay, c.colliderWorldAabb, limit)) {
          return null;
        }
        final hit = c.shape.raycast(
          unitRay,
          c.colliderWorldMatrix,
          maxDistance: limit,
        );
        return hit == null ? null : (hit.$1, hit.$2);
      },
    );
    if (treeHits.isEmpty) {
      return const [];
    }

    _unitRay.origin.setFrom(worldRay.origin);
    _unitRay.direction
      ..setFrom(worldRay.direction)
      ..scale(1.0 / dirLen);
    return [
      for (final h in treeHits)
        if (h.normal != null)
          ColliderRayHit3D(
            collider: h.item,
            distance: h.distance,
            point: Vector3(
              _unitRay.origin.x + _unitRay.direction.x * h.distance,
              _unitRay.origin.y + _unitRay.direction.y * h.distance,
              _unitRay.origin.z + _unitRay.direction.z * h.distance,
            ),
            normal: h.normal!,
          ),
    ];
  }

  bool _shapeOverlapsFrustum(
    Shape3D shape,
    Matrix4 worldTransform,
    Aabb3 worldAabb,
    Frustum frustum,
  ) {
    final cull = worldAabb.frustumCullTest(frustum);
    if (cull == CullResult.outside) {
      return false;
    }
    if (cull == CullResult.inside) {
      return true;
    }
    if (shape is CompoundShape3D) {
      final childMat = Matrix4.identity();
      final childBox = Aabb3();
      for (var i = 0; i < shape.children.length; i++) {
        final child = shape.children[i];
        childMat
          ..setFrom(worldTransform)
          ..multiply(child.localTransform);
        child.shape.computeWorldAabb(childMat, childBox);
        if (_shapeOverlapsFrustum(child.shape, childMat, childBox, frustum)) {
          return true;
        }
      }
      return false;
    }
    if (shape is HeightfieldShape3D) {
      return true;
    }
    return _supportInsidePlane(shape, worldTransform, frustum.plane0) &&
        _supportInsidePlane(shape, worldTransform, frustum.plane1) &&
        _supportInsidePlane(shape, worldTransform, frustum.plane2) &&
        _supportInsidePlane(shape, worldTransform, frustum.plane3) &&
        _supportInsidePlane(shape, worldTransform, frustum.plane4) &&
        _supportInsidePlane(shape, worldTransform, frustum.plane5);
  }

  bool _supportInsidePlane(
    Shape3D shape,
    Matrix4 worldTransform,
    Plane plane,
  ) {
    shape.supportPoint(plane.normal, worldTransform, _frustumSupScratch);
    return plane.normal.dot(_frustumSupScratch) + plane.constant >= 0.0;
  }

  static void _alignYToSegment(
    double ux,
    double uy,
    double uz,
    Quaternion out,
  ) {
    // Rotate `(0, 1, 0)` onto unit vector `(ux, uy, uz)`.
    if (uy > 0.999999) {
      out.setValues(0.0, 0.0, 0.0, 1.0);
      return;
    }
    if (uy < -0.999999) {
      out.setValues(1.0, 0.0, 0.0, 0.0);
      return;
    }
    // `(0, 1, 0) x (ux, uy, uz) = (uz, 0, -ux)`.
    final s = math.sqrt((1.0 + uy) * 2.0);
    final invS = 1.0 / s;
    out.setValues(uz * invS, 0.0, -ux * invS, 0.5 * s);
    out.normalize();
  }

  void _flushRemovedCollider(Collider3D removed) {
    final toRemove = <_ColliderPairKey>[];
    for (final entry in _activePairs.entries) {
      final (first, second) = entry.value;
      if (identical(first, removed) || identical(second, removed)) {
        toRemove.add(entry.key);
        _dispatchEnd(first, second);
        _dispatchEnd(second, first);
      }
    }
    for (final k in toRemove) {
      _activePairs.remove(k);
    }
  }

  static void _dispatchStart(
    Collider3D receiver,
    Collider3D other,
    CollisionManifold3D manifold,
  ) {
    if (receiver is TriggerVolume3D) {
      receiver.handleEnter3D(other, manifold);
    }
    if (receiver case final CollisionCallbacks3D cb) {
      cb.onCollisionStart3D(other, manifold);
    }
    final p = receiver.parent;
    if (p is CollisionCallbacks3D && !identical(p, receiver)) {
      p.onCollisionStart3D(other, manifold);
    }
  }

  static void _dispatchStay(
    Collider3D receiver,
    Collider3D other,
    CollisionManifold3D manifold,
  ) {
    if (receiver is TriggerVolume3D) {
      receiver.handleStay3D(other, manifold);
    }
    if (receiver case final CollisionCallbacks3D cb) {
      cb.onCollision3D(other, manifold);
    }
    final p = receiver.parent;
    if (p is CollisionCallbacks3D && !identical(p, receiver)) {
      p.onCollision3D(other, manifold);
    }
  }

  static void _dispatchEnd(Collider3D receiver, Collider3D other) {
    if (receiver is TriggerVolume3D) {
      receiver.handleExit3D(other);
    }
    if (receiver case final CollisionCallbacks3D cb) {
      cb.onCollisionEnd3D(other);
    }
    final p = receiver.parent;
    if (p is CollisionCallbacks3D && !identical(p, receiver)) {
      p.onCollisionEnd3D(other);
    }
  }

  static final Quaternion _identityQuat = Quaternion.identity();
  static final Vector3 _unitScale = Vector3.all(1.0);

  final List<Collider3D> _candidatesScratch = [];
  final Aabb3 _queryAabb = Aabb3();
  final Matrix4 _queryTransform = Matrix4.identity();
  final Vector3 _segMid = Vector3.zero();
  final Quaternion _segRot = Quaternion.identity();
  final Vector3 _frustumSupScratch = Vector3.zero();
  final Ray _unitRay = Ray();
}

@immutable
class const _ColliderPairKey(this.a, this.b) {
  final Collider3D a;
  final Collider3D b;

  @override
  bool operator ==(Object other) {
    return other is _ColliderPairKey &&
        ((identical(a, other.a) && identical(b, other.b)) ||
            (identical(a, other.b) && identical(b, other.a)));
  }

  @override
  int get hashCode => identityHashCode(a) ^ identityHashCode(b);
}
