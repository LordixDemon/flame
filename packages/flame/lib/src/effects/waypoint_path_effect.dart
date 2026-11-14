import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart';
import 'package:flame/src/effects/controllers/effect_controller.dart';
import 'package:flame/src/effects/move_effect.dart';
import 'package:flame/src/effects/provider_interfaces.dart';

/// Moves a [PositionProvider] smoothly through an ordered list of waypoints
/// using zero-`ui.Path`-allocation linear or Catmull-Rom spline interpolation,
/// with arc-length parameterization and per-waypoint arrival callbacks.
class WaypointPathEffect(
  List<Vector2> waypoints,
  EffectController controller, {
  final double tension = 0.0,
  final bool includeCurrentPosition = true,
  final bool oriented = false,
  final void Function(int waypointIndex)? onWaypointReached,
  PositionProvider? target,
  super.onComplete,
  super.key,
}) extends MoveEffect {
  this
    : assert(
        waypoints.isNotEmpty,
        'waypoints must contain at least one destination point',
      ),
      assert(
        tension >= 0.0 && tension <= 1.0,
        'tension must be in [0.0 .. 1.0]: $tension',
      ),
      super(controller, target);

  final List<Vector2> _inputWaypoints = List<Vector2>.generate(
    waypoints.length,
    (i) => waypoints[i].clone(),
    growable: false,
  );

  late Float64List _knotX;
  late Float64List _knotY;
  late Float64List _cumulativeLength;
  double _totalLength = 0.0;
  int _nextWaypointCallbackIndex = 0;

  final Vector2 _lastWorldPos = Vector2.zero();
  double _lastAngle = 0.0;

  void _rebuildSplineFrom(Vector2 startPos) {
    final count = includeCurrentPosition
        ? _inputWaypoints.length + 1
        : _inputWaypoints.length;
    _knotX = Float64List(count);
    _knotY = Float64List(count);
    _cumulativeLength = Float64List(count);

    if (includeCurrentPosition) {
      _knotX[0] = startPos.x;
      _knotY[0] = startPos.y;
      for (var i = 0; i < _inputWaypoints.length; i++) {
        _knotX[i + 1] = _inputWaypoints[i].x;
        _knotY[i + 1] = _inputWaypoints[i].y;
      }
    } else {
      for (var i = 0; i < _inputWaypoints.length; i++) {
        _knotX[i] = _inputWaypoints[i].x;
        _knotY[i] = _inputWaypoints[i].y;
      }
    }

    var acc = 0.0;
    _cumulativeLength[0] = 0.0;
    for (var i = 1; i < count; i++) {
      final dx = _knotX[i] - _knotX[i - 1];
      final dy = _knotY[i] - _knotY[i - 1];
      acc += math.sqrt(dx * dx + dy * dy);
      _cumulativeLength[i] = acc;
    }
    _totalLength = acc;
  }

  @override
  void onStart() {
    super.onStart();
    _rebuildSplineFrom(target.position);
    _nextWaypointCallbackIndex = 0;

    if (!includeCurrentPosition) {
      target.position.setValues(_knotX[0], _knotY[0]);
      if (onWaypointReached != null && _inputWaypoints.length == 1) {
        _nextWaypointCallbackIndex = 1;
        onWaypointReached!(0);
      }
    }
    _lastWorldPos.setValues(_knotX[0], _knotY[0]);

    if (oriented) {
      assert(
        target is AngleProvider,
        'An `oriented` WaypointPathEffect requires an AngleProvider target',
      );
      final (_, _, tx, ty) = _sampleAtDistance(0.0);
      final ang = math.atan2(ty, tx);
      _lastAngle = ang;
      final tgt = target;
      (tgt as AngleProvider).angle = ang;
      if (tgt is PositionComponent) {
        tgt.angle += tgt.nativeAngle;
      }
    }
  }

  (double x, double y, double tx, double ty) _sampleAtDistance(double dist) {
    final n = _knotX.length;
    if (n == 1 || _totalLength <= 1e-9) {
      return (_knotX[0], _knotY[0], 1.0, 0.0);
    }
    final clampedDist = dist.clamp(0.0, _totalLength);

    // Binary search segment [seg .. seg + 1]
    var lo = 0;
    var hi = n - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >>> 1;
      if (_cumulativeLength[mid] <= clampedDist) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final segStart = _cumulativeLength[lo];
    final segLen = _cumulativeLength[lo + 1] - segStart;
    final u = segLen > 1e-9 ? ((clampedDist - segStart) / segLen) : 0.0;

    final x1 = _knotX[lo];
    final y1 = _knotY[lo];
    final x2 = _knotX[lo + 1];
    final y2 = _knotY[lo + 1];

    // Pure piecewise-linear fast path when tension == 1.0 or only 2 knots.
    if (tension >= 0.999 || n == 2) {
      final px = x1 + (x2 - x1) * u;
      final py = y1 + (y2 - y1) * u;
      return (px, py, x2 - x1, y2 - y1);
    }

    final x0 = lo > 0 ? _knotX[lo - 1] : (2.0 * x1 - x2);
    final y0 = lo > 0 ? _knotY[lo - 1] : (2.0 * y1 - y2);
    final x3 = (lo + 2 < n) ? _knotX[lo + 2] : (2.0 * x2 - x1);
    final y3 = (lo + 2 < n) ? _knotY[lo + 2] : (2.0 * y2 - y1);

    // Cardinal / Catmull-Rom tangents scaled by `0.5 * (1 - tension)`.
    final s = 0.5 * (1.0 - tension);
    final m1x = s * (x2 - x0);
    final m1y = s * (y2 - y0);
    final m2x = s * (x3 - x1);
    final m2y = s * (y3 - y1);

    final u2 = u * u;
    final u3 = u2 * u;
    final h00 = 2.0 * u3 - 3.0 * u2 + 1.0;
    final h10 = u3 - 2.0 * u2 + u;
    final h01 = -2.0 * u3 + 3.0 * u2;
    final h11 = u3 - u2;

    final px = h00 * x1 + h10 * m1x + h01 * x2 + h11 * m2x;
    final py = h00 * y1 + h10 * m1y + h01 * y2 + h11 * m2y;

    final dh00 = 6.0 * u2 - 6.0 * u;
    final dh10 = 3.0 * u2 - 4.0 * u + 1.0;
    final dh01 = -6.0 * u2 + 6.0 * u;
    final dh11 = 3.0 * u2 - 2.0 * u;
    final tx = dh00 * x1 + dh10 * m1x + dh01 * x2 + dh11 * m2x;
    final ty = dh00 * y1 + dh10 * m1y + dh01 * y2 + dh11 * m2y;

    return (px, py, tx, ty);
  }

  @override
  void apply(double progress) {
    final dist = progress.clamp(0.0, 1.0) * _totalLength;
    final (px, py, tx, ty) = _sampleAtDistance(dist);

    target.position.x += px - _lastWorldPos.x;
    target.position.y += py - _lastWorldPos.y;
    _lastWorldPos.setValues(px, py);

    if (oriented && (tx.abs() > 1e-7 || ty.abs() > 1e-7)) {
      final ang = math.atan2(ty, tx);
      (target as AngleProvider).angle += ang - _lastAngle;
      _lastAngle = ang;
    }

    final cb = onWaypointReached;
    if (cb != null) {
      final offset = includeCurrentPosition ? 1 : 0;
      while (_nextWaypointCallbackIndex < _inputWaypoints.length) {
        final knotIdx = _nextWaypointCallbackIndex + offset;
        if (dist + 1e-6 >= _cumulativeLength[knotIdx]) {
          final reached = _nextWaypointCallbackIndex++;
          cb(reached);
        } else {
          break;
        }
      }
    }
  }

  @override
  double measure() {
    if (_totalLength == 0.0) {
      _rebuildSplineFrom(target.position);
    }
    return math.max(1e-4, _totalLength);
  }
}
