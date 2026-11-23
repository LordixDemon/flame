import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// The shape of a [BarrierMesh].
enum BarrierMeshShape() {
  /// A vertical band around a rectangle with rounded corners.
  roundedRectangle,

  /// A vertical band around a circle.
  ring,

  /// The upper half of a sphere.
  dome,
}

/// {@template barrier_mesh}
/// A wall for a [BarrierMaterial]: a band standing around a rectangle with
/// rounded corners, a ring, or a dome, with one surface whose vertices hold
/// what the material reads.
///
/// The wall stands on the `xz` plane, its foot at `y = 0`, around the origin.
/// Each vertex has:
///
/// - `vertexPosition`;
/// - `vertexTexCoord`: `x` the distance along the foot of the wall from its
///   start, in scene units, from `0` to [length]; `y` the height up the wall,
///   from `0` at its foot to `1` at its top (for the dome, the elevation from
///   its rim to its pole);
/// - `vertexNormal`: pointing out of the enclosed area.
///
/// The foot runs counter-clockwise seen from above (`+y`): from `+x` towards
/// `-z`, then `-x` and `+z`. The first and the last column of vertices are at
/// the same place, with the distances `0` and [length]. Front faces face
/// outwards.
///
/// Rotate the component that draws it to stand it in a scene whose up is
/// not `+y`.
///
/// When its surface's material is a [BarrierMaterial] whose
/// [BarrierMaterial.drawsReactionInFront] holds, the mesh draws the surface
/// a second time with [BarrierMaterial.reactionInFrontMaterial], outside the
/// shadow and depth-normal passes: the reaction over what stands in front
/// of the wall.
/// {@endtemplate}
class BarrierMesh._(
  /// The shape of the wall.
  final BarrierMeshShape shape,

  /// The distance around the foot of the wall, in scene units: the largest
  /// distance along it, at the end of the loop. Pass it to
  /// `BarrierMaterial.fitPatternTo`.
  final double length,

  /// The height of the wall, the radius of a dome.
  final double height,

  // The foot of the wall: x, z and the distance along it, per point.
  final Float64List _foot,
) extends Mesh {
  /// A band of [height] standing around the rectangle of [width] (along x) by
  /// [depth] (along z) centered on the origin, with corners rounded to
  /// [cornerRadius] (at most half the smaller side) in [cornerSegments]
  /// segments each.
  ///
  /// The distance along it starts at the middle of the `+x` side.
  ///
  /// The band has [heightSegments] rows of quads up its height (`1` by
  /// default) and, with [maxSegmentLength], columns at most that far apart
  /// along its foot (by default, only where the corners need them): a wall
  /// that wobbles (`BarrierMaterial.wobbleAmplitude`) needs rows and columns
  /// a fraction of the wobble's wavelength apart. Neither changes [length]
  /// or the wall coordinates.
  factory BarrierMesh.roundedRectangle({
    required double width,
    required double depth,
    required double height,
    double cornerRadius = 0,
    int cornerSegments = 8,
    int heightSegments = 1,
    double? maxSegmentLength,
    Material? material,
  }) {
    if (!(width > 0 && depth > 0 && height > 0)) {
      throw ArgumentError('width, depth and height must be positive');
    }
    if (cornerSegments < 1) {
      throw ArgumentError.value(cornerSegments, 'cornerSegments', 'Must be 1+');
    }
    final r = cornerRadius.clamp(0.0, math.min(width, depth) / 2);
    final hx = width / 2 - r;
    final hz = depth / 2 - r;
    // x, z, normal x, normal z per point.
    final points = <double>[width / 2, 0, 1, 0];
    const centers = [(1, -1), (-1, -1), (-1, 1), (1, 1)];
    for (var k = 0; k < 4; k++) {
      final (sx, sz) = centers[k];
      final cx = sx * hx;
      final cz = sz * hz;
      if (r <= 0) {
        // A sharp corner: one point with the normal of each side.
        final a0 = k * math.pi / 2;
        final a1 = a0 + math.pi / 2;
        points
          ..addAll([cx, cz, math.cos(a0), -math.sin(a0)])
          ..addAll([cx, cz, math.cos(a1), -math.sin(a1)]);
        continue;
      }
      for (var j = 0; j <= cornerSegments; j++) {
        final angle = (k + j / cornerSegments) * math.pi / 2;
        final nx = math.cos(angle);
        final nz = -math.sin(angle);
        points.addAll([cx + nx * r, cz + nz * r, nx, nz]);
      }
    }
    points.addAll([width / 2, 0, 1, 0]);
    return _band(
      BarrierMeshShape.roundedRectangle,
      _subdivide(_dropRepeats(points), maxSegmentLength),
      height,
      material,
      heightSegments: heightSegments,
    );
  }

  /// A band of [height] standing around the circle of [radius] centered on
  /// the origin, in [segments] segments.
  ///
  /// The distance along it starts at `(radius, 0, 0)`.
  ///
  /// The band has [heightSegments] rows of quads up its height, `1` by
  /// default; see [BarrierMesh.roundedRectangle].
  factory BarrierMesh.ring({
    required double radius,
    required double height,
    int segments = 64,
    int heightSegments = 1,
    Material? material,
  }) {
    if (!(radius > 0 && height > 0)) {
      throw ArgumentError('radius and height must be positive');
    }
    if (segments < 3) {
      throw ArgumentError.value(segments, 'segments', 'Must be 3 or more');
    }
    final points = <double>[];
    for (var i = 0; i <= segments; i++) {
      final angle = i * 2 * math.pi / segments;
      final nx = i == segments ? 1.0 : math.cos(angle);
      final nz = i == segments ? 0.0 : -math.sin(angle);
      points.addAll([nx * radius, nz * radius, nx, nz]);
    }
    return _band(
      BarrierMeshShape.ring,
      points,
      height,
      material,
      heightSegments: heightSegments,
    );
  }

  /// The upper half of the sphere of [radius] centered on the origin, in
  /// [segments] segments around and [rings] rings from its rim to its pole.
  ///
  /// The distance along it is measured on its rim and starts at
  /// `(radius, 0, 0)`; the height runs from `0` on the rim to `1` at the
  /// pole, by elevation.
  factory BarrierMesh.dome({
    required double radius,
    int segments = 64,
    int rings = 16,
    Material? material,
  }) {
    if (!(radius > 0)) {
      throw ArgumentError.value(radius, 'radius', 'Must be positive');
    }
    if (segments < 3 || rings < 1) {
      throw ArgumentError('segments must be 3 or more, rings 1 or more');
    }
    final columns = segments + 1;
    final vertexCount = columns * (rings + 1);
    if (vertexCount > 65535) {
      throw ArgumentError('segments and rings make more than 65535 vertices');
    }
    final foot = _footFrom([
      for (var i = 0; i <= segments; i++) ...[
        radius * (i == segments ? 1.0 : math.cos(i * 2 * math.pi / segments)),
        radius * (i == segments ? 0.0 : -math.sin(i * 2 * math.pi / segments)),
        0.0,
        0.0,
      ],
    ]);
    final stride = layout.strideInFloats;
    final vertices = Float32List(vertexCount * stride);
    var o = 0;
    for (var j = 0; j <= rings; j++) {
      final v = j / rings;
      final elevation = v * math.pi / 2;
      final c = math.cos(elevation);
      final s = math.sin(elevation);
      for (var i = 0; i <= segments; i++) {
        final nx = foot[i * 3] / radius * c;
        final nz = foot[i * 3 + 1] / radius * c;
        vertices
          ..[o] = nx * radius
          ..[o + 1] = s * radius
          ..[o + 2] = nz * radius
          ..[o + 3] = foot[i * 3 + 2]
          ..[o + 4] = v
          ..[o + 5] = nx
          ..[o + 6] = s
          ..[o + 7] = nz;
        o += stride;
      }
    }
    final indices = <int>[];
    for (var j = 0; j < rings; j++) {
      for (var i = 0; i < segments; i++) {
        final a = j * columns + i;
        final b = a + 1;
        final topA = a + columns;
        final topB = topA + 1;
        indices.addAll([a, b, topB]);
        if (j < rings - 1) {
          // The last ring meets at the pole: one triangle per segment.
          indices.addAll([a, topB, topA]);
        }
      }
    }
    return BarrierMesh._(
      BarrierMeshShape.dome,
      foot[segments * 3 + 2],
      radius,
      foot,
    )..addSurface(
      Surface.fromBuffers(
        vertices: vertices,
        indices: Uint16List.fromList(indices),
        layout: layout,
        material: material,
      ),
    );
  }

  /// The vertex layout of every barrier mesh: `vertexPosition` (3 floats),
  /// `vertexTexCoord` (2) and `vertexNormal` (3).
  static final VertexLayout layout = VertexLayout(const [
    VertexAttribute(VertexLayout.positionAttribute, 3),
    VertexAttribute('vertexTexCoord', 2),
    VertexAttribute('vertexNormal', 3),
  ]);

  /// Writes into [out] (a new vector when `null`) and returns the point of
  /// the wall at the distance [along] its foot (wrapped around [length]) and
  /// at [heightFraction] of its height (`0` at the foot, `1` at the top or
  /// the pole), in the mesh's own space.
  ///
  /// Transform it by the world transform of the component that draws the
  /// mesh to get the world position `BarrierMaterial.impact` takes.
  Vector3 pointOnWall(double along, double heightFraction, [Vector3? out]) {
    final result = out ?? Vector3.zero();
    final foot = _foot;
    final count = foot.length ~/ 3;
    var d = length > 0 ? along % length : 0.0;
    if (!d.isFinite) {
      d = 0;
    }
    // The segment of the foot holding the distance.
    var low = 0;
    var high = count - 1;
    while (high - low > 1) {
      final mid = (low + high) >> 1;
      if (foot[mid * 3 + 2] <= d) {
        low = mid;
      } else {
        high = mid;
      }
    }
    final d0 = foot[low * 3 + 2];
    final d1 = foot[high * 3 + 2];
    final t = d1 > d0 ? ((d - d0) / (d1 - d0)).clamp(0.0, 1.0) : 0.0;
    final x = foot[low * 3] + (foot[high * 3] - foot[low * 3]) * t;
    final z = foot[low * 3 + 1] + (foot[high * 3 + 1] - foot[low * 3 + 1]) * t;
    final h = heightFraction.clamp(0.0, 1.0);
    if (shape == BarrierMeshShape.dome) {
      final elevation = h * math.pi / 2;
      final c = math.cos(elevation);
      return result..setValues(x * c, height * math.sin(elevation), z * c);
    }
    return result..setValues(x, h * height, z);
  }

  /// Builds a band of [height] over the foot [points] (x, z, normal x,
  /// normal z per point), in [heightSegments] rows.
  static BarrierMesh _band(
    BarrierMeshShape shape,
    List<double> points,
    double height,
    Material? material, {
    int heightSegments = 1,
  }) {
    if (heightSegments < 1) {
      throw ArgumentError.value(heightSegments, 'heightSegments', 'Must be 1+');
    }
    final foot = _footFrom(points);
    final count = points.length ~/ 4;
    final rows = heightSegments + 1;
    if (count * rows > 65535) {
      throw ArgumentError(
        'The columns and heightSegments make more than 65535 vertices',
      );
    }
    final stride = layout.strideInFloats;
    final vertices = Float32List(count * rows * stride);
    for (var i = 0; i < count; i++) {
      final x = points[i * 4];
      final z = points[i * 4 + 1];
      final nx = points[i * 4 + 2];
      final nz = points[i * 4 + 3];
      final along = foot[i * 3 + 2];
      for (var row = 0; row < rows; row++) {
        final v = row == heightSegments ? 1.0 : row / heightSegments;
        final o = (i * rows + row) * stride;
        vertices
          ..[o] = x
          ..[o + 1] = v * height
          ..[o + 2] = z
          ..[o + 3] = along
          ..[o + 4] = v
          ..[o + 5] = nx
          ..[o + 6] = 0
          ..[o + 7] = nz;
      }
    }
    final indices = <int>[];
    for (var i = 0; i < count - 1; i++) {
      for (var row = 0; row < heightSegments; row++) {
        final foot0 = i * rows + row;
        final top0 = foot0 + 1;
        final foot1 = foot0 + rows;
        final top1 = foot1 + 1;
        // Counter-clockwise seen from outside.
        indices.addAll([foot0, foot1, top1, foot0, top1, top0]);
      }
    }
    return BarrierMesh._(shape, foot[(count - 1) * 3 + 2], height, foot)
      ..addSurface(
        Surface.fromBuffers(
          vertices: vertices,
          indices: Uint16List.fromList(indices),
          layout: layout,
          material: material,
        ),
      );
  }

  /// [points] (x, z, normal x, normal z per point) with points added along
  /// every segment longer than [maxLength], so that none is; the normals of
  /// the added points are interpolated. `null` keeps [points].
  static List<double> _subdivide(List<double> points, double? maxLength) {
    if (maxLength == null) {
      return points;
    }
    if (!(maxLength > 0)) {
      throw ArgumentError.value(maxLength, 'maxSegmentLength', 'Must be > 0');
    }
    final result = <double>[...points.sublist(0, 4)];
    for (var i = 4; i < points.length; i += 4) {
      final x0 = points[i - 4];
      final z0 = points[i - 3];
      final x1 = points[i];
      final z1 = points[i + 1];
      final dx = x1 - x0;
      final dz = z1 - z0;
      final parts = (math.sqrt(dx * dx + dz * dz) / maxLength).ceil();
      for (var k = 1; k < parts; k++) {
        final t = k / parts;
        var nx = points[i - 2] + (points[i + 2] - points[i - 2]) * t;
        var nz = points[i - 1] + (points[i + 3] - points[i - 1]) * t;
        final n = math.sqrt(nx * nx + nz * nz);
        if (n > 0) {
          nx /= n;
          nz /= n;
        }
        result.addAll([x0 + dx * t, z0 + dz * t, nx, nz]);
      }
      result.addAll(points.sublist(i, i + 4));
    }
    return result;
  }

  @override
  void draw(
    RenderContext3D context, {
    Matrix4? transform,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
    Map<int, List<Matrix4>>? jointTransforms,
    bool? mirrored,
  }) {
    super.draw(
      context,
      transform: transform,
      color: color,
      instanceData: instanceData,
      jointTransforms: jointTransforms,
      mirrored: mirrored,
    );
    if (context.isShadowPass || context.isDepthNormalPass) {
      return;
    }
    final surfaces = this.surfaces;
    for (var i = 0; i < surfaceCount; i++) {
      final surface = surfaces.elementAt(i);
      final material = surface.material;
      if (material is BarrierMaterial && material.drawsReactionInFront) {
        context.drawSurface(
          surface,
          transform: transform,
          color: color,
          instanceData: instanceData,
          material: material.reactionInFrontMaterial,
          mirrored: mirrored,
        );
      }
    }
  }

  /// The x, z and distance along the foot of each point of [points] (x, z,
  /// and two more values per point).
  static Float64List _footFrom(List<double> points) {
    final count = points.length ~/ 4;
    final foot = Float64List(count * 3);
    var distance = 0.0;
    for (var i = 0; i < count; i++) {
      final x = points[i * 4];
      final z = points[i * 4 + 1];
      if (i > 0) {
        final dx = x - points[(i - 1) * 4];
        final dz = z - points[(i - 1) * 4 + 1];
        distance += math.sqrt(dx * dx + dz * dz);
      }
      foot
        ..[i * 3] = x
        ..[i * 3 + 1] = z
        ..[i * 3 + 2] = distance;
    }
    return foot;
  }

  /// [points] without the points that repeat the previous one, position and
  /// normal.
  static List<double> _dropRepeats(List<double> points) {
    final result = <double>[];
    for (var i = 0; i < points.length; i += 4) {
      final n = result.length;
      if (n >= 4 &&
          (result[n - 4] - points[i]).abs() < 1e-9 &&
          (result[n - 3] - points[i + 1]).abs() < 1e-9 &&
          (result[n - 2] - points[i + 2]).abs() < 1e-9 &&
          (result[n - 1] - points[i + 3]).abs() < 1e-9) {
        continue;
      }
      result.addAll(points.sublist(i, i + 4));
    }
    return result;
  }
}
