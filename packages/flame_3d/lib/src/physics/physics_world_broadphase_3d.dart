part of 'physics_world_3d.dart';

extension _PhysicsWorldBroadphase3D on PhysicsWorld3D {
  CollisionSystem3D? _resolveCollisionSystem() {
    if (collisionSystem != null) {
      return collisionSystem;
    }
    final root = parent;
    if (root != null) {
      for (final child in root.children) {
        if (child is CollisionSystem3D) {
          return child;
        }
      }
    }
    return null;
  }

  /// Rebuilds [_activeBodies] (sorted by creation id) when the registered set
  /// changed. A world that has a parent but is not mounted (a component tree
  /// built without a game) searches its parent's subtree on every step.
  void _refreshBodies() {
    final root = parent;
    final walk = root != null && !isMounted;
    if (!walk && !_bodiesDirty) {
      return;
    }
    _bodiesDirty = false;
    _activeBodies.clear();
    final seen = _seenBodiesScratch..clear();
    for (var i = 0; i < _manualBodies.length; i++) {
      final b = _manualBodies[i];
      if (seen.add(b)) {
        _activeBodies.add(b);
      }
    }
    for (final b in _mountedBodies) {
      if (seen.add(b)) {
        _activeBodies.add(b);
      }
    }
    if (walk) {
      _walkStack
        ..clear()
        ..add(root);
      while (_walkStack.isNotEmpty) {
        final comp = _walkStack.removeLast();
        if (comp is RigidBody3D && seen.add(comp)) {
          _activeBodies.add(comp);
        }
        _walkStack.addAll(comp.children);
      }
    }
    // Deterministic ordering by `deterministicId`.
    _activeBodies.sort(PhysicsWorld3D._compareIds);

    // Drop broadphase proxies of bodies that left the world.
    if (_bodyProxies.length > _activeBodies.length || walk) {
      _staleBodiesScratch.clear();
      for (final b in _bodyProxies.keys) {
        if (!seen.contains(b)) {
          _staleBodiesScratch.add(b);
        }
      }
      for (var i = 0; i < _staleBodiesScratch.length; i++) {
        final proxy = _bodyProxies.remove(_staleBodiesScratch[i]);
        if (proxy != null) {
          broadphaseTree.remove(proxy);
        }
      }
    }
  }

  void _syncBroadphaseTree() {
    for (var i = 0; i < _activeBodies.length; i++) {
      final b = _activeBodies[i];
      final moved = b.refreshCachedWorldAabb();
      final existing = _bodyProxies[b];
      if (existing == null) {
        _bodyProxies[b] = broadphaseTree.insert(b, b.cachedWorldAabb);
      } else if (moved) {
        broadphaseTree.update(existing, b.cachedWorldAabb);
      }
    }
  }

  /// Synchronizes the collision system's tree and the deterministic order of
  /// its colliders (their position in `collectColliders`).
  void _syncColliders(CollisionSystem3D? colSys) {
    if (colSys == null) {
      return;
    }
    final colliders = colSys.syncBroadphase();
    var same =
        identical(colSys, _orderedSystem) &&
        colliders.length == _colliderOrderList.length;
    for (var i = 0; same && i < colliders.length; i++) {
      same = identical(colliders[i], _colliderOrderList[i]);
    }
    if (same) {
      return;
    }
    _orderedSystem = colSys;
    _colliderOrderList
      ..clear()
      ..addAll(colliders);
    _colliderOrder.clear();
    for (var i = 0; i < colliders.length; i++) {
      _colliderOrder[colliders[i]] = i;
    }
    // Forget proxies of colliders that are gone.
    _staleColliderScratch.clear();
    for (final c in _colliderProxies.keys) {
      if (!_colliderOrder.containsKey(c)) {
        _staleColliderScratch.add(c);
      }
    }
    for (final c in _staleColliderScratch) {
      final proxy = _colliderProxies.remove(c);
      if (proxy != null) {
        _proxyColliders.remove(proxy);
      }
    }
  }

  /// The static infinite-mass body standing in for [collider] in contacts.
  RigidBody3D _colliderProxy(Collider3D collider) {
    var proxy = _colliderProxies[collider];
    if (proxy == null) {
      proxy = RigidBody3D(
        shape: collider.shape,
        bodyType: BodyType3D.static,
        syncParent: false,
      );
      _colliderProxies[collider] = proxy;
      _proxyColliders[proxy] = collider;
    }
    proxy.material = collider.material;
    return proxy;
  }

  bool _jointBlocksCollision(RigidBody3D a, RigidBody3D b) {
    for (var i = 0; i < _joints.length; i++) {
      final j = _joints[i];
      if (!j.collideConnected &&
          ((identical(j.bodyA, a) && identical(j.bodyB, b)) ||
              (identical(j.bodyA, b) && identical(j.bodyB, a)))) {
        return true;
      }
    }
    return false;
  }

  void _collectBodyCandidate(int _, RigidBody3D cand) {
    final bodyA = _queryBody!;
    if (cand.deterministicId <= bodyA.deterministicId) {
      return;
    }
    if (!bodyA.canCollideWith(cand)) {
      return;
    }
    if (PhysicsWorld3D._isInactive(bodyA) && PhysicsWorld3D._isInactive(cand)) {
      return;
    }
    if (!aabbOverlaps(bodyA.cachedWorldAabb, cand.cachedWorldAabb)) {
      return;
    }
    if (_jointBlocksCollision(bodyA, cand)) {
      return;
    }
    _pairCandidates.add(cand);
  }

  void _collectColliderCandidate(int _, Collider3D collider) {
    final body = _queryBody!;
    if (!PhysicsWorld3D._isSolidColliderFor(collider, body)) {
      return;
    }
    if (!aabbOverlaps(body.cachedWorldAabb, collider.colliderWorldAabb)) {
      return;
    }
    _colliderCandidates.add(collider);
  }

  int _compareColliderOrder(Collider3D a, Collider3D b) =>
      (_colliderOrder[a] ?? 0).compareTo(_colliderOrder[b] ?? 0);
}
