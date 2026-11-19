import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// The depth a shadow map stores for a pixel must be that of the caster at
// that pixel. Under a spot light's perspective projection, the depth of the
// corners of a triangle interpolated across it is not: it is nearer than the
// surface between the corners, which then shadows itself.

const _size = 128;

/// The ground: two triangles, a square of side 2 in the z = -5 plane, facing
/// +z.
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

/// A spot light at (-0.6, 0, -1) shining down to the right: a cube of side
/// 0.4 at (0, 0, -4) shadows the ground from x -0.1 to about 0.6.
Light _spot({required bool shadows}) => Light(
  position: Vector3(-0.6, 0, -1),
  source: SpotLight(
    direction: Vector3(1, 0, -4),
    range: 10,
    innerConeAngle: 0.5,
    outerConeAngle: 0.7,
    shadows: shadows ? ShadowSettings() : null,
  ),
);

/// A spot light with shadows that lights nothing the camera sees: with it,
/// the maps of both spot lights are tiles of the atlas.
Light _farSpot() => Light(
  position: Vector3(0, 0, 20),
  source: SpotLight(
    direction: Vector3(0, 0, 1),
    intensity: 0.5,
    range: 2,
    shadows: ShadowSettings(resolution: 256),
  ),
);

Future<Frame> _render(List<Light> lights) async {
  final material = SpatialMaterial(roughness: 1);
  final ground = _ground(material);
  final cube = CuboidMesh(size: Vector3.all(0.4), material: material);
  void draw(RenderContext3D context) => context
    ..drawSurface(ground)
    ..drawMesh(cube, transform: Matrix4.translation(Vector3(0, 0, -4)));

  final device = GraphicsDevice();
  final context = RenderContext3D(device);
  device.begin();
  context
    ..lights = lights
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
    const Size(_size + 0.0, _size + 0.0),
    frontFace: context.frontFace,
  );
  draw(context);
  context.flush();
  final image = device.endPass();
  device.end();
  final stats = RenderStats()..setFrom(device.lastFrameStats);
  final pixels = await readImage(image);
  image.dispose();
  return Frame(pixels, stats);
}

void main() {
  setUpGpu();

  testGpuEngine('a spot light map holds the depth of every pixel', () async {
    final hemisphere = Light(
      position: Vector3.zero(),
      source: HemisphereLight(intensity: 0.4, up: Vector3(0, 0, 1)),
    );
    final shadowed = await _render([
      hemisphere,
      _spot(shadows: true),
      _farSpot(),
    ]);
    final unshadowed = await _render([
      hemisphere,
      _spot(shadows: false),
      _farSpot(),
    ]);

    // The cube's shadow.
    final (sx, sy) = pixelAt(0.35, 0, width: _size, height: _size);
    expect(
      unshadowed.pixels.at(sx, sy).$1 - shadowed.pixels.at(sx, sy).$1,
      greaterThan(20),
    );
    // Lit everywhere else.
    var differing = 0;
    for (var py = 0; py < _size; py++) {
      for (var px = 0; px < _size; px++) {
        final x = (px + 0.5) / _size * 2 - 1;
        final y = 1 - (py + 0.5) / _size * 2;
        // The cube and its shadow.
        if (x > -0.15 && x < 0.62 && y.abs() < 0.33) {
          continue;
        }
        final a = shadowed.pixels.at(px, py).$1;
        final b = unshadowed.pixels.at(px, py).$1;
        if ((a - b).abs() > 2) {
          differing++;
        }
      }
    }
    expect(differing, 0);
  });
}
