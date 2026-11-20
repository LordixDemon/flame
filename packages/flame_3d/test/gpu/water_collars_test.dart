import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show ObjectKey;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// The collars of WaterFoamSources: the pixels no source reaches skip the
// sources (the vertices tell them), and the material then draws exactly the
// pixels of the fragment stage of before
// (test/gpu/shaders/reference/water_collars_fragment.glsl), whatever the
// size of the triangles.

const _size = 128;

/// 32 pixels per world unit in the top views.
const _pixelsPerUnit = 32.0;

/// A grid of water in [WaterMaterial.vertexLayout] over x = -[half] to
/// [half] and z = -[half] to [half] (in a `+Y`-up world; [v] maps the
/// coordinates for other worlds), [cells] cells a side, foaming towards -x.
Mesh _grid(
  WaterMaterial material, {
  double half = 2,
  int cells = 32,
  Vector3 Function(double x, double y, double z)? v,
}) {
  final positions = <double>[];
  final depths = <double>[];
  final foams = <double>[];
  final indices = <int>[];
  for (var j = 0; j <= cells; j++) {
    final z = -half + 2 * half * j / cells;
    for (var i = 0; i <= cells; i++) {
      final x = -half + 2 * half * i / cells;
      final p = v?.call(x, 0, z) ?? Vector3(x, 0, z);
      positions.addAll([p.x, p.y, p.z]);
      depths.add(0.2 + 0.3 * (x + 2));
      foams.add(x < -1.6 ? 1 : (x < -1.2 ? 0.5 : 0));
    }
  }
  for (var j = 0; j < cells; j++) {
    for (var i = 0; i < cells; i++) {
      final a = j * (cells + 1) + i;
      final b = a + cells + 1;
      // Counter-clockwise seen from +y.
      indices.addAll([a, b, b + 1, a, b + 1, a + 1]);
    }
  }
  return Mesh()..addSurface(
    WaterMaterial.buildSurface(
      positions: positions,
      depths: depths,
      foam: foams,
      indices: indices,
      material: material,
    ),
  );
}

/// One quad of water in the standard layout over the same square: two
/// triangles whose vertices are far from every source.
Mesh _quad(WaterMaterial material, {required bool zUp}) => TerrainMesh3D(
  columns: 2,
  rows: 2,
  width: 4,
  depth: 4,
  heights: Float32List(4),
  upAxis: zUp ? TerrainUpAxis.z : TerrainUpAxis.y,
  material: material,
);

/// A top-down orthographic view of the plane y = 0 (or z = 0), centered on
/// the origin.
Matrix4 _topView({required bool zUp}) => Matrix4.identity()
  ..setAsViewMatrix(
    zUp ? Vector3(0, 0, 10) : Vector3(0, 10, 0),
    Vector3.zero(),
    zUp ? Vector3(0, 1, 0) : Vector3(0, 0, -1),
  );

/// [_size] pixels for 4 world units.
final Matrix4 _topProjection = Matrix4.identity()
  ..setAsOrthographic(_size / _pixelsPerUnit, 1, 0.1, 30);

Future<Frame> _render(
  WidgetTester tester,
  World3D world, {
  required Matrix4 view,
  required Matrix4 projection,
  Msaa msaa = Msaa.off,
}) async {
  // Mounted, so that the shadows are fitted to its components.
  final game = FlameGame3D(world: world);
  await tester.pumpWidget(GameWidget(key: ObjectKey(game), game: game));
  await tester.pump();
  return (await tester.runAsync(() async {
    final device = GraphicsDevice();
    final context = RenderContext3D(device);
    device.begin();
    final image = world.renderToImage(
      const Size(_size + 0.0, _size + 0.0),
      view: view,
      projection: projection,
      msaa: msaa,
      device: device,
      context: context,
    );
    device.end();
    final stats = RenderStats()..setFrom(device.lastFrameStats);
    final pixels = await readImage(image);
    image.dispose();
    return Frame(pixels, stats);
  }))!;
}

/// Replaces the fragment stage of [material] by the one of before the
/// pixels no source reaches skipped the sources (both vertex stages are the
/// material's own).
void _useFragmentOfBefore(WaterMaterial material) {
  material.fragmentShader = FragmentShader.fromAsset(
    'test/water_collars_reference.shaderbundle',
    slots: [
      'WaterMaterial',
      RenderContext3D.stylizedPassBlock,
      RenderContext3D.shadowMapSampler,
      RenderContext3D.depthNormalSampler,
      RenderContext3D.depthNormalBlock,
      RenderContext3D.sceneColorSampler,
      RenderContext3D.sceneColorBlock,
    ],
  );
}

/// Collars of every kind over the square of [_grid], in a world mapped by
/// [v]: circles, a point, rectangles turned or not, strong and faint, one
/// partly off the water, one in the middle of each triangle of [_quad].
WaterFoamSources _collars(Vector3 Function(double x, double y, double z) v) {
  final axis = v(math.cos(math.pi / 6), 0, -math.sin(math.pi / 6));
  return WaterFoamSources()
    ..addCircle(v(-1.1, 0, -0.9), radius: 0.3)
    ..addCircle(v(0.3, 0, -1.2), radius: 0, width: 0.12, strength: 1.3)
    ..addRectangle(
      v(0.8, 0, 0.6),
      halfLength: 0.6,
      halfWidth: 0.25,
      cornerRadius: 0.1,
      axis: axis,
      width: 0.2,
    )
    ..addRectangle(
      v(-0.6, 0, 1.0),
      halfLength: 0.4,
      halfWidth: 0.4,
      cornerRadius: 0.04,
      strength: 0.6,
    )
    ..addCircle(v(1.9, 0, -1.8), radius: 0.2, width: 0.25)
    ..addCircle(v(-0.7, 0, -0.1), radius: 0.15, width: 0.2)
    ..addCircle(v(0.7, 0, 0.1), radius: 0.1, width: 0.15, strength: 0.9);
}

void main() {
  setUpGpu();

  group('Water collars', () {
    setUpAll(() async {
      if (gpuAvailable) {
        await registerTestShaders(['water_collars_reference']);
      }
    });

    testGpu(
      'skip the pixels they do not reach: the pixels of before, exactly',
      (tester) async {
        for (final zUp in [false, true]) {
          Vector3 v(double x, double y, double z) =>
              zUp ? Vector3(x, -z, y) : Vector3(x, y, z);
          WaterMaterial water({required bool before}) {
            final material = WaterMaterial(
              opacity: 0.85,
              time: 1.3,
              rippleStrength: 0.2,
              upAxis: zUp ? Vector3(0, 0, 1) : null,
              causticStrength: 0.4,
              sparkleStrength: 1.5,
              detailStrength: 0.5,
              depthRange: 0.7,
              ripples: WaterRipples()
                ..add(v(-0.4, 0, 0.3), time: 0.9, strength: 1.4),
              foamSources: _collars(v),
            );
            if (before) {
              _useFragmentOfBefore(material);
            }
            return material;
          }

          for (final quad in [false, true]) {
            World3D scene(WaterMaterial material) => World3D(
              children: [
                LightComponent.directional(
                  direction: v(-0.4, -1, -0.3),
                  color: const Color(0xFFFFC890),
                  intensity: 1.1,
                ),
                LightComponent.point(
                  position: v(1, 1.2, 1),
                  color: const Color(0xFFFFB060),
                  intensity: 2,
                  range: 4,
                ),
                LightComponent.hemisphere(
                  up: v(0, 1, 0),
                  skyColor: const Color(0xFFA0C8FF),
                ),
                MeshComponent(
                  mesh: quad
                      ? _quad(material, zUp: zUp)
                      : _grid(material, v: v),
                ),
              ],
            );

            final eye = v(1.2, 3.6, 3.4);
            final views = [
              (_topView(zUp: zUp), _topProjection),
              (
                Matrix4.identity()
                  ..setAsViewMatrix(eye, v(0, 0, 0), v(0, 1, 0)),
                Matrix4.identity()..setAsPerspective(55, 1, 0.5, 40),
              ),
            ];
            for (final (view, projection) in views) {
              for (final msaa in [Msaa.off, Msaa.sample4]) {
                final where = 'zUp $zUp, quad $quad, $msaa, $view';
                final now = await _render(
                  tester,
                  scene(water(before: false)),
                  view: view,
                  projection: projection,
                  msaa: msaa,
                );
                final before = await _render(
                  tester,
                  scene(water(before: true)),
                  view: view,
                  projection: projection,
                  msaa: msaa,
                );
                // The collars foam.
                expect(
                  now.pixels.count(
                    (r, g, b, a) => r > 180 && g > 180 && b > 180,
                  ),
                  greaterThan(150),
                  reason: where,
                );
                expect(
                  differingPixels(now.pixels, before.pixels, tolerance: 0),
                  0,
                  reason: where,
                );
              }
            }
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });
}
