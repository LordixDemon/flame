import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/tilemap/tile_passage_grid.dart';
import 'package:vector_math/vector_math.dart';

/// Sampled pose for a party follower inside [PartyCaterpillarChain].
class PartyFollowerState({
  required double x,
  required double y,
  this.jumpElevationPx = 0.0,
  this.facing = GridCardinalDirection.south,
  this.stridePhase = 0.0,
  this.isMoving = false,
}) {
  final Vector2 position = Vector2(x, y);
  double jumpElevationPx;
  GridCardinalDirection facing;
  double stridePhase;
  bool isMoving;
}

/// Zero-allocation circular breadcrumb history driving a classic JRPG "party
/// caterpillar" trail (`1..N` companions or pets walking in the exact footsteps
/// and parabolic jump arcs of the party leader, plus smooth `gatherToLeader`
/// collapse before cutscenes and doors).
class PartyCaterpillarChain({
  required int followerCount,
  this.followerSpacingPx = 32.0,
  this.minRecordStepPx = 2.0,
  int ringCapacity = 512,
}) {
  this
    : assert(followerCount >= 0, 'followerCount must be >= 0'),
      assert(ringCapacity >= 16, 'ringCapacity must be >= 16') {
    _histX = Float64List(ringCapacity);
    _histY = Float64List(ringCapacity);
    _histElev = Float64List(ringCapacity);
    _histDist = Float64List(ringCapacity);
    _histFacing = Uint8List(ringCapacity);
    _followers = List<PartyFollowerState>.generate(
      followerCount,
      (_) => PartyFollowerState(x: 0, y: 0),
      growable: false,
    );
  }

  final double followerSpacingPx;
  final double minRecordStepPx;

  late final Float64List _histX;
  late final Float64List _histY;
  late final Float64List _histElev;
  late final Float64List _histDist;
  late final Uint8List _histFacing;
  late final List<PartyFollowerState> _followers;

  int _head = 0;
  int _count = 0;
  double _totalDistance = 0.0;
  bool _primed = false;

  List<PartyFollowerState> get followers => _followers;

  /// Teleports leader and all followers onto `(leaderX, leaderY)` facing
  /// [facing], clearing prior breadcrumb trail.
  void resetAt(
    double leaderX,
    double leaderY, {
    GridCardinalDirection facing = GridCardinalDirection.south,
  }) {
    _head = 0;
    _count = 1;
    _totalDistance = 0.0;
    _histX[0] = leaderX;
    _histY[0] = leaderY;
    _histElev[0] = 0.0;
    _histDist[0] = 0.0;
    _histFacing[0] = facing.index;
    _primed = true;

    for (var i = 0; i < _followers.length; i++) {
      _followers[i]
        ..position.setValues(leaderX, leaderY)
        ..jumpElevationPx = 0.0
        ..facing = facing
        ..stridePhase = 0.0
        ..isMoving = false;
    }
  }

  /// Records the leader's latest pose and updates every follower along the
  /// exact path-distance arc behind the leader with `0` heap allocations.
  void recordLeader({
    required double x,
    required double y,
    required GridCardinalDirection facing,
    double jumpElevationPx = 0.0,
    double leaderStridePhase = 0.0,
    bool leaderIsMoving = false,
  }) {
    if (!_primed) {
      resetAt(x, y, facing: facing);
      return;
    }

    final prevX = _histX[_head];
    final prevY = _histY[_head];
    final dx = x - prevX;
    final dy = y - prevY;
    final stepDist = math.sqrt(dx * dx + dy * dy);

    if (stepDist >= minRecordStepPx ||
        (jumpElevationPx - _histElev[_head]).abs() > 0.25) {
      _totalDistance += stepDist;
      _head = (_head + 1) % _histX.length;
      if (_count < _histX.length) {
        _count++;
      }
      _histX[_head] = x;
      _histY[_head] = y;
      _histElev[_head] = jumpElevationPx;
      _histDist[_head] = _totalDistance;
      _histFacing[_head] = facing.index;
    }

    for (var i = 0; i < _followers.length; i++) {
      final f = _followers[i];
      final targetDist = math.max(
        0.0,
        _totalDistance - (i + 1) * followerSpacingPx,
      );
      final oldX = f.position.x;
      final oldY = f.position.y;
      _sampleAtDistance(targetDist, f);
      final moved =
          (f.position.x - oldX).abs() > 1e-3 ||
          (f.position.y - oldY).abs() > 1e-3;
      f
        ..isMoving = leaderIsMoving && moved
        ..stridePhase = f.isMoving
            ? (leaderStridePhase + (i + 1) * 0.25) % 1.0
            : 0.0;
    }
  }

  /// Collapses all followers smoothly toward the leader at
  /// [gatherSpeedPxPerSec] over [dt], returning `true` once every follower has
  /// converged onto the leader's coordinates.
  bool gatherToLeader(double dt, {double gatherSpeedPxPerSec = 180.0}) {
    if (!_primed || _followers.isEmpty) {
      return true;
    }
    final lx = _histX[_head];
    final ly = _histY[_head];
    final lFace = GridCardinalDirection.values[_histFacing[_head]];
    final maxStep = math.max(0.0, gatherSpeedPxPerSec * dt);
    var allArrived = true;

    for (var i = 0; i < _followers.length; i++) {
      final f = _followers[i];
      final dx = lx - f.position.x;
      final dy = ly - f.position.y;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist <= maxStep || dist <= 0.5) {
        f
          ..position.setValues(lx, ly)
          ..jumpElevationPx = 0.0
          ..facing = lFace
          ..isMoving = false
          ..stridePhase = 0.0;
      } else {
        allArrived = false;
        f.position.setValues(
          f.position.x + (dx / dist) * maxStep,
          f.position.y + (dy / dist) * maxStep,
        );
        f
          ..jumpElevationPx = 0.0
          ..isMoving = true
          ..stridePhase = (f.stridePhase + dt * 4.0) % 1.0;
      }
    }

    if (allArrived) {
      resetAt(lx, ly, facing: lFace);
    }
    return allArrived;
  }

  void _sampleAtDistance(double targetDist, PartyFollowerState outState) {
    final cap = _histX.length;
    var curr = _head;
    for (var step = 0; step < _count - 1; step++) {
      final prev = (curr - 1 + cap) % cap;
      final dCurr = _histDist[curr];
      final dPrev = _histDist[prev];
      if (targetDist >= dPrev && targetDist <= dCurr) {
        final span = dCurr - dPrev;
        final t = span <= 1e-6 ? 1.0 : ((targetDist - dPrev) / span);
        outState
          ..position.setValues(
            _histX[prev] + (_histX[curr] - _histX[prev]) * t,
            _histY[prev] + (_histY[curr] - _histY[prev]) * t,
          )
          ..jumpElevationPx =
              _histElev[prev] + (_histElev[curr] - _histElev[prev]) * t
          ..facing = GridCardinalDirection.values[_histFacing[curr]];
        return;
      }
      curr = prev;
    }

    final oldest = (_head - (_count - 1) + cap * 2) % cap;
    outState
      ..position.setValues(_histX[oldest], _histY[oldest])
      ..jumpElevationPx = _histElev[oldest]
      ..facing = GridCardinalDirection.values[_histFacing[oldest]];
  }
}
