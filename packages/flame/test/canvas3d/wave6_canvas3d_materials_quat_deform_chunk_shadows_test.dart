import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/canvas3d.dart';
import 'package:flame/game.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _makeSolidImage(int w, int h, ui.Color color) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = color,
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(w, h);
  } finally {
    pic.dispose();
  }
}

Future<ui.Image> _makeSplitRedGreenAtlas() async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 16, 16),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  canvas.drawRect(
    const Rect.fromLTWH(16, 0, 16, 16),
    ui.Paint()..color = const ui.Color(0xFF00FF00),
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(32, 16);
  } finally {
    pic.dispose();
  }
}

Future<ByteData> _rasterizeRgba(
  int width,
  int height,
  void Function(ui.Canvas canvas) paint,
) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  paint(canvas);
  final pic = rec.endRecording();
  final img = pic.toImageSync(width, height);
  pic.dispose();
  try {
    final bytes = await img.toByteData();
    return bytes!;
  } finally {
    img.dispose();
  }
}

(int r, int g, int b, int a) _pixelAt(
  ByteData rgba,
  int width,
  int x,
  int y,
) {
  final off = (y * width + x) * 4;
  return (
    rgba.getUint8(off),
    rgba.getUint8(off + 1),
    rgba.getUint8(off + 2),
    rgba.getUint8(off + 3),
  );
}

void main() {
  group('Wave 6 — Canvas3D Multi-Material Z-Sort, Quaternions, Deformables, '
      'Partial Chunks & Decoupled Shadows', () {
    test(
      'Unlock #1: Multi-Material, Multi-Texture & Multi-BlendMode global '
      'Z-sort preserves 3D occlusion and coalesces contiguous runs',
      () async {
        final cyanImg = await _makeSolidImage(
          16,
          16,
          const ui.Color(0xFF00FFFF),
        );
        final yellowImg = await _makeSolidImage(
          16,
          16,
          const ui.Color(0xFFFFFF00),
        );
        final matCap = MatCapShader3D()..ensureInitialized();

        final cyanShader = ui.ImageShader(
          cyanImg,
          ui.TileMode.clamp,
          ui.TileMode.clamp,
          Float64List.fromList(<double>[
            1, 0, 0, 0, //
            0, 1, 0, 0, //
            0, 0, 1, 0, //
            0, 0, 0, 1, //
          ]),
        );
        final yellowShader = ui.ImageShader(
          yellowImg,
          ui.TileMode.clamp,
          ui.TileMode.clamp,
          Float64List.fromList(<double>[
            1, 0, 0, 0, //
            0, 1, 0, 0, //
            0, 0, 1, 0, //
            0, 0, 0, 1, //
          ]),
        );

        try {
          final matCyan = Material3D.texture(
            cyanShader,
            width: 16,
            height: 16,
          );
          final matCyanDup = Material3D.texture(
            cyanShader,
            width: 16,
            height: 16,
          );
          expect(matCyan, equals(matCyanDup));
          expect(matCyan.hashCode, equals(matCyanDup.hashCode));

          const matTranslucentRed = Material3D.unshaded();
          const matAdditiveGlow = Material3D.unshaded(
            blendMode: ui.BlendMode.plus,
          );
          final matYellow = Material3D.texture(
            yellowShader,
            width: 16,
            height: 16,
          );
          const matPearl = Material3D.matCap(
            MatCapPreset3D.glossyLacquer,
          );

          // Top-down orthographic camera (elevation 90 deg, zero perspective)
          // so worldZ purely orders depth at exact screen center (100, 100)!
          final cam = CameraRig3D(
            cellHalfW: 20.0,
            cellHalfH: 20.0,
            groundOriginY: 0.0,
            baseAzimuthRad: 0.0,
            baseElevationRad: math.pi / 2,
          );

          final light = DirectionalLight3D(
            sunDirX: 0.0,
            sunDirY: 0.0,
            sunDirZ: 1.0,
            sunColor: const Color(0xFFFFFFFF),
            skyColor: const Color(0xFFFFFFFF),
            groundColor: const Color(0xFFFFFFFF),
            ambientIntensity: 1.0,
            diffuseIntensity: 0.0,
            rimIntensity: 0.0,
          );
          final renderer = BatchMeshRenderer3D(
            light: light,
            backfaceCulling: false,
          );

          final largePlane = Mesh3D.plane(sizeX: 5.0, sizeY: 5.0);
          final midPlane = Mesh3D.plane(sizeX: 3.0, sizeY: 3.0);
          final smallPlane = Mesh3D.plane(sizeX: 1.2, sizeY: 1.2);
          // canvasOrigin (-100, -100) maps world (0, 0) -> canvas (100, 100).
          const origin = Offset(-100, -100);

          // Submit in intentionally scrambled order (front first, back middle,
          // translucent last) to prove global back-to-front Z-sorting across
          // distinct Material3Ds!
          final rgba = await _rasterizeRgba(200, 200, (canvas) {
            canvas.drawRect(
              const Rect.fromLTWH(0, 0, 200, 200),
              ui.Paint()..color = const Color(0xFF000000),
            );
            renderer
              ..beginBatch()
              // Front small yellow occluder at Z = 3.0 and Z = 3.1 sharing
              // matYellow -> coalesced into 1 contiguous material run!
              ..enqueueMesh(
                smallPlane,
                camera: cam,
                worldX: 0,
                worldY: 0,
                worldZ: 3.0,
                canvasOrigin: origin,
                material: matYellow,
              )
              ..enqueueMesh(
                smallPlane,
                camera: cam,
                worldX: 0,
                worldY: 0,
                worldZ: 3.1,
                canvasOrigin: origin,
                material: matYellow,
              )
              // Back large cyan base at Z = 0.0 and Z = -0.1 -> coalesced!
              ..enqueueMesh(
                largePlane,
                camera: cam,
                worldX: 0,
                worldY: 0,
                canvasOrigin: origin,
                material: matCyan,
              )
              ..enqueueMesh(
                largePlane,
                camera: cam,
                worldX: 0,
                worldY: 0,
                worldZ: -0.1,
                canvasOrigin: origin,
                material: matCyanDup,
              )
              // Middle translucent red glass at Z = 1.5
              ..enqueueMesh(
                midPlane,
                camera: cam,
                worldX: 0,
                worldY: 0,
                worldZ: 1.5,
                canvasOrigin: origin,
                tint: const Color(0xFFFF0000),
                opacity: 0.5,
                material: matTranslucentRed,
              )
              // Off-center MatCap prop + additive glow at Z = 2.0 / 2.2
              ..enqueueMesh(
                smallPlane,
                camera: cam,
                worldX: 3.6,
                worldY: 0,
                worldZ: 2.0,
                canvasOrigin: origin,
                material: matPearl,
              )
              ..enqueueMesh(
                smallPlane,
                camera: cam,
                worldX: -3.6,
                worldY: 0,
                worldZ: 2.2,
                canvasOrigin: origin,
                tint: const Color(0xFF204080),
                material: matAdditiveGlow,
              );

            renderer.flushBatch(canvas, matCapShader: matCap);
          });

          // 5 depth-ordered material runs across 14 triangles -> 5 draw calls,
          // 4 material switches!
          expect(renderer.lastFlushTriangles, 14);
          expect(renderer.lastFlushDrawCalls, 5);
          expect(renderer.lastFlushMaterialSwitches, 4);

          // Exact projected screen coordinates accounting for CameraRig3D's
          // clamped elevation angle:
          // - pCenter: center of front yellow smallPlane at Z = 3.1
          // - pMidRing: lateral Y = 1.25 on midPlane (Z = 1.5), outside
          //   smallPlane (±0.6) and inside back largePlane (±2.5)
          // - pOuterCyan: lateral Y = 2.15 on largePlane (Z = 0.0), outside
          //   midPlane (±1.5)
          final pCenter = cam.projectWorldPoint(0.0, 0.0, 3.1) - origin;
          final pMidRing = cam.projectWorldPoint(0.0, 1.25, 1.5) - origin;
          final pOuterCyan = cam.projectWorldPoint(0.0, 2.15, 0.0) - origin;

          final (cR, cG, cB, _) = _pixelAt(
            rgba,
            200,
            pCenter.dx.round(),
            pCenter.dy.round(),
          );
          expect(cR, greaterThan(220));
          expect(cG, greaterThan(220));
          expect(cB, lessThan(35));

          final (mR, mG, mB, _) = _pixelAt(
            rgba,
            200,
            pMidRing.dx.round(),
            pMidRing.dy.round(),
          );
          expect(mR, inInclusiveRange(95, 165));
          expect(mG, inInclusiveRange(95, 165));
          expect(mB, inInclusiveRange(95, 165));

          final (oR, oG, oB, _) = _pixelAt(
            rgba,
            200,
            pOuterCyan.dx.round(),
            pOuterCyan.dy.round(),
          );
          expect(oR, lessThan(25));
          expect(oG, greaterThan(220));
          expect(oB, greaterThan(220));
        } finally {
          cyanShader.dispose();
          yellowShader.dispose();
          cyanImg.dispose();
          yellowImg.dispose();
          matCap.dispose();
        }
      },
    );

    test(
      'Unlock #2: Quaternion3D math, 3-level pitch/roll/quat Node3D composition, '
      'MorphMeshWorkspace3D & SkinnedMeshWorkspace3D',
      () {
        // 1. Quaternion3D degenerate & orthonormal invariants
        expect(Quaternion3D.normalize(0, 0, 0, 0), Quaternion3D.identity);
        expect(
          Quaternion3D.fromAxisAngle(0, 0, 0, 1.2),
          Quaternion3D.identity,
        );

        final qEuler = Quaternion3D.fromEuler(
          yawRad: 0.65,
          pitchRad: -0.42,
          rollRad: 0.91,
        );
        final mFromQuat = Float32List(9);
        final mFromEuler = Float32List(9);
        Quaternion3D.writeMatrix3(
          qEuler.$1,
          qEuler.$2,
          qEuler.$3,
          qEuler.$4,
          mFromQuat,
        );
        Quaternion3D.writeEulerMatrix3(
          yawRad: 0.65,
          pitchRad: -0.42,
          rollRad: 0.91,
          out: mFromEuler,
        );
        for (var i = 0; i < 9; i++) {
          expect(mFromQuat[i], closeTo(mFromEuler[i], 1e-5));
        }

        // Shortest-arc SLERP invariance under antipodal sign negation (-q == q)
        const qStart = Quaternion3D.identity;
        final qEnd = Quaternion3D.fromAxisAngle(0, 0, 1, math.pi / 2);
        final qEndNeg = (-qEnd.$1, -qEnd.$2, -qEnd.$3, -qEnd.$4);
        final midPos = Quaternion3D.slerp(qStart, qEnd, 0.5);
        final midNeg = Quaternion3D.slerp(qStart, qEndNeg, 0.5);
        final expected45 = Quaternion3D.fromAxisAngle(0, 0, 1, math.pi / 4);
        expect(midPos.$3.abs(), closeTo(expected45.$3.abs(), 1e-5));
        expect(midPos.$4.abs(), closeTo(expected45.$4.abs(), 1e-5));
        expect(midNeg.$3.abs(), closeTo(midPos.$3.abs(), 1e-5));
        expect(midNeg.$4.abs(), closeTo(midPos.$4.abs(), 1e-5));

        // Gimbal-lock immunity at +90 deg pitch: composing local X vs local Z
        // rotations produces distinct orthonormal matrices with det == +1.
        final qPitch90 = Quaternion3D.fromAxisAngle(0, 1, 0, math.pi / 2);
        final qSpinX = Quaternion3D.multiply(
          qPitch90,
          Quaternion3D.fromAxisAngle(1, 0, 0, 0.7),
        );
        final qSpinZ = Quaternion3D.multiply(
          qPitch90,
          Quaternion3D.fromAxisAngle(0, 0, 1, 0.7),
        );
        final mSpinX = Float32List(9);
        final mSpinZ = Float32List(9);
        Quaternion3D.writeMatrix3(
          qSpinX.$1,
          qSpinX.$2,
          qSpinX.$3,
          qSpinX.$4,
          mSpinX,
        );
        Quaternion3D.writeMatrix3(
          qSpinZ.$1,
          qSpinZ.$2,
          qSpinZ.$3,
          qSpinZ.$4,
          mSpinZ,
        );
        final detX =
            mSpinX[0] * (mSpinX[4] * mSpinX[8] - mSpinX[5] * mSpinX[7]) -
            mSpinX[1] * (mSpinX[3] * mSpinX[8] - mSpinX[5] * mSpinX[6]) +
            mSpinX[2] * (mSpinX[3] * mSpinX[7] - mSpinX[4] * mSpinX[6]);
        expect(detX, closeTo(1.0, 1e-5));
        var diffSq = 0.0;
        for (var i = 0; i < 9; i++) {
          final d = mSpinX[i] - mSpinZ[i];
          diffSq += d * d;
        }
        expect(diffSq, greaterThan(0.2));

        // 2. Node3D 3-level true 3D matrix composition (pitch -> roll -> quat)
        final root = Node3D(
          name: 'shoulder',
          localX: 1.0,
          localY: 2.0,
          localZ: 3.0,
          // Pitch +90 deg around +Y maps local +Z -> world +X, local +X -> -Z
          localPitchRad: math.pi / 2,
        );
        final elbow = Node3D(
          name: 'elbow',
          // Offset +2 along root local Z -> +2 in world X => (3, 2, 3)
          localZ: 2.0,
          // Roll +90 deg around elbow's local X
          localRollRad: math.pi / 2,
        );
        final wrist = Node3D(
          name: 'wrist',
          mesh: Mesh3D.box(sizeX: 0.4, sizeY: 0.4, sizeZ: 0.4),
          localZ: 1.0,
        );
        final qWrist = Quaternion3D.fromAxisAngle(0, 0, 1, math.pi / 2);
        final beforeMut = Game.visualMutationCount;
        wrist.setLocalQuaternion(qWrist.$1, qWrist.$2, qWrist.$3, qWrist.$4);
        expect(wrist.hasLocalQuaternion, isTrue);
        expect(Game.visualMutationCount, greaterThan(beforeMut));

        root.addChild(elbow);
        elbow.addChild(wrist);
        root.updateWorldTransforms();

        expect(elbow.worldX, closeTo(3.0, 1e-5));
        expect(elbow.worldY, closeTo(2.0, 1e-5));
        expect(elbow.worldZ, closeTo(3.0, 1e-5));

        // Elbow rolled +90 deg around its local X (which is world -Z):
        // elbow's local +Z maps to root's local -Y -> world -Y!
        expect(wrist.worldX, closeTo(3.0, 1e-5));
        expect(wrist.worldY, closeTo(1.0, 1e-5));
        expect(wrist.worldZ, closeTo(3.0, 1e-5));

        final tipWorld = wrist.worldPointForLocal(0.0, 0.0, 2.0);
        expect(tipWorld.$1, closeTo(3.0, 1e-5));
        expect(tipWorld.$2, closeTo(-1.0, 1e-5));
        expect(tipWorld.$3, closeTo(3.0, 1e-5));

        wrist.clearLocalQuaternion();
        expect(wrist.hasLocalQuaternion, isFalse);

        // 3. MorphMeshWorkspace3D multi-target blend + normal renormalization
        final baseBox = Mesh3D.box();
        final posDeltaA = Float32List(baseBox.positions.length);
        final nrmDeltaA = Float32List(baseBox.normals.length);
        final posDeltaB = Float32List(baseBox.positions.length);
        for (var i = 0; i < baseBox.vertexCount; i++) {
          if (baseBox.positions[i * 3 + 2] > 0) {
            posDeltaA[i * 3 + 2] = 1.5;
          }
          nrmDeltaA[i * 3] = 0.5;
          posDeltaB[i * 3] = baseBox.positions[i * 3] * 0.5;
        }
        final morph = MorphMeshWorkspace3D(
          baseMesh: baseBox,
          targets: [
            MorphTarget3D(
              name: 'stretchZ',
              positionDeltas: posDeltaA,
              normalDeltas: nrmDeltaA,
            ),
            MorphTarget3D(
              name: 'widenX',
              positionDeltas: posDeltaB,
            ),
          ],
        );
        expect(morph.evaluateIfDirty(), isFalse);
        expect(morph.setWeightByName('stretchZ', 0.8), isTrue);
        expect(morph.setWeightByName('widenX', 0.5), isTrue);
        expect(morph.setWeightByName('nonexistent', 1.0), isFalse);
        expect(morph.evaluateIfDirty(), isTrue);
        expect(morph.maxZ, greaterThan(baseBox.maxZ + 1.0));

        // Every deformed normal must be renormalized to unit length 1.0!
        for (var i = 0; i < baseBox.vertexCount; i++) {
          final nx = morph.deformedNormals[i * 3];
          final ny = morph.deformedNormals[i * 3 + 1];
          final nz = morph.deformedNormals[i * 3 + 2];
          final len = math.sqrt(nx * nx + ny * ny + nz * nz);
          expect(len, closeTo(1.0, 1e-5));
        }

        // 4. SkinnedMeshWorkspace3D 2-bone articulated bend
        final armPos = Float32List.fromList(<double>[
          0.0, 0.0, 0.0, // v0: base (bone 0 = 1.0)
          0.0, 0.0, 1.0, // v1: elbow (bone 0 = 0.5, bone 1 = 0.5)
          0.0, 0.0, 2.0, // v2: fingertip (bone 0 = 0.0, bone 1 = 1.0)
        ]);
        final armNrm = Float32List.fromList(<double>[
          1.0, 0.0, 0.0, //
          1.0, 0.0, 0.0, //
          1.0, 0.0, 0.0, //
        ]);
        final armMesh = Mesh3D(
          positions: armPos,
          normals: armNrm,
          indices: Uint16List.fromList(<int>[0, 1, 2]),
        );
        final skin = SkinnedMeshWorkspace3D(
          baseMesh: armMesh,
          bones: [
            Bone3D(name: 'upper_arm'),
            Bone3D(name: 'forearm', parentIndex: 0, bindLocalZ: 1.0),
          ],
          boneIndices0: Uint16List.fromList(<int>[0, 0, 1]),
          boneIndices1: Uint16List.fromList(<int>[0, 1, 1]),
          boneWeights0: Float32List.fromList(<double>[1.0, 0.5, 0.0]),
        );

        // Rotate forearm +90 deg around +Y at the elbow (z = 1.0):
        // fingertip at bind (0, 0, 2) -> 1 unit above elbow -> (1, 0, 1)!
        final qBend90 = Quaternion3D.fromAxisAngle(0, 1, 0, math.pi / 2);
        skin.setBonePose(
          1,
          qx: qBend90.$1,
          qy: qBend90.$2,
          qz: qBend90.$3,
          qw: qBend90.$4,
        );
        expect(skin.evaluateIfDirty(), isTrue);

        expect(skin.skinnedPositions[0], closeTo(0.0, 1e-5));
        expect(skin.skinnedPositions[2], closeTo(0.0, 1e-5));
        expect(skin.skinnedPositions[3], closeTo(0.0, 1e-5));
        expect(skin.skinnedPositions[5], closeTo(1.0, 1e-5));
        expect(skin.skinnedNormals[3], closeTo(math.sqrt1_2, 1e-4));
        expect(skin.skinnedNormals[5], closeTo(-math.sqrt1_2, 1e-4));
        expect(skin.skinnedPositions[6], closeTo(1.0, 1e-5));
        expect(skin.skinnedPositions[7], closeTo(0.0, 1e-5));
        expect(skin.skinnedPositions[8], closeTo(1.0, 1e-5));

        final cam = CameraRig3D();
        final renderer = BatchMeshRenderer3D(backfaceCulling: false)
          ..beginBatch();
        root.enqueueHierarchy(renderer, camera: cam);
        renderer
          ..enqueueMorphMesh(morph, camera: cam, worldX: -2, worldY: 0)
          ..enqueueSkinnedMesh(skin, camera: cam, worldX: 2, worldY: 0);
        final rec = ui.PictureRecorder();
        renderer.flushBatch(ui.Canvas(rec));
        rec.endRecording().dispose();
        expect(renderer.lastFlushTriangles, greaterThan(12));

        skin.resetToBindPose();
        expect(skin.evaluateIfDirty(), isTrue);
        expect(skin.skinnedPositions[6], closeTo(0.0, 1e-5));
        expect(skin.skinnedPositions[8], closeTo(2.0, 1e-5));
      },
    );

    test(
      'Unlock #3: StaticMeshChunk3D preserves per-instance texture uvRectPx '
      'alongside MatCap instances and performs O(V_slot) partial slot rebakes',
      () async {
        final atlas = await _makeSplitRedGreenAtlas();
        final matCap = MatCapShader3D()..ensureInitialized();
        final atlasShader = ui.ImageShader(
          atlas,
          ui.TileMode.clamp,
          ui.TileMode.clamp,
          Float64List.fromList(<double>[
            1, 0, 0, 0, //
            0, 1, 0, 0, //
            0, 0, 1, 0, //
            0, 0, 0, 1, //
          ]),
        );

        try {
          final matAtlas = Material3D.texture(
            atlasShader,
            width: 32,
            height: 16,
          );
          const matGold = Material3D.matCap(
            MatCapPreset3D.metallicGold,
          );

          final cam = CameraRig3D(
            cellHalfW: 20.0,
            cellHalfH: 10.0,
            groundOriginY: 0.0,
          );
          final light = DirectionalLight3D(
            sunDirX: 0.0,
            sunDirY: 0.0,
            sunDirZ: 1.0,
            sunColor: const Color(0xFFFFFFFF),
            skyColor: const Color(0xFFFFFFFF),
            groundColor: const Color(0xFFFFFFFF),
            ambientIntensity: 1.0,
            diffuseIntensity: 0.0,
            rimIntensity: 0.0,
          );
          final renderer = BatchMeshRenderer3D(
            light: light,
            backfaceCulling: false,
          );
          final tile = Mesh3D.plane(sizeX: 1.4, sizeY: 1.4);
          const origin = Offset(-120, -80);

          final chunk = StaticMeshChunk3D();
          final slotLeftRed = chunk.addInstance(
            StaticMeshInstance3D(
              mesh: tile,
              worldX: -3.0,
              worldY: 0.0,
              uvRectPx: const Rect.fromLTWH(2, 2, 12, 12),
              material: matAtlas,
            ),
          );
          final slotMidGreen = chunk.add(
            StaticMeshInstance3D(
              mesh: tile,
              worldX: 0.0,
              worldY: 0.0,
              uvRectPx: const Rect.fromLTWH(18, 2, 12, 12),
              material: matAtlas,
            ),
          );
          final slotRightGold = chunk.addInstance(
            StaticMeshInstance3D(
              mesh: tile,
              worldX: 3.0,
              worldY: 0.0,
              material: matGold,
            ),
          );
          expect(slotLeftRed, 0);
          expect(slotMidGreen, 1);
          expect(slotRightGold, 2);

          final rgba1 = await _rasterizeRgba(240, 160, (canvas) {
            renderer
              ..beginBatch()
              ..enqueueStaticChunk(
                chunk,
                camera: cam,
                canvasOrigin: origin,
              )
              ..flushBatch(canvas, matCapShader: matCap);
          });

          expect(chunk.geometryBakeCount, 1);
          expect(chunk.partialSlotRebakeCount, 0);
          expect(chunk.visibleTriCount, 6);

          final pLeft = cam.projectWorldPoint(-3.0, 0.0, 0.0) - origin;
          final pMid = cam.projectWorldPoint(0.0, 0.0, 0.0) - origin;
          final pRight = cam.projectWorldPoint(3.0, 0.0, 0.0) - origin;

          // Left tile center -> pure RED from left half of atlas!
          final (lR, lG, lB, _) = _pixelAt(
            rgba1,
            240,
            pLeft.dx.round(),
            pLeft.dy.round(),
          );
          expect(lR, greaterThan(220));
          expect(lG, lessThan(25));
          expect(lB, lessThan(25));

          // Middle tile center -> pure GREEN from right half!
          final (mR, mG, mB, _) = _pixelAt(
            rgba1,
            240,
            pMid.dx.round(),
            pMid.dy.round(),
          );
          expect(mR, lessThan(25));
          expect(mG, greaterThan(220));
          expect(mB, lessThan(25));

          // Right tile center -> MatCap gold (non-black)!
          final (rR, rG, _, rA) = _pixelAt(
            rgba1,
            240,
            pRight.dx.round(),
            pRight.dy.round(),
          );
          expect(rA, 255);
          expect(rR + rG, greaterThan(180));

          // Surgical O(V_slot) update: flip middle tile's uvRectPx to the RED
          // half of the atlas without triggering a full geometry rebake!
          chunk.updateInstance(
            slotMidGreen,
            chunk
                .instanceAt(slotMidGreen)
                .copyWith(
                  uvRectPx: const Rect.fromLTWH(2, 2, 12, 12),
                ),
          );

          final rgba2 = await _rasterizeRgba(240, 160, (canvas) {
            renderer
              ..beginBatch()
              ..enqueueStaticChunk(
                chunk,
                camera: cam,
                canvasOrigin: origin,
              )
              ..flushBatch(canvas, matCapShader: matCap);
          });

          expect(chunk.geometryBakeCount, 1);
          expect(chunk.partialSlotRebakeCount, 1);
          final (m2R, m2G, _, _) = _pixelAt(
            rgba2,
            240,
            pMid.dx.round(),
            pMid.dy.round(),
          );
          expect(m2R, greaterThan(220));
          expect(m2G, lessThan(25));

          // Hide slot 0 via setInstanceVisible: O(1) partial slot rebake!
          chunk.setInstanceVisible(slotLeftRed, visible: false);
          chunk.prepare(
            camera: cam,
            light: light,
            canvasOrigin: origin,
            backfaceCulling: false,
          );
          expect(chunk.geometryBakeCount, 1);
          expect(chunk.partialSlotRebakeCount, 2);
          expect(chunk.visibleTriCount, 4);
        } finally {
          atlasShader.dispose();
          atlas.dispose();
          matCap.dispose();
        }
      },
    );

    test(
      'Unlock #4: cullBackfaceShadows halves shadow tris & prevents '
      'double-alpha darkening, shadowHeightFalloff softens high-Z shadows, '
      'and flushShadows/flushGeometry decouple multi-pass rendering',
      () async {
        final cam = CameraRig3D(
          cellHalfW: 24.0,
          cellHalfH: 12.0,
          groundOriginY: 0.0,
        );
        // Straight-down sun (0, 0, 1) projects box shadow directly onto ground
        // centered at world (0, 0, 0) -> canvas (80, 80) for origin (-80, -80).
        final light = DirectionalLight3D(
          sunDirX: 0.0,
          sunDirY: 0.0,
          sunDirZ: 1.0,
        );
        final box = Mesh3D.box(sizeX: 2.0, sizeY: 2.0);
        const origin = Offset(-80, -80);

        final culledRenderer = BatchMeshRenderer3D(
          light: light,
        );
        final unculledRenderer = BatchMeshRenderer3D(
          light: light,
          cullBackfaceShadows: false,
        );

        final rgbaCulled = await _rasterizeRgba(160, 160, (canvas) {
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 160, 160),
            ui.Paint()..color = const Color(0xFFFFFFFF),
          );
          culledRenderer
            ..beginBatch()
            ..enqueueMesh(
              box,
              camera: cam,
              worldX: 0,
              worldY: 0,
              worldZ: 1.0,
              canvasOrigin: origin,
              castGroundShadow: true,
              shadowColor: const Color(0xFF000000),
              shadowOpacity: 0.4,
            )
            ..flushShadows(canvas);
        });

        final rgbaUnculled = await _rasterizeRgba(160, 160, (canvas) {
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 160, 160),
            ui.Paint()..color = const Color(0xFFFFFFFF),
          );
          unculledRenderer
            ..beginBatch()
            ..enqueueMesh(
              box,
              camera: cam,
              worldX: 0,
              worldY: 0,
              worldZ: 1.0,
              canvasOrigin: origin,
              castGroundShadow: true,
              shadowColor: const Color(0xFF000000),
              shadowOpacity: 0.4,
            )
            ..flushShadows(canvas);
        });

        // Vertical sunlight culls both the 2 back-facing bottom triangles AND
        // the 8 zero-area grazing side-wall triangles -> 2 top-face triangles!
        expect(culledRenderer.lastFlushShadowTriangles, 2);
        expect(unculledRenderer.lastFlushShadowTriangles, 12);

        // Oblique sunlight (-0.45, -0.35, 0.82) lights 3 faces -> 6 tris!
        final obliqueRenderer =
            BatchMeshRenderer3D(
                light: DirectionalLight3D(),
              )
              ..beginBatch()
              ..enqueueMesh(
                box,
                camera: cam,
                worldX: 0,
                worldY: 0,
                worldZ: 1.0,
                canvasOrigin: origin,
                castGroundShadow: true,
              );
        final recOblique = ui.PictureRecorder();
        obliqueRenderer.flushShadows(ui.Canvas(recOblique));
        recOblique.endRecording().dispose();
        expect(obliqueRenderer.lastFlushShadowTriangles, 6);

        final (singleLum, _, _, _) = _pixelAt(rgbaCulled, 160, 80, 80);
        final (doubleLum, _, _, _) = _pixelAt(rgbaUnculled, 160, 80, 80);
        expect(singleLum, inInclusiveRange(140, 168));
        expect(doubleLum, lessThan(singleLum - 35));

        // 2. Height-attenuated shadow penumbra (shadowHeightFalloff > 0)
        final falloffRenderer = BatchMeshRenderer3D(
          light: light,
          shadowHeightFalloff: 0.8,
        );
        final rgbaLow = await _rasterizeRgba(160, 160, (canvas) {
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 160, 160),
            ui.Paint()..color = const Color(0xFFFFFFFF),
          );
          falloffRenderer
            ..beginBatch()
            ..enqueueMesh(
              box,
              camera: cam,
              worldX: 0,
              worldY: 0,
              worldZ: 0.5,
              canvasOrigin: origin,
              castGroundShadow: true,
              shadowColor: const Color(0xFF000000),
              shadowOpacity: 0.5,
            )
            ..flushShadows(canvas);
        });
        final rgbaHigh = await _rasterizeRgba(160, 160, (canvas) {
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 160, 160),
            ui.Paint()..color = const Color(0xFFFFFFFF),
          );
          falloffRenderer
            ..beginBatch()
            ..enqueueMesh(
              box,
              camera: cam,
              worldX: 0,
              worldY: 0,
              worldZ: 5.0,
              canvasOrigin: origin,
              castGroundShadow: true,
              shadowColor: const Color(0xFF000000),
              shadowOpacity: 0.5,
            )
            ..flushShadows(canvas);
        });
        final (lowShadowR, _, _, _) = _pixelAt(rgbaLow, 160, 80, 80);
        final (highShadowR, _, _, _) = _pixelAt(rgbaHigh, 160, 80, 80);
        expect(highShadowR, greaterThan(lowShadowR + 40));

        // 3. Split multi-pass flushShadows() -> flushGeometry()
        final splitRenderer = BatchMeshRenderer3D(light: DirectionalLight3D())
          ..beginBatch()
          ..enqueueMesh(
            box,
            camera: cam,
            worldX: 0,
            worldY: 0,
            worldZ: 1.0,
            canvasOrigin: origin,
            tint: const Color(0xFF2288FF),
            castGroundShadow: true,
          );
        expect(splitRenderer.pendingShadowTriangleCount, 6);
        expect(splitRenderer.pendingGeometryTriangleCount, greaterThan(0));

        final recShadow = ui.PictureRecorder();
        final shadowDraws = splitRenderer.flushShadows(ui.Canvas(recShadow));
        recShadow.endRecording().dispose();
        expect(shadowDraws, 1);
        expect(splitRenderer.pendingShadowTriangleCount, 0);
        expect(splitRenderer.pendingGeometryTriangleCount, greaterThan(0));

        final recGeo = ui.PictureRecorder();
        final geoDraws = splitRenderer.flushGeometry(ui.Canvas(recGeo));
        recGeo.endRecording().dispose();
        expect(geoDraws, 1);
        expect(splitRenderer.pendingGeometryTriangleCount, 0);
      },
    );

    test(
      'Combined stress: enqueueMesh rotationQuat vs rotationMatrix3 pixel '
      'parity, chunk Material3D swap + topology-change fallback + shadow '
      'backface/falloff parity',
      () async {
        final cam = CameraRig3D(
          cellHalfW: 22.0,
          cellHalfH: 12.0,
          groundOriginY: 0.0,
        );
        final light = DirectionalLight3D(
          sunDirX: 0.0,
          sunDirY: 0.0,
          sunDirZ: 1.0,
        );
        const origin = Offset(-100, -100);
        final box = Mesh3D.box(sizeX: 1.6, sizeZ: 1.2);
        final qArbitrary = Quaternion3D.fromAxisAngle(0.4, -0.7, 0.5, 1.15);
        final mArbitrary = Float32List(9);
        Quaternion3D.writeMatrix3(
          qArbitrary.$1,
          qArbitrary.$2,
          qArbitrary.$3,
          qArbitrary.$4,
          mArbitrary,
        );

        final rgbaQuat = await _rasterizeRgba(200, 200, (canvas) {
          BatchMeshRenderer3D(light: light)
            ..beginBatch()
            ..enqueueMesh(
              box,
              camera: cam,
              worldX: 0,
              worldY: 0,
              worldZ: 1.0,
              rotationQuat: qArbitrary,
              canvasOrigin: origin,
              tint: const Color(0xFF40A0FF),
            )
            ..flushBatch(canvas);
        });

        final rgbaMat = await _rasterizeRgba(200, 200, (canvas) {
          BatchMeshRenderer3D(light: light)
            ..beginBatch()
            ..enqueueMesh(
              box,
              camera: cam,
              worldX: 0,
              worldY: 0,
              worldZ: 1.0,
              rotationMatrix3: mArbitrary,
              canvasOrigin: origin,
              tint: const Color(0xFF40A0FF),
            )
            ..flushBatch(canvas);
        });

        // Pixel-for-pixel identical rendering between rotationQuat and
        // rotationMatrix3!
        for (var i = 0; i < rgbaQuat.lengthInBytes; i++) {
          expect(rgbaQuat.getUint8(i), rgbaMat.getUint8(i));
        }

        // StaticMeshChunk3D: switch material from unshaded blue -> MatCap gold
        // via partial slot rebake, then swap to a higher-poly sphere to verify
        // topology-change full-rebake fallback + chunk shadow backface culling!
        final matCap = MatCapShader3D()..ensureInitialized();
        try {
          final chunk = StaticMeshChunk3D();
          final slot = chunk.addInstance(
            StaticMeshInstance3D(
              mesh: box,
              worldX: 0,
              worldY: 0,
              worldZ: 1.5,
              rotationQuat: qArbitrary,
              tint: const Color(0xFF2060FF),
              material: const Material3D.unshaded(),
              castGroundShadow: true,
            ),
          );
          final chunkRenderer = BatchMeshRenderer3D(
            light: light,
            shadowHeightFalloff: 0.5,
          );
          final rec1 = ui.PictureRecorder();
          chunkRenderer
            ..beginBatch()
            ..enqueueStaticChunk(chunk, camera: cam, canvasOrigin: origin)
            ..flushBatch(ui.Canvas(rec1), matCapShader: matCap);
          rec1.endRecording().dispose();

          expect(chunk.geometryBakeCount, 1);
          expect(chunk.partialSlotRebakeCount, 0);
          // Culled chunk shadows for rotated box under vertical light < 12!
          expect(chunk.projectedShadowTriCount, lessThan(12));
          expect(chunk.projectedShadowTriCount, greaterThan(0));

          // Partial O(V_slot) Material3D swap to MatCap gold!
          chunk.updateInstance(
            slot,
            chunk
                .instanceAt(slot)
                .copyWith(
                  material: const Material3D.matCap(
                    MatCapPreset3D.metallicGold,
                  ),
                ),
          );
          final rec2 = ui.PictureRecorder();
          chunkRenderer
            ..beginBatch()
            ..enqueueStaticChunk(chunk, camera: cam, canvasOrigin: origin)
            ..flushBatch(ui.Canvas(rec2), matCapShader: matCap);
          rec2.endRecording().dispose();
          expect(chunk.geometryBakeCount, 1);
          expect(chunk.partialSlotRebakeCount, 1);

          // Topology upgrade (box -> uvSphere) triggers clean full rebake!
          final sphere = Mesh3D.uvSphere(radius: 0.9);
          chunk.updateInstance(
            slot,
            chunk.instanceAt(slot).copyWith(mesh: sphere),
          );
          final rec3 = ui.PictureRecorder();
          chunkRenderer
            ..beginBatch()
            ..enqueueStaticChunk(chunk, camera: cam, canvasOrigin: origin)
            ..flushBatch(ui.Canvas(rec3), matCapShader: matCap);
          rec3.endRecording().dispose();
          expect(chunk.geometryBakeCount, 2);
          expect(chunk.visibleTriCount, greaterThan(12));
        } finally {
          matCap.dispose();
        }
      },
    );
  });
}
