import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// Every built-in receiver must show the sun's shadow in the same place
// whichever way the shadow pass stores it: one map, cascades, or the shared
// atlas that a second shadow-casting light (spot or point) moves the frame
// to. The scene: the default camera (looking down -z, x and y in [-1, 1]), a
// ground facing +z at z = -5, a cube of side 0.4 centered at (0, 0, -4), and
// a sun travelling along (0.5, 0, -1): the cube's shadow spans x 0.2 to 0.8
// and y -0.2 to 0.2.

const _size = 128;

/// The ground: a square of side 2 in the z = -5 plane, facing +z.
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

Aabb3 _bounds() => Aabb3.minMax(Vector3(-1, -1, -5), Vector3(1, 1, -3.8));

/// A light that casts shadows but lights nothing the camera sees: it only
/// moves the frame to the shadow atlas.
Light _farSpot() => Light(
  position: Vector3(0, 0, 20),
  source: SpotLight(
    direction: Vector3(0, 0, 1),
    intensity: 0.5,
    range: 2,
    shadows: ShadowSettings(resolution: 256),
  ),
);

/// See [_farSpot].
Light _farPoint() => Light(
  position: Vector3(0, 0, 40),
  source: PointLight(
    color: const Color(0xFFFFFFFF),
    intensity: 0.5,
    range: 1,
    shadows: ShadowSettings(resolution: 256),
  ),
);

/// The ways a frame stores the sun's shadow.
final Map<String, List<Light> Function()> _paths = {
  'one map': () => [_sun(ShadowSettings())],
  '2 cascades': () => [_sun(ShadowSettings(cascades: 2))],
  '3 cascades': () => [_sun(ShadowSettings(cascades: 3))],
  '4 cascades': () => [_sun(ShadowSettings(cascades: 4))],
  'a second shadow-casting spot light': () => [
    _sun(ShadowSettings()),
    _farSpot(),
  ],
  'a shadow-casting point light': () => [
    _sun(ShadowSettings()),
    _farPoint(),
  ],
};

Light _sun(ShadowSettings shadows) => Light(
  position: Vector3.zero(),
  source: DirectionalLight(
    direction: Vector3(0.5, 0, -1),
    intensity: 0.5,
    shadows: shadows,
  ),
);

Light _hemisphere() => Light(
  position: Vector3.zero(),
  source: HemisphereLight(intensity: 0.4, up: Vector3(0, 0, 1)),
);

/// Renders a frame of the default camera after the whole shadow pass, every
/// tile of the atlas included.
Future<Frame> renderWithShadows({
  required void Function(RenderContext3D context) draw,
  required List<Light> lights,
  Aabb3? sceneBounds,
  RenderContext3D? context,
  GraphicsDevice? device,
  DirectionalShadowProjection? shadowProjection,
  Matrix4? view,
  Matrix4? projection,
  int size = _size,
}) async {
  final graphicsDevice = device ?? context?.device ?? GraphicsDevice();
  final ctx = context ?? RenderContext3D(graphicsDevice);
  graphicsDevice.begin();
  ctx
    ..lights = lights
    ..setCamera(view ?? defaultView, projection ?? defaultProjection);
  if (ctx.beginShadowPass(
    projection: shadowProjection ?? DirectionalShadowProjection(),
    sceneBounds: sceneBounds ?? _bounds(),
  )) {
    draw(ctx);
    while (ctx.advanceShadowAtlasTile()) {
      draw(ctx);
    }
    ctx.endShadowPass();
  }
  graphicsDevice.beginPass(
    Size(size.toDouble(), size.toDouble()),
    frontFace: ctx.frontFace,
  );
  draw(ctx);
  ctx.flush();
  final image = graphicsDevice.endPass();
  graphicsDevice.end();
  final stats = RenderStats()..setFrom(graphicsDevice.lastFrameStats);
  final pixels = await readImage(image);
  image.dispose();
  return Frame(pixels, stats);
}

(int, int, int, int) _at(Frame frame, double x, double y) {
  final (px, py) = pixelAt(x, y, width: _size, height: _size);
  return frame.pixels.at(px, py);
}

/// The x coordinates where the row through [y] crosses [threshold] in
/// [channel].
List<double> _edges(Frame frame, double y, int threshold, {int channel = 0}) {
  final (_, py) = pixelAt(0, y, width: _size, height: _size);
  int value(int px) {
    final (r, g, b, a) = frame.pixels.at(px, py);
    return [r, g, b, a][channel];
  }

  final edges = <double>[];
  for (var px = 1; px < _size; px++) {
    final before = value(px - 1);
    final after = value(px);
    if ((before < threshold) != (after < threshold)) {
      final t = (threshold - before) / (after - before);
      edges.add((px - 0.5 + t) / _size * 2 - 1);
    }
  }
  return edges;
}

void main() {
  setUpGpu();

  // Lit by the sun: 0.4 + 0.5 * cos(26.57°); in shadow: 0.4.
  const lit = 216;
  const shadowed = 102;

  group('StylizedMaterial receives the sun shadow', () {
    for (final MapEntry(key: name, value: lights) in _paths.entries) {
      testGpuEngine('with $name', () async {
        final material = StylizedMaterial();
        final ground = _ground(material);
        final cube = CuboidMesh(size: Vector3.all(0.4), material: material);
        final frame = await renderWithShadows(
          lights: [_hemisphere(), ...lights()],
          draw: (context) => context
            ..drawSurface(ground)
            ..drawMesh(cube, transform: Matrix4.translation(_cubeCenter)),
        );
        expect(_at(frame, 0.5, 0).$1, closeTo(shadowed, 4));
        expect(_at(frame, 0.3, 0.1).$1, closeTo(shadowed, 4));
        expect(_at(frame, 0.7, -0.1).$1, closeTo(shadowed, 4));
        expect(_at(frame, 0.5, 0.5).$1, closeTo(lit, 4));
        expect(_at(frame, 0.5, -0.5).$1, closeTo(lit, 4));
        expect(_at(frame, -0.5, 0).$1, closeTo(lit, 4));
        expect(_at(frame, 0.9, 0).$1, closeTo(lit, 4));
        final edges = _edges(frame, 0.05, (lit + shadowed) ~/ 2);
        expect(edges, hasLength(2));
        expect(edges[0], closeTo(0.2, 0.05));
        expect(edges[1], closeTo(0.8, 0.05));
      });
    }
  });

  group('SpatialMaterial receives the sun shadow', () {
    for (final MapEntry(key: name, value: lights) in _paths.entries) {
      testGpuEngine('with $name', () async {
        final material = SpatialMaterial(roughness: 1);
        final ground = _ground(material);
        final cube = CuboidMesh(size: Vector3.all(0.4), material: material);
        final frame = await renderWithShadows(
          lights: [_hemisphere(), ...lights()],
          draw: (context) => context
            ..drawSurface(ground)
            ..drawMesh(cube, transform: Matrix4.translation(_cubeCenter)),
        );
        final litRed = _at(frame, -0.5, 0).$1;
        final shadowRed = _at(frame, 0.5, 0).$1;
        expect(litRed - shadowRed, greaterThan(20));
        expect(_at(frame, 0.5, 0.5).$1, closeTo(litRed, 3));
        expect(_at(frame, 0.9, 0).$1, closeTo(litRed, 3));
        final edges = _edges(frame, 0.05, (litRed + shadowRed) ~/ 2);
        expect(edges, hasLength(2));
        expect(edges[0], closeTo(0.2, 0.05));
        expect(edges[1], closeTo(0.8, 0.05));
      });
    }
  });

  group('ShadowCatcherMaterial shows the sun shadow', () {
    for (final MapEntry(key: name, value: lights) in _paths.entries) {
      testGpuEngine('with $name', () async {
        final ground = _ground(ShadowCatcherMaterial());
        final cube = CuboidMesh(
          size: Vector3.all(0.4),
          material: StylizedMaterial(),
        );
        // The cube only casts: the catcher alone is seen.
        final frame = await renderWithShadows(
          lights: [_hemisphere(), ...lights()],
          draw: (context) {
            context.drawSurface(ground);
            if (context.isShadowPass) {
              context.drawMesh(
                cube,
                transform: Matrix4.translation(_cubeCenter),
              );
            }
          },
        );
        // Half-opaque black where the ground is in shadow, nothing where it
        // is lit.
        expect(_at(frame, 0.5, 0).$4, closeTo(128, 4));
        expect(_at(frame, 0.3, 0.1).$4, closeTo(128, 4));
        expect(_at(frame, 0.5, 0.5).$4, 0);
        expect(_at(frame, -0.5, 0).$4, 0);
        expect(_at(frame, 0.9, 0).$4, 0);
        final edges = _edges(frame, 0.05, 64, channel: 3);
        expect(edges, hasLength(2));
        expect(edges[0], closeTo(0.2, 0.05));
        expect(edges[1], closeTo(0.8, 0.05));
      });
    }
  });

  // A spot or point light at (-0.6, 0, -1), towards which the cube casts its
  // shadow on the ground from x 0.2 to about 0.54; a sun with shadows from
  // the other side (shadowing x -0.8 to -0.2) puts the frame on the atlas.
  final lamp = Vector3(-0.6, 0, -1);
  Light sunFromTheRight() => Light(
    position: Vector3.zero(),
    source: DirectionalLight(
      direction: Vector3(-0.5, 0, -1),
      intensity: 0.3,
      shadows: ShadowSettings(),
    ),
  );
  Light spot({required bool shadows}) => Light(
    position: lamp,
    source: SpotLight(
      direction: Vector3(1, 0, -4),
      range: 10,
      innerConeAngle: 0.5,
      outerConeAngle: 0.7,
      shadows: shadows ? ShadowSettings(resolution: 512) : null,
    ),
  );
  Light point({required bool shadows}) => Light(
    position: lamp,
    source: PointLight(
      color: const Color(0xFFFFFFFF),
      intensity: 1,
      range: 10,
      shadows: shadows ? ShadowSettings(resolution: 512) : null,
    ),
  );

  for (final (name, lamp) in [('spot', spot), ('point', point)]) {
    testGpuEngine(
      'StylizedMaterial receives $name shadows from the atlas',
      () async {
        final material = StylizedMaterial();
        final ground = _ground(material);
        final cube = CuboidMesh(size: Vector3.all(0.4), material: material);
        void draw(RenderContext3D context) => context
          ..drawSurface(ground)
          ..drawMesh(cube, transform: Matrix4.translation(_cubeCenter));

        final shadowed = await renderWithShadows(
          lights: [_hemisphere(), sunFromTheRight(), lamp(shadows: true)],
          draw: draw,
        );
        final unshadowed = await renderWithShadows(
          lights: [_hemisphere(), sunFromTheRight(), lamp(shadows: false)],
          draw: draw,
        );
        // The lamp's shadow.
        expect(
          _at(unshadowed, 0.35, 0).$1 - _at(shadowed, 0.35, 0).$1,
          greaterThan(30),
        );
        // Lit by the lamp in both.
        expect(
          _at(shadowed, 0.75, 0).$1,
          closeTo(_at(unshadowed, 0.75, 0).$1, 2),
        );
        expect(
          _at(shadowed, 0.35, 0.6).$1,
          closeTo(_at(unshadowed, 0.35, 0.6).$1, 2),
        );
        // The sun's shadow in both.
        expect(
          _at(shadowed, -0.5, 0).$1,
          closeTo(_at(unshadowed, -0.5, 0).$1, 2),
        );
        expect(
          _at(shadowed, -0.5, 0).$1,
          lessThan(_at(shadowed, -0.5, 0.6).$1 - 20),
        );
      },
    );

    testGpuEngine(
      'ShadowCatcherMaterial shows $name shadows from the atlas',
      () async {
        final ground = _ground(ShadowCatcherMaterial());
        final cube = CuboidMesh(
          size: Vector3.all(0.4),
          material: StylizedMaterial(),
        );
        final frame = await renderWithShadows(
          lights: [_hemisphere(), sunFromTheRight(), lamp(shadows: true)],
          draw: (context) {
            context.drawSurface(ground);
            if (context.isShadowPass) {
              context.drawMesh(
                cube,
                transform: Matrix4.translation(_cubeCenter),
              );
            }
          },
        );
        expect(_at(frame, 0.35, 0).$4, closeTo(128, 4));
        expect(_at(frame, -0.5, 0).$4, closeTo(128, 4));
        expect(_at(frame, 0.75, 0).$4, 0);
        expect(_at(frame, 0, 0.6).$4, 0);
      },
    );
  }

  group('Cascades seen in perspective', () {
    // A ground of 12 by 12 units at z = 0 with cubes on it, seen from above
    // and behind by a perspective camera: every cascade setting shadows the
    // same pixels as one map.
    Surface ground(Material material) {
      final stride = VertexLayout.standard.strideInFloats;
      final vertices = Float32List(4 * stride);
      const corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)];
      for (final (i, (x, y)) in corners.indexed) {
        vertices
          ..setRange(i * stride, i * stride + 3, [x * 6.0, y * 6.0, 0])
          ..setRange(i * stride + 5, i * stride + 9, [1, 1, 1, 1])
          ..setRange(i * stride + 9, i * stride + 12, [0, 0, 1]);
      }
      return Surface.fromBuffers(
        vertices: vertices,
        indices: Uint16List.fromList([0, 1, 2, 2, 3, 0]),
        material: material,
      );
    }

    final cubes = [
      Vector3(0, 0, 0.5),
      Vector3(-3, 3, 0.5),
      Vector3(3, -2, 0.5),
      Vector3(-2, -4, 0.5),
    ];

    Future<Frame> render(
      ShadowSettings settings, {
      RenderContext3D? context,
    }) {
      final material = StylizedMaterial();
      final floor = ground(material);
      final cube = CuboidMesh(size: Vector3.all(1), material: material);
      return renderWithShadows(
        lights: [
          _hemisphere(),
          Light(
            position: Vector3.zero(),
            source: DirectionalLight(
              direction: Vector3(0.4, 0.6, -1),
              intensity: 0.5,
              shadows: settings,
            ),
          ),
        ],
        context: context,
        sceneBounds: Aabb3.minMax(Vector3(-6, -6, 0), Vector3(6, 6, 1)),
        view: Matrix4.identity()
          ..setAsViewMatrix(
            Vector3(0, -5, 4),
            Vector3(0, 0, 0),
            Vector3(0, 0, 1),
          ),
        projection: Matrix4.identity()..setAsPerspective(60, 1, 0.5, 40),
        draw: (context) {
          context.drawSurface(floor);
          for (final center in cubes) {
            context.drawMesh(cube, transform: Matrix4.translation(center));
          }
        },
      );
    }

    late Frame single;
    setUp(() async {
      if (gpuAvailable) {
        single = await render(ShadowSettings(resolution: 512));
      }
    });

    for (final cascades in [2, 3, 4]) {
      testGpuEngine('with $cascades cascades', () async {
        final context = RenderContext3D(GraphicsDevice());
        final frame = await render(
          ShadowSettings(resolution: 512, cascades: cascades),
          context: context,
        );
        // The cascades kept (those that see a part of the view the next
        // one covers less sharply) are sharper than the next.
        final tiles = context.shadowAtlas.tiles;
        expect(tiles.length, inInclusiveRange(2, cascades));
        for (var c = 1; c < tiles.length; c++) {
          expect(
            tiles[c - 1].texelWorldSize,
            lessThan(tiles[c].texelWorldSize),
          );
        }
        var shadowed = 0;
        var differing = 0;
        for (var y = 0; y < _size; y++) {
          for (var x = 0; x < _size; x++) {
            final a = single.pixels.at(x, y).$1;
            final b = frame.pixels.at(x, y).$1;
            if (a < 150) {
              shadowed++;
            }
            if ((a - b).abs() > 40) {
              differing++;
            }
          }
        }
        expect(shadowed, greaterThan(400));
        // Only along the edges of the shadows, sharper with cascades.
        expect(differing, lessThan(math.max(20, shadowed ~/ 15)));
      });
    }
  });
}
