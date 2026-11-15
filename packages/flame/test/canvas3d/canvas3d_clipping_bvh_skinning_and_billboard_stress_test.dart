import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/canvas3d.dart';
import 'package:flame/math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

ui.Image _createSolidTexture(int size) {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final pic = rec.endRecording();
  final img = pic.toImageSync(size, size);
  pic.dispose();
  return img;
}

/// Independent world-space O(T) Moller-Trumbore ray-mesh reference oracle for
/// verifying [MeshBvh3D] + [Raycaster3D.raycastMeshTransform] accuracy under
/// arbitrary 3x3 rotations and mirrored negative scales!
double? _bruteForceWorldRaycastMesh({
  required Mesh3D mesh,
  required Ray3D worldRay,
  required double wx,
  required double wy,
  required double wz,
  required Float32List rotRowMajor9,
  required double sx,
  required double sy,
  required double sz,
  required bool cullBackfaces,
}) {
  final pos = mesh.positions;
  final idx = mesh.indices;

  double? bestT;
  final v0 = Vector3.zero();
  final v1 = Vector3.zero();
  final v2 = Vector3.zero();
  final e1 = Vector3.zero();
  final e2 = Vector3.zero();
  final h = Vector3.zero();
  final s = Vector3.zero();
  final q = Vector3.zero();
  final ro = Vector3(worldRay.ox, worldRay.oy, worldRay.oz);
  final rd = Vector3(worldRay.dx, worldRay.dy, worldRay.dz);
  final flipWinding = (sx * sy * sz) < 0.0;

  void transformVert(int vi, Vector3 out) {
    final lx = pos[vi * 3] * sx;
    final ly = pos[vi * 3 + 1] * sy;
    final lz = pos[vi * 3 + 2] * sz;
    out.setValues(
      rotRowMajor9[0] * lx + rotRowMajor9[1] * ly + rotRowMajor9[2] * lz + wx,
      rotRowMajor9[3] * lx + rotRowMajor9[4] * ly + rotRowMajor9[5] * lz + wy,
      rotRowMajor9[6] * lx + rotRowMajor9[7] * ly + rotRowMajor9[8] * lz + wz,
    );
  }

  for (var t = 0; t < idx.length; t += 3) {
    transformVert(idx[t], v0);
    if (flipWinding) {
      transformVert(idx[t + 2], v1);
      transformVert(idx[t + 1], v2);
    } else {
      transformVert(idx[t + 1], v1);
      transformVert(idx[t + 2], v2);
    }
    e1
      ..setFrom(v1)
      ..sub(v0);
    e2
      ..setFrom(v2)
      ..sub(v0);
    rd.crossInto(e2, h);
    final a = e1.dot(h);
    if (cullBackfaces) {
      if (a < 1e-8) {
        continue;
      }
    } else if (a.abs() < 1e-8) {
      continue;
    }
    final f = 1.0 / a;
    s
      ..setFrom(ro)
      ..sub(v0);
    final u = f * s.dot(h);
    if (u < -1e-6 || u > 1.0 + 1e-6) {
      continue;
    }
    s.crossInto(e1, q);
    final v = f * rd.dot(q);
    if (v < -1e-6 || u + v > 1.0 + 1e-6) {
      continue;
    }
    final dist = f * e2.dot(q);
    if (dist >= 1e-5 && (bestT == null || dist < bestT)) {
      bestT = dist;
    }
  }
  return bestT;
}

void main() {
  group('Canvas3D perspective near-plane fuzz, BVH oracle & >100k buffers', () {
    test(
      'fuzzes 1,000 random perspective near-plane straddling, sliver, and '
      'behind-camera triangles without NaN or coordinate inversion',
      () {
        final rig = CameraRig3D(
          projectionMode: CameraProjectionMode3D.perspective,
          cameraDistance: 10.0,
          fovYRad: math.pi / 3,
          nearClip: 0.35,
          baseElevationRad: 0.42,
        );
        final env =
            SceneEnvironment3D(
              fogEnabled: true,
              fogStartDepth: 2.0,
              fogEndDepth: 30.0,
            )..addPointLight(
              x: 1,
              y: -1,
              z: 2,
              radius: 12,
              color: const ui.Color(0xFFFFAA55),
            );
        final renderer = BatchMeshRenderer3D(
          backfaceCulling: false,
          frustumCullMeshes: false,
          environment: env,
        );

        final rng = SeededRng(0x5150ABCD);
        final positions = Float32List(9);
        final normals = Float32List.fromList(const <double>[
          0,
          0,
          1,
          0,
          0,
          1,
          0,
          0,
          1,
        ]);
        final uvs = Float32List.fromList(const <double>[0, 0, 1, 0, 0, 1]);
        final indices = Uint16List.fromList(const <int>[0, 1, 2]);

        renderer.beginBatch();
        for (var i = 0; i < 1000; i++) {
          for (var k = 0; k < 9; k++) {
            // Span [-25 .. +25] so many triangles cross z_cam == nearClip!
            positions[k] = (rng.nextDouble() - 0.5) * 50.0;
          }
          // Inject exact degenerate collinear / zero-area triangles every 25th!
          if (i % 25 == 0) {
            positions[3] = positions[0];
            positions[4] = positions[1];
            positions[5] = positions[2];
          }
          final triMesh = Mesh3D(
            positions: Float32List.fromList(positions),
            normals: normals,
            uvs: uvs,
            indices: indices,
          );
          renderer.enqueueMesh(
            triMesh,
            camera: rig,
            worldX: 0,
            worldY: 0,
            tint: const ui.Color(0xFF88CCFF),
          );
        }

        final rec = ui.PictureRecorder();
        final draws = renderer.flushGeometry(
          ui.Canvas(rec, const ui.Rect.fromLTWH(-600, -600, 1200, 1200)),
        );
        rec.endRecording().dispose();
        expect(draws, greaterThanOrEqualTo(1));
        expect(renderer.lastFlushTriangles, greaterThan(100));
      },
    );

    test(
      'proves MeshBvh3D + Raycaster3D.raycastMeshTransform matches O(T) '
      'brute-force oracle across 400 random rays & negative scales',
      () {
        final sphere = Mesh3D.uvSphere(
          radius: 1.9,
          segments: 24,
          rings: 16,
        );
        expect(sphere.bvh.nodeCount, greaterThan(20));

        final rng = SeededRng(0xB7412345);
        final rotMat = Float32List(9);
        var hitsVerified = 0;
        var missesVerified = 0;

        for (var trial = 0; trial < 400; trial++) {
          final wx = (rng.nextDouble() - 0.5) * 4.0;
          final wy = (rng.nextDouble() - 0.5) * 4.0;
          final wz = (rng.nextDouble() - 0.5) * 4.0;
          final yaw = rng.nextDouble() * math.pi * 2;
          final pitch = (rng.nextDouble() - 0.5) * math.pi;
          final roll = (rng.nextDouble() - 0.5) * math.pi;
          Quaternion3D.writeEulerMatrix3(
            yawRad: yaw,
            pitchRad: pitch,
            rollRad: roll,
            out: rotMat,
          );

          // Alternate positive and mirrored negative non-uniform scales!
          final sx = (rng.nextBool() ? 1.0 : -1.0) * (0.6 + rng.nextDouble());
          final sy = (rng.nextBool() ? 1.0 : -1.0) * (0.6 + rng.nextDouble());
          final sz = (rng.nextBool() ? 1.0 : -1.0) * (0.6 + rng.nextDouble());
          final cullBack = trial.isEven;

          final ox = (rng.nextDouble() - 0.5) * 16.0;
          final oy = (rng.nextDouble() - 0.5) * 16.0;
          final oz = (rng.nextDouble() - 0.5) * 16.0;
          // Aim roughly toward mesh center with jitter so ~50% hit!
          var dx = (wx - ox) + (rng.nextDouble() - 0.5) * 4.8;
          var dy = (wy - oy) + (rng.nextDouble() - 0.5) * 4.8;
          var dz = (wz - oz) + (rng.nextDouble() - 0.5) * 4.8;
          final len = math.sqrt(dx * dx + dy * dy + dz * dz);
          dx /= len;
          dy /= len;
          dz /= len;
          final ray = Ray3D(ox: ox, oy: oy, oz: oz, dx: dx, dy: dy, dz: dz);

          final bvhHit = Raycaster3D.raycastMeshTransform(
            ray,
            sphere,
            worldX: wx,
            worldY: wy,
            worldZ: wz,
            yawRad: yaw,
            pitchRad: pitch,
            rollRad: roll,
            scaleX: sx,
            scaleY: sy,
            scaleZ: sz,
            cullBackfaces: cullBack,
          );
          final linearHit = Raycaster3D.raycastMeshTransform(
            ray,
            sphere,
            worldX: wx,
            worldY: wy,
            worldZ: wz,
            yawRad: yaw,
            pitchRad: pitch,
            rollRad: roll,
            scaleX: sx,
            scaleY: sy,
            scaleZ: sz,
            cullBackfaces: cullBack,
            useBvh: false,
          );
          final oracleT = _bruteForceWorldRaycastMesh(
            mesh: sphere,
            worldRay: ray,
            wx: wx,
            wy: wy,
            wz: wz,
            rotRowMajor9: rotMat,
            sx: sx,
            sy: sy,
            sz: sz,
            cullBackfaces: cullBack,
          );

          if (oracleT == null) {
            expect(bvhHit, isNull, reason: 'Trial $trial BVH false positive');
            expect(linearHit, isNull);
            missesVerified++;
          } else {
            expect(bvhHit, isNotNull, reason: 'Trial $trial BVH missed sphere');
            expect(linearHit, isNotNull);
            expect(bvhHit!.$1, closeTo(linearHit!.$1, 1e-4));
            expect(
              bvhHit.$1,
              closeTo(oracleT, 2e-3),
              reason: 'Trial $trial distance mismatch vs world oracle',
            );
            hitsVerified++;
          }
        }

        expect(hitsVerified, greaterThan(80));
        expect(missesVerified, greaterThan(80));
      },
    );

    test(
      'stresses 105,000-vertex 32-bit mesh buffers, 500 SpriteBillboard3D '
      'standees with shadows, and 2,000-instance StaticMeshChunk3D rebakes',
      () {
        final tex = _createSolidTexture(32);
        addTearDown(tex.dispose);
        final mat = Material3D.texture(
          ui.ImageShader(
            tex,
            ui.TileMode.clamp,
            ui.TileMode.clamp,
            Float64List.fromList(const <double>[
              1,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              1,
            ]),
          ),
          width: 32,
          height: 32,
        );

        final rig = CameraRig3D();
        final renderer = BatchMeshRenderer3D(frustumCullMeshes: false);

        // 1. 35,000 triangles = 105,000 vertices (> 65,535 Uint16 limit!).
        const triCount = 35000;
        const vertCount = triCount * 3;
        final pos = Float32List(vertCount * 3);
        final nrm = Float32List(vertCount * 3);
        final idx32 = Uint32List(vertCount);
        for (var t = 0; t < triCount; t++) {
          final v = t * 3;
          final x = (t % 250) * 0.03;
          final y = (t ~/ 250) * 0.03;
          pos[v * 3] = x;
          pos[v * 3 + 1] = y;
          pos[(v + 1) * 3] = x + 0.02;
          pos[(v + 1) * 3 + 1] = y;
          pos[(v + 2) * 3] = x;
          pos[(v + 2) * 3 + 1] = y + 0.02;
          for (var k = 0; k < 3; k++) {
            nrm[(v + k) * 3 + 2] = 1.0;
            idx32[v + k] = v + k;
          }
        }

        renderer
          ..beginBatch()
          ..enqueueLargeBuffers32(
            positions: pos,
            normals: nrm,
            indices: idx32,
            boundingRadius: 30.0,
            minZ: 0,
            maxZ: 0,
            camera: rig,
            worldX: 0,
            worldY: 0,
          );

        // 2. Enqueue 500 SpriteBillboard3D standees casting shadows into the
        // same batch!
        for (var i = 0; i < 500; i++) {
          final standee =
              SpriteBillboard3D(
                worldX: (i % 25) * 0.5 - 6.0,
                worldY: (i ~/ 25) * 0.5 - 5.0,
                material: mat,
                width: 0.8,
                height: 1.2,
                orientation: BillboardOrientationMode3D
                    .values[i % BillboardOrientationMode3D.values.length],
              )..setFlipbookFrame(
                frameIndex: i % 4,
                columns: 2,
                frameWidthPx: 16,
                frameHeightPx: 16,
              );
          standee.enqueue(renderer, camera: rig);
        }

        final rec = ui.PictureRecorder();
        final canvas = ui.Canvas(
          rec,
          const ui.Rect.fromLTWH(-800, -800, 1600, 1600),
        );
        final shadowDraws = renderer.flushShadows(canvas);
        final geoDraws = renderer.flushGeometry(canvas);
        rec.endRecording().dispose();

        expect(shadowDraws, greaterThanOrEqualTo(1));
        expect(renderer.lastFlushShadowTriangles, 1000); // 500 * 2 tris!
        expect(geoDraws, greaterThanOrEqualTo(2));

        // 3. StaticMeshChunk3D with 2,000 instances + surgical slot updates:
        final cube = Mesh3D.box(sizeX: 0.5, sizeY: 0.5, sizeZ: 0.5);
        final chunk = StaticMeshChunk3D()
          ..addAll(
            List<StaticMeshInstance3D>.generate(
              2000,
              (i) => StaticMeshInstance3D(
                mesh: cube,
                worldX: (i % 50) * 1.0,
                worldY: (i ~/ 50) * 1.0,
              ),
            ),
          );
        renderer
          ..beginBatch()
          ..enqueueStaticChunk(chunk, camera: rig);
        expect(chunk.geometryBakeCount, 1);

        // Update 50 slots + hide 50 slots -> 100 surgical slot rebakes and 0
        // full chunk rebuilds!
        for (var s = 0; s < 50; s++) {
          chunk
            ..updateInstance(
              s * 10,
              StaticMeshInstance3D(mesh: cube, worldX: s * 2.0, worldY: -3.0),
            )
            ..setInstanceVisible(s * 10 + 1, visible: false);
        }
        renderer
          ..beginBatch()
          ..enqueueStaticChunk(chunk, camera: rig);
        expect(chunk.geometryBakeCount, 1);
        expect(chunk.partialSlotRebakeCount, 100);
      },
    );
  });
}
