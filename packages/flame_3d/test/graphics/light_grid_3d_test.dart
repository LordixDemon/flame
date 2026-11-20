import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' show makeOrthographicMatrix;

Light _point(
  double x,
  double y,
  double z, {
  double range = 1.5,
  double? intensity,
  Color color = const Color(0xFFFFC080),
  ShadowSettings? shadows,
  int lightMask = 0xFFFFFFFF,
}) => Light(
  position: Vector3(x, y, z),
  lightMask: lightMask,
  source: PointLight(
    color: color,
    intensity: intensity ?? 1,
    range: range,
    shadows: shadows,
  ),
);

Light _spot(
  double x,
  double y,
  double z, {
  required Vector3 direction,
  double range = 3,
  double intensity = 2,
  double outer = 0.5,
  double inner = 0.3,
}) => Light(
  position: Vector3(x, y, z),
  source: SpotLight(
    intensity: intensity,
    range: range,
    direction: direction,
    outerConeAngle: outer,
    innerConeAngle: inner,
    specular: 0.6,
  ),
);

/// The header `(point start, point count, spot start, spot count)` of the
/// cell of [grid] around ([x], [y], [z]), as the shader finds it (in
/// float32), or `null` outside the grid.
List<double>? _cellAt(LightGrid3D grid, double x, double y, double z) {
  final s = grid.stats;
  final f = Float32List(4);
  double cellOf(double p, double o) {
    f
      ..[0] = p
      ..[1] = o
      ..[2] = 1 / s.cellSize;
    f[3] = (f[0] - f[1]) * f[2];
    return f[3].floorToDouble();
  }

  final cx = cellOf(x, grid.origin.x);
  final cy = cellOf(y, grid.origin.y);
  final cz = cellOf(z, grid.origin.z);
  if (cx < 0 ||
      cy < 0 ||
      cz < 0 ||
      cx >= s.cellsX ||
      cy >= s.cellsY ||
      cz >= s.cellsZ) {
    return null;
  }
  final index = (cx + s.cellsX * (cy + s.cellsY * cz)).toInt();
  return grid.texels.sublist(index * 4, index * 4 + 4);
}

/// The positions of the point lights the cell [header] lists.
List<Vector3> _pointsOf(LightGrid3D grid, List<double> header) => [
  for (var k = 0; k < header[1]; k++)
    Vector3(
      grid.texels[(header[0].toInt() + 2 * k) * 4],
      grid.texels[(header[0].toInt() + 2 * k) * 4 + 1],
      grid.texels[(header[0].toInt() + 2 * k) * 4 + 2],
    ),
];

bool _listsPointAt(LightGrid3D grid, List<double> header, Vector3 at) =>
    _pointsOf(grid, header).any(
      (p) =>
          (p.x - at.x).abs() < 1e-5 &&
          (p.y - at.y).abs() < 1e-5 &&
          (p.z - at.z).abs() < 1e-5,
    );

void main() {
  group('LightGrid3D', () {
    test('holds the point and spot lights with a range and no shadows', () {
      expect(LightGrid3D.binnable(_point(0, 0, 0)), isTrue);
      expect(LightGrid3D.binnable(_point(0, 0, 0, range: 0)), isFalse);
      expect(
        LightGrid3D.binnable(
          Light(
            position: Vector3.zero(),
            source: PointLight(color: const Color(0xFFFFFFFF), intensity: 1),
          ),
        ),
        isFalse,
      );
      expect(
        LightGrid3D.binnable(_point(0, 0, 0, shadows: ShadowSettings())),
        isFalse,
      );
      expect(LightGrid3D.binnable(_point(0, 0, 0, intensity: 0)), isFalse);
      expect(LightGrid3D.binnable(_point(0, 0, 0, intensity: -1)), isTrue);
      expect(
        LightGrid3D.binnable(_spot(0, 0, 0, direction: Vector3(0, -1, 0))),
        isTrue,
      );
      expect(
        LightGrid3D.binnable(
          _spot(0, 0, 0, direction: Vector3(0, -1, 0), intensity: 0),
        ),
        isFalse,
      );
      expect(
        LightGrid3D.binnable(
          Light(position: Vector3.zero(), source: DirectionalLight()),
        ),
        isFalse,
      );
    });

    test('lists every light in every cell it reaches, in their order', () {
      final random = math.Random(7);
      final lights = [
        for (var i = 0; i < 120; i++)
          _point(
            random.nextDouble() * 20 - 10,
            random.nextDouble() * 2,
            random.nextDouble() * 20 - 10,
            range: 0.6 + random.nextDouble() * 1.4,
          ),
      ];
      final grid = LightGrid3D();
      expect(
        grid.build(
          lights: lights,
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(),
          points: true,
          spots: false,
        ),
        isTrue,
      );
      final s = grid.stats;
      expect(s.active, isTrue);
      expect(s.pointLights, 120);
      expect(s.droppedEntries, 0);
      expect(s.droppedLights, 0);
      // The power of two nearest the geometric mean of the ranges.
      expect(s.cellSize, 1);
      expect(s.cells, lessThanOrEqualTo(4096));

      // Points inside the reach of each light find it in their cell.
      for (final light in lights) {
        final range = (light.source as PointLight).range!;
        for (var j = 0; j < 40; j++) {
          final dir = Vector3(
            random.nextDouble() * 2 - 1,
            random.nextDouble() * 2 - 1,
            random.nextDouble() * 2 - 1,
          )..normalize();
          final at = light.position + dir * (range * random.nextDouble());
          final header = _cellAt(grid, at.x, at.y, at.z);
          expect(header, isNotNull);
          expect(_listsPointAt(grid, header!, light.position), isTrue);
        }
      }

      // Each cell lists its lights in the order of the list.
      for (var c = 0; c < s.cells; c++) {
        final header = grid.texels.sublist(c * 4, c * 4 + 4);
        final listed = _pointsOf(grid, header);
        var previous = -1;
        for (final p in listed) {
          final index = lights.indexWhere(
            (l) => (l.position - p).length < 1e-5,
          );
          expect(index, greaterThan(previous));
          previous = index;
        }
      }
    });

    test('writes the values the light blocks hold', () {
      final grid = LightGrid3D()
        ..build(
          lights: [
            _point(1, 2, 3, range: 2, intensity: 3),
            _spot(
              -1,
              4,
              0,
              direction: Vector3(0, -2, 0),
              outer: 0.7,
              inner: 0.4,
            ),
          ],
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(),
          points: true,
          spots: true,
        );
      final point = _cellAt(grid, 1, 2, 3)!;
      expect(point[1], 1);
      final p = point[0].toInt() * 4;
      final f = Float32List(1);
      double f32(double v) => (f..[0] = v)[0];
      const color = Color(0xFFFFC080);
      expect(grid.texels.sublist(p, p + 8), [
        1,
        2,
        3,
        2,
        f32(color.r),
        f32(color.g),
        f32(color.b),
        3,
      ]);

      final spot = _cellAt(grid, -1, 2, 0)!;
      expect(spot[3], 1);
      final o = spot[2].toInt() * 4;
      final cosOuter = math.cos(0.7);
      expect(grid.texels.sublist(o, o + 4), [-1, 4, 0, 3]);
      expect(grid.texels[o + 7], 2);
      expect(grid.texels.sublist(o + 8, o + 12), [0, 1, 0, f32(0.6)]);
      expect(grid.texels[o + 12], f32(cosOuter));
      expect(grid.texels[o + 13], f32(1 / (math.cos(0.4) - cosOuter)));
    });

    test('lists a spot light only in the cells its cone reaches', () {
      final light = _spot(
        0,
        3,
        0,
        direction: Vector3(0, -1, 0),
        range: 4,
        outer: 0.35,
        inner: 0.2,
      );
      final grid = LightGrid3D()
        ..build(
          lights: [light],
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(cellSize: 0.5),
          points: false,
          spots: true,
        );
      // Under it, inside the cone, it is listed.
      for (var y = 0.0; y < 2.9; y += 0.25) {
        final depth = 3 - y;
        final radius = math.tan(0.35) * depth * 0.95;
        for (final (dx, dz) in [(0.0, 0.0), (radius, 0.0), (0.0, -radius)]) {
          expect(_cellAt(grid, dx, y, dz)![3], 1, reason: '$dx $y $dz');
        }
      }
      // Above it and far to the side, it is not.
      expect(_cellAt(grid, 0, 6.5, 0)?[3] ?? 0, 0);
      expect(_cellAt(grid, 3, 0.5, 0)?[3] ?? 0, 0);
      expect(grid.stats.entries, lessThan(grid.stats.cells ~/ 4));
    });

    test('keeps in a full cell the lights that light it the most', () {
      // Five lights reaching the cell around the origin; the cell keeps two.
      final lights = [
        _point(0.9, 0.5, 0.5, range: 1.2, intensity: 1),
        _point(0.5, 0.5, 0.5, range: 1.2, intensity: 0.2),
        _point(0.5, 0.4, 0.5, range: 1.2, intensity: 3),
        _point(1.7, 0.5, 0.5, range: 1.2, intensity: 5),
        _point(0.4, 0.6, 0.4, range: 1.2, intensity: 1),
      ];
      final grid = LightGrid3D()
        ..build(
          lights: lights,
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(
            cellSize: 1,
            maxPointLightsPerCell: 2,
          ),
          points: true,
          spots: false,
        );
      final header = _cellAt(grid, 0.5, 0.5, 0.5)!;
      expect(header[1], 2);
      // Inside the cell: lights 0, 1, 2, 4 light it fully (scores 1, 0.2, 3,
      // 1), light 3 from 0.7 away ((1 - 0.7 / 1.2)² * 5 ≈ 0.87): it keeps
      // light 2, then light 0 (before light 4, of the same score), in their
      // order.
      expect(_pointsOf(grid, header), [
        lights[0].position,
        lights[2].position,
      ]);
      expect(grid.stats.droppedEntries, greaterThanOrEqualTo(3));
      expect(grid.stats.maxPointLightsInCell, 2);
    });

    test('does not depend on the camera, and rebuilds only on changes', () {
      final lights = [
        for (var i = 0; i < 30; i++) _point(i * 0.7, 0.5, (i % 5) * 0.9),
      ];
      final grid = LightGrid3D();
      bool build(Matrix4 view) => grid.build(
        lights: lights,
        cameraMask: 0xFFFFFFFF,
        settings: const LightGridSettings(),
        points: true,
        spots: false,
        viewProjection: view,
      );

      expect(build(Matrix4.identity()), isTrue);
      final texels = Float32List.fromList(grid.texels);
      final version = grid.contentVersion;
      final origin = grid.origin.clone();
      // Another camera: the same grid, not even rebuilt.
      expect(build(Matrix4.translationValues(5, 1, 0)..rotateY(0.4)), isFalse);
      expect(grid.contentVersion, version);
      expect(grid.stats.builds, 1);
      expect(grid.texels, texels);
      expect(grid.origin, origin);

      // A light moves: rebuilt.
      lights[3].position.x += 0.25;
      expect(build(Matrix4.identity()), isTrue);
      expect(grid.contentVersion, version + 1);
      // Its intensity changes: rebuilt.
      (lights[4].source as PointLight).intensity = 2;
      expect(build(Matrix4.identity()), isTrue);
      // Nothing changes: kept.
      expect(build(Matrix4.identity()), isFalse);
      expect(grid.stats.builds, 3);
    });

    test('keeps the maxLights strongest lights', () {
      final lights = [
        _point(0, 0, 0, intensity: 1),
        _point(1, 0, 0, intensity: 4),
        _point(2, 0, 0, intensity: 1),
        _point(3, 0, 0, intensity: 3),
        _point(4, 0, 0, intensity: 1),
      ];
      final grid = LightGrid3D()
        ..build(
          lights: lights,
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(maxLights: 3),
          points: true,
          spots: false,
        );
      expect(grid.stats.pointLights, 3);
      expect(grid.stats.droppedLights, 2);
      // Lights 1 and 3, and of the three of intensity 1 the first.
      bool listed(Light light) {
        final header = _cellAt(
          grid,
          light.position.x,
          light.position.y,
          light.position.z,
        );
        return header != null && _listsPointAt(grid, header, light.position);
      }

      expect(lights.map(listed), [true, true, false, true, false]);
    });

    test('leaves out lights the pass does not shade', () {
      final grid = LightGrid3D()
        ..build(
          lights: [
            _point(0, 0, 0),
            _point(1, 0, 0, lightMask: 2),
            _point(2, 0, 0, shadows: ShadowSettings()),
            _point(3, 0, 0, range: 0),
            _spot(4, 0, 0, direction: Vector3(0, -1, 0)),
          ],
          cameraMask: 1,
          settings: const LightGridSettings(),
          points: true,
          spots: false,
        );
      expect(grid.stats.pointLights, 1);
      expect(grid.stats.spotLights, 0);
    });

    test('is cut to the view when the lights need too many cells', () {
      final lights = [
        for (var i = 0; i < 200; i++)
          _point((i % 20) * 10.0, 0.5, (i ~/ 20) * 10.0, range: 1),
      ];
      // An orthographic view of the region from (0, 0) to (30, 30).
      final view = Matrix4.identity()..setRotationX(math.pi / 2);
      final projection = makeOrthographicMatrix(0, 30, -30, 0, -50, 50);
      final grid = LightGrid3D()
        ..build(
          lights: lights,
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(),
          points: true,
          spots: false,
          viewProjection: projection.multiplied(view),
        );
      final s = grid.stats;
      expect(s.clippedToView, isTrue);
      expect(s.cellSize, 1);
      // Without the cut, 192 x 2 x 192 cells.
      expect(s.cells, lessThanOrEqualTo(4096));
      // The 16 lights of the view, and its rim, not those far from it.
      expect(s.pointLights, inInclusiveRange(16, 25));
      expect(_cellAt(grid, 10, 0.5, 20)![1], 1);
      expect(_cellAt(grid, 150, 0.5, 150), isNull);
    });

    test('covers only the bounds of what the pass draws', () {
      final lights = [
        for (var i = 0; i < 40; i++)
          _point((i % 8) * 1.0, (i ~/ 8) * 1.0, 0.8, range: 1.2),
        // Two large lights high above.
        _point(0, 0, 3, range: 7),
        _point(6, 3, 3, range: 7),
      ];
      final grid = LightGrid3D();
      grid.build(
        lights: lights,
        cameraMask: 0xFFFFFFFF,
        settings: const LightGridSettings(),
        points: true,
        spots: false,
      );
      // The large lights reach 14 units up and down: cells of 1 would be
      // too many.
      expect(grid.stats.cellSize, 2);
      expect(
        grid.build(
          lights: lights,
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(),
          points: true,
          spots: false,
          bounds: Aabb3.minMax(Vector3(-2, -2, -0.5), Vector3(9, 6, 1.5)),
        ),
        isTrue,
      );
      final s = grid.stats;
      // Cut to the bounds, cells of 1 fit.
      expect(s.cellSize, 1);
      expect(s.cellsZ, 3);
      expect(s.pointLights, 42);
      expect(_cellAt(grid, 3, 2, 0)![1], greaterThanOrEqualTo(3));
      // Outside the bounds there are no cells.
      expect(_cellAt(grid, 3, 2, 4), isNull);
      // The same bounds again: kept.
      expect(
        grid.build(
          lights: lights,
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(),
          points: true,
          spots: false,
          bounds: Aabb3.minMax(Vector3(-2, -2, -0.5), Vector3(9, 6, 1.5)),
        ),
        isFalse,
      );
    });

    test('grows its cells until it fits its texture', () {
      final lights = [
        for (var i = 0; i < 400; i++)
          _point((i % 20) * 0.5, (i ~/ 20) * 0.5, 0, range: 6),
      ];
      final grid = LightGrid3D()
        ..build(
          lights: lights,
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(cellSize: 0.125, maxCells: 65536),
          points: true,
          spots: false,
        );
      final s = grid.stats;
      expect(s.cellSize, greaterThan(0.125));
      expect(s.usedTexels, lessThanOrEqualTo(LightGrid3D.maxTexels));
      expect(s.textureHeight * LightGrid3D.textureWidth, greaterThan(0));
      expect(s.maxPointLightsInCell, 32);
    });

    test('holds nothing without lights', () {
      final grid = LightGrid3D()
        ..build(
          lights: const [],
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(),
          points: true,
          spots: true,
        );
      expect(grid.hasLights, isFalse);
      expect(grid.stats.active, isFalse);
      expect(grid.stats.textureHeight, 1);
    });

    test('settings compare by value', () {
      expect(
        const LightGridSettings(cellSize: 2),
        const LightGridSettings(cellSize: 2),
      );
      expect(
        const LightGridSettings(cellSize: 2).hashCode,
        const LightGridSettings(cellSize: 2).hashCode,
      );
      expect(
        const LightGridSettings(),
        isNot(const LightGridSettings(beyondLimitsOnly: false)),
      );
    });
  });
}
