part of 'physics_world_3d.dart';

extension _PhysicsWorldSnapshotAccess3D on PhysicsWorld3D {
  /// Internal snapshot hook: the warm-start history of every contact pair,
  /// with bodies given as indices into [bodies] and static colliders as
  /// `colliderFlag | index` into the collision system's collider order.
  List<WarmContactRecord3D> _exportWarmStartRecordsImpl(
    List<RigidBody3D> bodies,
  ) {
    final index = <RigidBody3D, int>{
      for (var i = 0; i < bodies.length; i++) bodies[i]: i,
    };
    final keyed = <(int, int, _ContactPair3D)>[];
    for (final pair in _pairList) {
      final a = index[pair.bodyA];
      if (a == null) {
        continue;
      }
      var b = index[pair.bodyB];
      if (b == null) {
        final collider = _proxyColliders[pair.bodyB];
        final order = collider == null ? null : _colliderOrder[collider];
        if (order == null) {
          continue;
        }
        b = WarmContactRecord3D.colliderFlag | order;
      }
      keyed.add((a, b, pair));
    }
    keyed.sort((x, y) => x.$1 != y.$1 ? x.$1 - y.$1 : x.$2 - y.$2);
    final records = <WarmContactRecord3D>[];
    for (final (a, b, pair) in keyed) {
      for (var m = 0; m < pair.manifoldCount; m++) {
        final c = pair.constraintAt(m);
        for (var k = 0; k < c.prevCount; k++) {
          const stride = _ContactConstraint3D.historyStride;
          records.add(
            WarmContactRecord3D(
              bodyA: a,
              bodyB: b,
              manifold: m,
              featureId: c.prevIds[k],
              values: Float64List.sublistView(
                c.prevImpulses,
                k * stride,
                (k + 1) * stride,
              ),
            ),
          );
        }
      }
    }
    return records;
  }

  /// Internal snapshot hook restoring the simulation clock and the warm-start
  /// history exported by [exportWarmStartRecords], with record bodies looked
  /// up in [bodies] (`null` entries are skipped).
  void _restoreInternalStateImpl({
    required int tick,
    required double accumulator,
    required List<RigidBody3D?> bodies,
    required List<WarmContactRecord3D> warmRecords,
  }) {
    _tick = tick;
    _accumulator = accumulator;
    for (final pair in _pairList) {
      _pairPool.add(pair);
    }
    _pairList.clear();
    _pairsByBodyA.clear();

    final colSys = _resolveCollisionSystem();
    _syncColliders(colSys);
    for (final r in warmRecords) {
      if (r.bodyA < 0 || r.bodyA >= bodies.length) {
        continue;
      }
      final a = bodies[r.bodyA];
      if (a == null) {
        continue;
      }
      RigidBody3D? b;
      if ((r.bodyB & WarmContactRecord3D.colliderFlag) != 0) {
        final order = r.bodyB & ~WarmContactRecord3D.colliderFlag;
        if (order < _colliderOrderList.length) {
          b = _colliderProxy(_colliderOrderList[order]);
        }
      } else if (r.bodyB >= 0 && r.bodyB < bodies.length) {
        b = bodies[r.bodyB];
      }
      if (b == null) {
        continue;
      }
      final pair = _acquirePair(a, b)..lastTick = tick;
      if (r.manifold + 1 > pair.manifoldCount) {
        pair.manifoldCount = r.manifold + 1;
      }
      pair.constraintAt(r.manifold).appendHistory(r.featureId, r.values, 0);
    }
    _bodiesDirty = true;
    _refreshBodies();
    _syncBroadphaseTree();
  }
}

class WarmContactRecord3D({
  required final int bodyA,
  required final int bodyB,
  required final int manifold,
  required final int featureId,
  required Float64List values,
}) {
  /// Number of doubles in [values].
  static const int valueCount = _ContactConstraint3D.historyStride;

  /// Normal impulse, friction impulse and contact offset (a copy).
  final Float64List values = Float64List.fromList(values);

  /// Set in [bodyB] when it names a static collider instead of a body.
  static const int colliderFlag = 0x40000000;
}
