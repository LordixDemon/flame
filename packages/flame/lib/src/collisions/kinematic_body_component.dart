import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flame/src/collisions/shape_cast_2d.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:vector_math/vector_math.dart';

/// Solid axis-aligned obstacle provider consumed by [KinematicBodyComponent].
typedef SolidObstacleQuery = void Function(Rect sweptBounds, List<Rect> out);

/// Lightweight arcade/tabletop/RPG kinematic body (`moveAndCollide` and
/// `moveAndSlide`) bridging the gap between raw `PositionComponent` transforms
/// and full rigid-body Box2D solvers, with swept anti-tunneling, wall sliding,
/// restitution bounce, friction, and floor/wall contact flags.
class KinematicBodyComponent({
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
  Vector2? velocity,
  Vector2? gravity,
  this.bounciness = 0.0,
  this.linearDamping = 0.0,
  this.skinWidth = 0.05,
  this.floorMaxSlopeCos = 0.7,
  this.obstacleQuery,
}) extends PositionComponent {
  /// Linear velocity in world units per second.
  final Vector2 velocity = velocity?.clone() ?? Vector2.zero();

  /// Optional constant acceleration (e.g. `Vector2(0, 980)`) applied in
  /// [integrateForces].
  final Vector2 gravity = gravity?.clone() ?? Vector2.zero();

  /// Restitution factor in `[0.0, 1.0]` (`0.0` = inelastic slide, `> 0.0` =
  /// elastic reflection off surfaces).
  double bounciness;

  /// Exponential linear drag (`0.0` = none).
  double linearDamping;

  /// Small separation epsilon preventing floating-point re-penetration against
  /// walls.
  double skinWidth;

  /// Minimum upward normal dot-product (`dot(normal, upDirection)`) classifying
  /// a surface as floor (`isOnFloor = true`).
  double floorMaxSlopeCos;

  /// World-space upward normal (defaults to `(0, -1)` in Flame's Y-down world).
  final Vector2 upDirection = Vector2(0.0, -1.0);

  /// Callback populating solid static/kinematic obstacle `Rect`s overlapping a
  /// query region.
  SolidObstacleQuery? obstacleQuery;

  bool _isOnFloor = false;
  bool _isOnWall = false;
  bool _isOnCeiling = false;

  /// Whether the most recent [moveAndSlide] / [moveAndCollide] step contacted a
  /// floor surface.
  bool get isOnFloor => _isOnFloor;

  /// Whether the most recent step contacted a wall surface.
  bool get isOnWall => _isOnWall;

  /// Whether the most recent step contacted a ceiling surface.
  bool get isOnCeiling => _isOnCeiling;

  final List<Rect> _obstaclesScratch = <Rect>[];
  final ShapeCastHit2D _bestHit = ShapeCastHit2D();
  final ShapeCastHit2D _candidateHit = ShapeCastHit2D();
  final Vector2 _deltaScratch = Vector2.zero();

  /// Applies [gravity] and [linearDamping] to [velocity] for [dt] seconds.
  void integrateForces(double dt) {
    if (dt <= 0.0) {
      return;
    }
    velocity.x += gravity.x * dt;
    velocity.y += gravity.y * dt;
    if (linearDamping > 0.0) {
      final damp = math.exp(-linearDamping * dt);
      velocity.scale(damp);
    }
  }

  /// World-space AABB of this kinematic body at its current [position].
  Rect computeWorldBounds() {
    final topLeftX = position.x - anchor.x * size.x;
    final topLeftY = position.y - anchor.y * size.y;
    return Rect.fromLTWH(topLeftX, topLeftY, size.x, size.y);
  }

  /// Moves along `velocity * dt` and stops at the first obstacle impact,
  /// returning the [ShapeCastHit2D] or `null` if unobstructed.
  ShapeCastHit2D? moveAndCollide(
    double dt, {
    List<Rect>? explicitObstacles,
  }) {
    _resetContactFlags();
    if (dt <= 0.0) {
      return null;
    }
    _deltaScratch.setValues(velocity.x * dt, velocity.y * dt);
    return _sweepSingleStep(_deltaScratch, explicitObstacles);
  }

  /// Moves along `velocity * dt`, sliding smoothly (or bouncing when
  /// [bounciness] > 0) across up to [maxSlides] surfaces per tick. Returns the
  /// number of surface contacts resolved.
  int moveAndSlide(
    double dt, {
    int maxSlides = 4,
    List<Rect>? explicitObstacles,
  }) {
    _resetContactFlags();
    if (dt <= 0.0) {
      return 0;
    }

    var remainingX = velocity.x * dt;
    var remainingY = velocity.y * dt;
    var contacts = 0;

    for (var slide = 0; slide < maxSlides; slide++) {
      if (remainingX.abs() <= 1e-6 && remainingY.abs() <= 1e-6) {
        break;
      }
      _deltaScratch.setValues(remainingX, remainingY);
      final hit = _sweepSingleStep(_deltaScratch, explicitObstacles);
      if (hit == null) {
        break;
      }
      contacts++;

      final nx = hit.normal.x;
      final ny = hit.normal.y;
      final leftOverRatio = 1.0 - hit.toi;
      remainingX *= leftOverRatio;
      remainingY *= leftOverRatio;

      // Project remaining displacement & velocity onto tangent plane (bounce).
      final remDotN = remainingX * nx + remainingY * ny;
      if (remDotN < 0.0) {
        final factor = 1.0 + bounciness.clamp(0.0, 1.0);
        remainingX -= factor * remDotN * nx;
        remainingY -= factor * remDotN * ny;
      }

      final velDotN = velocity.x * nx + velocity.y * ny;
      if (velDotN < 0.0) {
        final factor = 1.0 + bounciness.clamp(0.0, 1.0);
        velocity.x -= factor * velDotN * nx;
        velocity.y -= factor * velDotN * ny;
      }
    }
    return contacts;
  }

  void _resetContactFlags() {
    _isOnFloor = false;
    _isOnWall = false;
    _isOnCeiling = false;
  }

  ShapeCastHit2D? _sweepSingleStep(
    Vector2 delta,
    List<Rect>? explicitObstacles,
  ) {
    final startRect = computeWorldBounds();
    final List<Rect> obstacles;
    if (explicitObstacles != null) {
      obstacles = explicitObstacles;
    } else if (obstacleQuery != null) {
      final sweptBounds = startRect
          .expandToInclude(startRect.shift(Offset(delta.x, delta.y)))
          .inflate(2.0);
      _obstaclesScratch.clear();
      obstacleQuery!(sweptBounds, _obstaclesScratch);
      obstacles = _obstaclesScratch;
    } else {
      position.add(delta);
      return null;
    }

    var found = false;
    _bestHit.toi = 2.0;

    for (var i = 0; i < obstacles.length; i++) {
      final obs = obstacles[i];
      if (ShapeCast2D.sweepRectVsRect(
        movingRect: startRect,
        delta: delta,
        obstacleRect: obs,
        out: _candidateHit,
        collider: obs,
      )) {
        if (_candidateHit.toi < _bestHit.toi) {
          found = true;
          _bestHit
            ..toi = _candidateHit.toi
            ..penetration = _candidateHit.penetration
            ..collider = _candidateHit.collider;
          _bestHit.normal.setFrom(_candidateHit.normal);
          _bestHit.point.setFrom(_candidateHit.point);
        }
      }
    }

    if (!found) {
      position.add(delta);
      return null;
    }

    // A body that already overlapped the obstacle (it was placed inside it,
    // or the obstacle moved onto it) is pushed out by the whole penetration,
    // so that it is free to move again right away.
    final safeT = math.max(0.0, _bestHit.toi);
    final separation = _bestHit.penetration + skinWidth;
    position.x += delta.x * safeT + _bestHit.normal.x * separation;
    position.y += delta.y * safeT + _bestHit.normal.y * separation;

    final upDot =
        _bestHit.normal.x * upDirection.x + _bestHit.normal.y * upDirection.y;
    if (upDot >= floorMaxSlopeCos) {
      _isOnFloor = true;
    } else if (upDot <= -floorMaxSlopeCos) {
      _isOnCeiling = true;
    } else {
      _isOnWall = true;
    }
    return _bestHit;
  }
}
