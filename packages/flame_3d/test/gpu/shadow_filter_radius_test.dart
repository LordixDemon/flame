import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// The shadow filter at every radius it takes (`ShadowSettings.softness` 0 to
// 3), on each way a frame stores the shadows (one map, cascades in the atlas,
// a spot light's tile, a point light's tiles): over a shadow map that holds
// no caster, a ShadowCatcherMaterial shows nothing and a lit receiver is as
// bright as without shadows; with a caster, its shadow shows (the filter
// runs) and the ground away from it stays as bright as without shadows.
//
// The filter's loops have constant bounds because an OpenGL ES driver (the
// Android emulator's) ran the loops that started at `-radius` wrongly: every
// surface came out partly in shadow at radius 1 to 3. The renderer of these
// tests runs either form right, so they guard the filter's result, and
// test/shaders/shader_loops_test.dart guards its form.
//
// The scene: the default camera (looking down -z, x and y in [-1, 1]), a
// ground facing +z at z = -5 and a cube of side 0.4 centered at (0, 0, -4)
// that only casts (the camera does not see it). The sun travels along
// (0.5, 0, -1): its shadow spans x 0.2 to 0.8 and y -0.2 to 0.2. The spot
// and point lights hang at (0, 0, 1): their shadows span x and y -0.25 to
// 0.25.

const _size = 128;

Surface _ground(Material material) {
  final stride = VertexLayout.standard.strideInFloats;
  final vertices = Float32List(4 * stride);
  const corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)];
  for (final (i, (x, y)) in corners.indexed) {
    vertices
      ..setRange(i * stride, i * stride + 3, [x.toDouble(), y.toDouble(), -5])
      ..setRange(i * stride + 5, i * stride + 9, [1, 1, 1, 1])
      ..setRange(i * stride + 9, i * stride + 12, [0, 0, 1]);
  }
  return Surface.fromBuffers(
    vertices: vertices,
    indices: Uint16List.fromList([0, 1, 2, 2, 3, 0]),
    material: material,
  );
}

final Vector3 _cubeCenter = Vector3(0, 0, -4);

Light _sun(ShadowSettings? shadows) => Light(
  position: Vector3.zero(),
  source: DirectionalLight(
    direction: Vector3(0.5, 0, -1),
    intensity: 0.5,
    shadows: shadows,
  ),
);

Light _spot(ShadowSettings? shadows) => Light(
  position: Vector3(0, 0, 1),
  source: SpotLight(
    direction: Vector3(0, 0, -1),
    intensity: 0.3,
    range: 20,
    innerConeAngle: 0.4,
    outerConeAngle: 0.5,
    shadows: shadows,
  ),
);

Light _point(ShadowSettings? shadows) => Light(
  position: Vector3(0, 0, 1),
  source: PointLight(
    color: const Color(0xFFFFFFFF),
    intensity: 0.3,
    range: 20,
    shadows: shadows,
  ),
);

Light _hemisphere() => Light(
  position: Vector3.zero(),
  source: HemisphereLight(intensity: 0.4, up: Vector3(0, 0, 1)),
);

/// The ways a frame stores the shadows, each with the lights of a softness
/// (`null`: the same lights without shadows) and a point inside a shadow of
/// the cube.
final Map<String, (List<Light> Function(int? softness), (double, double))>
_paths = {
  'one map': (
    (s) => [_sun(s == null ? null : ShadowSettings(softness: s))],
    (0.5, 0.0),
  ),
  '2 cascades': (
    (s) => [_sun(s == null ? null : ShadowSettings(cascades: 2, softness: s))],
    (0.5, 0.0),
  ),
  "a spot light's tile": (
    (s) => [
      _sun(s == null ? null : ShadowSettings(softness: s)),
      _spot(s == null ? null : ShadowSettings(resolution: 256, softness: s)),
    ],
    (0.0, 0.0),
  ),
  "a point light's tiles": (
    (s) => [
      _sun(s == null ? null : ShadowSettings(softness: s)),
      _point(s == null ? null : ShadowSettings(resolution: 256, softness: s)),
    ],
    (0.0, 0.0),
  ),
};

/// Points of the ground away from every shadow of the cube.
const _lit = [(-0.6, 0.6), (-0.6, -0.6), (0.6, 0.6), (0.6, -0.6), (-0.6, 0.0)];

/// Renders the ground in [material] under [lights] after the whole shadow
/// pass (every tile of the atlas), with the cube in the shadow pass when
/// [caster].
Future<Pixels> _render(
  Material material,
  List<Light> lights, {
  required bool caster,
}) async {
  final ground = _ground(material);
  final cube = CuboidMesh(size: Vector3.all(0.4), material: StylizedMaterial());
  void draw(RenderContext3D context) {
    if (!context.isShadowPass) {
      context.drawSurface(ground);
    } else if (caster) {
      context.drawMesh(cube, transform: Matrix4.translation(_cubeCenter));
    }
  }

  final device = GraphicsDevice();
  final context = RenderContext3D(device);
  device.begin();
  context
    ..lights = [_hemisphere(), ...lights]
    ..setCamera(defaultView, defaultProjection);
  if (context.beginShadowPass(
    projection: DirectionalShadowProjection(),
    sceneBounds: Aabb3.minMax(Vector3(-1, -1, -5), Vector3(1, 1, -3.8)),
  )) {
    draw(context);
    while (context.advanceShadowAtlasTile()) {
      draw(context);
    }
    context.endShadowPass();
  }
  device.beginPass(
    const Size(_size * 1.0, _size * 1.0),
    frontFace: context.frontFace,
  );
  draw(context);
  context.flush();
  final image = device.endPass();
  device.end();
  final pixels = await readImage(image);
  image.dispose();
  return pixels;
}

(int, int, int, int) _at(Pixels pixels, (double, double) point) {
  final (px, py) = pixelAt(point.$1, point.$2, width: _size, height: _size);
  return pixels.at(px, py);
}

void main() {
  setUpGpu();

  for (final MapEntry(key: name, value: (lights, shadowPoint))
      in _paths.entries) {
    group('With $name', () {
      for (final softness in [0, 1, 2, 3]) {
        testGpuEngine(
          'ShadowCatcherMaterial shows nothing where the ground is lit, '
          'softness $softness',
          () async {
            final empty = await _render(
              ShadowCatcherMaterial(),
              lights(softness),
              caster: false,
            );
            expect(empty.count((r, g, b, a) => a > 0), 0);

            final cast = await _render(
              ShadowCatcherMaterial(),
              lights(softness),
              caster: true,
            );
            expect(_at(cast, shadowPoint).$4, greaterThan(100));
            for (final point in _lit) {
              expect(_at(cast, point).$4, 0, reason: 'at $point');
            }
          },
        );

        testGpuEngine(
          'a lit receiver is as bright as without shadows, '
          'softness $softness',
          () async {
            final unshadowed = await _render(
              StylizedMaterial(),
              lights(null),
              caster: true,
            );
            final empty = await _render(
              StylizedMaterial(),
              lights(softness),
              caster: false,
            );
            expect(differingPixels(empty, unshadowed, tolerance: 1), 0);

            final cast = await _render(
              StylizedMaterial(),
              lights(softness),
              caster: true,
            );
            expect(
              _at(unshadowed, shadowPoint).$1 - _at(cast, shadowPoint).$1,
              greaterThan(20),
            );
            for (final point in _lit) {
              expect(
                _at(cast, point).$1,
                closeTo(_at(unshadowed, point).$1, 1),
                reason: 'at $point',
              );
            }
          },
        );
      }
    });
  }
}
