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
  List<Vector3> _findCentroidPathImpl(Vector3 start, Vector3 goal) {
    final sHit = findNearestPoly(start);
    final gHit = findNearestPoly(goal);
    if (sHit == null || gHit == null) {
      return const [];
    }
    final res = _astarSearch(sHit.polyIndex, gHit.polyIndex, gHit.point);
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
  List<NavPathSegment3D> _findSegmentedPathImpl(Vector3 start, Vector3 goal) {
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
      final search = _astarSearch(sHit.polyIndex, gHit.polyIndex, gHit.point);
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
  List<Vector3> _findPathImpl(Vector3 start, Vector3 goal) {
    final segments = findSegmentedPath(start, goal);
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

  List<Vector3> _funnelSubCorridor(
    List<int> corridor,
    int fromIdx,
    int toIdx,
    Vector3 startPt,
    Vector3 goalPt,
  ) {
    if (fromIdx == toIdx) {
      if (startPt.distanceToSquared(goalPt) <= 1e-12) {
        return [startPt.clone()];
      }
      return [startPt.clone(), goalPt.clone()];
    }

    final polys = corridor.sublist(fromIdx, toIdx + 1);
    if (!_tightenCorridor(polys, startPt, goalPt)) {
      return const [];
    }

    final cornerPoints = _cornerPoints;
    final cornerPortals = _cornerPortal;
    final smoothWaypoints = <Vector3>[cornerPoints.first.clone()];
    for (var s = 0; s < cornerPoints.length - 1; s++) {
      final wpA = cornerPoints[s];
      final wpB = cornerPoints[s + 1];
      final pStart = math.min(cornerPortals[s], cornerPortals[s + 1]);
      final pEnd = math.max(cornerPortals[s], cornerPortals[s + 1]);
      _drapeSegmentAcrossPortals(
        wpA,
        wpB,
        pStart,
        pEnd,
        _portalLeft,
        _portalRight,
        smoothWaypoints,
      );
      smoothWaypoints.add(wpB.clone());
    }
    return smoothWaypoints;
  }

  /// String-pulls [polys] from [startPt] to [goalPt], widening the corridor
  /// until the path is taut, and leaves the result in the corner scratch
  /// lists. Returns `false` when consecutive polygons do not share a portal.
  ///
  /// The funnel gives the shortest path inside the corridor that A* chose,
  /// but on a fine mesh (a voxel grid, a terrain) many corridors tie and the
  /// chosen one is often a staircase, so the path bends at vertices that are
  /// not obstacles. A shortest path only bends at vertices on the boundary of
  /// the walkable area. So every bend at a vertex whose polygon fan is
  /// complete is removed by moving the corridor to the other side of that
  /// vertex (which strictly shortens the path), until no such bend remains.
  /// Polygons more expensive than the ones they replace, blocked polygons and
  /// polygons already in the corridor are never added.
  bool _tightenCorridor(List<int> polys, Vector3 startPt, Vector3 goalPt) {
    if (!_buildCorridorPortals(polys, startPt, goalPt)) {
      return false;
    }
    _stringPull();
    if (_cornerPoints.length > 2 && _shortcutByVisibility(polys, goalPt)) {
      if (!_buildCorridorPortals(polys, startPt, goalPt)) {
        return false;
      }
      _stringPull();
    }
    var length = _cornerPathLength();
    final maxRounds = 32 + polys.length;
    Set<int>? members;
    for (var round = 0; round < maxRounds; round++) {
      final previous = List<int>.of(polys);
      if (!_widenAtFreeCorners(polys, members ??= polys.toSet())) {
        return true;
      }
      if (!_buildCorridorPortals(polys, startPt, goalPt)) {
        polys
          ..clear()
          ..addAll(previous);
        break;
      }
      _stringPull();
      final next = _cornerPathLength();
      if (next >= length - 1e-9) {
        polys
          ..clear()
          ..addAll(previous);
        break;
      }
      length = next;
    }
    // Restore the corner lists of the corridor that was kept.
    _buildCorridorPortals(polys, startPt, goalPt);
    _stringPull();
    return true;
  }

  /// Replaces stretches of [polys] by the polygons along straight lines of
  /// sight: from the start, the farthest corner of the current path that a
  /// straight walk over the mesh reaches (through polygons no more expensive
  /// than the stretch it replaces) becomes the next anchor, and so on. Uses
  /// the corner lists of the current corridor. Returns whether [polys]
  /// changed.
  bool _shortcutByVisibility(List<int> polys, Vector3 goalPt) {
    final cornerCount = _cornerPoints.length;
    final last = cornerCount - 1;
    final oldIndex = <int, int>{};
    for (var i = 0; i < polys.length; i++) {
      oldIndex[polys[i]] = i;
    }
    final targets = List<Vector3>.filled(cornerCount, goalPt);
    final targetIdx = List<int>.filled(cornerCount, polys.length - 1);
    for (var j = 1; j < last; j++) {
      // A point just inside the polygon the path enters at corner `j`.
      final idx = _cornerPortal[j].clamp(0, polys.length - 1);
      final corner = _cornerPoints[j];
      final centroid = polygons[polys[idx]].centroid;
      targets[j] = Vector3.copy(corner)..addScaled(centroid - corner, 0.01);
      targetIdx[j] = idx;
    }

    final result = <int>[polys[0]];
    final inResult = <int>{polys[0]};
    final walk = <int>[];
    var anchor = _cornerPoints[0];
    var anchorIdx = 0;
    var k = 0;
    var changed = false;
    while (k < last) {
      var advanced = false;
      for (var j = last; j >= k + 2; j--) {
        final xIdx = targetIdx[j];
        if (xIdx <= anchorIdx) {
          continue;
        }
        var maxCost = 0.0;
        for (var i = anchorIdx; i <= xIdx; i++) {
          maxCost = math.max(maxCost, _polygonCosts[polys[i]]);
        }
        walk.clear();
        if (!_raycastWalk(
          polys[anchorIdx],
          anchor,
          targets[j],
          polys[xIdx],
          maxCost + 1e-9,
          walk,
        )) {
          continue;
        }
        var clash = false;
        for (var i = 1; i < walk.length && !clash; i++) {
          final q = walk[i];
          final o = oldIndex[q];
          clash = inResult.contains(q) || (o != null && o > xIdx);
        }
        if (clash) {
          continue;
        }
        for (var i = 1; i < walk.length; i++) {
          result.add(walk[i]);
          inResult.add(walk[i]);
        }
        anchor = targets[j];
        anchorIdx = xIdx;
        k = j;
        advanced = true;
        changed = true;
        break;
      }
      if (advanced) {
        continue;
      }
      // No line of sight beyond the next corner: keep the corridor up to it.
      final next = k + 1;
      final xIdx = math.max(anchorIdx, targetIdx[next]);
      for (var i = anchorIdx + 1; i <= xIdx; i++) {
        if (!inResult.add(polys[i])) {
          return false;
        }
        result.add(polys[i]);
      }
      anchor = targets[next];
      anchorIdx = xIdx;
      k = next;
    }
    if (!changed) {
      return false;
    }
    for (var i = anchorIdx + 1; i < polys.length; i++) {
      if (!inResult.add(polys[i])) {
        return false;
      }
      result.add(polys[i]);
    }
    polys
      ..clear()
      ..addAll(result);
    return true;
  }

  /// Walks the mesh from [fromPoly] along the straight horizontal line from
  /// [from] to [to] through shared edges, appending each polygon to [out].
  /// Succeeds when it reaches [targetPoly] containing [to]; fails at the
  /// boundary of the walkable area, at a blocked polygon, or at a polygon
  /// costing more than [maxCost].
  bool _raycastWalk(
    int fromPoly,
    Vector3 from,
    Vector3 to,
    int targetPoly,
    double maxCost,
    List<int> out,
  ) {
    final su = from.dot(_basisU);
    final sv = from.dot(_basisV);
    final du = to.dot(_basisU) - su;
    final dv = to.dot(_basisV) - sv;
    var cur = fromPoly;
    var prev = -1;
    for (var step = 0; step <= polygons.length; step++) {
      if (_polyObstacleRefCount[cur] > 0 || _polygonCosts[cur] > maxCost) {
        return false;
      }
      out.add(cur);
      if (cur == targetPoly) {
        return true;
      }
      final poly = polygons[cur];
      final a = vertices[poly.v0];
      final b = vertices[poly.v1];
      final c = vertices[poly.v2];
      final orient = _triArea2Horiz(a, b, c) >= 0.0 ? 1.0 : -1.0;
      var tExit = double.infinity;
      var exitA = -1;
      var exitB = -1;
      for (var e = 0; e < 3; e++) {
        final ia = e == 0 ? poly.v0 : (e == 1 ? poly.v1 : poly.v2);
        final ib = e == 0 ? poly.v1 : (e == 1 ? poly.v2 : poly.v0);
        final pa = vertices[ia];
        final pb = vertices[ib];
        final au = pa.dot(_basisU);
        final av = pa.dot(_basisV);
        final eu = pb.dot(_basisU) - au;
        final ev = pb.dot(_basisV) - av;
        // Outward normal of the edge in the horizontal plane.
        final nu = orient * ev;
        final nv = -orient * eu;
        final denom = nu * du + nv * dv;
        if (denom <= 1e-14) {
          continue;
        }
        final t = (nu * (au - su) + nv * (av - sv)) / denom;
        if (t < tExit) {
          tExit = t;
          exitA = ia;
          exitB = ib;
        }
      }
      if (exitA < 0) {
        return false;
      }
      var next = -1;
      var matches = 0;
      for (final portal in poly.portals) {
        final l = portal.leftVertex;
        final r = portal.rightVertex;
        if ((l == exitA && r == exitB) || (l == exitB && r == exitA)) {
          next = portal.targetPoly;
          matches++;
        }
      }
      if (tExit >= 1.0 - 1e-9) {
        // The line ends in this polygon (or on its edge): only an end point
        // on the edge shared with the target counts.
        if (matches == 1 && next == targetPoly && tExit <= 1.0 + 1e-6) {
          if (_polyObstacleRefCount[next] > 0 ||
              _polygonCosts[next] > maxCost) {
            return false;
          }
          out.add(next);
          return true;
        }
        return false;
      }
      if (matches != 1 || next == prev) {
        return false;
      }
      prev = cur;
      cur = next;
    }
    return false;
  }

  /// Moves the corridor to the other side of every bend vertex that has a
  /// free polygon fan, from the goal end back, skipping bends whose polygons
  /// overlap a change made earlier in the same pass. Returns whether
  /// anything changed.
  bool _widenAtFreeCorners(List<int> polys, Set<int> members) {
    final n = polys.length - 1; // portals are indices 1..n
    var limit = polys.length;
    var changed = false;
    for (var k = _cornerPoints.length - 2; k >= 1; k--) {
      final v = _cornerVertex[k];
      if (v < 0) {
        continue;
      }
      final sideVerts = _cornerSide[k] > 0
          ? _portalLeftVertex
          : _portalRightVertex;
      final p = _cornerPortal[k];
      if (p < 1 || p > n || sideVerts[p] != v) {
        continue;
      }
      var a = p;
      while (a - 1 >= 1 && sideVerts[a - 1] == v) {
        a--;
      }
      var b = p;
      while (b + 1 <= n && sideVerts[b + 1] == v) {
        b++;
      }
      final arcStart = a - 1;
      final arcEnd = b;
      if (arcEnd >= limit || arcStart < 0) {
        continue;
      }
      final replacement = _fanComplement(
        v,
        polys[arcStart],
        polys[arcStart + 1],
        polys[arcEnd],
      );
      if (replacement == null) {
        continue;
      }
      var maxCost = 0.0;
      for (var i = arcStart; i <= arcEnd; i++) {
        maxCost = math.max(maxCost, _polygonCosts[polys[i]]);
      }
      var accepted = true;
      for (var i = 0; i < replacement.length && accepted; i++) {
        final q = replacement[i];
        if (members.contains(q) || _polygonCosts[q] > maxCost + 1e-9) {
          accepted = false;
        }
      }
      if (!accepted) {
        continue;
      }
      for (var i = arcStart + 1; i < arcEnd; i++) {
        members.remove(polys[i]);
      }
      members.addAll(replacement);
      polys.replaceRange(arcStart + 1, arcEnd, replacement);
      limit = arcStart;
      changed = true;
    }
    return changed;
  }

  /// Walks around vertex [v] from [startPoly], away from [oldNext] (the
  /// polygon the corridor currently enters next), until [endPoly] is reached,
  /// returning the polygons strictly between them, or `null` when the walk
  /// meets the boundary of the walkable area (a missing, ambiguous or
  /// blocked neighbour), so that [v] is a real corner.
  List<int>? _fanComplement(int v, int startPoly, int oldNext, int endPoly) {
    final out = <int>[];
    var prev = oldNext;
    var cur = startPoly;
    for (var step = 0; step < 64; step++) {
      final poly = polygons[cur];
      final prevPoly = polygons[prev];
      // The vertex of `cur` shared with `prev` (besides `v`) marks the edge
      // the walk came across; it leaves through the edge to the other one.
      var exitVertex = -1;
      var sharedCount = 0;
      for (var c = 0; c < 3; c++) {
        final w = c == 0 ? poly.v0 : (c == 1 ? poly.v1 : poly.v2);
        if (w == v) {
          continue;
        }
        if (w == prevPoly.v0 || w == prevPoly.v1 || w == prevPoly.v2) {
          sharedCount++;
        } else {
          exitVertex = w;
        }
      }
      if (sharedCount != 1 || exitVertex < 0) {
        return null;
      }
      var next = -1;
      var matches = 0;
      for (final portal in poly.portals) {
        final l = portal.leftVertex;
        final r = portal.rightVertex;
        if ((l == v && r == exitVertex) || (l == exitVertex && r == v)) {
          next = portal.targetPoly;
          matches++;
        }
      }
      if (matches != 1 || _polyObstacleRefCount[next] > 0) {
        return null;
      }
      if (next == endPoly) {
        return out;
      }
      if (next == startPoly || next == oldNext) {
        return null;
      }
      out.add(next);
      prev = cur;
      cur = next;
    }
    return null;
  }

  bool _buildCorridorPortals(
    List<int> polys,
    Vector3 startPt,
    Vector3 goalPt,
  ) {
    _portalLeft
      ..clear()
      ..add(startPt);
    _portalRight
      ..clear()
      ..add(startPt);
    _portalLeftVertex
      ..clear()
      ..add(-1);
    _portalRightVertex
      ..clear()
      ..add(-1);
    for (var i = 0; i < polys.length - 1; i++) {
      final curr = polygons[polys[i]];
      final nextIdx = polys[i + 1];
      NavPortal3D? portal;
      for (var p = 0; p < curr.portals.length; p++) {
        if (curr.portals[p].targetPoly == nextIdx) {
          portal = curr.portals[p];
          break;
        }
      }
      if (portal == null) {
        return false;
      }
      _portalLeft.add(portal.left);
      _portalRight.add(portal.right);
      _portalLeftVertex.add(portal.leftVertex);
      _portalRightVertex.add(portal.rightVertex);
    }
    _portalLeft.add(goalPt);
    _portalRight.add(goalPt);
    _portalLeftVertex.add(-1);
    _portalRightVertex.add(-1);
    return true;
  }

  /// Simple Stupid Funnel over the portal scratch lists. Fills the corner
  /// lists with the path's corners, each with its portal index, the mesh
  /// vertex it sits on (`-1` for the end points) and its side (`1` left, `-1`
  /// right, `0` end point), and drops corners the path passes straight
  /// through.
  void _stringPull() {
    final portalsLeft = _portalLeft;
    final portalsRight = _portalRight;
    final startPt = portalsLeft.first;
    final goalPt = portalsLeft.last;
    final cornerPoints = _cornerPoints
      ..clear()
      ..add(startPt);
    final cornerPortals = _cornerPortal
      ..clear()
      ..add(0);
    final cornerVertices = _cornerVertex
      ..clear()
      ..add(-1);
    final cornerSides = _cornerSide
      ..clear()
      ..add(0);

    var apex = startPt;
    var portalLeft = startPt;
    var portalRight = startPt;
    var apexIndex = 0;
    var leftIndex = 0;
    var rightIndex = 0;

    for (var i = 1; i < portalsLeft.length; i++) {
      final left = portalsLeft[i];
      final right = portalsRight[i];

      if (_triArea2Horiz(apex, portalRight, right) >= 0.0) {
        if (_horizDist2(apex, portalRight) <= 1e-12 ||
            _triArea2Horiz(apex, portalLeft, right) < 0.0) {
          portalRight = right;
          rightIndex = i;
        } else {
          if (_horizDist2(cornerPoints.last, portalLeft) > 1e-10) {
            cornerPoints.add(portalLeft);
            cornerPortals.add(leftIndex);
            cornerVertices.add(_portalLeftVertex[leftIndex]);
            cornerSides.add(1);
          }
          apex = portalLeft;
          apexIndex = leftIndex;
          portalLeft = apex;
          portalRight = apex;
          leftIndex = apexIndex;
          rightIndex = apexIndex;
          i = apexIndex;
          continue;
        }
      }

      if (_triArea2Horiz(apex, portalLeft, left) <= 0.0) {
        if (_horizDist2(apex, portalLeft) <= 1e-12 ||
            _triArea2Horiz(apex, portalRight, left) > 0.0) {
          portalLeft = left;
          leftIndex = i;
        } else {
          if (_horizDist2(cornerPoints.last, portalRight) > 1e-10) {
            cornerPoints.add(portalRight);
            cornerPortals.add(rightIndex);
            cornerVertices.add(_portalRightVertex[rightIndex]);
            cornerSides.add(-1);
          }
          apex = portalRight;
          apexIndex = rightIndex;
          portalLeft = apex;
          portalRight = apex;
          leftIndex = apexIndex;
          rightIndex = apexIndex;
          i = apexIndex;
          continue;
        }
      }
    }

    final goalIndex = portalsLeft.length - 1;
    if (cornerPoints.length > 1 &&
        cornerPoints.last.distanceToSquared(goalPt) <= 1e-10) {
      cornerPoints.removeLast();
      cornerPortals.removeLast();
      cornerVertices.removeLast();
      cornerSides.removeLast();
    }
    if (cornerPoints.length == 1 &&
        startPt.distanceToSquared(goalPt) <= 1e-10) {
      cornerPortals[0] = goalIndex;
      return;
    }
    cornerPoints.add(goalPt);
    cornerPortals.add(goalIndex);
    cornerVertices.add(-1);
    cornerSides.add(0);

    // Drop corners the path goes straight through (the funnel reports a
    // corner wherever a portal end point is exactly on the current line).
    var kept = 1;
    for (var k = 1; k < cornerPoints.length - 1; k++) {
      final a = cornerPoints[kept - 1];
      final b = cornerPoints[k];
      final c = cornerPoints[k + 1];
      final ab = math.sqrt(_horizDist2(a, b));
      final bc = math.sqrt(_horizDist2(b, c));
      final cross = _triArea2Horiz(a, b, c).abs();
      if (ab <= 1e-9 || bc <= 1e-9 || cross <= 1e-6 * ab * bc) {
        continue;
      }
      cornerPoints[kept] = b;
      cornerPortals[kept] = cornerPortals[k];
      cornerVertices[kept] = cornerVertices[k];
      cornerSides[kept] = cornerSides[k];
      kept++;
    }
    final last = cornerPoints.length - 1;
    cornerPoints[kept] = cornerPoints[last];
    cornerPortals[kept] = cornerPortals[last];
    cornerVertices[kept] = cornerVertices[last];
    cornerSides[kept] = cornerSides[last];
    cornerPoints.length = kept + 1;
    cornerPortals.length = kept + 1;
    cornerVertices.length = kept + 1;
    cornerSides.length = kept + 1;
  }

  double _cornerPathLength() {
    var sum = 0.0;
    for (var i = 0; i < _cornerPoints.length - 1; i++) {
      sum += math.sqrt(_horizDist2(_cornerPoints[i], _cornerPoints[i + 1]));
    }
    return sum;
  }

  void _drapeSegmentAcrossPortals(
    Vector3 wpA,
    Vector3 wpB,
    int pStart,
    int pEnd,
    List<Vector3> portalsLeft,
    List<Vector3> portalsRight,
    List<Vector3> out,
  ) {
    if (pEnd - pStart <= 1) {
      return;
    }
    final au = wpA.dot(_basisU);
    final av = wpA.dot(_basisV);
    final bu = wpB.dot(_basisU);
    final bv = wpB.dot(_basisV);
    final du = bu - au;
    final dv = bv - av;
    final segLen2 = du * du + dv * dv;
    if (segLen2 <= 1e-10) {
      return;
    }

    var bestDev = 1e-3;
    Vector3? splitPoint;
    var splitPortal = -1;

    final aUp = wpA.dot(upAxis);
    final bUp = wpB.dot(upAxis);

    for (var p = pStart + 1; p < pEnd; p++) {
      final l = portalsLeft[p];
      final r = portalsRight[p];
      final lu = l.dot(_basisU);
      final lv = l.dot(_basisV);
      final eu = r.dot(_basisU) - lu;
      final ev = r.dot(_basisV) - lv;

      final denom = du * ev - dv * eu;
      if (denom.abs() <= 1e-10) {
        continue;
      }
      final inv = 1.0 / denom;
      final qx = lu - au;
      final qy = lv - av;
      final t = (qx * ev - qy * eu) * inv;
      final s = ((qx * dv - qy * du) * inv).clamp(0.0, 1.0);
      if (t <= 1e-3 || t >= 1.0 - 1e-3) {
        continue;
      }

      final crossPt = Vector3(
        l.x + (r.x - l.x) * s,
        l.y + (r.y - l.y) * s,
        l.z + (r.z - l.z) * s,
      );
      final chordUp = aUp + (bUp - aUp) * t;
      final dev = (crossPt.dot(upAxis) - chordUp).abs();
      if (dev > bestDev) {
        bestDev = dev;
        splitPoint = crossPt;
        splitPortal = p;
      }
    }

    if (splitPoint != null && splitPortal > pStart && splitPortal < pEnd) {
      _drapeSegmentAcrossPortals(
        wpA,
        splitPoint,
        pStart,
        splitPortal,
        portalsLeft,
        portalsRight,
        out,
      );
      out.add(splitPoint);
      _drapeSegmentAcrossPortals(
        splitPoint,
        wpB,
        splitPortal,
        pEnd,
        portalsLeft,
        portalsRight,
        out,
      );
    }
  }

  _AStarCorridorResult? _astarSearch(
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
    final gScore = _gScore ??= Float64List(n);
    final cameFrom = _cameFrom ??= Int32List(n);
    final cameViaLink = _cameViaLink ??= Int32List(n);
    final openStamp = _openStamp ??= Int32List(n);
    final closedStamp = _closedStamp ??= Int32List(n);
    final heap = _heap ??= _MinPolyHeap(n);
    if (_searchStamp >= 0x3FFFFFFF) {
      openStamp.fillRange(0, n, 0);
      closedStamp.fillRange(0, n, 0);
      _searchStamp = 0;
    }
    final stamp = ++_searchStamp;
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
