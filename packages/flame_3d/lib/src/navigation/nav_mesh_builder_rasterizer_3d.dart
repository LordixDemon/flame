part of 'nav_mesh_builder_3d.dart';

void _insertSolidSpan(
  List<_SolidSpan> column, {
  required int sMin,
  required int sMax,
  required double topY,
  required bool walkable,
  required int mergeThr,
}) {
  var curMin = sMin;
  var curMax = sMax;
  var curTopY = topY;
  var curWalkable = walkable;

  var idx = 0;
  while (idx < column.length) {
    final ex = column[idx];
    if (ex.sMax < curMin - 1) {
      idx++;
      continue;
    }
    if (ex.sMin > curMax + 1) {
      break;
    }

    // Overlapping or vertically adjacent spans merge into one solid column
    // interval, inheriting walkability at whichever top surface wins.
    if ((curMax - ex.sMax).abs() <= mergeThr) {
      curWalkable = curWalkable || ex.walkable;
    } else if (ex.sMax > curMax) {
      curWalkable = ex.walkable;
    }
    if (ex.topY > curTopY) {
      curTopY = ex.topY;
    }
    curMin = math.min(curMin, ex.sMin);
    curMax = math.max(curMax, ex.sMax);
    column.removeAt(idx);
  }

  column.insert(
    idx,
    _SolidSpan(
      sMin: curMin,
      sMax: curMax,
      topY: curTopY,
      walkable: curWalkable,
    ),
  );
}

class _VoxelClipScratch() {
  final Float64List clipA = Float64List(24);
  final Float64List clipB = Float64List(24);
  double minY = 0.0;
  double maxY = 0.0;
}

bool _clipTriangleColumnYRange(
  _VoxelClipScratch scratch,
  double x0,
  double y0,
  double z0,
  double x1,
  double y1,
  double z1,
  double x2,
  double y2,
  double z2,
  double xLo,
  double xHi,
  double zLo,
  double zHi,
) {
  final a = scratch.clipA;
  final b = scratch.clipB;
  a[0] = x0;
  a[1] = y0;
  a[2] = z0;
  a[3] = x1;
  a[4] = y1;
  a[5] = z1;
  a[6] = x2;
  a[7] = y2;
  a[8] = z2;

  var count = _clipSlabXZ(a, b, 3, useX: true, bound: xLo, isMin: true);
  if (count == 0) {
    return false;
  }
  count = _clipSlabXZ(b, a, count, useX: true, bound: xHi, isMin: false);
  if (count == 0) {
    return false;
  }
  count = _clipSlabXZ(a, b, count, useX: false, bound: zLo, isMin: true);
  if (count == 0) {
    return false;
  }
  count = _clipSlabXZ(b, a, count, useX: false, bound: zHi, isMin: false);
  if (count == 0) {
    return false;
  }

  var lo = double.infinity;
  var hi = double.negativeInfinity;
  for (var i = 0; i < count; i++) {
    final y = a[i * 3 + 1];
    if (y < lo) {
      lo = y;
    }
    if (y > hi) {
      hi = y;
    }
  }
  if (!lo.isFinite) {
    return false;
  }
  scratch.minY = lo;
  scratch.maxY = hi;
  return true;
}

int _clipSlabXZ(
  Float64List src,
  Float64List dst,
  int n, {
  required bool useX,
  required double bound,
  required bool isMin,
}) {
  if (n == 0) {
    return 0;
  }
  var outCount = 0;
  final coordOffset = useX ? 0 : 2;
  var prevOff = (n - 1) * 3;
  var prevVal = src[prevOff + coordOffset];
  var prevIn = isMin ? prevVal >= bound - 1e-7 : prevVal <= bound + 1e-7;

  for (var i = 0; i < n; i++) {
    final currOff = i * 3;
    final currVal = src[currOff + coordOffset];
    final currIn = isMin ? currVal >= bound - 1e-7 : currVal <= bound + 1e-7;
    if (prevIn != currIn) {
      final denom = currVal - prevVal;
      final t = denom.abs() > 1e-12
          ? ((bound - prevVal) / denom).clamp(0.0, 1.0)
          : 0.5;
      final outOff = outCount * 3;
      dst[outOff] = src[prevOff] + (src[currOff] - src[prevOff]) * t;
      dst[outOff + 1] =
          src[prevOff + 1] + (src[currOff + 1] - src[prevOff + 1]) * t;
      dst[outOff + 2] =
          src[prevOff + 2] + (src[currOff + 2] - src[prevOff + 2]) * t;
      outCount++;
    }
    if (currIn) {
      final outOff = outCount * 3;
      dst[outOff] = src[currOff];
      dst[outOff + 1] = src[currOff + 1];
      dst[outOff + 2] = src[currOff + 2];
      outCount++;
    }
    prevOff = currOff;
    prevVal = currVal;
    prevIn = currIn;
  }
  return outCount;
}

Vector3 _triUpNormal(Vector3 a, Vector3 b, Vector3 c) {
  final e1x = b.x - a.x;
  final e1y = b.y - a.y;
  final e1z = b.z - a.z;
  final e2x = c.x - a.x;
  final e2y = c.y - a.y;
  final e2z = c.z - a.z;
  final nx = e1y * e2z - e1z * e2y;
  final ny = e1z * e2x - e1x * e2z;
  final nz = e1x * e2y - e1y * e2x;
  final len = math.sqrt(nx * nx + ny * ny + nz * nz);
  if (len > 1e-12) {
    return Vector3(nx / len, ny / len, nz / len);
  }
  return Vector3(0.0, 1.0, 0.0);
}

class _SolidSpan({
  required final int sMin,
  required final int sMax,
  required final double topY,
  required final bool walkable,
});

class _WalkableSpan({
  required final int col,
  required final int row,
  required final double topY,
  required final double ceilingY,
}) {
  final Int32List neighbors = Int32List(4)..fillRange(0, 4, -1);
}
