import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect, Size;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

final bool _gpuAvailable = GpuBackend.isAvailable;

void _setUpGpu() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_gpuAvailable) {
      await GpuBackend.initialize();
    }
  });
}

@isTest
void _testGpuEngine(String description, Future<void> Function() body) {
  test(
    description,
    body,
    skip: _gpuAvailable
        ? false
        : 'Flutter GPU unavailable; run with '
              '--enable-impeller --enable-flutter-gpu',
  );
}

CameraComponent3D _makeCamera({
  required Vector3 position,
  required Vector3 target,
  double fovY = 60,
  double near = 0.5,
  double far = 300,
}) {
  return CameraComponent3D(
    position: position,
    target: target,
    fovY: fovY,
    near: near,
    far: far,
    viewport: FixedResolutionViewport(resolution: Vector2(256, 128)),
  );
}

/// Builds a 3-step 90-degree staircase mesh with horizontal `+Y` treads,
/// vertical `+Z` risers, and a back-facing `-Z` rear wall.
Mesh _buildStaircaseMesh(Material material) {
  final vertices = <Vertex>[];
  final indices = <int>[];

  void addQuad(
    Vector3 a,
    Vector3 b,
    Vector3 c,
    Vector3 d,
    Vector3 normal,
  ) {
    final base = vertices.length;
    vertices.addAll([
      Vertex(position: a, texCoord: Vector2(0, 1), normal: normal),
      Vertex(position: b, texCoord: Vector2(1, 1), normal: normal),
      Vertex(position: c, texCoord: Vector2(1, 0), normal: normal),
      Vertex(position: d, texCoord: Vector2(0, 0), normal: normal),
    ]);
    indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
  }

  // Three steps climbing +Y while stepping toward -Z:
  // Each step has a vertical riser facing +Z and a horizontal tread facing +Y.
  for (var step = 0; step < 3; step++) {
    final y0 = step * 1.0;
    final y1 = (step + 1) * 1.0;
    final zFront = -step * 1.0;
    final zBack = -(step + 1) * 1.0;

    // Vertical riser facing +Z (CCW seen from +Z).
    addQuad(
      Vector3(-2, y0, zFront),
      Vector3(2, y0, zFront),
      Vector3(2, y1, zFront),
      Vector3(-2, y1, zFront),
      Vector3(0, 0, 1),
    );

    // Horizontal tread facing +Y (CCW seen from +Y).
    addQuad(
      Vector3(-2, y1, zFront),
      Vector3(2, y1, zFront),
      Vector3(2, y1, zBack),
      Vector3(-2, y1, zBack),
      Vector3(0, 1, 0),
    );
  }

  // Rear vertical wall facing -Z (away from decal projector -> must be
  // rejected by normalAngleFadeCos!).
  addQuad(
    Vector3(2, 0, -1.5),
    Vector3(-2, 0, -1.5),
    Vector3(-2, 3, -1.5),
    Vector3(2, 3, -1.5),
    Vector3(0, 0, -1),
  );

  return Mesh()..addSurface(
    Surface(vertices: vertices, indices: indices, material: material),
  );
}

void main() {
  _setUpGpu();

  group('ChunkedTerrain3D (Quadtree CDLOD, Skirts & 4-Biome Splatting)', () {
    test('selects step 1..8 LOD chunks and seals T-junction skirts', () {
      final terrain = ChunkedTerrain3D.procedural(
        worldWidth: 160.0,
        worldDepth: 160.0,
        maxHeight: 20.0,
        lodSplitFactor: 1.25,
      );

      // Camera near the south-west corner looking diagonally north-east across
      // the full 160m x 160m heightfield.
      final camera = _makeCamera(
        position: Vector3(-72, 12, -72),
        target: Vector3(60, 4, 60),
        far: 400,
      );

      final allChunks = terrain.selectVisibleChunks(
        cameraPosition: camera.position,
      );
      final stepsSeen = <int>{for (final c in allChunks) c.step};
      // Nearby chunks refine to full resolution (`step = 1`), mid/far chunks
      // coarsen through `step = 2, 4, 8`!
      expect(stepsSeen.contains(1), isTrue);
      expect(stepsSeen.contains(2), isTrue);
      expect(stepsSeen.contains(4), isTrue);
      expect(stepsSeen.contains(8), isTrue);

      // Frustum culling looking narrowly away from the terrain center culls
      // off-frustum chunks.
      final narrowAwayCam = _makeCamera(
        position: Vector3(-72, 12, -72),
        target: Vector3(-120, 12, -120),
        fovY: 45,
      );
      final culledChunks = terrain.selectVisibleChunks(
        cameraPosition: narrowAwayCam.position,
        frustum: narrowAwayCam.frustum,
      );
      expect(culledChunks.length, lessThan(allChunks.length));

      // Verify every chunk has crack-sealing perimeter skirts AND verify that
      // at any T-junction border between adjacent chunks of different LODs, the
      // vertical skirt spans overlap with 0 vertical crack!
      for (final chunk in allChunks) {
        expect(chunk.skirtVertexCount, greaterThan(0));
        expect(chunk.skirtTriangleCount, greaterThan(0));

        // Verify bottom skirt vertices sit exactly `skirtDepth` below top
        // perimeter vertices.
        final vData = chunk.surface.vertexData;
        final minSurfaceY = chunk.surface.aabb.min.y;
        expect(
          minSurfaceY,
          lessThanOrEqualTo(
            chunk.localBounds.max.y - terrain.skirtDepth + 1e-3,
          ),
        );
        expect(
          vData.length,
          (chunk.topVertexCount + chunk.skirtVertexCount) * 20,
        );
      }

      // Find an adjacent pair `(fine, coarse)` sharing a column boundary where
      // `fine.step < coarse.step`, and verify zero vertical gap at midpoint!
      var verifiedBorderPair = false;
      for (final fine in allChunks) {
        for (final coarse in allChunks) {
          if (fine.step < coarse.step &&
              fine.colEnd == coarse.colStart &&
              fine.rowStart >= coarse.rowStart &&
              fine.rowEnd <= coarse.rowEnd) {
            final borderCol = fine.colEnd;
            for (var r = fine.rowStart; r <= fine.rowEnd; r += fine.step) {
              final r0 =
                  coarse.rowStart +
                  ((r - coarse.rowStart) ~/ coarse.step) * coarse.step;
              final r1 = math.min(coarse.rowEnd, r0 + coarse.step);
              final t = r1 > r0 ? (r - r0) / (r1 - r0) : 0.0;

              final hFine =
                  terrain.heights[r * terrain.gridColumns + borderCol];
              final hCoarse0 =
                  terrain.heights[r0 * terrain.gridColumns + borderCol];
              final hCoarse1 =
                  terrain.heights[r1 * terrain.gridColumns + borderCol];
              final hCoarseEdge = hCoarse0 + (hCoarse1 - hCoarse0) * t;

              // Fine vertical curtain `[hFine - skirtDepth, hFine]` and coarse
              // vertical curtain `[hCoarseEdge - skirtDepth, hCoarseEdge]` MUST
              // overlap (`(hFine - hCoarseEdge).abs() <= terrain.skirtDepth`)!
              expect(
                (hFine - hCoarseEdge).abs(),
                lessThanOrEqualTo(terrain.skirtDepth),
              );
            }
            verifiedBorderPair = true;
            break;
          }
        }
        if (verifiedBorderPair) {
          break;
        }
      }
      expect(verifiedBorderPair, isTrue);
    });

    test(
      'bakes 4-biome splat weights and samples height/normal accurately',
      () {
        // Custom 17x17 ramp with low sand flat, mid grass gentle slope, steep
        // cliff, and high snow plateau.
        const cols = 17;
        const rows = 17;
        final heights = Float32List(cols * rows);
        for (var r = 0; r < rows; r++) {
          for (var c = 0; c < cols; c++) {
            double h;
            if (c < 4) {
              h = 1.0; // Low flat sand (`hNorm = 0.05`).
            } else if (c < 9) {
              h = 8.0; // Mid flat grass (`hNorm = 0.4`).
            } else if (c < 12) {
              h = 8.0 + (c - 8) * 3.8; // Steep cliff -> rock!
            } else {
              h = 19.5; // High flat snow (`hNorm = 0.975`).
            }
            heights[r * cols + c] = h;
          }
        }

        final terrain = ChunkedTerrain3D(
          heights: heights,
          gridColumns: cols,
          gridRows: rows,
          worldWidth: 32.0,
          worldDepth: 32.0,
          maxHeight: 20.0,
        );

        final sandW = terrain.sampleBiomeWeights(-14, 0);
        final grassW = terrain.sampleBiomeWeights(-4, 0);
        final rockW = terrain.sampleBiomeWeights(4, 0);
        final snowW = terrain.sampleBiomeWeights(14, 0);

        expect(sandW.sand, greaterThan(0.7));
        expect(grassW.grass, greaterThan(0.6));
        expect(rockW.rock, greaterThan(0.6));
        expect(snowW.snow, greaterThan(0.7));

        // Verify raycast hits the terrain at the exact sampled height.
        final expectedY = terrain.sampleHeight(-4, 2);
        final hit = terrain.raycast(
          Ray.originDirection(Vector3(-4, 40, 2), Vector3(0, -1, 0)),
        );
        expect(hit, isNotNull);
        expect(hit!.worldPoint.y, closeTo(expectedY, 1e-2));
      },
    );

    _testGpuEngine(
      'renders visible CDLOD terrain chunks with 4-biome vertex splatting',
      () async {
        final terrain = ChunkedTerrain3D.procedural(
          gridColumns: 65,
          gridRows: 65,
          worldWidth: 80.0,
          worldDepth: 80.0,
          maxHeight: 12.0,
          material: UnlitMaterial()..renderState = RenderState.opaque,
        );
        final world = World3D(children: [terrain]);
        final camera = _makeCamera(
          position: Vector3(-30, 18, -30),
          target: Vector3(20, 2, 20),
        );
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        device.begin();
        final image = world.renderToImage(
          const Size(128, 128),
          view: camera.viewMatrix,
          projection: camera.projectionMatrix,
          device: device,
          context: context,
        );
        device.end();
        addTearDown(image.dispose);

        expect(terrain.lastDrawnChunkCount, greaterThan(2));
        expect(
          device.lastFrameStats.drawCalls,
          terrain.lastDrawnChunkCount,
        );
      },
    );
  });

  group('FoliageSystem3D (10,000 Blades, Cell Culling & Player Trample)', () {
    test(
      'scatters 10,000 blades, culls cells, and bends/recovers on trample',
      () {
        final terrain = ChunkedTerrain3D.procedural(
          gridColumns: 65,
          gridRows: 65,
          worldWidth: 120.0,
          worldDepth: 120.0,
          maxHeight: 6.0,
        );

        final playerSphere = FoliageInteractor3D(
          position: Vector3(0, terrain.sampleHeight(0, 0), 0),
          radius: 3.5,
        );

        final foliage = FoliageSystem3D(
          capacity: 16384,
          cellSize: 15.0,
          maxDrawDistance: 75.0,
          interactors: [playerSphere],
        );

        final placed = foliage.scatterOnTerrain(
          terrain,
          count: 10000,
          minSlopeCos: 0.5,
          seed: 42,
        );
        expect(placed, 10000);
        expect(foliage.bladeCount, 10000);
        expect(foliage.cellCount, greaterThan(16));

        // Narrow camera looking at one corner culls non-visible cells & distant
        // blades!
        final cornerCam = _makeCamera(
          position: Vector3(-50, 8, -50),
          target: Vector3(-58, 2, -58),
          fovY: 45,
          far: 80,
        );
        final visibleCornerCount = foliage.buildVisibleInstances(
          cameraPosition: cornerCam.position,
          frustum: cornerCam.frustum,
        );
        expect(visibleCornerCount, greaterThan(0));
        expect(visibleCornerCount, lessThan(2500));
        expect(foliage.lastVisibleCellCount, lessThan(foliage.cellCount));

        // Step simulation so `playerSphere` at (0, h, 0) tramples nearby grass!
        for (var step = 0; step < 6; step++) {
          foliage.update(0.05);
        }

        var trampledCount = 0;
        var untouchedFarCount = 0;
        final bladePos = Vector3.zero();
        final bendVec = Vector2.zero();

        for (var i = 0; i < foliage.bladeCount; i++) {
          foliage.bladePosition(i, out: bladePos);
          final dx = bladePos.x - playerSphere.position.x;
          final dz = bladePos.z - playerSphere.position.z;
          final horizDist = math.sqrt(dx * dx + dz * dz);

          if (horizDist > 0.1 && horizDist < 2.8) {
            trampledCount++;
            expect(foliage.bladeCrush(i), greaterThan(0.05));
            foliage.bladeBendVector(i, out: bendVec);
            // Blade MUST bend radially AWAY from the player sphere (`dot > 0`)!
            expect(bendVec.x * dx + bendVec.y * dz, greaterThan(0));
          } else if (horizDist > 10.0) {
            untouchedFarCount++;
            expect(foliage.bladeCrush(i), 0);
          }
        }
        expect(trampledCount, greaterThan(10));
        expect(untouchedFarCount, greaterThan(5000));

        // Move player far away and verify smooth spring recovery back upright!
        playerSphere.position.setValues(500, 0, 500);
        for (var step = 0; step < 40; step++) {
          foliage.update(0.05);
        }
        var maxResidualCrush = 0.0;
        for (var i = 0; i < foliage.bladeCount; i++) {
          maxResidualCrush = math.max(maxResidualCrush, foliage.bladeCrush(i));
        }
        expect(maxResidualCrush, lessThan(0.02));
      },
    );

    _testGpuEngine(
      'renders 10,000 scattered foliage instances in 1 GPU draw call',
      () async {
        final terrain = ChunkedTerrain3D.procedural(
          gridColumns: 33,
          gridRows: 33,
          worldWidth: 40.0,
          worldDepth: 40.0,
          maxHeight: 2.0,
        );
        final foliage = FoliageSystem3D(
          capacity: 12000,
          maxDrawDistance: 120.0,
          fadeStartFraction: 0.95,
          material: UnlitMaterial(albedoColor: const Color(0xFF60C848))
            ..renderState = RenderState.opaque,
        )..scatterOnTerrain(terrain, count: 10000, minSlopeCos: 0.2);

        final world = World3D(children: [foliage]);
        final camera = _makeCamera(
          position: Vector3(0, 35, 35),
          target: Vector3.zero(),
          fovY: 75,
        );
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        device.begin();
        final image = world.renderToImage(
          const Size(128, 128),
          view: camera.viewMatrix,
          projection: camera.projectionMatrix,
          device: device,
          context: context,
        );
        device.end();
        addTearDown(image.dispose);

        expect(foliage.lastVisibleInstanceCount, greaterThan(8000));
        expect(device.lastFrameStats.drawCalls, 1);
      },
    );
  });

  group('VolumeDecalBatch3D (Stairs, Walls & Terrain Projection)', () {
    test('projects decals across 90-degree stairs while culling back', () {
      final wallMat = SpatialMaterial();
      final stairsMesh = _buildStaircaseMesh(wallMat);

      // Tilt the decal box 45 degrees downward-and-forward (`receiveNormal =
      // (0, +0.7071, +0.7071)`) so BOTH horizontal `+Y` stair treads AND
      // vertical `+Z` stair risers receive conformal decal triangles, while the
      // `-Z` back wall (`cos = -0.7071`) is completely culled!
      final tilt45 = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 4);
      final stairDecal = ProjectedDecalBox3D(
        center: Vector3(0, 1.2, -0.8),
        halfExtents: Vector3(0.9, 2.2, 1.8),
        rotation: tilt45,
        uvRect: const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5),
        color: const Color(0xFFFF5030),
        normalAngleFadeCos: 0.2,
      );

      final secondDecal = ProjectedDecalBox3D(
        center: Vector3(0.6, 2.2, -1.8),
        halfExtents: Vector3(0.7, 1.8, 1.4),
        rotation: tilt45,
        color: const Color(0xFF30D0FF),
        normalAngleFadeCos: 0.2,
      );

      final batch = VolumeDecalBatch3D(normalOffset: 0.005)
        ..projectOntoSurfaces(
          [stairDecal, secondDecal],
          VolumeDecalTarget3D.fromMesh(stairsMesh),
        );

      expect(batch.projectedDecalCount, 2);
      expect(batch.mergedSurface, isNotNull);
      expect(batch.generatedTriangleCount, greaterThanOrEqualTo(6));

      final verts = batch.mergedSurface!.vertexData;
      const stride = 20;
      var hasHorizontalTreadVerts = false;
      var hasVerticalRiserVerts = false;

      for (var v = 0; v < batch.generatedVertexCount; v++) {
        final o = v * stride;
        final x = verts[o];
        final u = verts[o + 3];
        final w = verts[o + 4];
        final alpha = verts[o + 8];
        final nx = verts[o + 9];
        final ny = verts[o + 10];
        final nz = verts[o + 11];

        // Clipped strictly to the decal X half-extents (`[-0.9..1.3]`).
        expect(x, greaterThanOrEqualTo(-0.91));
        expect(x, lessThanOrEqualTo(1.31));
        expect(u, inInclusiveRange(0.0, 1.0));
        expect(w, inInclusiveRange(0.0, 1.0));
        expect(alpha, greaterThan(0));

        // Zero back-facing (`nz < -0.5`) triangles may survive!
        expect(nz, greaterThan(-0.1));
        expect(nx.abs(), lessThan(1e-4));

        if (ny > 0.9) {
          hasHorizontalTreadVerts = true;
        }
        if (nz > 0.9) {
          hasVerticalRiserVerts = true;
        }
      }

      // Conformed across BOTH faces of the 90-degree staircase!
      expect(hasHorizontalTreadVerts, isTrue);
      expect(hasVerticalRiserVerts, isTrue);
    });

    _testGpuEngine(
      'projects decals onto stairs + curved terrain in 1 GPU draw call',
      () async {
        final terrain = ChunkedTerrain3D.procedural(
          gridColumns: 33,
          gridRows: 33,
          worldWidth: 24.0,
          worldDepth: 24.0,
          maxHeight: 3.0,
        );
        final stairs = _buildStaircaseMesh(
          UnlitMaterial(albedoColor: const Color(0xFF505868))
            ..renderState = RenderState.opaque,
        );

        final decalBatch =
            VolumeDecalBatch3D(
                material: UnlitMaterial(albedoColor: const Color(0xFFFFD030))
                  ..renderState = RenderState.alphaBlend
                  ..castsShadows = false,
              )
              ..projectOntoSurfaces(
                [
                  ProjectedDecalBox3D(
                    center: Vector3(0, 1.2, -0.8),
                    halfExtents: Vector3(1.0, 2.0, 1.6),
                    rotation: Quaternion.axisAngle(
                      Vector3(1, 0, 0),
                      math.pi / 4,
                    ),
                  ),
                ],
                VolumeDecalTarget3D.fromMesh(stairs),
              )
              ..projectOntoTerrain(
                [
                  ProjectedDecalBox3D(
                    center: Vector3(3, terrain.sampleHeight(3, -3), -3),
                    halfExtents: Vector3(2.0, 3.0, 2.0),
                  ),
                ],
                terrain,
                append: true,
              );

        expect(decalBatch.projectedDecalCount, 2);
        expect(decalBatch.generatedTriangleCount, greaterThan(10));

        final world = World3D(children: [decalBatch]);
        final camera = _makeCamera(
          position: Vector3(0, 8, 8),
          target: Vector3(1, 1, -2),
        );
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        device.begin();
        final image = world.renderToImage(
          const Size(128, 128),
          view: camera.viewMatrix,
          projection: camera.projectionMatrix,
          device: device,
          context: context,
        );
        device.end();
        addTearDown(image.dispose);

        // Both stair + terrain volume decals draw together in 1 draw call!
        expect(device.lastFrameStats.drawCalls, 1);
      },
    );
  });
}
