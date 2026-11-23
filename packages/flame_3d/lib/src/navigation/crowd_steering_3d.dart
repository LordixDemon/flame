import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';

part 'crowd_steering_orca_3d.dart';

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
    final basisU = _scratch.basisU;
    final basisV = _scratch.basisV;
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
      _computePreferredVelocity(a, up, _scratch.prefVel);
      _prefU[i] =
          _scratch.prefVel.x * bux +
          _scratch.prefVel.y * buy +
          _scratch.prefVel.z * buz;
      _prefV[i] =
          _scratch.prefVel.x * bvx +
          _scratch.prefVel.y * bvy +
          _scratch.prefVel.z * bvz;
      _prefUp[i] =
          _scratch.prefVel.x * ux +
          _scratch.prefVel.y * uy +
          _scratch.prefVel.z * uz;

      final p = a.position;
      final v = a.velocity;
      final vu = v.x * bux + v.y * buy + v.z * buz;
      final vv = v.x * bvx + v.y * bvy + v.z * bvz;
      _posU[i] = p.x * bux + p.y * buy + p.z * buz;
      _posV[i] = p.x * bvx + p.y * bvy + p.z * bvz;
      _posUp[i] = p.x * ux + p.y * uy + p.z * uz;
      _velU[i] = vu;
      _velV[i] = vv;
      _agentRadius[i] = a.radius;
      _agentMaxSpeed[i] = a.maxSpeed;
      _agentMoving[i] = (vu * vu + vv * vv > 1e-4 || !a.hasReachedGoal) ? 1 : 0;

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
          outUV: _scratch.chosenUV,
        );
        chosenU = _scratch.chosenUV.x;
        chosenV = _scratch.chosenUV.y;
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

  final _CrowdSteeringScratch _scratch = _CrowdSteeringScratch();

  Float64List _posU = Float64List(0);
  Float64List _posV = Float64List(0);
  Float64List _posUp = Float64List(0);
  Float64List _velU = Float64List(0);
  Float64List _velV = Float64List(0);
  Float64List _prefU = Float64List(0);
  Float64List _prefV = Float64List(0);
  Float64List _prefUp = Float64List(0);
  Float64List _agentRadius = Float64List(0);
  Float64List _agentMaxSpeed = Float64List(0);
  Uint8List _agentMoving = Uint8List(0);
  Float64List _nbRelU = Float64List(0);
  Float64List _nbRelV = Float64List(0);
  Float64List _nbVelU = Float64List(0);
  Float64List _nbVelV = Float64List(0);
  Float64List _nbCombR2 = Float64List(0);
  Uint8List _nbMoving = Uint8List(0);
  Int32List _agentCellU = Int32List(0);
  Int32List _agentCellV = Int32List(0);
  Int32List _gridNext = Int32List(0);
  Int32List _gridHeads = Int32List(0);
  int _hashMask = 0;
}
