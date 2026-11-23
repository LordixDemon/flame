part of 'transform_gizmo_3d.dart';

Matrix4 _gizmoBasisTransform(
  Vector3 origin,
  Vector3 ax,
  Vector3 ay,
  Vector3 az,
) {
  return Matrix4.columns(
    Vector4(ax.x, ax.y, ax.z, 0),
    Vector4(ay.x, ay.y, ay.z, 0),
    Vector4(az.x, az.y, az.z, 0),
    Vector4(origin.x, origin.y, origin.z, 1),
  );
}

void _drawTranslateAxis(
  DebugRenderer3D renderer,
  Vector3 origin,
  Vector3 axis,
  double scale,
  Color color,
  double thickness,
) {
  final shaftEnd = origin + axis * scale;
  final tip = origin + axis * (scale * 1.18);
  renderer
    ..drawLine(origin, shaftEnd, color: color, thickness: thickness)
    ..drawCone(
      tip,
      -axis,
      length: scale * 0.18,
      halfAngleRad: 0.34,
      color: color,
      segments: 8,
      thickness: thickness * 0.75,
    );
}

void _drawPlaneQuad(
  DebugRenderer3D renderer,
  Vector3 origin,
  Vector3 u,
  Vector3 v,
  double scale,
  Color color,
  double thickness,
) {
  final lo = scale * 0.22;
  final hi = scale * 0.42;
  final p0 = origin + u * lo + v * lo;
  final p1 = origin + u * hi + v * lo;
  final p2 = origin + u * hi + v * hi;
  final p3 = origin + u * lo + v * hi;
  renderer.drawPolyline(
    [p0, p1, p2, p3],
    closed: true,
    color: color,
    thickness: thickness,
  );
}

void _drawRing(
  DebugRenderer3D renderer,
  Vector3 origin,
  Vector3 normal,
  Vector3 tangentA,
  Vector3 tangentB,
  double radius,
  Color color,
  double thickness,
) {
  const segments = 32;
  final pts = <Vector3>[];
  for (var i = 0; i < segments; i++) {
    final t = (i / segments) * 2.0 * math.pi;
    pts.add(
      origin +
          tangentA * (math.cos(t) * radius) +
          tangentB * (math.sin(t) * radius),
    );
  }
  renderer.drawPolyline(
    pts,
    closed: true,
    color: color,
    thickness: thickness,
  );
}

void _drawScaleAxis(
  DebugRenderer3D renderer,
  Vector3 origin,
  Vector3 axis,
  double scale,
  Color color,
  double thickness,
) {
  final end = origin + axis * scale;
  renderer.drawLine(origin, end, color: color, thickness: thickness);
  final perpA = _perpendicularUnit(axis);
  final perpB = axis.cross(perpA)..normalize();
  renderer.drawObb(
    Vector3.all(scale * 0.075),
    _gizmoBasisTransform(end, axis, perpA, perpB),
    color: color,
    thickness: thickness * 0.85,
  );
}

GizmoAxis3D _pickPlaneQuads(
  Vector3 ro,
  Vector3 rd,
  Vector3 origin,
  Vector3 ax,
  Vector3 ay,
  Vector3 az,
  double scale,
) {
  final lo = scale * 0.2;
  final hi = scale * 0.44;
  var bestT = double.infinity;
  var bestAxis = GizmoAxis3D.none;

  void checkPlane(GizmoAxis3D candidate, Vector3 n, Vector3 u, Vector3 v) {
    final denom = n.dot(rd);
    if (denom.abs() <= 1e-6) {
      return;
    }
    final t = n.dot(origin - ro) / denom;
    if (t <= 0 || t >= bestT) {
      return;
    }
    final rel = (ro + rd * t) - origin;
    final cu = rel.dot(u);
    final cv = rel.dot(v);
    if (cu >= lo && cu <= hi && cv >= lo && cv <= hi) {
      bestT = t;
      bestAxis = candidate;
    }
  }

  checkPlane(GizmoAxis3D.xy, az, ax, ay);
  checkPlane(GizmoAxis3D.xz, ay, ax, az);
  checkPlane(GizmoAxis3D.yz, ax, ay, az);
  return bestAxis;
}

GizmoAxis3D _pickAxisSegments(
  Vector3 ro,
  Vector3 rd,
  Vector3 origin,
  Vector3 ax,
  Vector3 ay,
  Vector3 az, {
  required double startFrac,
  required double endFrac,
  required double scale,
  required double tolerance,
}) {
  var bestDist = tolerance;
  var bestAxis = GizmoAxis3D.none;

  void checkAxis(GizmoAxis3D candidate, Vector3 dir) {
    final a = origin + dir * (scale * startFrac);
    final len = scale * (endFrac - startFrac);
    final dist = _raySegmentDistance(ro, rd, a, dir, len);
    if (dist < bestDist) {
      bestDist = dist;
      bestAxis = candidate;
    }
  }

  checkAxis(GizmoAxis3D.x, ax);
  checkAxis(GizmoAxis3D.y, ay);
  checkAxis(GizmoAxis3D.z, az);
  return bestAxis;
}

GizmoAxis3D _pickRotationRings(
  Vector3 ro,
  Vector3 rd,
  Vector3 origin,
  Vector3 ax,
  Vector3 ay,
  Vector3 az,
  double radius,
  double tolerance,
) {
  var bestDist = tolerance;
  var bestAxis = GizmoAxis3D.none;

  void checkRing(
    GizmoAxis3D candidate,
    Vector3 normal,
    Vector3 tangentA,
    Vector3 tangentB,
  ) {
    final denom = normal.dot(rd);
    if (denom.abs() > 0.08) {
      final t = normal.dot(origin - ro) / denom;
      if (t > 0) {
        final rel = (ro + rd * t) - origin;
        final radialDist = (rel.length - radius).abs();
        if (radialDist < bestDist) {
          bestDist = radialDist;
          bestAxis = candidate;
          return;
        }
      }
    }
    // Edge-on polyline fallback (slightly biased behind face-on intersections
    // where two orthogonal rings cross).
    final edgeBias = radius * 0.025;
    const segs = 24;
    for (var i = 0; i < segs; i++) {
      final t0 = (i / segs) * 2.0 * math.pi;
      final t1 = ((i + 1) / segs) * 2.0 * math.pi;
      final p0 =
          origin +
          tangentA * (math.cos(t0) * radius) +
          tangentB * (math.sin(t0) * radius);
      final p1 =
          origin +
          tangentA * (math.cos(t1) * radius) +
          tangentB * (math.sin(t1) * radius);
      final diff = p1 - p0;
      final len = diff.length;
      if (len > 1e-6) {
        final d = _raySegmentDistance(ro, rd, p0, diff / len, len) + edgeBias;
        if (d < bestDist) {
          bestDist = d;
          bestAxis = candidate;
        }
      }
    }
  }

  checkRing(GizmoAxis3D.x, ax, ay, az);
  checkRing(GizmoAxis3D.y, ay, az, ax);
  checkRing(GizmoAxis3D.z, az, ax, ay);
  return bestAxis;
}

double _raySegmentDistance(
  Vector3 ro,
  Vector3 rd,
  Vector3 segStart,
  Vector3 segDir,
  double segLen,
) {
  final w0 = ro - segStart;
  final b = rd.dot(segDir);
  final d = rd.dot(w0);
  final e = segDir.dot(w0);
  final denom = 1.0 - b * b;

  var s = denom > 1e-8 ? (e - b * d) / denom : e;
  s = s.clamp(0.0, segLen);
  var t = math.max(0.0, rd.dot((segStart + segDir * s) - ro));
  s = segDir.dot((ro + rd * t) - segStart).clamp(0.0, segLen);
  t = math.max(0.0, rd.dot((segStart + segDir * s) - ro));

  final pRay = ro + rd * t;
  final pSeg = segStart + segDir * s;
  return pRay.distanceTo(pSeg);
}

bool _raySphereHit(
  Vector3 ro,
  Vector3 rd,
  Vector3 center,
  double radius,
) {
  final oc = ro - center;
  final b = oc.dot(rd);
  final c = oc.dot(oc) - radius * radius;
  final disc = b * b - c;
  if (disc < 0) {
    return false;
  }
  return -b + math.sqrt(disc) >= 0;
}

Vector3? _intersectPlane(
  Vector3 ro,
  Vector3 rd,
  Vector3 planeOrigin,
  Vector3 planeNormal,
) {
  final denom = planeNormal.dot(rd);
  if (denom.abs() <= 1e-7) {
    return null;
  }
  final t = planeNormal.dot(planeOrigin - ro) / denom;
  if (t < 0) {
    return null;
  }
  return ro + rd * t;
}

Vector3 _perpendicularUnit(Vector3 n) {
  final ref = n.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
  return ref.cross(n)..normalize();
}
