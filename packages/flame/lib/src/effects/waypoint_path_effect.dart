import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart';
import 'package:flame/src/effects/controllers/effect_controller.dart';
import 'package:flame/src/effects/move_effect.dart';
import 'package:flame/src/effects/provider_interfaces.dart';

/// Moves a [PositionProvider] smoothly through an ordered list of waypoints
/// using zero-`ui.Path`-allocation linear or Catmull-Rom spline interpolation,
/// with arc-length parameterization and per-waypoint arrival callbacks.
///
/// The effect's progress is proportional to the distance travelled along the
/// curve, so with a linear controller the target moves at constant speed over
/// the whole path, however unevenly the waypoints are spaced and however much
/// the curve bends between them. The length of each curved segment is
/// measured on [samplesPerSegment] straight pieces; [measure] returns the
/// length of the whole curve.
///
/// [tension] `0.0` gives a Catmull-Rom spline through the waypoints, `1.0`
/// straight lines between them.
class WaypointPathEffect(
  List<Vector2> waypoints,
  EffectController controller, {
  final double tension = 0.0,
  final bool includeCurrentPosition = true,
  final bool oriented = false,
  final int samplesPerSegment = 16,
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
      assert(
        samplesPerSegment >= 1,
        'samplesPerSegment must be at least 1: $samplesPerSegment',
      ),
      super(controller, target);

  final List<Vector2> _inputWaypoints = List<Vector2>.generate(
    waypoints.length,
    (i) => waypoints[i].clone(),
    growable: false,
  );

  late Float64List _knotX;
  late Float64List _knotY;

  /// Distance along the curve from its start to each knot.
  late Float64List _cumulativeLength;

  /// Distance along the curve from its start to each sample point; every
  /// segment between two knots contributes [_samplesInSegment] pieces.
  late Float64List _arcTable;
  int _samplesInSegment = 1;
  double _totalLength = 0.0;
  int _nextWaypointCallbackIndex = 0;

  final Vector2 _lastWorldPos = Vector2.zero();
  double _lastAngle = 0.0;

  /// Whether the path consists of straight lines between the knots.
  bool get _isPiecewiseLinear => tension >= 0.999 || _knotX.length <= 2;

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

    // A straight segment needs no subdivision to be measured exactly.
    final samples = _isPiecewiseLinear ? 1 : samplesPerSegment;
    _samplesInSegment = samples;
    final segments = count - 1;
    _arcTable = Float64List(segments * samples + 1);

    var acc = 0.0;
    var prevX = _knotX[0];
    var prevY = _knotY[0];
    for (var seg = 0; seg < segments; seg++) {
      for (var k = 1; k <= samples; k++) {
        final (px, py, _, _) = _evaluateSegment(seg, k / samples);
        final dx = px - prevX;
        final dy = py - prevY;
        acc += math.sqrt(dx * dx + dy * dy);
        _arcTable[seg * samples + k] = acc;
        prevX = px;
        prevY = py;
      }
      _cumulativeLength[seg + 1] = acc;
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

  /// Position and (unnormalized) tangent of the curve at [dist] along it.
  (double x, double y, double tx, double ty) _sampleAtDistance(double dist) {
    final n = _knotX.length;
    if (n == 1 || _totalLength <= 1e-9) {
      return (_knotX[0], _knotY[0], 1.0, 0.0);
    }
    final clampedDist = dist.clamp(0.0, _totalLength);

    // Binary search the piece [lo .. lo + 1] of the arc table.
    var lo = 0;
    var hi = _arcTable.length - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >>> 1;
      if (_arcTable[mid] <= clampedDist) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final pieceStart = _arcTable[lo];
    final pieceLen = _arcTable[lo + 1] - pieceStart;
    final within = pieceLen > 1e-12
        ? (clampedDist - pieceStart) / pieceLen
        : 0.0;

    final samples = _samplesInSegment;
    final seg = lo ~/ samples;
    final u = ((lo - seg * samples) + within) / samples;
    return _evaluateSegment(seg, u);
  }

  /// Position and (unnormalized) tangent at parameter [u] in `[0, 1]` of the
  /// segment between knots [seg] and `seg + 1`.
  (double x, double y, double tx, double ty) _evaluateSegment(
    int seg,
    double u,
  ) {
    final n = _knotX.length;
    final x1 = _knotX[seg];
    final y1 = _knotY[seg];
    final x2 = _knotX[seg + 1];
    final y2 = _knotY[seg + 1];

    // Pure piecewise-linear fast path when tension == 1.0 or only 2 knots.
    if (_isPiecewiseLinear) {
      final px = x1 + (x2 - x1) * u;
      final py = y1 + (y2 - y1) * u;
      return (px, py, x2 - x1, y2 - y1);
    }

    final x0 = seg > 0 ? _knotX[seg - 1] : (2.0 * x1 - x2);
    final y0 = seg > 0 ? _knotY[seg - 1] : (2.0 * y1 - y2);
    final x3 = (seg + 2 < n) ? _knotX[seg + 2] : (2.0 * x2 - x1);
    final y3 = (seg + 2 < n) ? _knotY[seg + 2] : (2.0 * y2 - y1);

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
