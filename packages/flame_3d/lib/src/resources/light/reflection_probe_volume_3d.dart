import 'dart:math' as math;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

/// {@template reflection_probe_volume_3d}
/// Local box-projected [EnvironmentProbe3D] volume component for spatially
/// localized indoor/corridor reflections.
///
/// Every object drawn with a material that uses volumes (see
/// `Material.usesReflectionProbes`; a `SpatialMaterial` without an
/// environment of its own) takes the environment of the volume around it,
/// faded by [weightAt] at its center, so reflections fade out across
/// [blendDistance] as an object leaves the box. Overlapping volumes are not
/// blended: the one with the highest priority, then the highest weight, wins.
///
/// When [boxProjection] is `true` (default), reflection rays originating inside
/// the volume's world AABB `[worldCenter - extents, worldCenter + extents]` are
/// intersected against the box walls and re-directed from the probe's origin
/// (`parallaxCorrectRay`), producing accurate finite-room parallax reflections
/// instead of infinite-distance skybox reflections.
/// {@endtemplate}
class ReflectionProbeVolume3D({
  required var EnvironmentProbe3D probe,
  Vector3? extents,
  var double blendDistance = 1.0,
  var bool boxProjection = true,
  int priority = 0,
  super.position,
  super.rotation,
  super.scale,
}) extends Component3D {
  this {
    this.priority = priority;
  }

  /// Half-extents of the local reflection box along `(X, Y, Z)`.
  final Vector3 extents = extents?.clone() ?? Vector3.all(5);

  final Vector3 _worldCenter = Vector3.zero();
  final Aabb3 _worldBox = Aabb3();

  /// Current world-space center of this reflection probe volume.
  Vector3 get worldCenter {
    final m = worldTransformMatrix.storage;
    return _worldCenter..setValues(m[12], m[13], m[14]);
  }

  /// Current world-space AABB
  /// `[worldCenter - scaledExtents, worldCenter + scaledExtents]`.
  Aabb3 get worldBounds {
    final c = worldCenter;
    final m = worldTransformMatrix.storage;
    final sx = math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
    final sy = math.sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
    final sz = math.sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]);
    final hx = math.max(1e-3, extents.x.abs() * (sx > 1e-6 ? sx : 1.0));
    final hy = math.max(1e-3, extents.y.abs() * (sy > 1e-6 ? sy : 1.0));
    final hz = math.max(1e-3, extents.z.abs() * (sz > 1e-6 ? sz : 1.0));
    _worldBox.min.setValues(c.x - hx, c.y - hy, c.z - hz);
    _worldBox.max.setValues(c.x + hx, c.y + hy, c.z + hz);
    return _worldBox;
  }

  /// Smooth containment weight in `[0, 1]` for [worldPoint] (`1` deep inside
  /// the volume, fading smoothly to `0` across [blendDistance] at the box
  /// boundary).
  double weightAt(Vector3 worldPoint) {
    final box = worldBounds;
    final cx = (box.min.x + box.max.x) * 0.5;
    final cy = (box.min.y + box.max.y) * 0.5;
    final cz = (box.min.z + box.max.z) * 0.5;
    final hx = (box.max.x - box.min.x) * 0.5;
    final hy = (box.max.y - box.min.y) * 0.5;
    final hz = (box.max.z - box.min.z) * 0.5;

    final fade = math.max(0.0, blendDistance);
    final outerX = hx + fade;
    final outerY = hy + fade;
    final outerZ = hz + fade;

    final dx = (worldPoint.x - cx).abs();
    final dy = (worldPoint.y - cy).abs();
    final dz = (worldPoint.z - cz).abs();
    if (dx > outerX || dy > outerY || dz > outerZ) {
      return 0.0;
    }
    if (fade <= 1e-5) {
      return 1.0;
    }

    double axisWeight(double dist, double halfExtent) {
      final t = ((halfExtent + fade - dist) / fade).clamp(0.0, 1.0);
      return t * t * (3.0 - 2.0 * t);
    }

    return axisWeight(dx, hx) * axisWeight(dy, hy) * axisWeight(dz, hz);
  }

  /// Parallax-corrects unit [reflectionDir] from [worldPos] by intersecting the
  /// ray against [worldBounds] and returning the normalized vector from
  /// [worldCenter] to the box hit point.
  Vector3 parallaxCorrectRay(
    Vector3 worldPos,
    Vector3 reflectionDir, {
    Vector3? out,
  }) {
    final res = out ?? Vector3.zero();
    final len = reflectionDir.length;
    if (len <= 1e-9) {
      return res..setValues(0, 1, 0);
    }
    final rx = reflectionDir.x / len;
    final ry = reflectionDir.y / len;
    final rz = reflectionDir.z / len;

    if (!boxProjection) {
      return res..setValues(rx, ry, rz);
    }

    final box = worldBounds;
    double intersectPositiveAxis(double p, double d, double bMin, double bMax) {
      if (d.abs() < 1e-8) {
        return double.infinity;
      }
      final t1 = (bMin - p) / d;
      final t2 = (bMax - p) / d;
      return math.max(t1, t2);
    }

    final tx = intersectPositiveAxis(worldPos.x, rx, box.min.x, box.max.x);
    final ty = intersectPositiveAxis(worldPos.y, ry, box.min.y, box.max.y);
    final tz = intersectPositiveAxis(worldPos.z, rz, box.min.z, box.max.z);
    final tHit = math.min(tx, math.min(ty, tz));
    if (!tHit.isFinite || tHit <= 0.0) {
      return res..setValues(rx, ry, rz);
    }

    final center = worldCenter;
    final hx = worldPos.x + rx * tHit - center.x;
    final hy = worldPos.y + ry * tHit - center.y;
    final hz = worldPos.z + rz * tHit - center.z;
    final hLen = math.sqrt(hx * hx + hy * hy + hz * hz);
    if (hLen <= 1e-8) {
      return res..setValues(rx, ry, rz);
    }
    return res..setValues(hx / hLen, hy / hLen, hz / hLen);
  }

  @override
  void onMount() {
    super.onMount();
    worldRef.addReflectionProbe(this);
  }

  @override
  void onRemove() {
    worldRef.removeReflectionProbe(this);
    super.onRemove();
  }

  @override
  void update(double dt) {
    worldTransformMatrix;
    super.update(dt);
  }
}
