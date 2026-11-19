import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show makePerspectiveMatrix, makeViewMatrix;

import '../gpu/gpu_test_helpers.dart';

/// A sun travelling along (0.4, -1, 0.3) that casts shadows.
List<Light> _sun() {
  return [
    Light(
      position: Vector3.zero(),
      source: DirectionalLight(
        direction: Vector3(0.4, -1, 0.3),
        intensity: 0.8,
        shadows: ShadowSettings(),
      ),
    ),
  ];
}

/// Records [draw] in a shadow pass of the sun and then in the main pass of a
/// perspective camera at [eye] looking at [target]; [inShadowPass] runs right
/// after the shadow pass draw, [inMainPass] right after the main pass draw.
Future<void> _renderBothPasses({
  required Vector3 eye,
  required Vector3 target,
  required Aabb3 sceneBounds,
  required void Function(RenderContext3D context) draw,
  required void Function(RenderContext3D context) inShadowPass,
  required void Function(RenderContext3D context) inMainPass,
}) async {
  final device = GraphicsDevice();
  final context = RenderContext3D(device);
  final view = makeViewMatrix(eye, target, Vector3(0, 1, 0));
  final projection = makePerspectiveMatrix(math.pi / 3, 1, 0.5, 600);
  device.begin();
  context
    ..lights = _sun()
    ..setCamera(view, projection);
  final began = context.beginShadowPass(
    projection: DirectionalShadowProjection(),
    sceneBounds: sceneBounds,
  );
  expect(began, isTrue);
  expect(context.isShadowPass, isTrue);
  draw(context);
  inShadowPass(context);
  context.endShadowPass();
  device.beginPass(const Size(64, 64), frontFace: context.frontFace);
  draw(context);
  inMainPass(context);
  context.flush();
  final image = device.endPass();
  device.end();
  image.dispose();
}

/// A mesh of [count] separate unit cubes side by side, each its own surface.
Mesh _cubes(int count) {
  final material = SpatialMaterial();
  final mesh = Mesh();
  for (var i = 0; i < count; i++) {
    final cube = CuboidMesh(size: Vector3.all(0.5), material: material);
    final surface = cube.surfaces.single;
    final stride = surface.layout.strideInFloats;
    final vertices = Float32List.fromList(surface.vertexData);
    for (var v = 0; v < surface.vertexCount; v++) {
      vertices[v * stride] += i * 0.6;
    }
    mesh.addSurface(
      Surface.fromBuffers(
        vertices: vertices,
        indices: surface.indices,
        layout: surface.layout,
        material: material,
      ),
    );
  }
  return mesh;
}

void main() {
  setUpGpu();

  group('shadow passes choose detail from the main camera', () {
    testGpuEngine('RenderContext3D.viewerPosition stays the main camera '
        'while a shadow pass records', () async {
      final eye = Vector3(1000, 30, 1080);
      await _renderBothPasses(
        eye: eye,
        target: Vector3(1000, 0, 1000),
        sceneBounds: Aabb3.minMax(
          Vector3(900, -1, 900),
          Vector3(1100, 20, 1100),
        ),
        draw: (_) {},
        inShadowPass: (context) {
          // The light's view is centered on the world origin.
          expect(context.cameraPosition.distanceTo(eye), greaterThan(100));
          expect(context.viewerPosition.distanceTo(eye), lessThan(1e-3));
        },
        inMainPass: (context) {
          expect(context.cameraPosition.distanceTo(eye), lessThan(1e-3));
          expect(context.viewerPosition.distanceTo(eye), lessThan(1e-3));
        },
      );
    });

    testGpuEngine('ChunkedTerrain3D far from the origin casts from the '
        'chunks the camera selects, not from its coarsest chunk', () async {
      final terrain = ChunkedTerrain3D.procedural(
        gridColumns: 65,
        gridRows: 65,
        position: Vector3(1000, 0, 1000),
      );
      final eye = Vector3(1000, 25, 1050);
      var shadowChunks = -1;
      var expectedShadowChunks = -1;
      var mainChunks = -1;
      await _renderBothPasses(
        eye: eye,
        target: Vector3(1000, 0, 1000),
        sceneBounds: Aabb3.copy(terrain.aabb),
        draw: terrain.draw,
        inShadowPass: (context) {
          shadowChunks = terrain.lastDrawnChunkCount;
          expectedShadowChunks = terrain
              .selectVisibleChunks(
                cameraPosition: eye,
                frustum: context.frustum,
              )
              .length;
        },
        inMainPass: (_) => mainChunks = terrain.lastDrawnChunkCount,
      );
      expect(mainChunks, greaterThan(4));
      expect(shadowChunks, greaterThan(4));
      expect(shadowChunks, expectedShadowChunks);
      terrain.onRemove();
    });

    testGpuEngine('LodMeshComponent casts from the level the current camera '
        'selects', () async {
      final lod = LodMeshComponent(
        levels: [
          MeshLodLevel(mesh: _cubes(3), maxDistance: 20),
          MeshLodLevel(mesh: _cubes(1)),
        ],
        position: Vector3(1000, 0, 1000),
      );
      final bounds = Aabb3.minMax(
        Vector3(990, -5, 990),
        Vector3(1010, 5, 1010),
      );
      final target = Vector3(1000, 0, 1000);
      final device = GraphicsDevice();
      final context = RenderContext3D(device);
      final projection = makePerspectiveMatrix(math.pi / 3, 1, 0.5, 600);

      int shadowDrawsSeenFrom(Vector3 eye) {
        device.begin();
        context
          ..lights = _sun()
          ..setCamera(
            makeViewMatrix(eye, target, Vector3(0, 1, 0)),
            projection,
          );
        expect(
          context.beginShadowPass(
            projection: DirectionalShadowProjection(),
            sceneBounds: bounds,
          ),
          isTrue,
        );
        lod.draw(context);
        context.endShadowPass();
        device.beginPass(const Size(64, 64), frontFace: context.frontFace);
        lod.draw(context);
        context.flush();
        device.endPass().dispose();
        device.end();
        return device.lastFrameStats.shadowDrawCalls;
      }

      // Far away: the coarse level, one cube.
      expect(shadowDrawsSeenFrom(Vector3(1000, 50, 1100)), 1);
      // The camera came close: the detailed level casts in this very frame.
      expect(shadowDrawsSeenFrom(Vector3(1000, 3, 1006)), 3);
    });

    testGpuEngine('FoliageSystem3D far from the origin casts the blades near '
        'the camera', () async {
      final foliage = FoliageSystem3D(
        capacity: 400,
        maxDrawDistance: 100,
        castsShadows: true,
      );
      final rng = math.Random(7);
      for (var i = 0; i < 400; i++) {
        foliage.addBlade(
          position: Vector3(
            1000 + rng.nextDouble() * 40 - 20,
            0,
            1000 + rng.nextDouble() * 40 - 20,
          ),
          densityRank: 0,
        );
      }
      var shadowBlades = -1;
      var mainBlades = -1;
      await _renderBothPasses(
        eye: Vector3(1000, 10, 1030),
        target: Vector3(1000, 0, 1000),
        sceneBounds: Aabb3.minMax(
          Vector3(970, -1, 970),
          Vector3(1030, 5, 1030),
        ),
        draw: foliage.draw,
        inShadowPass: (_) => shadowBlades = foliage.lastVisibleInstanceCount,
        inMainPass: (_) => mainBlades = foliage.lastVisibleInstanceCount,
      );
      expect(mainBlades, greaterThan(0));
      // Every blade lies within the draw distance of the camera and inside
      // the light's view, so all of them cast.
      expect(shadowBlades, 400);
      foliage.onRemove();
    });
  });
}
