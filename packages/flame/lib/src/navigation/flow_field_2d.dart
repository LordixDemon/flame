import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/grid/grid_topology.dart';
import 'package:vector_math/vector_math.dart';

/// Zero-allocation 2D Dijkstra integration & normalized vector flow field
/// enabling hundreds of agents to steer around walls toward one or more goals
/// via `O(1)` cell lookups.
class FlowField2D({required final int width, required final int height}) {
  final Uint8List _blocked = Uint8List(width * height);
  final Float32List _integration = Float32List(width * height);
  final Float32List _dirX = Float32List(width * height);
  final Float32List _dirY = Float32List(width * height);
  final Int32List _queue = Int32List(width * height);

  /// Marks `(col, row)` as blocked or passable.
  void setBlocked(int col, int row, {required bool blocked}) {
    if (col >= 0 && col < width && row >= 0 && row < height) {
      _blocked[row * width + col] = blocked ? 1 : 0;
    }
  }

  /// Bakes the integration cost field and normalized flow vectors toward
  /// [goals].
  void bake(Iterable<GridCell> goals) {
    final len = width * height;
    _integration.fillRange(0, len, double.infinity);
    _dirX.fillRange(0, len, 0.0);
    _dirY.fillRange(0, len, 0.0);

    var head = 0;
    var tail = 0;
    for (final g in goals) {
      if (g.col >= 0 && g.col < width && g.row >= 0 && g.row < height) {
        final idx = g.row * width + g.col;
        if (_blocked[idx] == 0 && _integration[idx].isInfinite) {
          _integration[idx] = 0.0;
          _queue[tail++] = idx;
        }
      }
    }

    // 4-way BFS wave propagation.
    while (head < tail) {
      final curr = _queue[head++];
      final cx = curr % width;
      final cy = curr ~/ width;
      final nextCost = _integration[curr] + 1.0;

      void tryEnqueue(int nx, int ny) {
        if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
          return;
        }
        final nIdx = ny * width + nx;
        if (_blocked[nIdx] != 0 || nextCost >= _integration[nIdx]) {
          return;
        }
        _integration[nIdx] = nextCost;
        _queue[tail++] = nIdx;
      }

      tryEnqueue(cx + 1, cy);
      tryEnqueue(cx - 1, cy);
      tryEnqueue(cx, cy + 1);
      tryEnqueue(cx, cy - 1);
    }

    // Compute steepest-descent unit vector across 8 neighbors.
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final idx = y * width + x;
        final selfCost = _integration[idx];
        if (!selfCost.isFinite || selfCost == 0.0) {
          continue;
        }
        var bestCost = selfCost;
        var vx = 0.0;
        var vy = 0.0;

        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) {
              continue;
            }
            final nx = x + dx;
            final ny = y + dy;
            if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
              continue;
            }
            // Guard diagonal corner-cutting around wall corners.
            if (dx != 0 && dy != 0) {
              if (_blocked[y * width + nx] != 0 ||
                  _blocked[ny * width + x] != 0) {
                continue;
              }
            }
            final c = _integration[ny * width + nx];
            if (c < bestCost) {
              bestCost = c;
              vx = dx.toDouble();
              vy = dy.toDouble();
            }
          }
        }
        final mag = math.sqrt(vx * vx + vy * vy);
        if (mag > 0.0) {
          _dirX[idx] = vx / mag;
          _dirY[idx] = vy / mag;
        }
      }
    }
  }

  /// Returns the integration distance at `(col, row)` (`double.infinity` if
  /// unreachable).
  double costAt(int col, int row) =>
      (col >= 0 && col < width && row >= 0 && row < height)
      ? _integration[row * width + col]
      : double.infinity;

  /// Writes the unit steering vector at `(col, row)` into [out].
  void sampleDirection(int col, int row, Vector2 out) {
    if (col < 0 || col >= width || row < 0 || row >= height) {
      out.setZero();
      return;
    }
    final idx = row * width + col;
    out.setValues(_dirX[idx], _dirY[idx]);
  }
}
