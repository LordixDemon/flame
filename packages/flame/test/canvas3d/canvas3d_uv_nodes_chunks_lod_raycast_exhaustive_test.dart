import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/canvas3d.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _checkerTextureSync(int size) {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final half = size / 2.0;
  c.drawRect(
    Rect.fromLTWH(0, 0, half, half),
    Paint()..color = const Color(0xFFFF5252),
  );
  c.drawRect(
    Rect.fromLTWH(half, 0, half, half),
    Paint()..color = const Color(0xFF448AFF),
  );
  c.drawRect(
    Rect.fromLTWH(0, half, half, half),
    Paint()..color = const Color(0xFF69F0AE),
  );
  c.drawRect(
    Rect.fromLTWH(half, half, half, half),
    Paint()..color = const Color(0xFFFFD740),
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(size, size);
  } finally {
    pic.dispose();
  }
}

void main() {
  group('Mesh3D generators, Raycaster3D & Node3D/Decal3D scene graph', () {
    test(
      'all Mesh3D procedural primitives have valid normals, bounds & ray hits',
      () {
        final primitives = <Mesh3D>[
          Mesh3D.plane(sizeX: 2, sizeY: 3),
          Mesh3D.box(sizeX: 1.5, sizeY: 1.2, sizeZ: 2.0),
          Mesh3D.pyramid(includeBase: false),
          Mesh3D.pyramid(),
          Mesh3D.octahedron(),
          Mesh3D.prism(sides: 8, topRadius: 0.3),
          Mesh3D.prism(sides: 8, smoothSides: true),
          Mesh3D.uvSphere(segments: 12, rings: 8),
          Mesh3D.fromRaw(
            positions: Float32List.fromList(<double>[
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              1,
              0,
            ]),
            indices: Uint16List.fromList(<int>[0, 1, 2]),
          ),
        ];

        for (final m in primitives) {
          expect(m.vertexCount, greaterThan(0));
          expect(m.triangleCount, greaterThan(0));
          expect(m.boundingRadius, greaterThan(0));
          for (var i = 0; i < m.normals.length; i += 3) {
            final len = math.sqrt(
              m.normals[i] * m.normals[i] +
                  m.normals[i + 1] * m.normals[i + 1] +
                  m.normals[i + 2] * m.normals[i + 2],
            );
            expect(len, closeTo(1.0, 1e-4));
          }
        }

        // Raycaster3D rotated/scaled collider picking and backface culling.
        final box = Mesh3D.box();
        final nearCol = MeshCollider3D(
          id: 10,
          positions: box.positions,
          indices: box.indices,
          minX: box.minX,
          minY: box.minY,
          minZ: box.minZ,
          maxX: box.maxX,
          maxY: box.maxY,
          maxZ: box.maxZ,
          worldX: 0,
          worldY: 0,
          yawRad: 0.4,
          scale: 2.0,
        );
        final farCol = MeshCollider3D(
          id: 20,
          positions: box.positions,
          indices: box.indices,
          minX: box.minX,
          minY: box.minY,
          minZ: box.minZ,
          maxX: box.maxX,
          maxY: box.maxY,
          maxZ: box.maxZ,
          worldX: 0,
          worldY: 0,
          worldZ: -5.0,
        );
        const topDownRay = Ray3D(ox: 0, oy: 0, oz: 10, dx: 0, dy: 0, dz: -1);
        final picked = Raycaster3D.pickClosest(
          topDownRay,
          <MeshCollider3D>[farCol, nearCol],
        );
        expect(picked, isNotNull);
        expect(picked!.id, 10);
        expect(picked.worldZ, closeTo(1.0, 1e-4)); // top of scale=2 unit box!
      },
    );

    test(
      'Node3D 3-level TRS composition, reparenting, visibility & Decal3D',
      () {
        final root = Node3D(
          name: 'turret_base',
          localX: 10.0,
          localY: 5.0,
          localYawRad: math.pi / 2,
          localScaleX: 2.0,
          localScaleY: 2.0,
          opacity: 0.8,
        );
        final pivot = Node3D(
          name: 'arm_pivot',
          localX: 3.0,
          opacity: 0.5,
        );
        final tip = Node3D(
          name: 'muzzle_tip',
          mesh: Mesh3D.box(sizeX: 0.4, sizeY: 0.4, sizeZ: 0.4),
          localY: 1.0,
        );
        root.addChild(pivot);
        pivot.addChild(tip);
        root.updateWorldTransforms();

        expect(root.findByName('muzzle_tip'), same(tip));
        // Pivot local (3, 0) * root scale 2 = (6, 0) rotated +90 deg -> (0, +6)
        // + root (10, 5) = (10, 11)!
        expect(pivot.worldX, closeTo(10.0, 1e-5));
        expect(pivot.worldY, closeTo(11.0, 1e-5));
        // Tip local (0, 1) * worldScale 2 = (0, 2) rotated +90 deg -> (-2, 0)
        // + pivot (10, 11) = (8, 11)!
        expect(tip.worldX, closeTo(8.0, 1e-5));
        expect(tip.worldY, closeTo(11.0, 1e-5));

        // Reparenting detaches from old parent automatically.
        final otherRoot = Node3D(name: 'other')..addChild(tip);
        expect(pivot.children, isEmpty);
        expect(tip.parent, same(otherRoot));
        pivot.addChild(tip);

        final camera = CameraRig3D();
        final renderer = BatchMeshRenderer3D()..beginBatch();
        pivot.visible = false; // hides entire subtree!
        root.enqueueHierarchy(renderer, camera: camera);
        expect(renderer.activeEnqueuedMeshes, 0);

        pivot.visible = true;
        root.enqueueHierarchy(renderer, camera: camera);
        expect(renderer.activeEnqueuedMeshes, 1);

        final decal = Decal3D(worldX: 0, worldY: 0, opacity: 0.0)
          ..enqueue(renderer, camera: camera);
        expect(renderer.activeEnqueuedMeshes, 1); // opacity 0 skipped!
        decal.opacity = 0.9;
        decal.enqueue(renderer, camera: camera);
        expect(renderer.activeEnqueuedMeshes, 2);
      },
    );
  });

  group('BatchMeshRenderer3D UV/MatCap separation, >65k split, Chunk & LOD', () {
    test(
      'MatCapShader3D and textureShader coexist cleanly on UV Mesh3D.box',
      () {
        final tex = _checkerTextureSync(32);
        final matcap = MatCapShader3D()..ensureInitialized();
        final texShader = ui.ImageShader(
          tex,
          TileMode.clamp,
          TileMode.clamp,
          Float64List.fromList(const <double>[
            1, 0, 0, 0, //
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
          ]),
        );

        try {
          final cam = CameraRig3D();
          final renderer = BatchMeshRenderer3D();
          final uvBox = Mesh3D.box(sizeX: 1.5, sizeY: 1.5, sizeZ: 1.5);

          // Pass 1: flush UV-bearing box with MatCapShader3D (uses spherical
          // normal UVs, NOT mesh.uvs!).
          renderer
            ..beginBatch()
            ..enqueueMesh(
              uvBox,
              camera: cam,
              worldX: 0,
              worldY: 0,
              castGroundShadow: true,
            );
          final rec1 = ui.PictureRecorder();
          renderer.flushBatch(
            ui.Canvas(rec1),
            matCapShader: matcap,
            matCapPreset: MatCapPreset3D.metallicGold,
          );
          rec1.endRecording().dispose();
          expect(renderer.lastFlushTriangles, greaterThan(0));
          expect(renderer.lastFlushShadowTriangles, 12);

          // Pass 2: flush same UV-bearing box with textureShader (both full
          // normalized UV scaled by textureWidth/Height and explicit uvRectPx).
          renderer
            ..beginBatch()
            ..enqueueMesh(uvBox, camera: cam, worldX: -1, worldY: 0)
            ..enqueueMesh(
              uvBox,
              camera: cam,
              worldX: 1,
              worldY: 0,
              uvRectPx: const Rect.fromLTWH(0, 0, 16, 16),
            );
          final rec2 = ui.PictureRecorder();
          renderer.flushBatch(
            ui.Canvas(rec2),
            textureShader: texShader,
            textureWidth: 32,
            textureHeight: 32,
          );
          rec2.endRecording().dispose();
          expect(renderer.lastFlushDrawCalls, 1);
        } finally {
          texShader.dispose();
          matcap.dispose();
          tex.dispose();
        }
      },
    );

    test(
      'exceeding 21,840 triangles splits cleanly into multiple Uint16 chunks',
      () {
        // High-segment sphere: 40 * 30 * 2 = 2,400 tris.
        // Enqueueing 10 spheres yields 24,000 triangles (> 21,840 cap)!
        final denseSphere = Mesh3D.uvSphere(segments: 40, rings: 30);
        final cam = CameraRig3D();
        final renderer = BatchMeshRenderer3D(backfaceCulling: false)
          ..beginBatch();
        for (var i = 0; i < 10; i++) {
          renderer.enqueueMesh(
            denseSphere,
            camera: cam,
            worldX: (i % 5).toDouble(),
            worldY: (i ~/ 5).toDouble(),
          );
        }
        // 10 * 2400 = 24,000 triangles > 21,840 maxTrisPerChunk!
        final rec = ui.PictureRecorder();
        renderer.flushBatch(ui.Canvas(rec));
        rec.endRecording().dispose();

        expect(renderer.lastFlushTriangles, 24000);
        expect(renderer.lastFlushDrawCalls, 2);
      },
    );

    test(
      'StaticMeshChunk3D caching, AABB light signature, LOD & ParticlePool3D',
      () {
        final env = SceneEnvironment3D(
          fogEnabled: true,
          fogStartDepth: 4.0,
          fogEndDepth: 24.0,
          heightFogDensity: 0.35,
        )..addPointLight(x: 0, y: 0, z: 2, radius: 4);

        final chunk = StaticMeshChunk3D()
          ..addInstance(
            StaticMeshInstance3D(
              mesh: Mesh3D.box(),
              worldX: 0,
              worldY: 0,
              castGroundShadow: true,
            ),
          );

        final cam = CameraRig3D();
        final renderer = BatchMeshRenderer3D(environment: env);

        // Frame 1: initial geometry + projection bake (1, 1).
        renderer
          ..beginBatch()
          ..enqueueStaticChunk(chunk, camera: cam);
        expect(chunk.geometryBakeCount, 1);
        expect(chunk.projectionBakeCount, 1);

        // Frame 2 (stationary): 0 new bakes!
        renderer
          ..beginBatch()
          ..enqueueStaticChunk(chunk, camera: cam);
        expect(chunk.geometryBakeCount, 1);
        expect(chunk.projectionBakeCount, 1);

        // Frame 3 (pure 2D pan): projection bakes, geometry/lighting stays 1!
        cam.update(camX: 40, camY: -10, zoom: 1.0);
        renderer
          ..beginBatch()
          ..enqueueStaticChunk(chunk, camera: cam);
        expect(chunk.geometryBakeCount, 1);
        expect(chunk.projectionBakeCount, 2);

        // Adding a FAR point light outside chunk AABB does NOT invalidate
        // geometry cache!
        env.addPointLight(x: 100, y: 100, z: 2, radius: 3);
        renderer
          ..beginBatch()
          ..enqueueStaticChunk(chunk, camera: cam);
        expect(chunk.geometryBakeCount, 1);

        // Adding a NEAR point light overlapping chunk AABB triggers re-bake!
        env.addPointLight(x: 0.5, y: 0.5, z: 1.5, radius: 4);
        renderer
          ..beginBatch()
          ..enqueueStaticChunk(chunk, camera: cam);
        expect(chunk.geometryBakeCount, 2);

        // MeshLodChain3D selects high -> low -> null across camera zooms.
        final hi = Mesh3D.uvSphere();
        final lo = Mesh3D.octahedron();
        final lod = MeshLodChain3D.progressive(
          high: hi,
          low: lo,
          highMinPixels: 50.0,
          cullBelowPixels: 8.0,
        );
        cam.update(camX: 0, camY: 0, zoom: 2.0);
        expect(lod.selectMesh(camera: cam), same(hi));
        cam.update(camX: 0, camY: 0, zoom: 0.35);
        expect(lod.selectMesh(camera: cam), same(lo));
        cam.update(camX: 0, camY: 0, zoom: 0.02);
        expect(lod.selectMesh(camera: cam), isNull);

        // ParticlePool3D capacity ring-wrap & ground bounce.
        final pool = ParticlePool3D(capacity: 8)..burstCoins(0, 0, count: 16);
        expect(pool.activeCount, 8);
        for (var i = 0; i < 20; i++) {
          pool.update(1 / 60);
        }
        final rec = ui.PictureRecorder();
        pool.render(ui.Canvas(rec), cam);
        rec.endRecording().dispose();
        expect(pool.lastDrawCalls, greaterThan(0));
      },
    );
  });
}
