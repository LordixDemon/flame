import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/game/game.dart';
import 'package:vector_math/vector_math.dart';

/// Zero-allocation Struct-of-Arrays 2D Verlet rope, chain, banner, or tether
/// simulation with iterative distance constraints.
///
/// `nodeCount` must be at least `1`. A single node is a degenerate rope: one
/// free (or pinned) point with no segments.
///
/// The integrator is plain position Verlet: velocity is carried as the
/// displacement of the previous [step] and `damping` is applied once per
/// step, so call [step] with a steady time step (for example from a fixed
/// update) if the motion must not depend on the frame rate.
class VerletRope2D({
  required final int nodeCount,
  required Vector2 start,
  Vector2? end,
  var double segmentLength = 12.0,
  var double gravityX = 0.0,
  var double gravityY = 680.0,
  var double damping = 0.985,
  var int constraintIterations = 8,
  bool pinStart = true,
  bool pinEnd = false,
}) {
  this {
    if (nodeCount < 1) {
      throw ArgumentError.value(nodeCount, 'nodeCount', 'must be at least 1');
    }
    final targetEnd =
        end ?? Vector2(start.x, start.y + segmentLength * (nodeCount - 1));
    for (var i = 0; i < nodeCount; i++) {
      // A single node sits on `start` (no `0 / 0`).
      final t = nodeCount > 1 ? i / (nodeCount - 1) : 0.0;
      final x = start.x + (targetEnd.x - start.x) * t;
      final y = start.y + (targetEnd.y - start.y) * t;
      posX[i] = x;
      posY[i] = y;
      prevX[i] = x;
      prevY[i] = y;
    }
    if (pinStart) {
      pinned[0] = 1;
    }
    if (pinEnd) {
      pinned[nodeCount - 1] = 1;
    }
  }

  /// Current X positions of each rope node.
  final Float32List posX = Float32List(nodeCount);

  /// Current Y positions of each rope node.
  final Float32List posY = Float32List(nodeCount);

  /// Previous X positions used for Verlet integration.
  final Float32List prevX = Float32List(nodeCount);

  /// Previous Y positions used for Verlet integration.
  final Float32List prevY = Float32List(nodeCount);

  /// Per-node pin mask (`1` = pinned/kinematic, `0` = dynamic).
  final Uint8List pinned = Uint8List(nodeCount);

  /// Pins [index] at `(x, y)` with zero velocity.
  void setNodePin(int index, double x, double y, {bool isPinned = true}) {
    posX[index] = x;
    posY[index] = y;
    prevX[index] = x;
    prevY[index] = y;
    pinned[index] = isPinned ? 1 : 0;
    Game.notifyVisualMutation();
  }

  /// Advances Verlet integration and distance constraints by [dt] seconds.
  void step(double dt) {
    // `!(dt > 0.0)` also rejects NaN.
    if (!(dt > 0.0)) {
      return;
    }
    Game.notifyVisualMutation();
    final clampedDt = math.min(dt, 1.0 / 20.0);
    final dt2 = clampedDt * clampedDt;
    final damp = damping.clamp(0.0, 1.0);

    for (var i = 0; i < nodeCount; i++) {
      if (pinned[i] != 0) {
        continue;
      }
      final cx = posX[i];
      final cy = posY[i];
      final vx = (cx - prevX[i]) * damp;
      final vy = (cy - prevY[i]) * damp;
      prevX[i] = cx;
      prevY[i] = cy;
      posX[i] = cx + vx + gravityX * dt2;
      posY[i] = cy + vy + gravityY * dt2;
    }

    final iters = math.max(1, constraintIterations);
    for (var k = 0; k < iters; k++) {
      for (var i = 0; i < nodeCount - 1; i++) {
        final dx = posX[i + 1] - posX[i];
        final dy = posY[i + 1] - posY[i];
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist <= 1e-6) {
          continue;
        }
        final diff = (dist - segmentLength) / dist;
        final pA = pinned[i] != 0;
        final pB = pinned[i + 1] != 0;
        if (pA && pB) {
          continue;
        } else if (pA) {
          posX[i + 1] -= dx * diff;
          posY[i + 1] -= dy * diff;
        } else if (pB) {
          posX[i] += dx * diff;
          posY[i] += dy * diff;
        } else {
          final ox = dx * diff * 0.5;
          final oy = dy * diff * 0.5;
          posX[i] += ox;
          posY[i] += oy;
          posX[i + 1] -= ox;
          posY[i + 1] -= oy;
        }
      }
    }
  }
}
