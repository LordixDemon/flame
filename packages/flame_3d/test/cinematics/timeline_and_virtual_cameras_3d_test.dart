import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart' as flame show Component;
import 'package:flame/game.dart' show FlameGame;
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

  group('VirtualCameraBrain3D discovery', () {
    testWithGame(
      'finds the cameras of its world without walking it',
      () => FlameGame(world: World3D()),
      (game) async {
        final world = game.world;
        final near = VirtualCamera3D(priority: 1);
        final far = VirtualCamera3D(priority: 5, position: Vector3(0, 0, 9));
        // Many components, and the cameras nested in them.
        final groups = [
          for (var i = 0; i < 200; i++)
            Group3D(
              children: [
                for (var j = 0; j < 50; j++) Group3D(),
              ],
            ),
        ];
        groups[10].add(Group3D(children: [near]));
        groups[150].add(far);
        await world.ensureAddAll(groups);
        await game.ready();
        final output = CameraComponent3D(
          viewport: FixedSizeViewport(100, 100),
        );
        final brain = VirtualCameraBrain3D(camera: output, world: world)
          ..evaluate(0);
        expect(brain.activeCamera, same(far));

        // Removing a camera removes it from the candidates.
        far.removeFromParent();
        await game.ready();
        brain.evaluate(0);
        expect(brain.activeCamera, same(near));

        // An evaluation costs far less than walking the world's 10,000
        // components once, which it used to do.
        void walk(flame.Component c) {
          for (final child in c.children) {
            walk(child);
          }
        }

        final walkTime = Stopwatch()..start();
        for (var i = 0; i < 20; i++) {
          walk(world);
        }
        walkTime.stop();
        final evaluateTime = Stopwatch()..start();
        for (var i = 0; i < 20; i++) {
          brain.evaluate(1 / 60);
        }
        evaluateTime.stop();
        expect(
          evaluateTime.elapsedMicroseconds,
          lessThan(walkTime.elapsedMicroseconds / 4),
        );
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

  group('Timeline3D playback', () {
    test('plays backward from the end, after a seek or from the start', () {
      final log = <String>[];
      Timeline3D build() => Timeline3D(
        speed: -1,
        tracks: [
          EventMarkerTrack3D(
            onMarker: (m, dir) => log.add('${dir.name}:${m.name}'),
            markers: [
              EventMarker3D(name: 'start', time: 0),
              EventMarker3D(name: 'middle', time: 1),
              EventMarker3D(name: 'end', time: 2),
            ],
          ),
        ],
      );

      var completed = 0;
      final timeline = build()..onComplete = () => completed++;
      timeline
        ..seek(2, fireEvents: false)
        ..play()
        ..update(0.5);
      expect(timeline.currentTime, closeTo(1.5, 1e-9));
      expect(timeline.isPlaying, isTrue);
      expect(completed, 0);
      timeline.update(2);
      expect(timeline.currentTime, 0);
      expect(completed, 1);
      expect(log, ['backward:middle', 'backward:start']);

      // Playing backward again from the start begins at the end.
      log.clear();
      timeline
        ..play()
        ..update(0.25);
      expect(timeline.currentTime, closeTo(1.75, 1e-9));
      expect(log, ['backward:end']);

      // A fresh timeline with a negative speed plays from its end.
      final fresh = build()..play();
      expect(fresh.currentTime, 2);
      fresh.update(0.5);
      expect(fresh.currentTime, closeTo(1.5, 1e-9));
    });

    test('AnimationClipTrack3D holds the model clock inside its spans', () {
      final actor = _buildMorphAndAnimActor();
      final track = AnimationClipTrack3D(
        target: actor,
        clips: [
          AnimationClipSpan3D(
            animation: actor.model.animations.single,
            startTime: 0,
            endTime: 2,
          ),
        ],
      );
      final timeline = Timeline3D(tracks: [track], duration: 3);
      double headY() => actor.nodeTransform(0)!.getTranslation().y;

      // Paused inside the span, the model does not advance the clip.
      timeline.seek(0.5);
      expect(headY(), closeTo(1.5, 1e-9));
      actor.update(0.5);
      expect(headY(), closeTo(1.5, 1e-9));
      expect(actor.animationState.speed, 0);

      // Outside every span the model gets its speed back and plays on from
      // where the timeline left it.
      timeline.seek(2.5);
      expect(actor.animationState.speed, 1);
      actor.update(0.5);
      expect(headY(), closeTo(3, 1e-9));

      // Back in a span, then released at once.
      timeline.seek(1);
      expect(actor.animationState.speed, 0);
      track.releaseModelClock();
      expect(actor.animationState.speed, 1);
    });

    testWithGame(
      'a removed timeline gives the model its clock back',
      FlameGame.new,
      (game) async {
        final actor = _buildMorphAndAnimActor()..animationState.speed = 2;
        final timeline = Timeline3D(
          tracks: [
            AnimationClipTrack3D(
              target: actor,
              clips: [
                AnimationClipSpan3D(
                  animation: actor.model.animations.single,
                  startTime: 0,
                ),
              ],
            ),
          ],
        );
        await game.ensureAdd(timeline);
        timeline.seek(1);
        expect(actor.animationState.speed, 0);
        timeline.removeFromParent();
        await game.ready();
        expect(actor.animationState.speed, 2);
      },
    );

    test('CameraShotTrack3D gives the blend duration override back', () {
      final camA = VirtualCamera3D(enabled: false);
      final camB = VirtualCamera3D(enabled: false, blendDurationOverride: 2);
      final track = CameraShotTrack3D(
        shots: [
          CameraShot3D(
            camera: camA,
            startTime: 0,
            endTime: 1,
            blendDurationOverride: 0,
          ),
          CameraShot3D(
            camera: camB,
            startTime: 1,
            endTime: 2,
            blendDurationOverride: 0.25,
          ),
        ],
      );
      track.evaluate(0.5);
      expect(camA.blendDurationOverride, 0);
      expect(camB.blendDurationOverride, 2);
      track.evaluate(1.5);
      expect(camA.blendDurationOverride, isNull);
      expect(camB.blendDurationOverride, 0.25);
      expect(camA.enabled, isFalse);
      expect(camB.enabled, isTrue);
      // Outside every shot the cameras are disabled with their own values.
      track.evaluate(2.5);
      expect(camB.enabled, isFalse);
      expect(camB.blendDurationOverride, 2);
    });

    test('TransformTrack3D uses a single quaternion tangent as vectors do', () {
      final prop = _TargetActor();
      TransformTrack3D(
        target: prop,
        rotationKeys: [
          TransformKeyframe3D<Quaternion>(
            time: 0,
            value: Quaternion.identity(),
            interpolation: TimelineInterpolation3D.cubicHermite,
            outTangent: Quaternion(0, 1, 0, 0),
          ),
          TransformKeyframe3D<Quaternion>(
            time: 2,
            value: Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 2),
          ),
        ],
      ).evaluate(1);
      // Hermite with a zero incoming tangent: about 70.5 degrees, where a
      // smoothstep slerp would give 45.
      final q = prop.rotation;
      expect(2 * math.atan2(q.y, q.w), closeTo(1.23096, 1e-4));
    });
  });
}
