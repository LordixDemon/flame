part of 'nav_mesh_3d.dart';

extension _NavMeshPathfinder3D on NavMesh3D {
  /// Clamps an arbitrary 3D [point] onto the closest unblocked walkable
  /// triangle, returning `null` when no unblocked walkable polygon exists.
  NavPolyHit3D? _findNearestPolyImpl(
    Vector3 point, {
    bool ignoreObstacles = false,
  }) {
    if (polygons.isEmpty) {
      return null;
    }
    return _bvh.findNearest(
      point,
      vertices,
      polygons,
      ignoreObstacles ? null : _polyObstacleRefCount,
    );
  }

  /// Computes the raw A* corridor of polygon centroids between [start] and
  /// [goal] (without funnel string-pulling), returning `[]` if unreachable.
  List<Vector3> _findCentroidPathImpl(
    Vector3 start,
    Vector3 goal,
    NavQueryContext3D ctx,
  ) {
    final sHit = findNearestPoly(start);
    final gHit = findNearestPoly(goal);
    if (sHit == null || gHit == null) {
      return const [];
    }
    final res = _astarSearch(ctx, sHit.polyIndex, gHit.polyIndex, gHit.point);
    if (res == null) {
      return const [];
    }
    return [
      sHit.point.clone(),
      for (final pIdx in res.polySequence) polygons[pIdx].centroid.clone(),
      gHit.point.clone(),
    ];
  }

  /// Plans a path from [start] to [goal] segmented into surface walk legs and
  /// [OffMeshLink3D] traversal legs (preserving `linkTag` metadata such as
  /// `'jump'` or `'ladder'`).
  List<NavPathSegment3D> _findSegmentedPathImpl(
    Vector3 start,
    Vector3 goal,
    NavQueryContext3D ctx,
  ) {
    final sHit = findNearestPoly(start);
    final gHit = findNearestPoly(goal);
    if (sHit == null || gHit == null) {
      return const [];
    }
    if (sHit.polyIndex == gHit.polyIndex) {
      final pts = sHit.point.distanceToSquared(gHit.point) <= 1e-12
          ? [sHit.point.clone()]
          : [sHit.point.clone(), gHit.point.clone()];
      return [NavPathSegment3D(waypoints: pts)];
    }

    _ensureLinksResolved();
    List<int>? polySeq;
    List<int>? edgeLinkIndices;
    if (_resolvedLinks.isEmpty) {
      // Straight line of cheapest polygons from start to goal: nothing can be
      // shorter, so the search is skipped.
      final direct = <int>[];
      if (_raycastWalk(
        sHit.polyIndex,
        sHit.point,
        gHit.point,
        gHit.polyIndex,
        _minPolygonCost + 1e-9,
        direct,
      )) {
        polySeq = direct;
        edgeLinkIndices = List<int>.filled(direct.length - 1, -1);
      }
    }
    if (polySeq == null || edgeLinkIndices == null) {
      final search = _astarSearch(
        ctx,
        sHit.polyIndex,
        gHit.polyIndex,
        gHit.point,
      );
      if (search == null) {
        return const [];
      }
      polySeq = search.polySequence;
      edgeLinkIndices = search.edgeLinkIndices;
    }

    final segments = <NavPathSegment3D>[];
    var subStartIdx = 0;
    var subStartPoint = sHit.point;

    for (var e = 0; e < edgeLinkIndices.length; e++) {
      final linkIdx = edgeLinkIndices[e];
      if (linkIdx < 0) {
        continue;
      }
      final resolved = _resolvedLinks[linkIdx];

      // 1. Walk segment from `subStartPoint` (`polySeq[subStartIdx..e]`) to
      // `resolved.entryPoint`.
      final walkPts = _funnelSubCorridor(
        ctx,
        polySeq,
        subStartIdx,
        e,
        subStartPoint,
        resolved.entryPoint,
      );
      if (walkPts.isNotEmpty) {
        segments.add(NavPathSegment3D(waypoints: walkPts));
      }

      // 2. Off-mesh link traversal segment `[entryPoint, exitPoint]`.
      segments.add(
        NavPathSegment3D(
          waypoints: [resolved.entryPoint.clone(), resolved.exitPoint.clone()],
          offMeshLink: resolved.link,
          linkTag: resolved.link.linkTag,
        ),
      );

      subStartIdx = e + 1;
      subStartPoint = resolved.exitPoint;
    }

    // Final walk segment from `subStartPoint` to `gHit.point`.
    final tailWalk = _funnelSubCorridor(
      ctx,
      polySeq,
      subStartIdx,
      polySeq.length - 1,
      subStartPoint,
      gHit.point,
    );
    if (tailWalk.isNotEmpty) {
      segments.add(NavPathSegment3D(waypoints: tailWalk));
    }
    return segments;
  }

  /// Finds a short 3D path between [start] and [goal] by clamping both
  /// endpoints onto the navmesh, running cost-aware A* over portals and
  /// [OffMeshLink3D]s, and string-pulling surface legs via the **3D Simple
  /// Stupid Funnel** algorithm with portal-edge elevation draping.
  ///
  /// When the straight line from start to goal stays on polygons of the
  /// lowest cost (and no off-mesh link is registered), it is returned
  /// directly without a search. Otherwise the funnel runs over the A*
  /// corridor widened along lines of sight and around every bend at a vertex
  /// that is not on the boundary of the walkable area, so paths over open
  /// ground are straight and bend only at real corners: of walls, of blocked
  /// polygons, and of more expensive regions that the search avoided. The
  /// result is the shortest path through the chosen sequence of open regions;
  /// it can still be longer than the true shortest path when A* chose a
  /// different way around an obstacle. Waypoints the path goes straight
  /// through are left out; extra waypoints are inserted where the path
  /// crosses a portal at a different elevation (ramps, steps).
  List<Vector3> _findPathImpl(
    Vector3 start,
    Vector3 goal,
    NavQueryContext3D ctx,
  ) {
    final segments = findSegmentedPath(start, goal, context: ctx);
    if (segments.isEmpty) {
      return const [];
    }
    if (segments.length == 1) {
      return [for (final p in segments.first.waypoints) p.clone()];
    }
    final combined = <Vector3>[];
    for (var s = 0; s < segments.length; s++) {
      final wps = segments[s].waypoints;
      for (var i = 0; i < wps.length; i++) {
        final pt = wps[i];
        if (combined.isEmpty || combined.last.distanceToSquared(pt) > 1e-10) {
          combined.add(pt.clone());
        }
      }
    }
    return combined;
  }

  _AStarCorridorResult? _astarSearch(
    NavQueryContext3D ctx,
    int startPoly,
    int goalPoly,
    Vector3 goalPoint,
  ) {
    if (_polyObstacleRefCount[startPoly] > 0 ||
        _polyObstacleRefCount[goalPoly] > 0) {
      return null;
    }
    _ensureLinksResolved();

    final n = polygons.length;
    ctx._ensureAStarCapacity(n);
    final gScore = ctx._gScore!;
    final cameFrom = ctx._cameFrom!;
    final cameViaLink = ctx._cameViaLink!;
    final openStamp = ctx._openStamp!;
    final closedStamp = ctx._closedStamp!;
    final heap = ctx._heap!;
    final stamp = ctx._nextStamp(n);
    heap.clear();

    // Admissible heuristic scaled by `_minPolygonCost` (zeroed when off-mesh
    // links exist so teleport/jump shortcuts are never pruned sub-optimally!).
    final hScale = _resolvedLinks.isEmpty ? _minPolygonCost : 0.0;

    gScore[startPoly] = 0.0;
    cameFrom[startPoly] = -1;
    cameViaLink[startPoly] = -1;
    openStamp[startPoly] = stamp;
    heap.push(
      startPoly,
      polygons[startPoly].centroid.distanceTo(goalPoint) * hScale,
    );

    while (!heap.isEmpty) {
      final current = heap.pop();
      if (current == goalPoly) {
        heap.clear();
        final revPolys = <int>[];
        final revLinks = <int>[];
        var curr = goalPoly;
        while (curr != -1) {
          revPolys.add(curr);
          final prev = cameFrom[curr];
          if (prev != -1) {
            revLinks.add(cameViaLink[curr]);
          }
          curr = prev;
        }
        return _AStarCorridorResult(
          polySequence: revPolys.reversed.toList(growable: false),
          edgeLinkIndices: revLinks.reversed.toList(growable: false),
        );
      }
      if (closedStamp[current] == stamp) {
        continue;
      }
      closedStamp[current] = stamp;

      final portals = polygons[current].portals;
      final curG = gScore[current];
      final curCost = _polygonCosts[current];

      // 1. Shared-edge surface portals.
      for (var i = 0; i < portals.length; i++) {
        final portal = portals[i];
        final next = portal.targetPoly;
        if (closedStamp[next] == stamp || _polyObstacleRefCount[next] > 0) {
          continue;
        }
        final areaWeight = 0.5 * (curCost + _polygonCosts[next]);
        final tentativeG = curG + portal.cost * areaWeight;
        if (openStamp[next] != stamp || tentativeG < gScore[next]) {
          openStamp[next] = stamp;
          gScore[next] = tentativeG;
          cameFrom[next] = current;
          cameViaLink[next] = -1;
          final f =
              tentativeG +
              polygons[next].centroid.distanceTo(goalPoint) * hScale;
          heap.pushOrDecrease(next, f);
        }
      }

      // 2. Outgoing OffMeshLink3D connections originating on `current`.
      final outgoing = _linksFromPoly[current];
      if (outgoing != null) {
        for (var k = 0; k < outgoing.length; k++) {
          final l = outgoing[k];
          final rl = _resolvedLinks[l];
          final next = rl.toPoly;
          if (closedStamp[next] == stamp || _polyObstacleRefCount[next] > 0) {
            continue;
          }
          final approach =
              polygons[current].centroid.distanceTo(rl.entryPoint) * curCost +
              polygons[next].centroid.distanceTo(rl.exitPoint) *
                  _polygonCosts[next];
          final tentativeG = curG + rl.cost + approach * 0.5;
          if (openStamp[next] != stamp || tentativeG < gScore[next]) {
            openStamp[next] = stamp;
            gScore[next] = tentativeG;
            cameFrom[next] = current;
            cameViaLink[next] = l;
            final f =
                tentativeG +
                polygons[next].centroid.distanceTo(goalPoint) * hScale;
            heap.pushOrDecrease(next, f);
          }
        }
      }
    }
    heap.clear();
    return null;
  }

  double _horizDist2(Vector3 a, Vector3 b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final dz = b.z - a.z;
    final du = dx * _basisU.x + dy * _basisU.y + dz * _basisU.z;
    final dv = dx * _basisV.x + dy * _basisV.y + dz * _basisV.z;
    return du * du + dv * dv;
  }

  double _triArea2Horiz(Vector3 a, Vector3 b, Vector3 c) {
    return _triArea2Up(a, b, c, upAxis);
  }
}
