import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flame/rendering.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _testSpriteImageSync() {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    const Rect.fromLTWH(0, 0, 32, 8),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(32, 8);
  } finally {
    pic.dispose();
  }
}

void main() {
  group('RibbonTrailComponent, SplineStripMesh2D & VerletRope2D', () {
    test('RibbonTrailComponent ring-buffer wraparound, aging & render', () {
      var target = Vector2(0, 0);
      final trail = RibbonTrailComponent(
        maxPoints: 6,
        lifetime: 0.30,
        minPointDistance: 4.0,
        targetProvider: () => target,
      );

      // Push 10 points into maxPoints=6 ring buffer -> wraps cleanly!
      for (var i = 0; i < 10; i++) {
        target = Vector2(i * 10.0, math.sin(i.toDouble()) * 5.0);
        trail.update(0.02);
      }
      expect(trail.pointCount, 6);

      // Sub-threshold jitter is ignored unless force == true.
      trail.addPointXY(90.5, 0.0);
      expect(trail.pointCount, 6);
      trail.addPointXY(90.5, 0.0, force: true);
      expect(trail.pointCount, 6);

      final rec = ui.PictureRecorder();
      trail.render(ui.Canvas(rec));
      rec.endRecording().dispose();

      // Advance past lifetime (without moving target) -> old points expire.
      trail.targetProvider = null;
      trail.update(0.5);
      expect(trail.pointCount, 0);
    });

    test(
      'SplineStripMesh2D degenerate guard & VerletRope2D catenary constraints',
      () {
        final empty = SplineStripMesh2D.fromCatmullRom(
          controlPoints: <Vector2>[Vector2.zero()],
        );
        expect(empty.sampleCount, 0);

        final river = SplineStripMesh2D.fromCatmullRom(
          controlPoints: <Vector2>[
            Vector2(0, 0),
            Vector2(40, 20),
            Vector2(90, -10),
            Vector2(140, 15),
          ],
          subdivisionsPerSegment: 6,
          startWidth: 18,
          endWidth: 8,
        );
        expect(river.sampleCount, 3 * 6 + 1);
        final rec = ui.PictureRecorder();
        river.render(ui.Canvas(rec));
        rec.endRecording().dispose();

        // Bridge rope pinned at both ends sags downward under +Y gravity while
        // preserving pinned endpoints and converged segment lengths!
        final rope = VerletRope2D(
          nodeCount: 9,
          start: Vector2(0, 0),
          end: Vector2(80, 0),
          constraintIterations: 16,
          pinEnd: true,
        );
        for (var i = 0; i < 90; i++) {
          rope.step(1 / 60);
        }
        expect(rope.posX[0], 0.0);
        expect(rope.posY[0], 0.0);
        expect(rope.posX[8], 80.0);
        expect(rope.posY[8], 0.0);
        expect(rope.posY[4], greaterThan(15.0)); // catenary sag at midpoint!
        for (var i = 0; i < 8; i++) {
          final dx = rope.posX[i + 1] - rope.posX[i];
          final dy = rope.posY[i + 1] - rope.posY[i];
          expect(math.sqrt(dx * dx + dy * dy), closeTo(12.0, 0.6));
        }
      },
    );
  });

  group(
    'SpriteAnimationTicker, Socket, SpringBone & AnimationStateTree',
    () {
      test(
        'SpriteAnimationTicker multi-loop dt spike, frame events & jumpToFrame',
        () {
          final img = _testSpriteImageSync();
          try {
            final anim = SpriteAnimation.fromFrameData(
              img,
              SpriteAnimationData.sequenced(
                amount: 4,
                stepTime: 0.1,
                textureSize: Vector2(8, 8),
              ),
            );
            final events = <String>[];
            final ticker = anim.createTicker()
              ..registerFrameEvent(1, 'footstep_l')
              ..registerFrameEvent(3, 'footstep_r')
              ..onEvent = (idx, name) => events.add('$idx:$name');

            // Single huge dt = 0.85s spans 2 full loops + frame 0 of loop 3!
            ticker.update(0.85);
            expect(
              events,
              <String>[
                '1:footstep_l',
                '3:footstep_r',
                '1:footstep_l',
                '3:footstep_r',
              ],
            );

            events.clear();
            ticker.jumpToFrame(3);
            expect(ticker.currentIndex, 3);
            expect(events, isEmpty);

            ticker.jumpToFrame(1, emitEvents: true);
            expect(ticker.currentIndex, 1);
            expect(events, <String>['1:footstep_l']);

            // Non-looping animation completes and jumpToFrame re-arms `_done`.
            final oneShot = SpriteAnimation.fromFrameData(
              img,
              SpriteAnimationData.sequenced(
                amount: 2,
                stepTime: 0.1,
                textureSize: Vector2(8, 8),
                loop: false,
              ),
            ).createTicker()..update(0.5);
            expect(oneShot.done(), isTrue);
            oneShot.jumpToFrame(0);
            expect(oneShot.done(), isFalse);
          } finally {
            img.dispose();
          }
        },
      );

      test(
        'AttachmentSocket2D, SpringBone2D/3D stability & AnimationStateTree',
        () {
          final host = PositionComponent(
            position: Vector2(100, 200),
            scale: Vector2(2.0, 2.0),
            angle: math.pi / 2,
          );
          final weapon = PositionComponent();
          final socket = AttachmentSocket2D(
            name: 'hand_r',
            localOffset: Vector2(10, 0),
            localAngle: 0.25,
            localScale: Vector2(0.5, 0.5),
          )..syncFollower(host, weapon);
          expect(socket.name, 'hand_r');
          // Local (10, 0) * scale 2 = (20, 0) rotated +90 deg -> (0, +20)!
          expect(weapon.position.x, closeTo(100.0, 1e-5));
          expect(weapon.position.y, closeTo(220.0, 1e-5));
          expect(weapon.angle, closeTo(math.pi / 2 + 0.25, 1e-5));
          expect(weapon.scale, Vector2(1.0, 1.0));

          // SpringBone2D & SpringBone3D clamp displacements cleanly under huge
          // dt spikes and settle back to zero when anchor stops moving.
          final sb2 = SpringBone2D(maxDisplacement: 20.0)
            ..update(0.016, 0, 0)
            ..update(5.0, 500, -300); // extreme frame spike + teleport!
          final peak2 = math.sqrt(
            sb2.offsetX * sb2.offsetX + sb2.offsetY * sb2.offsetY,
          );
          expect(peak2, lessThanOrEqualTo(20.0 + 1e-5));
          for (var i = 0; i < 120; i++) {
            sb2.update(1 / 60, 500, -300);
          }
          final settled2 = math.sqrt(
            sb2.offsetX * sb2.offsetX + sb2.offsetY * sb2.offsetY,
          );
          expect(settled2, lessThan(0.5));

          final sb3 = SpringBone3D(maxDisplacement: 1.2)
            ..update(0.016, 0, 0, 0)
            ..update(2.0, 50, 50, 50);
          final mag3 = math.sqrt(
            sb3.offsetX * sb3.offsetX +
                sb3.offsetY * sb3.offsetY +
                sb3.offsetZ * sb3.offsetZ,
          );
          expect(mag3, lessThanOrEqualTo(1.2 + 1e-5));

          // AnimationStateTree one-shot auto-return & mid-swing interruption!
          final img = _testSpriteImageSync();
          try {
            final idleAnim = SpriteAnimation.fromFrameData(
              img,
              SpriteAnimationData.sequenced(
                amount: 2,
                stepTime: 0.1,
                textureSize: Vector2(8, 8),
              ),
            );
            final attackAnim = SpriteAnimation.fromFrameData(
              img,
              SpriteAnimationData.sequenced(
                amount: 2,
                stepTime: 0.1,
                textureSize: Vector2(8, 8),
                loop: false,
              ),
            );
            final tree = AnimationStateTree<String>(initialState: 'idle')
              ..registerState('idle', idleAnim)
              ..registerState('run', idleAnim)
              ..registerState('attack', attackAnim)
              ..playOneShot('attack');
            expect(tree.currentState, 'attack');
            tree.update(0.25);
            expect(tree.currentState, 'idle'); // auto-returned!

            // Interrupting a one-shot via transitionTo cancels returnTo!
            tree
              ..playOneShot('attack')
              ..transitionTo('run')
              ..update(0.25);
            expect(tree.currentState, 'run');
          } finally {
            img.dispose();
          }
        },
      );
    },
  );

  group('Light2DLayer, StandardEffects & OutlineDecorator', () {
    test(
      'Light2DLayer extrudes shadows & guards coincident light safely',
      () {
        final occluderBox = ShadowOccluder2D.rect(
          const Rect.fromLTWH(40, 40, 20, 20),
        );
        final occluderWall = ShadowOccluder2D.segment(
          Vector2(10, 10),
          Vector2(30, 10),
        );
        final path = Path();
        // Light coinciding with segment endpoint `(10, 10)` skips degenerate
        // edge safely without NaN!
        expect(
          occluderWall.appendShadowQuads(
            lx: 10,
            ly: 10,
            radius: 100,
            extrudeDistance: 200,
            outPath: path,
          ),
          0,
        );

        final layer = Light2DLayer(bounds: const Rect.fromLTWH(0, 0, 256, 256))
          ..pointLights.add(
            PointLight2D(
              position: Vector2(20, 50),
              radius: 150,
              flickerAmplitude: 0.25,
            ),
          )
          ..spotLights.add(
            SpotLight2D(position: Vector2(100, 100), radius: 140),
          )
          ..occluders.addAll(<ShadowOccluder2D>[occluderBox, occluderWall])
          ..update(0.1);
        final rec = ui.PictureRecorder();
        layer.render(ui.Canvas(rec));
        rec.endRecording().dispose();
        expect(layer.lastRenderedLights, 2);
        expect(layer.lastShadowQuads, greaterThan(0));
      },
    );

    test(
      'ColorGradingPresets, PostProcess effects & OutlineDecorator render',
      () {
        for (final preset in ColorGradingPreset.values) {
          final grade = ColorGradingPostProcess(
            preset: preset,
            exposure: 0.2,
            contrast: 1.1,
            saturation: 1.05,
            temperature: -0.15,
          );
          final mat = grade.computeColorMatrix();
          expect(mat.length, 20);
          expect(mat.any((v) => v.isNaN || v.isInfinite), isFalse);
        }

        final outline = OutlineDecorator(thickness: 3.0);
        final rec = ui.PictureRecorder();
        final canvas = ui.Canvas(rec);
        outline.applyBounded(
          (c) => c.drawCircle(
            const Offset(20, 20),
            8,
            Paint()..color = const Color(0xFF42A5F5),
          ),
          canvas,
          const Rect.fromLTWH(8, 8, 24, 24),
        );
        outline.enabled = false;
        outline.apply(
          (c) => c.drawRect(const Rect.fromLTWH(0, 0, 5, 5), Paint()),
          canvas,
        );
        rec.endRecording().dispose();
      },
    );
  });
}
