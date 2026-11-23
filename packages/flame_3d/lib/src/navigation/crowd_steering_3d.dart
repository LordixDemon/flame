import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';

/// A single 3D navigation crowd agent managed by [CrowdSteering3D].
class CrowdAgent3D({
  required Vector3 position,
  var double radius = 0.4,
  var double maxSpeed = 3.5,
  var double maxAcceleration = 18.0,
  var double waypointReachRadius = 0.25,
  var double arrivalSlowingRadius = 0.8,
  var double timeHorizon = 1.8,
  var double separationWeight = 2.5,
  Vector3? velocity,
  this.targetComponent,
}) {
  this : assert(radius > 0, 'radius must be positive');

  /// Current world-space position of this agent.
  final Vector3 position = position.clone();

  /// Current world-space velocity of this agent.
  final Vector3 velocity = velocity?.clone() ?? Vector3.zero();

  /// Optional visual [Component3D] synchronized to [position] every update.
  Component3D? targetComponent;

  List<Vector3> _path = const [];
  int _waypointIndex = 0;
  final Vector3 _nextVelocity = Vector3.zero();

  /// Current planned waypoint list.
  List<Vector3> get path => _path;

  /// Index of the active waypoint along [path].
  int get currentWaypointIndex => _waypointIndex;

  /// Whether this agent has arrived at the end of its [path] (or has no path).
  bool get hasReachedGoal => _waypointIndex >= _path.length;

  /// Assigns an explicit sequence of 3D [waypoints] to follow.
  void setPath(List<Vector3> waypoints) {
    _path = List.unmodifiable([for (final p in waypoints) p.clone()]);
    _waypointIndex = _path.length > 1 ? 1 : 0;
  }

  /// Plans and assigns a smooth funnel path from [position] to [goal] on
  /// [navMesh]. Returns `true` if a valid path was found.
  bool setDestination(Vector3 goal, NavMesh3D navMesh) {
    final planned = navMesh.findPath(position, goal);
    if (planned.isEmpty) {
      _path = const [];
      _waypointIndex = 0;
      return false;
    }
    setPath(planned);
    return true;
  }

  /// Clears the active path and stops desired motion.
  void stop() {
    _path = const [];
    _waypointIndex = 0;
  }
}

/// Multi-agent 3D crowd steering solver combining waypoint path following,
/// sampled-velocity Reciprocal Velocity-Obstacle (RVO) avoidance of the other
/// agents with right-hand symmetry breaking, separation, and optional
/// [NavMesh3D] surface clamping.
///
/// Agents avoid each other, not walls: they stay on the mesh only by
/// following their paths, and [navMesh] (when set) moves them onto the
/// walkable surface after each step, through [NavMesh3D.sampleHeightAt]
/// (`O(log P)` per agent).
class CrowdSteering3D({
  List<CrowdAgent3D>? agents,
  this.navMesh,
  Vector3? upAxis,
  var double safetyMargin = 0.04,
}) {
  /// Managed agents steered together each frame.
  final List<CrowdAgent3D> agents = agents != null
      ? List<CrowdAgent3D>.of(agents)
      : <CrowdAgent3D>[];

  /// Optional [NavMesh3D] used to keep agents clamped onto walkable ground.
  NavMesh3D? navMesh;

  /// Normalized vertical axis perpendicular to the horizontal steering plane.
  final Vector3 upAxis = (upAxis?.clone() ?? Vector3(0.0, 1.0, 0.0))
    ..normalize();

  /// Adds [agent] to the managed crowd.
  void addAgent(CrowdAgent3D agent) {
    if (!agents.contains(agent)) {
      agents.add(agent);
    }
  }

  /// Removes [agent] from the managed crowd.
  void removeAgent(CrowdAgent3D agent) {
    agents.remove(agent);
  }

  /// Advances all [agents] by [dt] seconds without overlapping one another.
  void update(double dt) {
    if (dt <= 0.0 || agents.isEmpty) {
      return;
    }

    final n = agents.length;
    _ensureScratchCapacity(n);

    final up = upAxis;
    final basisU = _basisU;
    final basisV = _basisV;
    buildUpTangentBasis3D(up, basisU, basisV);

    final ux = up.x;
    final uy = up.y;
    final uz = up.z;
    final bux = basisU.x;
    final buy = basisU.y;
    final buz = basisU.z;
    final bvx = basisV.x;
    final bvy = basisV.y;
    final bvz = basisV.z;

    var maxRadius = 0.0;
    var maxSpeed = 0.0;
    var maxTimeHorizon = 0.0;

    // 0. Precompute per-agent preferred velocities and horizontal/vertical
    // projections once into flat scratch arrays.
    for (var i = 0; i < n; i++) {
      final a = agents[i];
      _computePreferredVelocity(a, up, _prefVel);
      _prefU[i] = _prefVel.x * bux + _prefVel.y * buy + _prefVel.z * buz;
      _prefV[i] = _prefVel.x * bvx + _prefVel.y * bvy + _prefVel.z * bvz;
      _prefUp[i] = _prefVel.x * ux + _prefVel.y * uy + _prefVel.z * uz;

      final p = a.position;
      final v = a.velocity;
      _posU[i] = p.x * bux + p.y * buy + p.z * buz;
      _posV[i] = p.x * bvx + p.y * bvy + p.z * bvz;
      _posUp[i] = p.x * ux + p.y * uy + p.z * uz;
      _velU[i] = v.x * bux + v.y * buy + v.z * buz;
      _velV[i] = v.x * bvx + v.y * bvy + v.z * bvz;

      if (a.radius > maxRadius) {
        maxRadius = a.radius;
      }
      if (a.maxSpeed > maxSpeed) {
        maxSpeed = a.maxSpeed;
      }
      if (a.timeHorizon > maxTimeHorizon) {
        maxTimeHorizon = a.timeHorizon;
      }
    }

    final useSpatialHash = n > 16;
    var rvoInvCell = 0.0;
    if (useSpatialHash) {
      final maxSpan =
          2.0 * maxRadius + safetyMargin + 2.0 * maxSpeed * maxTimeHorizon;
      final rvoCellSize = math.max(1.0, maxSpan * 0.5);
      rvoInvCell = 1.0 / rvoCellSize;
      _rebuildSpatialHash(n, rvoInvCell);
    }

    // 1. Compute RVO-avoiding horizontal velocity + path vertical tracking for
    // each agent simultaneously before integrating positions.
    for (var i = 0; i < n; i++) {
      final a = agents[i];
      final prefUp = _prefUp[i];
      final prefU = _prefU[i];
      final prefV = _prefV[i];

      var chosenU = prefU;
      var chosenV = prefV;

      if (n > 1) {
        _selectRvoVelocity2D(
          agentIndex: i,
          agentCount: n,
          prefU: prefU,
          prefV: prefV,
          maxOtherRadius: maxRadius,
          maxOtherSpeed: maxSpeed,
          useSpatialHash: useSpatialHash,
          rvoInvCell: rvoInvCell,
          outUV: _chosenUV,
        );
        chosenU = _chosenUV.x;
        chosenV = _chosenUV.y;
      }

      // Smoothly accelerate toward chosen velocity within `maxAcceleration`.
      final targetVx = bux * chosenU + bvx * chosenV + ux * prefUp;
      final targetVy = buy * chosenU + bvy * chosenV + uy * prefUp;
      final targetVz = buz * chosenU + bvz * chosenV + uz * prefUp;

      final dvx = targetVx - a.velocity.x;
      final dvy = targetVy - a.velocity.y;
      final dvz = targetVz - a.velocity.z;
      final dvLen = math.sqrt(dvx * dvx + dvy * dvy + dvz * dvz);
      final maxDv = a.maxAcceleration * dt;
      if (dvLen > maxDv && dvLen > 1e-9) {
        final s = maxDv / dvLen;
        a._nextVelocity.setValues(
          a.velocity.x + dvx * s,
          a.velocity.y + dvy * s,
          a.velocity.z + dvz * s,
        );
      } else {
        a._nextVelocity.setValues(targetVx, targetVy, targetVz);
      }
    }

    // 2. Commit velocities and integrate positions.
    for (var i = 0; i < n; i++) {
      final a = agents[i];
      a.velocity.setFrom(a._nextVelocity);
      a.position.addScaled(a.velocity, dt);
    }

    // 3. Enforce strict non-overlap in the horizontal plane in case high crowd
    // density compressed agents closer than `rA + rB`.
    if (n > 1) {
      if (!useSpatialHash) {
        for (var pass = 0; pass < 2; pass++) {
          for (var i = 0; i < n; i++) {
            final a = agents[i];
            for (var j = i + 1; j < n; j++) {
              final b = agents[j];
              _separatePair(a, b, ux, uy, uz, bux, buy, buz);
            }
          }
        }
      } else {
        final sepCellSize = math.max(0.5, 2.0 * maxRadius);
        final sepInvCell = 1.0 / sepCellSize;
        for (var pass = 0; pass < 2; pass++) {
          for (var i = 0; i < n; i++) {
            final p = agents[i].position;
            _posU[i] = p.x * bux + p.y * buy + p.z * buz;
            _posV[i] = p.x * bvx + p.y * bvy + p.z * bvz;
          }
          _rebuildSpatialHash(n, sepInvCell);
          final mask = _hashMask;
          for (var i = 0; i < n; i++) {
            final a = agents[i];
            final cu = _agentCellU[i];
            final cv = _agentCellV[i];
            for (var dcv = -1; dcv <= 1; dcv++) {
              final ncv = cv + dcv;
              for (var dcu = -1; dcu <= 1; dcu++) {
                final ncu = cu + dcu;
                final bucket = ((ncu * 73856093) ^ (ncv * 19349663)) & mask;
                var j = _gridHeads[bucket];
                while (j != -1) {
                  if (j > i && _agentCellU[j] == ncu && _agentCellV[j] == ncv) {
                    _separatePair(a, agents[j], ux, uy, uz, bux, buy, buz);
                  }
                  j = _gridNext[j];
                }
              }
            }
          }
        }
      }
    }

    // 4. Optional NavMesh surface elevation clamping & visual sync.
    final mesh = navMesh;
    for (var i = 0; i < n; i++) {
      final a = agents[i];
      if (mesh != null) {
        final h = mesh.sampleHeightAt(a.position);
        if (h != null) {
          final curH = a.position.dot(up);
          a.position.addScaled(up, h - curH);
        } else {
          final nearest = mesh.findNearestPoly(a.position);
          if (nearest != null) {
            a.position.setFrom(nearest.point);
          }
        }
      }
      a.targetComponent?.position.setFrom(a.position);
    }
  }

  static void _separatePair(
    CrowdAgent3D a,
    CrowdAgent3D b,
    double ux,
    double uy,
    double uz,
    double bux,
    double buy,
    double buz,
  ) {
    // Only separate agents on the same elevation layer (`|dUp| < 1.5`).
    final relX = b.position.x - a.position.x;
    final relY = b.position.y - a.position.y;
    final relZ = b.position.z - a.position.z;
    final dUp = relX * ux + relY * uy + relZ * uz;
    if (dUp.abs() > 1.5) {
      return;
    }
    final diffX = relX - ux * dUp;
    final diffY = relY - uy * dUp;
    final diffZ = relZ - uz * dUp;
    final dist2 = diffX * diffX + diffY * diffY + diffZ * diffZ;
    final minSep = a.radius + b.radius;
    if (dist2 < minSep * minSep) {
      final dist = math.sqrt(dist2);
      double nx;
      double ny;
      double nz;
      if (dist > 1e-6) {
        final invDist = 1.0 / dist;
        nx = diffX * invDist;
        ny = diffY * invDist;
        nz = diffZ * invDist;
      } else {
        nx = bux;
        ny = buy;
        nz = buz;
      }
      final push = 0.5 * (minSep - dist + 1e-4);
      a.position.setValues(
        a.position.x - nx * push,
        a.position.y - ny * push,
        a.position.z - nz * push,
      );
      b.position.setValues(
        b.position.x + nx * push,
        b.position.y + ny * push,
        b.position.z + nz * push,
      );
    }
  }

  void _computePreferredVelocity(
    CrowdAgent3D agent,
    Vector3 up,
    Vector3 out,
  ) {
    while (agent._waypointIndex < agent._path.length) {
      final wp = agent._path[agent._waypointIndex];
      final dx = wp.x - agent.position.x;
      final dy = wp.y - agent.position.y;
      final dz = wp.z - agent.position.z;
      final dUp = dx * up.x + dy * up.y + dz * up.z;
      final hx = dx - up.x * dUp;
      final hy = dy - up.y * dUp;
      final hz = dz - up.z * dUp;
      final hDist = math.sqrt(hx * hx + hy * hy + hz * hz);
      final isFinal = agent._waypointIndex == agent._path.length - 1;
      final reach = isFinal
          ? math.min(0.08, agent.waypointReachRadius * 0.5)
          : agent.waypointReachRadius;

      if (hDist <= reach && dUp.abs() <= math.max(0.5, agent.radius * 2.0)) {
        agent._waypointIndex++;
        continue;
      }

      final fullLen = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (fullLen <= 1e-8) {
        agent._waypointIndex++;
        continue;
      }

      var speed = agent.maxSpeed;
      if (isFinal &&
          agent.arrivalSlowingRadius > 1e-4 &&
          fullLen < agent.arrivalSlowingRadius) {
        speed =
            agent.maxSpeed *
            (fullLen / agent.arrivalSlowingRadius).clamp(0.1, 1.0);
      }
      final s = speed / fullLen;
      out.setValues(dx * s, dy * s, dz * s);
      return;
    }

    out.setZero();
  }

  void _selectRvoVelocity2D({
    required int agentIndex,
    required int agentCount,
    required double prefU,
    required double prefV,
    required double maxOtherRadius,
    required double maxOtherSpeed,
    required bool useSpatialHash,
    required double rvoInvCell,
    required Vector2 outUV,
  }) {
    final me = agents[agentIndex];
    final myPosU = _posU[agentIndex];
    final myPosV = _posV[agentIndex];
    final myPosUp = _posUp[agentIndex];
    final myVelU = _velU[agentIndex];
    final myVelV = _velV[agentIndex];
    final myRadius = me.radius;
    final myMaxSpeed = me.maxSpeed;
    final myHorizon = me.timeHorizon;

    final prefSpeed = math.sqrt(prefU * prefU + prefV * prefV);
    final baseAngle = prefSpeed > 1e-5
        ? math.atan2(prefV, prefU)
        : (myVelU * myVelU + myVelV * myVelV > 1e-5
              ? math.atan2(myVelV, myVelU)
              : 0.0);
    final cosBase = math.cos(baseAngle);
    final sinBase = math.sin(baseAngle);
    final refSpeed = prefSpeed > 1e-4 ? prefSpeed : myMaxSpeed;

    // Collect relevant neighbors within agent i's RVO horizon ONCE outside
    // the 52-sample loop so inner collision checks never touch distant agents.
    var neighborCount = 0;
    final neighbors = _rvoNeighbors;
    final searchR =
        myRadius +
        maxOtherRadius +
        safetyMargin +
        (myMaxSpeed + maxOtherSpeed) * myHorizon;

    var useGrid = false;
    var minCu = 0;
    var maxCu = 0;
    var minCv = 0;
    var maxCv = 0;
    if (useSpatialHash) {
      minCu = ((myPosU - searchR) * rvoInvCell).floor();
      maxCu = ((myPosU + searchR) * rvoInvCell).floor();
      minCv = ((myPosV - searchR) * rvoInvCell).floor();
      maxCv = ((myPosV + searchR) * rvoInvCell).floor();
      if ((maxCu - minCu + 1) * (maxCv - minCv + 1) < agentCount) {
        useGrid = true;
      }
    }

    if (useGrid) {
      final mask = _hashMask;
      for (var cv = minCv; cv <= maxCv; cv++) {
        for (var cu = minCu; cu <= maxCu; cu++) {
          final bucket = ((cu * 73856093) ^ (cv * 19349663)) & mask;
          var j = _gridHeads[bucket];
          while (j != -1) {
            if (j != agentIndex &&
                _agentCellU[j] == cu &&
                _agentCellV[j] == cv &&
                (_posUp[j] - myPosUp).abs() <= 1.5) {
              final other = agents[j];
              final relU = _posU[j] - myPosU;
              final relV = _posV[j] - myPosV;
              final combinedR = myRadius + other.radius + safetyMargin;
              final maxD =
                  combinedR + (myMaxSpeed + other.maxSpeed) * myHorizon;
              if (relU * relU + relV * relV <= maxD * maxD) {
                neighbors[neighborCount++] = j;
              }
            }
            j = _gridNext[j];
          }
        }
      }
    } else {
      for (var j = 0; j < agentCount; j++) {
        if (j == agentIndex) {
          continue;
        }
        if ((_posUp[j] - myPosUp).abs() > 1.5) {
          continue;
        }
        final other = agents[j];
        final relU = _posU[j] - myPosU;
        final relV = _posV[j] - myPosV;
        final combinedR = myRadius + other.radius + safetyMargin;
        final maxD = combinedR + (myMaxSpeed + other.maxSpeed) * myHorizon;
        if (relU * relU + relV * relV <= maxD * maxD) {
          neighbors[neighborCount++] = j;
        }
      }
    }

    var bestU = prefU;
    var bestV = prefV;
    var bestPenalty = double.infinity;

    // Candidate angles (in radians) and speed scales around `baseAngle`.
    // In `(basisU, basisV)` with `basisV = up x basisU`, rotating by `-angle`
    // turns to the agent's **right**! A tiny right-side preference (`+0.02` on
    // left turns) breaks exact head-on symmetry deterministically so both
    // opposing agents pass smoothly on their respective right sides!
    for (var si = 0; si < _speedScales.length; si++) {
      final speedScale = _speedScales[si];
      final spd = speedScale == 0.0 ? 0.0 : refSpeed * speedScale;
      for (var ai = 0; ai < _candidateAngles.length; ai++) {
        if (spd == 0.0 && ai > 0) {
          break;
        }
        final offset = _candidateAngles[ai];
        final cosAng = cosBase * _cosOffsets[ai] - sinBase * _sinOffsets[ai];
        final sinAng = sinBase * _cosOffsets[ai] + cosBase * _sinOffsets[ai];
        final cu = spd * cosAng;
        final cv = spd * sinAng;

        final du = cu - prefU;
        final dv = cv - prefV;
        var penalty = math.sqrt(du * du + dv * dv);
        // Right-hand rule tie-breaker (`offset < 0` is right turn in `(U, V)`).
        if (offset > 1e-4) {
          penalty += 0.03 * myMaxSpeed;
        }

        var minTtc = double.infinity;
        for (var k = 0; k < neighborCount; k++) {
          final j = neighbors[k];
          final other = agents[j];
          final relPosU = _posU[j] - myPosU;
          final relPosV = _posV[j] - myPosV;
          final combinedR = myRadius + other.radius + safetyMargin;
          final otherVelU = _velU[j];
          final otherVelV = _velV[j];

          // Reciprocal Velocity Obstacle (`2 * v_cand - v_me - v_other`), or
          // full VO if the other agent is stationary.
          final otherMoving =
              otherVelU * otherVelU + otherVelV * otherVelV > 1e-4 ||
              !other.hasReachedGoal;
          final rvoVx = otherMoving
              ? (2.0 * cu - myVelU - otherVelU)
              : (cu - otherVelU);
          final rvoVy = otherMoving
              ? (2.0 * cv - myVelV - otherVelV)
              : (cv - otherVelV);

          final ttc = _timeToCollision2D(
            relPosU,
            relPosV,
            rvoVx,
            rvoVy,
            combinedR,
          );
          if (ttc < minTtc) {
            minTtc = ttc;
          }
        }

        if (minTtc < myHorizon) {
          penalty +=
              me.separationWeight *
              myMaxSpeed *
              (myHorizon / math.max(0.02, minTtc));
        }

        if (penalty < bestPenalty) {
          bestPenalty = penalty;
          bestU = cu;
          bestV = cv;
        }
      }
    }

    outUV.setValues(bestU, bestV);
  }

  static double _timeToCollision2D(
    double px,
    double py,
    double vx,
    double vy,
    double r,
  ) {
    // Ray `0 + t * v` intersecting disk centered at `p` of radius `r`:
    // `||t * v - p||^2 = r^2`.
    final c = px * px + py * py - r * r;
    if (c <= 0.0) {
      // Already inside combined margin: strongly penalize moving closer
      // (`v . p > 0`), allow separating (`v . p < 0`).
      final vp = vx * px + vy * py;
      return vp >= 0.0 ? 0.01 : 0.35;
    }
    final a = vx * vx + vy * vy;
    if (a <= 1e-10) {
      return double.infinity;
    }
    final b = -(vx * px + vy * py); // half-b in `a*t^2 + 2*b*t + c = 0`
    if (b >= 0.0) {
      return double.infinity;
    }
    final disc = b * b - a * c;
    if (disc < 0.0) {
      return double.infinity;
    }
    final t = (-b - math.sqrt(disc)) / a;
    return t >= 0.0 ? t : double.infinity;
  }

  static final Vector3 _prefVel = Vector3.zero();
  static final Vector2 _chosenUV = Vector2.zero();
  static final Vector3 _basisU = Vector3.zero();
  static final Vector3 _basisV = Vector3.zero();

  Float64List _posU = Float64List(0);
  Float64List _posV = Float64List(0);
  Float64List _posUp = Float64List(0);
  Float64List _velU = Float64List(0);
  Float64List _velV = Float64List(0);
  Float64List _prefU = Float64List(0);
  Float64List _prefV = Float64List(0);
  Float64List _prefUp = Float64List(0);
  Int32List _rvoNeighbors = Int32List(0);
  Int32List _agentCellU = Int32List(0);
  Int32List _agentCellV = Int32List(0);
  Int32List _gridNext = Int32List(0);
  Int32List _gridHeads = Int32List(0);
  int _hashMask = 0;

  void _ensureScratchCapacity(int count) {
    if (_posU.length < count) {
      var cap = math.max(32, _posU.length);
      while (cap < count) {
        cap *= 2;
      }
      _posU = Float64List(cap);
      _posV = Float64List(cap);
      _posUp = Float64List(cap);
      _velU = Float64List(cap);
      _velV = Float64List(cap);
      _prefU = Float64List(cap);
      _prefV = Float64List(cap);
      _prefUp = Float64List(cap);
      _rvoNeighbors = Int32List(cap);
      _agentCellU = Int32List(cap);
      _agentCellV = Int32List(cap);
      _gridNext = Int32List(cap);
    }
    final targetHash = count * 4;
    if (_gridHeads.length < targetHash) {
      var h = math.max(64, _gridHeads.length);
      while (h < targetHash) {
        h *= 2;
      }
      _gridHeads = Int32List(h);
      _hashMask = h - 1;
    }
  }

  void _rebuildSpatialHash(int count, double invCellSize) {
    _gridHeads.fillRange(0, _gridHeads.length, -1);
    final mask = _hashMask;
    for (var i = 0; i < count; i++) {
      final cu = (_posU[i] * invCellSize).floor();
      final cv = (_posV[i] * invCellSize).floor();
      _agentCellU[i] = cu;
      _agentCellV[i] = cv;
      final bucket = ((cu * 73856093) ^ (cv * 19349663)) & mask;
      _gridNext[i] = _gridHeads[bucket];
      _gridHeads[bucket] = i;
    }
  }

  static const List<double> _speedScales = [1.0, 0.75, 0.45, 0.0];
  static const List<double> _candidateAngles = [
    0.0,
    -0.2617993877991494, // -15 deg (right)
    0.2617993877991494, // +15 deg (left)
    -0.5235987755982988, // -30 deg
    0.5235987755982988, // +30 deg
    -0.7853981633974483, // -45 deg
    0.7853981633974483, // +45 deg
    -1.0471975511965976, // -60 deg
    1.0471975511965976, // +60 deg
    -1.3962634015954636, // -80 deg
    1.3962634015954636, // +80 deg
    -1.8325957145940461, // -105 deg
    1.8325957145940461, // +105 deg
  ];
  static final Float64List _cosOffsets = Float64List.fromList([
    for (final a in _candidateAngles) math.cos(a),
  ]);
  static final Float64List _sinOffsets = Float64List.fromList([
    for (final a in _candidateAngles) math.sin(a),
  ]);
}
