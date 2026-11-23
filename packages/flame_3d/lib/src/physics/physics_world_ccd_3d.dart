part of 'physics_world_3d.dart';

extension _PhysicsWorldCcd3D on PhysicsWorld3D {
  void _integrateBodyPose(RigidBody3D b, double dt) {
    final hasCom = b.hasCenterOfMassOffset;
    if (hasCom) {
      _comScratch.setFrom(b.worldCenterOfMass);
    }

    final lv = b.linearVelocity;
    if (hasCom) {
      _comScratch.addScaled(lv, dt);
    } else if (lv.x != 0.0 || lv.y != 0.0 || lv.z != 0.0) {
      final pos = b.bodyPosition;
      pos.setValues(pos.x + lv.x * dt, pos.y + lv.y * dt, pos.z + lv.z * dt);
    }

    final av = b.angularVelocity;
    final wLen = av.length;
    if (wLen > 1e-9) {
      final angle = wLen * dt;
      final half = 0.5 * angle;
      final s = math.sin(half) / wLen;
      final dqx = av.x * s;
      final dqy = av.y * s;
      final dqz = av.z * s;
      final dqw = math.cos(half);

      final q = b.bodyRotation;
      final qx = q.x;
      final qy = q.y;
      final qz = q.z;
      final qw = q.w;

      final nx = dqw * qx + dqx * qw + dqy * qz - dqz * qy;
      final ny = dqw * qy - dqx * qz + dqy * qw + dqz * qx;
      final nz = dqw * qz + dqx * qy - dqy * qx + dqz * qw;
      final nw = dqw * qw - dqx * qx - dqy * qy - dqz * qz;
      final invNorm = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz + nw * nw);
      q.setValues(nx * invNorm, ny * invNorm, nz * invNorm, nw * invNorm);
      b.updateWorldInertia();
    }

    if (hasCom) {
      rotateVectorByQuat(
        b.bodyRotation,
        b.localCenterOfMass,
        _rotOffsetScratch,
      );
      b.bodyPosition.setValues(
        _comScratch.x - _rotOffsetScratch.x,
        _comScratch.y - _rotOffsetScratch.y,
        _comScratch.z - _rotOffsetScratch.z,
      );
    }
  }

  void _integrateBodyWithCcd(
    RigidBody3D b,
    double totalDt,
    double rCcd,
    CollisionSystem3D? colSys,
  ) {
    var sphere = _ccdSphere;
    if (sphere == null || sphere.radius != rCcd) {
      sphere = _ccdSphere = SphereShape3D(radius: rCcd);
    }
    var remDt = totalDt;
    const maxImpacts = 3;

    for (var sub = 0; remDt > 1e-7; sub++) {
      _ccdDelta
        ..setFrom(b.linearVelocity)
        ..scale(remDt);
      final sweepLen = _ccdDelta.length;
      if (sweepLen <= math.max(1e-4, rCcd * 0.25)) {
        _integrateBodyPose(b, remDt);
        return;
      }

      final com = b.worldCenterOfMass;
      final startX = com.x;
      final startY = com.y;
      final startZ = com.z;
      _ccdStartMat
        ..setIdentity()
        ..setTranslationRaw(startX, startY, startZ);

      final endX = startX + _ccdDelta.x;
      final endY = startY + _ccdDelta.y;
      final endZ = startZ + _ccdDelta.z;
      _ccdSweptAabb
        ..min.setValues(
          math.min(startX, endX) - rCcd,
          math.min(startY, endY) - rCcd,
          math.min(startZ, endZ) - rCcd,
        )
        ..max.setValues(
          math.max(startX, endX) + rCcd,
          math.max(startY, endY) + rCcd,
          math.max(startZ, endZ) + rCcd,
        );

      _ccdBody = b;
      _ccdBestHit = null;
      _ccdHitBody = null;
      _ccdHitCollider = null;
      _ccdMaxToi = 1.0;

      // 1. Swept TOI against RigidBody3D obstacles in `broadphaseTree`.
      broadphaseTree.queryAabbCallback(_ccdSweptAabb, _onCcdBody);
      // 2. Swept TOI against the solid colliders of the collision system.
      if (colSys != null) {
        colSys.broadphaseTree.queryAabbCallback(_ccdSweptAabb, _onCcdCollider);
      }
      _ccdBody = null;

      final impact = _ccdBestHit;
      if (impact == null || impact.toi >= 1.0) {
        _integrateBodyPose(b, remDt);
        return;
      }

      final skinDist = math.min(0.002, rCcd * 0.05);
      final safeToi = math.max(0.0, impact.toi - skinDist / sweepLen);
      _integrateBodyPose(b, safeToi * remDt);

      // Refresh `b`'s proxy in the broadphase tree after moving to impact.
      final proxy = _bodyProxies[b];
      if (proxy != null) {
        b.refreshCachedWorldAabb();
        broadphaseTree.update(proxy, b.cachedWorldAabb);
      }

      if (sub >= maxImpacts) {
        // Out of impact budget: stop at the obstacle for the rest of the
        // step; the discrete contacts of the next step take over.
        return;
      }

      // Resolve the impact like a contact (restitution, friction, and the
      // effective mass at the contact point).
      final other = _ccdHitBody ?? _colliderProxy(_ccdHitCollider!);
      other.wakeUp();
      // `impact.normal` points from the obstacle toward `b`, so the A-to-B
      // normal (`b -> other`) is `-impact.normal`.
      final n = impact.normal;
      final p = impact.point;
      final c = _ccdConstraint
        ..loadSinglePoint(
          b,
          other,
          -n.x,
          -n.y,
          -n.z,
          p.x,
          p.y,
          p.z,
          0.001,
          restitutionVelocityThreshold,
        )
        ..prepare(_scratchVec, remDt, warmStart: false);
      for (var it = 0; it < velocityIterations; it++) {
        c.solveVelocity(_scratchVec);
      }

      final consumed = math.max(impact.toi, 0.05).clamp(0.0, 1.0);
      remDt *= 1.0 - consumed;
    }
  }

  void _sweepAgainstBody(int _, RigidBody3D other) {
    final b = _ccdBody!;
    if (identical(other, b) ||
        !b.canCollideWith(other) ||
        _jointBlocksCollision(b, other)) {
      return;
    }
    if (!aabbOverlaps(_ccdSweptAabb, other.cachedWorldAabb)) {
      return;
    }
    final hit = ShapeCast3D.castShapeAgainstShape(
      shapeA: _ccdSphere!,
      startTransformA: _ccdStartMat,
      delta: _ccdDelta,
      shapeB: other.shape,
      transformB: other.bodyWorldMatrix,
      maxToi: _ccdMaxToi,
      component: other.hostComponent,
    );
    if (hit == null || hit.toi > _ccdMaxToi) {
      return;
    }
    final prevBody = _ccdHitBody;
    // Equal times of impact: the lower creation id wins, whatever the order
    // in which the tree visits the candidates.
    if (hit.toi == _ccdMaxToi &&
        _ccdBestHit != null &&
        (_ccdHitCollider != null ||
            (prevBody != null &&
                prevBody.deterministicId < other.deterministicId))) {
      return;
    }
    _ccdMaxToi = hit.toi;
    _ccdBestHit = hit;
    _ccdHitBody = other;
    _ccdHitCollider = null;
  }

  void _sweepAgainstCollider(int _, Collider3D collider) {
    final b = _ccdBody!;
    if (!PhysicsWorld3D._isSolidColliderFor(collider, b)) {
      return;
    }
    if (!aabbOverlaps(_ccdSweptAabb, collider.colliderWorldAabb)) {
      return;
    }
    final hit = ShapeCast3D.castShapeAgainstShape(
      shapeA: _ccdSphere!,
      startTransformA: _ccdStartMat,
      delta: _ccdDelta,
      shapeB: collider.shape,
      transformB: collider.colliderWorldMatrix,
      maxToi: _ccdMaxToi,
      component: collider.hostComponent,
      collider: collider,
    );
    if (hit == null || hit.toi > _ccdMaxToi) {
      return;
    }
    final prevCollider = _ccdHitCollider;
    if (hit.toi == _ccdMaxToi &&
        _ccdBestHit != null &&
        (prevCollider == null ||
            (_colliderOrder[prevCollider] ?? 0) <
                (_colliderOrder[collider] ?? 0))) {
      return;
    }
    _ccdMaxToi = hit.toi;
    _ccdBestHit = hit;
    _ccdHitBody = null;
    _ccdHitCollider = collider;
  }
}
