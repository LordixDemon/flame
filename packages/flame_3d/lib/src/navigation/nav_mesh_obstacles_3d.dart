part of 'nav_mesh_3d.dart';

extension _NavMeshObstacles3D on NavMesh3D {
  /// Sets the traversal [cost] (`> 0`) of all walkable polygons intersecting
  /// [bounds] in `O(log P)` via the navmesh BVH, returning the number of
  /// updated polygons.
  int _setRegionCostInAabbImpl(Aabb3 bounds, double cost) {
    assert(cost > 0, 'region cost must be positive');
    if (polygons.isEmpty) {
      return 0;
    }
    _bvhCandidatesScratch.clear();
    _bvh.queryAabb(bounds, _bvhCandidatesScratch);
    var updated = 0;
    for (var i = 0; i < _bvhCandidatesScratch.length; i++) {
      final pIdx = _bvhCandidatesScratch[i];
      final poly = polygons[pIdx];
      if (_triangleIntersectsAabb(
        vertices[poly.v0],
        vertices[poly.v1],
        vertices[poly.v2],
        bounds,
      )) {
        _polygonCosts[pIdx] = cost;
        updated++;
      }
    }
    if (updated > 0 && cost < _minPolygonCost) {
      _minPolygonCost = cost;
    }
    return updated;
  }

  /// Dynamically blocks all walkable polygons intersected by [obstacle] in
  /// `O(log P)` via the BVH.
  void _addObstacleImpl(NavMeshObstacle3D obstacle) {
    if (_obstaclePolys.containsKey(obstacle)) {
      updateObstacle(obstacle);
      return;
    }
    final blocked = obstacle.enabled
        ? _computeBlockedPolygons(obstacle)
        : Int32List(0);
    _obstaclePolys[obstacle] = blocked;
    _incrementRefCounts(blocked);
    _linksDirty = true;
  }

  /// Refreshes the blocked polygon set after [obstacle] moves, rotates,
  /// resizes, or toggles `enabled`.
  void _updateObstacleImpl(NavMeshObstacle3D obstacle) {
    final prev = _obstaclePolys[obstacle];
    if (prev != null) {
      _decrementRefCounts(prev);
    }
    final next = obstacle.enabled
        ? _computeBlockedPolygons(obstacle)
        : Int32List(0);
    _obstaclePolys[obstacle] = next;
    _incrementRefCounts(next);
    _linksDirty = true;
  }

  /// Removes [obstacle] and immediately unblocks its polygons.
  void _removeObstacleImpl(NavMeshObstacle3D obstacle) {
    final prev = _obstaclePolys.remove(obstacle);
    if (prev != null) {
      _decrementRefCounts(prev);
      _linksDirty = true;
    }
  }

  /// Registers an [OffMeshLink3D] (jump, drop, ladder, or teleporter) for
  /// seamless A* traversal.
  void _addOffMeshLinkImpl(OffMeshLink3D link) {
    if (!_offMeshLinks.contains(link)) {
      _offMeshLinks.add(link);
      _linksDirty = true;
    }
  }

  /// Unregisters [link].
  void _removeOffMeshLinkImpl(OffMeshLink3D link) {
    if (_offMeshLinks.remove(link)) {
      _linksDirty = true;
    }
  }

  void _incrementRefCounts(Int32List polyIds) {
    for (var i = 0; i < polyIds.length; i++) {
      final p = polyIds[i];
      if (_polyObstacleRefCount[p] == 0) {
        _blockedPolyCount++;
      }
      _polyObstacleRefCount[p]++;
    }
  }

  void _decrementRefCounts(Int32List polyIds) {
    for (var i = 0; i < polyIds.length; i++) {
      final p = polyIds[i];
      if (_polyObstacleRefCount[p] > 0) {
        _polyObstacleRefCount[p]--;
        if (_polyObstacleRefCount[p] == 0) {
          _blockedPolyCount--;
        }
      }
    }
  }

  void _ensureLinksResolved() {
    if (!_linksDirty) {
      for (var i = 0; i < _offMeshLinks.length; i++) {
        if (_offMeshLinks[i]._changedSinceResolve()) {
          _linksDirty = true;
          break;
        }
      }
      if (!_linksDirty) {
        return;
      }
    }
    _linksDirty = false;
    _resolvedLinks.clear();
    _linksFromPoly.clear();
    for (var i = 0; i < _offMeshLinks.length; i++) {
      _offMeshLinks[i]._markResolved();
    }
    if (polygons.isEmpty || _offMeshLinks.isEmpty) {
      return;
    }

    for (var i = 0; i < _offMeshLinks.length; i++) {
      final link = _offMeshLinks[i];
      if (!link.enabled) {
        continue;
      }
      final sHit = findNearestPoly(link.start);
      final eHit = findNearestPoly(link.end);
      if (sHit == null || eHit == null || sHit.polyIndex == eHit.polyIndex) {
        continue;
      }
      final snap2 = link.snapRadius * link.snapRadius;
      if (sHit.distanceSquared > snap2 || eHit.distanceSquared > snap2) {
        continue;
      }
      final baseDist = math.max(1e-3, sHit.point.distanceTo(eHit.point));
      final cost = baseDist * link.costMultiplier;
      _addResolvedLink(
        _ResolvedOffMeshLink(
          link: link,
          fromPoly: sHit.polyIndex,
          toPoly: eHit.polyIndex,
          entryPoint: sHit.point,
          exitPoint: eHit.point,
          cost: cost,
        ),
      );
      if (link.bidirectional) {
        _addResolvedLink(
          _ResolvedOffMeshLink(
            link: link,
            fromPoly: eHit.polyIndex,
            toPoly: sHit.polyIndex,
            entryPoint: eHit.point,
            exitPoint: sHit.point,
            cost: cost,
          ),
        );
      }
    }
  }

  void _addResolvedLink(_ResolvedOffMeshLink resolved) {
    (_linksFromPoly[resolved.fromPoly] ??= <int>[]).add(_resolvedLinks.length);
    _resolvedLinks.add(resolved);
  }
}

void _toLocalObb(
  Vector3 worldPt,
  Vector3 center,
  Quaternion invRot,
  Vector3 out,
) {
  out
    ..setFrom(worldPt)
    ..sub(center);
  invRot.rotate(out);
}
