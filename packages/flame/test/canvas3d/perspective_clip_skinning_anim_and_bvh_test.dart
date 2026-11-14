import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Canvas3D Sort/65k Buffers, Pinhole '
      'Perspective + Near-Plane Clip, 4-Bone Skinning / AnimationMixer3D & BVH', () {
    test(
      'BatchMeshRenderer3D sortOrder, depthBias, '
      'TriangleDepthMode3D, Mesh3D.partitionByVertexLimit & 70k-vertex '
      'enqueueLargeBuffers32',
      () {
        final rig = CameraRig3D();
        final renderer = BatchMeshRenderer3D(
          backfaceCulling: false,
          frustumCullMeshes: false,
          depthMode: TriangleDepthMode3D.nearestVertex,
        );

        final quad = Mesh3D.plane(sizeX: 2.0, sizeY: 2.0);
        renderer.beginBatch();
        renderer.enqueueMesh(
          quad,
          camera: rig,
          worldX: 0,
          worldY: 0,
          worldZ: 2.0,
          tint: const ui.Color(0xFFFF0000),
        );
        renderer.enqueueMesh(
          quad,
          camera: rig,
          worldX: 0,
          worldY: 0,
          sortOrder: 10,
          depthBias: 0.25,
          tint: const ui.Color(0xFF00FF00),
        );
        expect(renderer.pendingGeometryTriangleCount, 4);

        final rec1 = ui.PictureRecorder();
        final draws1 = renderer.flushGeometry(
          ui.Canvas(rec1, const ui.Rect.fromLTWH(-400, -400, 800, 800)),
        );
        rec1.endRecording().dispose();
        expect(draws1, 1);

        // 2. Mesh3D.partitionByVertexLimit splits meshes cleanly into valid
        // sub-meshes without losing faces.
        final sphere = Mesh3D.uvSphere(
          radius: 2.0,
          rings: 24,
          segments: 32,
        );
        final parts = sphere.splitByVertexLimit(maxVerticesPerPart: 120);
        expect(parts.length, greaterThan(4));
        var totalPartitionedFaces = 0;
        for (final p in parts) {
          expect(p.vertexCount, lessThanOrEqualTo(120));
          totalPartitionedFaces = totalPartitionedFaces + p.triangleCount;
        }
        expect(totalPartitionedFaces, sphere.triangleCount);

        // 3. enqueueLargeBuffers32 renders a 72,000-vertex (> 65,535!) 32-bit
        // indexed mesh across multiple Vertices.raw batches without overflow!
        const triCount = 24000; // 72,000 unique vertices (> 65,535!)
        const vertCount = triCount * 3;
        final pos = Float32List(vertCount * 3);
        final nrm = Float32List(vertCount * 3);
        final idx32 = Uint32List(vertCount);
        for (var t = 0; t < triCount; t++) {
          final v0 = t * 3;
          final ox = (t % 200) * 0.05;
          final oy = (t ~/ 200) * 0.05;
          pos[v0 * 3] = ox;
          pos[v0 * 3 + 1] = oy;
          pos[(v0 + 1) * 3] = ox + 0.04;
          pos[(v0 + 1) * 3 + 1] = oy;
          pos[(v0 + 2) * 3] = ox;
          pos[(v0 + 2) * 3 + 1] = oy + 0.04;
          for (var k = 0; k < 3; k++) {
            nrm[(v0 + k) * 3 + 2] = 1.0;
            idx32[v0 + k] = v0 + k;
          }
        }

        renderer.beginBatch();
        renderer.enqueueLargeBuffers32(
          positions: pos,
          normals: nrm,
          indices: idx32,
          boundingRadius: 20.0,
          minZ: 0.0,
          maxZ: 0.0,
          camera: rig,
          worldX: 0,
          worldY: 0,
        );
        expect(renderer.pendingGeometryTriangleCount, triCount);
        final rec2 = ui.PictureRecorder();
        renderer.flushGeometry(
          ui.Canvas(rec2, const ui.Rect.fromLTWH(-400, -400, 800, 800)),
        );
        rec2.endRecording().dispose();
        expect(renderer.lastFlushDrawCalls, greaterThanOrEqualTo(2));
      },
    );

    test(
      'True pinhole CameraProjectionMode3D.perspective '
      'foreshortening, exact unprojectWorldRay inverse & near-plane clipping',
      () {
        final rig = CameraRig3D(
          projectionMode: CameraProjectionMode3D.perspective,
          cameraDistance: 12.0,
          fovYRad: math.pi / 3,
          nearClip: 1.0,
        );

        // 1. Perspective foreshortening: a camera-parallel horizontal span
        // centered on the optical axis projects strictly wider when closer!
        final rx = rig.rightX;
        final ry = rig.rightY;
        final nearCx = rig.viewX * 3.0;
        final nearCy = rig.viewY * 3.0;
        final farCx = -rig.viewX * 3.0;
        final farCy = -rig.viewY * 3.0;

        final nearP0 = rig.projectWorldPoint(nearCx - rx, nearCy - ry, 0);
        final nearP1 = rig.projectWorldPoint(nearCx + rx, nearCy + ry, 0);
        final farP0 = rig.projectWorldPoint(farCx - rx, farCy - ry, 0);
        final farP1 = rig.projectWorldPoint(farCx + rx, farCy + ry, 0);
        final (_, _, nearCamZ) = rig.worldToCameraSpace(nearCx, nearCy, 0);
        final (_, _, farCamZ) = rig.worldToCameraSpace(farCx, farCy, 0);
        expect(nearCamZ, lessThan(farCamZ));
        expect(
          (nearP1.dx - nearP0.dx).abs(),
          greaterThan((farP1.dx - farP0.dx).abs() * 1.4),
        );
        expect(
          rig.viewDepth(nearCx, nearCy, 0),
          greaterThan(rig.viewDepth(farCx, farCy, 0)),
        );

        // 2. Exact analytical inverse: projectWorldPoint <-> unprojectWorldRay!
        const wx = 2.35;
        const wy = -1.75;
        const wz = 1.40;
        final screenTap = rig.projectWorldPoint(wx, wy, wz);
        final ray = rig.unprojectWorldRay(screenTap);
        final vx = wx - ray.ox;
        final vy = wy - ray.oy;
        final vz = wz - ray.oz;
        final t = vx * ray.dx + vy * ray.dy + vz * ray.dz;
        expect(t, greaterThan(0.0));
        expect(ray.ox + ray.dx * t, closeTo(wx, 1e-9));
        expect(ray.oy + ray.dy * t, closeTo(wy, 1e-9));
        expect(ray.oz + ray.dz * t, closeTo(wz, 1e-9));

        // 3. Sutherland-Hodgman near-plane clipping on a triangle straddling
        // camZ < nearClip and camZ > nearClip!
        final eyePos = Float32List.fromList([
          0.0,
          0.0,
          0.0,
          1.0,
          0.0,
          0.0,
          ray.ox * 1.5,
          ray.oy * 1.5,
          ray.oz * 1.5,
        ]);
        final nrm = Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]);
        final straddlingMesh = Mesh3D(
          positions: eyePos,
          normals: nrm,
          indices: Uint16List.fromList([0, 1, 2]),
        );

        final renderer = BatchMeshRenderer3D(
          backfaceCulling: false,
          frustumCullMeshes: false,
        )..beginBatch();
        renderer.enqueueMesh(
          straddlingMesh,
          camera: rig,
          worldX: 0,
          worldY: 0,
        );
        expect(renderer.pendingGeometryTriangleCount, greaterThanOrEqualTo(1));

        final rec = ui.PictureRecorder();
        renderer.flushGeometry(
          ui.Canvas(rec, const ui.Rect.fromLTWH(-400, -400, 800, 800)),
        );
        rec.endRecording().dispose();
        expect(renderer.lastNearPlaneClippedTriangles, 1);
      },
    );

    test(
      '4-bone SkinnedMeshWorkspace3D LBS + DA3D binary '
      'AnimationClip3D roundtrip + AnimationMixer3D crossFadeTo & bone masks',
      () {
        final baseBox = Mesh3D.box(sizeZ: 2);
        final vCount = baseBox.vertexCount;
        final bones = <Bone3D>[
          Bone3D(name: 'root'),
          Bone3D(name: 'spine', parentIndex: 0, bindLocalZ: 0.5),
          Bone3D(name: 'arm_l', parentIndex: 1, bindLocalX: -0.5),
          Bone3D(name: 'arm_r', parentIndex: 1, bindLocalX: 0.5),
        ];

        final idx0 = Uint16List(vCount)..fillRange(0, vCount, 0);
        final idx1 = Uint16List(vCount)..fillRange(0, vCount, 1);
        final idx2 = Uint16List(vCount)..fillRange(0, vCount, 2);
        final idx3 = Uint16List(vCount)..fillRange(0, vCount, 3);
        final w0 = Float32List(vCount)..fillRange(0, vCount, 1.0);
        final w1 = Float32List(vCount)..fillRange(0, vCount, 1.0);
        final w2 = Float32List(vCount)..fillRange(0, vCount, 1.0);
        final w3 = Float32List(vCount)..fillRange(0, vCount, 1.0);

        final skin = SkinnedMeshWorkspace3D(
          baseMesh: baseBox,
          bones: bones,
          boneIndices0: idx0,
          boneIndices1: idx1,
          boneIndices2: idx2,
          boneIndices3: idx3,
          boneWeights0: w0,
          boneWeights1: w1,
          boneWeights2: w2,
          boneWeights3: w3,
        );
        expect(skin.findBoneIndex('arm_l'), 2);

        final idleClip = AnimationClip3D(
          name: 'idle',
          duration: 1.0,
          tracks: [
            TransformTrack3D(
              targetIndex: 1,
              targetName: 'spine',
              times: Float32List.fromList([0.0, 1.0]),
              translations: Float32List.fromList([0, 0, 0, 0, 0, 0.4]),
              scales: Float32List.fromList([1, 1, 1, 1.1, 1.1, 1.0]),
            ),
          ],
          events: const [
            AnimationEvent3D(time: 0.5, name: 'breath_peak'),
          ],
        );

        final bytes = idleClip.toBytes();
        final decodedIdle = AnimationClip3D.fromBytes(bytes);
        expect(decodedIdle.name, 'idle');
        expect(decodedIdle.duration, closeTo(1.0, 1e-6));
        expect(decodedIdle.tracks.length, 1);
        expect(decodedIdle.events.single.name, 'breath_peak');

        final runClip = AnimationClip3D(
          name: 'run',
          duration: 1.0,
          tracks: [
            TransformTrack3D(
              targetIndex: 1,
              targetName: 'spine',
              times: Float32List.fromList([0.0, 1.0]),
              translations: Float32List.fromList([2.0, 0, 0, 2.0, 0, 0]),
            ),
          ],
        );

        final waveLayerClip = AnimationClip3D(
          name: 'wave_arm',
          duration: 1.0,
          tracks: [
            TransformTrack3D(
              targetIndex: 2,
              targetName: 'arm_l',
              times: Float32List.fromList([0.0, 1.0]),
              rotations: Float32List.fromList([
                0,
                0,
                0,
                1,
                0,
                0,
                0.70710678,
                0.70710678,
              ]),
            ),
          ],
        );

        final firedEvents = <String>[];
        final mixer = AnimationMixer3D(
          skinnedWorkspace: skin,
          onEvent: (ev) => firedEvents.add(ev.name),
        )..play(decodedIdle);

        mixer.update(0.6);
        expect(firedEvents, ['breath_peak']);
        mixer.update(0.95);
        expect(firedEvents, ['breath_peak', 'breath_peak']);

        mixer.crossFadeTo(runClip, duration: 0.4);
        expect(mixer.isCrossFading, isTrue);
        mixer.update(0.2);
        final midPose = skin.getBoneLocalPose(1);
        expect(midPose.dx, closeTo(1.0, 0.15));

        mixer.setLayerClip(waveLayerClip, boneMask: {2});
        mixer.update(0.5);
        final armPose = skin.getBoneLocalPose(2);
        expect(armPose.qz, greaterThan(0.25));

        skin.evaluateIfDirty();
        expect(skin.skinnedPositions.any((v) => v.isNaN), isFalse);
      },
    );

    test(
      'Flat zero-alloc MeshBvh3D matches brute-force raycast '
      'with O(log T) triangle tests & full 3x3 transform / Node3D hierarchy',
      () {
        final highPolySphere = Mesh3D.uvSphere(
          radius: 3.0,
          rings: 28,
          segments: 36,
        );
        expect(highPolySphere.triangleCount, greaterThan(1800));

        var hits = 0;
        for (var i = 0; i < 50; i++) {
          final ox = -2.2 + (i % 10) * 0.48;
          final oy = -2.2 + (i ~/ 10) * 1.1;
          final ray = Ray3D(
            ox: ox,
            oy: oy,
            oz: 10.0,
            dx: 0.05,
            dy: -0.04,
            dz: -1.0,
          );
          final bvhHit = Raycaster3D.raycastMeshTransform(
            ray,
            highPolySphere,
            worldX: 0,
            worldY: 0,
          );
          final bruteHit = Raycaster3D.raycastMeshTransform(
            ray,
            highPolySphere,
            worldX: 0,
            worldY: 0,
            useBvh: false,
          );
          if (bruteHit == null) {
            expect(bvhHit, isNull);
          } else {
            hits++;
            expect(bvhHit, isNotNull);
            expect(bvhHit!.$1, closeTo(bruteHit.$1, 1e-4));
            expect(
              highPolySphere.bvh.lastTrianglesTested,
              lessThan(highPolySphere.triangleCount ~/ 6),
            );
          }
        }
        expect(hits, greaterThan(20));

        final parentNode = Node3D(
          name: 'turret_base',
          localX: 4.0,
          localY: -3.0,
          localZ: 1.0,
          localYawRad: 0.65,
          localPitchRad: 0.35,
          localRollRad: -0.25,
          localScaleX: 1.5,
          localScaleY: 0.8,
          localScaleZ: 2.0,
        );
        final barrelMesh = Mesh3D.box(
          sizeZ: 2.0,
          centerZ: 1.0,
        );
        final childNode = Node3D(
          name: 'turret_barrel',
          localX: 1.2,
          localY: -0.4,
          localZ: 0.8,
          mesh: barrelMesh,
        );
        parentNode.addChild(childNode);
        parentNode.updateWorldTransforms();

        final (targetX, targetY, targetZ) = childNode.worldPointForLocal(
          0.0,
          0.0,
          1.0,
        );
        final sniperRay = Ray3D(
          ox: targetX - 6.0,
          oy: targetY + 4.0,
          oz: targetZ + 8.0,
          dx: 6.0,
          dy: -4.0,
          dz: -8.0,
        );

        final nodeHit = Raycaster3D.raycastNodeHierarchy(sniperRay, parentNode);
        expect(nodeHit, isNotNull);
        expect(nodeHit!.node, same(childNode));
        expect(nodeHit.distance, greaterThan(0.0));
        expect(nodeHit.distance, lessThan(12.0));
      },
    );
  });
}
