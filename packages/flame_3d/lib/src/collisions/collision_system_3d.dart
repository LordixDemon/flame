part of 'collider_3d.dart';

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
    shape.computeWorldAabb(worldTransform, _queryScratch.queryAabb);
    final hits = <(Collider3D, CollisionManifold3D)>[];

    broadphaseTree.queryAabbCallback(_queryScratch.queryAabb, (_, c) {
      if (!includeTriggers && c.isTrigger) {
        return;
      }
      if ((c.collisionLayer & collisionMask) == 0) {
        return;
      }
      if (filter != null && !filter(c)) {
        return;
      }
      if (!aabbOverlaps(_queryScratch.queryAabb, c.colliderWorldAabb)) {
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
    _queryScratch.candidatesScratch.clear();
    broadphaseTree.querySphere(
      center,
      radius,
      out: _queryScratch.candidatesScratch,
    );
    if (_queryScratch.candidatesScratch.isEmpty) {
      return const [];
    }

    final sphere = SphereShape3D(radius: radius);
    _queryScratch.queryTransform.setIdentity();
    _queryScratch.queryTransform.setTranslation(center);
    sphere.computeWorldAabb(
      _queryScratch.queryTransform,
      _queryScratch.queryAabb,
    );

    final hits = <Collider3D>[];
    for (var i = 0; i < _queryScratch.candidatesScratch.length; i++) {
      final c = _queryScratch.candidatesScratch[i];
      if (!includeTriggers && c.isTrigger) {
        continue;
      }
      if ((c.collisionLayer & mask) == 0) {
        continue;
      }
      if (filter != null && !filter(c)) {
        continue;
      }
      if (!aabbOverlaps(_queryScratch.queryAabb, c.colliderWorldAabb)) {
        continue;
      }
      final manifold = Narrowphase3D.test(
        sphere,
        _queryScratch.queryTransform,
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
    _queryScratch.queryTransform.setFromTranslationRotationScale(
      center,
      rotation ?? _CollisionQueryScratch.identityQuat,
      _CollisionQueryScratch.unitScale,
    );
    final raw = overlapShape(
      boxShape,
      _queryScratch.queryTransform,
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
    _queryScratch.segMid.setValues(
      0.5 * (p0.x + p1.x),
      0.5 * (p0.y + p1.y),
      0.5 * (p0.z + p1.z),
    );
    _alignYToSegment(
      dx / segLen,
      dy / segLen,
      dz / segLen,
      _queryScratch.segRot,
    );
    _queryScratch.queryTransform.setFromTranslationRotationScale(
      _queryScratch.segMid,
      _queryScratch.segRot,
      _CollisionQueryScratch.unitScale,
    );
    final raw = overlapShape(
      capsule,
      _queryScratch.queryTransform,
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
    _queryScratch.candidatesScratch.clear();
    broadphaseTree.queryFrustum(frustum, out: _queryScratch.candidatesScratch);
    if (_queryScratch.candidatesScratch.isEmpty) {
      return const [];
    }

    final hits = <Collider3D>[];
    for (var i = 0; i < _queryScratch.candidatesScratch.length; i++) {
      final c = _queryScratch.candidatesScratch[i];
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

    _queryScratch.unitRay.origin.setFrom(worldRay.origin);
    _queryScratch.unitRay.direction
      ..setFrom(worldRay.direction)
      ..scale(1.0 / dirLen);
    final t = treeHit.distance;
    return ColliderRayHit3D(
      collider: treeHit.item,
      distance: t,
      point: Vector3(
        _queryScratch.unitRay.origin.x + _queryScratch.unitRay.direction.x * t,
        _queryScratch.unitRay.origin.y + _queryScratch.unitRay.direction.y * t,
        _queryScratch.unitRay.origin.z + _queryScratch.unitRay.direction.z * t,
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

    _queryScratch.unitRay.origin.setFrom(worldRay.origin);
    _queryScratch.unitRay.direction
      ..setFrom(worldRay.direction)
      ..scale(1.0 / dirLen);
    return [
      for (final h in treeHits)
        if (h.normal != null)
          ColliderRayHit3D(
            collider: h.item,
            distance: h.distance,
            point: Vector3(
              _queryScratch.unitRay.origin.x +
                  _queryScratch.unitRay.direction.x * h.distance,
              _queryScratch.unitRay.origin.y +
                  _queryScratch.unitRay.direction.y * h.distance,
              _queryScratch.unitRay.origin.z +
                  _queryScratch.unitRay.direction.z * h.distance,
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
    shape.supportPoint(
      plane.normal,
      worldTransform,
      _queryScratch.frustumSupScratch,
    );
    return plane.normal.dot(_queryScratch.frustumSupScratch) + plane.constant >=
        0.0;
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

  final _CollisionQueryScratch _queryScratch = _CollisionQueryScratch();
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

class _CollisionQueryScratch() {
  static final Quaternion identityQuat = Quaternion.identity();
  static final Vector3 unitScale = Vector3.all(1.0);

  final List<Collider3D> candidatesScratch = [];
  final Aabb3 queryAabb = Aabb3();
  final Matrix4 queryTransform = Matrix4.identity();
  final Vector3 segMid = Vector3.zero();
  final Quaternion segRot = Quaternion.identity();
  final Vector3 frustumSupScratch = Vector3.zero();
  final Ray unitRay = Ray();
}
