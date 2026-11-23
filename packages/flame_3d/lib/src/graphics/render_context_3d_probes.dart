part of 'render_context_3d.dart';

class _ReflectionProbeSelector() {
  List<ReflectionProbeSource3D> probes = const [];

  int drawProbeSlot = 0;
  double drawProbeWeight = 0;
  int boundProbeSlot = 0;
  double boundProbeWeight = 0;
  bool anyProbeDraw = false;

  // Per pass: the center, half extents, blend distance and priority of each
  // volume, 8 doubles per volume.
  Float64List _probeBoxes = Float64List(0);
  int _probeBoxesPass = -1;
  List<ReflectionProbeSource3D>? _probeBoxesOf;
  int _probeBoxesCount = 0;

  ReflectionProbeSource3D? get activeProbe {
    final slot = drawProbeSlot;
    return slot > 0 && slot <= probes.length ? probes[slot - 1] : null;
  }

  double get activeWeight => activeProbe == null ? 0.0 : drawProbeWeight;

  void resetPass() {
    anyProbeDraw = false;
  }

  (ReflectionProbeSource3D, double)? select(Vector3 worldPoint) {
    final list = probes;
    if (list.isEmpty) {
      return null;
    }
    ReflectionProbeSource3D? best;
    var bestWeight = 0.0;
    var bestPriority = -0x7FFFFFFF;
    for (var i = 0; i < list.length; i++) {
      final p = list[i];
      final w = p.weightAt(worldPoint);
      if (w <= 1e-4) {
        continue;
      }
      if (best == null ||
          p.priority > bestPriority ||
          (p.priority == bestPriority && w > bestWeight)) {
        best = p;
        bestWeight = w;
        bestPriority = p.priority;
      }
    }
    return best != null ? (best, bestWeight) : null;
  }

  void ensureBoxes(int pass) {
    final list = probes;
    if (_probeBoxesPass == pass &&
        identical(_probeBoxesOf, list) &&
        _probeBoxesCount == list.length) {
      return;
    }
    if (_probeBoxes.length < list.length * 8) {
      _probeBoxes = Float64List(list.length * 8);
    }
    final boxes = _probeBoxes;
    for (var k = 0; k < list.length; k++) {
      final p = list[k];
      final box = p.worldBounds;
      final o = k * 8;
      boxes
        ..[o] = (box.min.x + box.max.x) * 0.5
        ..[o + 1] = (box.min.y + box.max.y) * 0.5
        ..[o + 2] = (box.min.z + box.max.z) * 0.5
        ..[o + 3] = (box.max.x - box.min.x) * 0.5
        ..[o + 4] = (box.max.y - box.min.y) * 0.5
        ..[o + 5] = (box.max.z - box.min.z) * 0.5
        ..[o + 6] = math.max(0.0, p.blendDistance)
        ..[o + 7] = p.priority.toDouble();
    }
    _probeBoxesPass = pass;
    _probeBoxesOf = list;
    _probeBoxesCount = list.length;
  }

  void selectForDraw(
    _DrawQueue queue,
    int drawIndex,
    int pass,
    double x,
    double y,
    double z,
  ) {
    ensureBoxes(pass);
    final boxes = _probeBoxes;
    var best = -1;
    var bestWeight = 0.0;
    var bestPriority = 0.0;
    for (var k = 0; k < _probeBoxesCount; k++) {
      final o = k * 8;
      final fade = boxes[o + 6];
      final dx = (x - boxes[o]).abs();
      final dy = (y - boxes[o + 1]).abs();
      final dz = (z - boxes[o + 2]).abs();
      final hx = boxes[o + 3];
      final hy = boxes[o + 4];
      final hz = boxes[o + 5];
      if (dx > hx + fade || dy > hy + fade || dz > hz + fade) {
        continue;
      }
      final w = fade <= 1e-5
          ? 1.0
          : _axisWeight(dx, hx, fade) *
                _axisWeight(dy, hy, fade) *
                _axisWeight(dz, hz, fade);
      if (w <= 1e-4) {
        continue;
      }
      final priority = boxes[o + 7];
      if (best < 0 ||
          priority > bestPriority ||
          (priority == bestPriority && w > bestWeight)) {
        best = k;
        bestWeight = w;
        bestPriority = priority;
      }
    }
    var quantized = 0.0;
    if (best >= 0) {
      if (bestWeight >= 1.0 - 1e-6) {
        quantized = 1.0;
      } else {
        final q = (bestWeight * 64.0).round();
        quantized = (q > 0 ? q : 1) / 64.0;
      }
      anyProbeDraw = true;
    }
    queue.probeSlots[drawIndex] = best + 1;
    queue.probeWeights[drawIndex] = quantized;
  }

  @pragma('vm:prefer-inline')
  static double _axisWeight(double distance, double half, double fade) {
    final t = ((half + fade - distance) / fade).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }
}
