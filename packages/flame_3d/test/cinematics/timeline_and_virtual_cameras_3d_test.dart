import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/cinematics.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter/animation.dart' show Curves;
import 'package:flutter_test/flutter_test.dart';

class _TargetActor({super.position}) extends Component3D;

ModelComponent _buildMorphAndAnimActor() {
  final stride = VertexLayout.standard.strideInFloats;
  final baseVerts = Float32List(3 * stride)
    ..[stride] = 1.0
    ..[2 * stride + 1] = 1.0;
  final surface = Surface.fromBuffers(
    vertices: baseVerts,
    indices: Uint16List.fromList(const [0, 1, 2]),
    morphTargets: [
      MorphTargetData(
        name: 'Smile',
        positionDeltas: Float32List.fromList(const [
          4.0, 0.0, 0.0, //
          0.0, 0.0, 0.0, //
          0.0, 0.0, 0.0, //
        ]),
      ),
    ],
  );
  final mesh = Mesh()..addSurface(surface);

  final waveClip = ModelAnimation(
    name: 'wave',
    nodes: {
      0: NodeAnimation(
        channels: [
          AnimationController(
            animation: TranslationAnimationSpline.from(
              interpolation: AnimationInterpolation.linear,
              times: const [0.0, 2.0],
              values: [Vector3.zero(), Vector3(0.0, 6.0, 0.0)],
            ),
          ),
        ],
      ),
    },
  );

  final model = Model(
    nodes: {
      0: ModelNode(
        name: 'Head',
        nodeIndex: 0,
        parentNodeIndex: null,
        transform: Matrix4.identity(),
        mesh: mesh,
        joints: const {},
      ),
    },
    animations: [waveClip],
  );
  return ModelComponent(model: model);
}

void main() {
  group('VirtualCamera3D & VirtualCameraBrain3D', () {
    test(
      'selects highest-priority enabled camera, aims at lookAtTarget with '
      'damping, and shortest-arc cross-blends position / rotation / fovY',
      () {
        final actor = _TargetActor(position: Vector3(0.0, 2.0, 0.0));
        final wideShot = VirtualCamera3D(
          priority: 10,
          fovY: 70.0,
          position: Vector3(0.0, 2.0, 10.0),
          lookAtTarget: actor,
        );
        // Close-up shot rotated -90 deg around Y (passed as negated `-q` to
        // verify shortest-arc SLERP!).
        final closeRot = Quaternion.axisAngle(
          Vector3(0.0, 1.0, 0.0),
          math.pi * 0.5,
        )..scale(-1.0);
        final closeUp = VirtualCamera3D(
          priority: 25,
          enabled: false,
          fovY: 38.0,
          position: Vector3(4.0, 2.0, 0.0),
          rotation: closeRot,
        );

        final outputCam = CameraComponent3D(
          viewport: FixedSizeViewport(800, 600),
        );
        final brain = VirtualCameraBrain3D(
          camera: outputCam,
          cameras: [wideShot, closeUp],
          blendDuration: 1.0,
          blendCurve: Curves.linear,
        );

        // 1. Initial evaluation cuts straight to `wideShot` (`priority: 10`).
        brain.update(0.016);
        expect(brain.activeCamera, same(wideShot));
        expect(brain.isBlending, isFalse);
        expect(
          outputCam.position,
          closeToVector3(Vector3(0.0, 2.0, 10.0), 1e-4),
        );
        expect(outputCam.fovY, closeTo(70.0, 1e-4));
        final fwd0 = outputCam.forward..normalize();
        expect(fwd0, closeToVector3(Vector3(0.0, 0.0, -1.0), 1e-4));

        // 2. Enabling higher-priority `closeUp` (`25 > 10`) starts a 1.0s
        // linear cross-blend!
        closeUp.enabled = true;
        brain.update(0.5);
        expect(brain.activeCamera, same(closeUp));
        expect(brain.previousCamera, same(wideShot));
        expect(brain.isBlending, isTrue);
        expect(brain.blendProgress, closeTo(0.5, 1e-4));
        expect(
          outputCam.position,
          closeToVector3(Vector3(2.0, 2.0, 5.0), 1e-4),
        );
        expect(outputCam.fovY, closeTo(54.0, 1e-4));

        // Shortest-arc 45 deg midway between `-Z` and `-X` (`Ry(+90 deg)` maps
        // `(0, 0, -1)` to `(-1, 0, 0)` -> midway is `(-0.7071, 0, -0.7071)`!).
        final midFwd = outputCam.forward..normalize();
        expect(midFwd.x, closeTo(-math.sqrt1_2, 1e-3));
        expect(midFwd.z, closeTo(-math.sqrt1_2, 1e-3));

        // 3. Finishing the remaining `0.5s` settles cleanly onto `closeUp`.
        brain.update(0.5);
        expect(brain.isBlending, isFalse);
        expect(
          outputCam.position,
          closeToVector3(Vector3(4.0, 2.0, 0.0), 1e-4),
        );
        expect(outputCam.fovY, closeTo(38.0, 1e-4));

        // 4. Verify `damping` on `wideShot` when `actor` moves!
        closeUp.enabled = false;
        brain.blendDuration = 0.0;
        wideShot.damping = 10.0;
        brain.update(0.016);
        wideShot.position.setValues(10.0, 2.0, 10.0);
        brain.update(0.05);
        expect(outputCam.position.x, greaterThan(1.0));
        expect(outputCam.position.x, lessThan(9.0));
      },
    );
  });

  group('Timeline3D multi-track deterministic cutscene sequencer', () {
    test(
      'drives CameraShotTrack3D, TransformTrack3D (linear & Hermite), '
      'AnimationClipTrack3D, MorphWeightTrack3D, and directional EventMarkers',
      () {
        final actor = _buildMorphAndAnimActor();
        final prop = _TargetActor();

        final camA = VirtualCamera3D(
          enabled: false,
          fovY: 65.0,
          position: Vector3(0.0, 1.0, 8.0),
        );
        final camB = VirtualCamera3D(
          enabled: false,
          fovY: 42.0,
          position: Vector3(3.0, 2.0, 4.0),
        );
        final outputCam = CameraComponent3D(
          viewport: FixedSizeViewport(800, 600),
        );
        final brain = VirtualCameraBrain3D(
          camera: outputCam,
          cameras: [camA, camB],
          blendDuration: 0.4,
          blendCurve: Curves.linear,
        );

        final shotTrack = CameraShotTrack3D(
          shots: [
            CameraShot3D(camera: camA, startTime: 0.0, endTime: 1.5),
            CameraShot3D(camera: camB, startTime: 1.5, endTime: 3.0),
          ],
        );

        final transformTrack = TransformTrack3D(
          target: prop,
          positionKeys: [
            TransformKeyframe3D<Vector3>(
              time: 0.0,
              value: Vector3.zero(),
              interpolation: TimelineInterpolation3D.cubicHermite,
              outTangent: Vector3(4.0, 0.0, 0.0),
            ),
            TransformKeyframe3D<Vector3>(
              time: 2.0,
              value: Vector3(10.0, 0.0, 0.0),
              inTangent: Vector3.zero(),
            ),
          ],
          rotationKeys: [
            TransformKeyframe3D<Quaternion>(
              time: 0.0,
              value: Quaternion.identity(),
            ),
            TransformKeyframe3D<Quaternion>(
              time: 2.0,
              value: Quaternion.axisAngle(
                Vector3(0.0, 1.0, 0.0),
                math.pi * 0.5,
              ),
            ),
          ],
          scaleKeys: [
            TransformKeyframe3D<Vector3>(
              time: 0.0,
              value: Vector3.all(1.0),
            ),
            TransformKeyframe3D<Vector3>(
              time: 2.0,
              value: Vector3.all(3.0),
            ),
          ],
        );

        final animTrack = AnimationClipTrack3D(
          target: actor,
          clips: [
            AnimationClipSpan3D(
              animation: actor.model.animations.single,
              startTime: 0.5,
              endTime: 2.5,
            ),
          ],
        );

        final morphTrack = MorphWeightTrack3D(
          target: actor,
          keyframes: [
            MorphWeightKeyframe3D(time: 0.0, weights: const [0.0]),
            MorphWeightKeyframe3D(time: 2.0, weights: const [0.75]),
          ],
        );

        final markerLog = <String>[];
        final markerTrack = EventMarkerTrack3D(
          onMarker: (m, dir) => markerLog.add('${dir.name}:${m.name}'),
          markers: [
            EventMarker3D(name: 'intro', time: 0.0),
            EventMarker3D(name: 'cut_b', time: 1.5),
            EventMarker3D(name: 'outro', time: 3.0),
          ],
        );

        var completedCount = 0;
        final timeline = Timeline3D(
          tracks: [
            shotTrack,
            transformTrack,
            animTrack,
            morphTrack,
            markerTrack,
          ],
          onComplete: () => completedCount++,
        );
        expect(timeline.duration, closeTo(3.0, 1e-6));

        // 1. Play forward to `t = 1.0s`.
        timeline
          ..play()
          ..update(1.0);
        brain.update(0.016);

        expect(timeline.currentTime, closeTo(1.0, 1e-6));
        expect(markerLog, ['forward:intro']);
        expect(camA.enabled, isTrue);
        expect(camB.enabled, isFalse);
        expect(brain.activeCamera, same(camA));

        // Cubic Hermite on `[0..2]` at `t = 1.0` (`u = 0.5`, `dt = 2.0`,
        // `v0 = 0`, `b0 = 4`, `v1 = 10`, `a1 = 0`):
        // `h10 = (0.125 - 0.5 + 0.5) * 2 = 0.25`, `h01 = 0.5`
        // -> `x = 0.25 * 4 + 0.5 * 10 = 6.0`!
        expect(prop.position.x, closeTo(6.0, 1e-4));
        expect(prop.scale.x, closeTo(2.0, 1e-4));

        // AnimationClipTrack3D at `t = 1.0` (`0.5s` into `2.0s` wave -> 25% of
        // `6.0` = `1.5` Y!).
        expect(actor.nodeTransform(0)!.getTranslation().y, closeTo(1.5, 1e-4));

        // MorphWeightTrack3D at `t = 1.0`: weight `0.375` * `4.0` = `1.5`!
        final headMesh = actor.nodeMesh(0)!;
        expect(headMesh.surfaces.first.vertexData[0], closeTo(1.5, 1e-4));

        // 2. Advance past `1.5s` to `2.0s` -> switches shot to `camB` and fires
        // `forward:cut_b`!
        timeline.update(1.0);
        brain.update(0.2);
        expect(markerLog, ['forward:intro', 'forward:cut_b']);
        expect(camA.enabled, isFalse);
        expect(camB.enabled, isTrue);
        expect(brain.activeCamera, same(camB));
        expect(brain.isBlending, isTrue);

        // 3. Pause holds time steady; Seek backward from `2.0s -> 1.0s` fires
        // `backward:cut_b` and deterministically scrubs every track!
        timeline
          ..pause()
          ..update(0.5);
        expect(timeline.currentTime, closeTo(2.0, 1e-6));

        markerLog.clear();
        timeline.seek(1.0);
        expect(markerLog, ['backward:cut_b']);
        expect(prop.position.x, closeTo(6.0, 1e-4));
        expect(actor.nodeTransform(0)!.getTranslation().y, closeTo(1.5, 1e-4));

        // 4. Seek forward `1.0s -> 3.0s` fires `cut_b` and `outro` in order;
        // finishing playback invokes `onComplete`, and `loop = true` wraps!
        markerLog.clear();
        timeline.seek(2.5);
        expect(markerLog, ['forward:cut_b']);
        timeline
          ..play()
          ..update(0.6);
        expect(completedCount, 1);
        expect(timeline.isPlaying, isFalse);

        markerLog.clear();
        timeline
          ..loop = true
          ..stop()
          ..play()
          ..update(3.6);
        expect(timeline.currentTime, closeTo(0.6, 1e-5));
        expect(
          markerLog,
          ['forward:intro', 'forward:cut_b', 'forward:outro', 'forward:intro'],
        );
      },
    );
  });
}
