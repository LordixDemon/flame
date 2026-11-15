import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/post_process.dart';
import 'package:flame/rendering.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _makeTinyImageSync(int w, int h, Color color) {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(w, h);
  } finally {
    pic.dispose();
  }
}

void main() {
  group(
    'Ribbons, Verlet, Sockets/SpringBones/AnimTree, Light2D, Effects & 3D UV',
    () {
      test(
        'RibbonTrailComponent, SplineStripMesh2D & VerletRope2D simulate and '
        'render cleanly',
        () {
          final trail =
              RibbonTrailComponent(
                  maxPoints: 16,
                  lifetime: 0.5,
                  minPointDistance: 2.0,
                )
                ..addPointXY(0, 0)
                ..addPointXY(10, 4)
                ..addPointXY(24, 12);

          expect(trail.pointCount, 3);
          final rec = ui.PictureRecorder();
          final canvas = ui.Canvas(rec);
          trail.render(canvas);

          final strip = SplineStripMesh2D.fromCatmullRom(
            controlPoints: <Vector2>[
              Vector2(0, 0),
              Vector2(40, 20),
              Vector2(80, 0),
            ],
            subdivisionsPerSegment: 6,
          );
          strip.render(canvas);
          rec.endRecording().dispose();

          // Expire trail points past lifetime.
          trail.update(0.6);
          expect(trail.pointCount, 0);

          // VerletRope2D maintains pinned start and segment lengths.
          final rope = VerletRope2D(
            nodeCount: 5,
            start: Vector2(0, 0),
            end: Vector2(40, 0),
            segmentLength: 10.0,
            constraintIterations: 12,
          );
          for (var i = 0; i < 30; i++) {
            rope.step(1.0 / 60.0);
          }
          expect(rope.posX[0], 0.0);
          expect(rope.posY[0], 0.0);
          expect(rope.posY[4], greaterThan(15.0));
          final lastSegLen = math.sqrt(
            math.pow(rope.posX[4] - rope.posX[3], 2) +
                math.pow(rope.posY[4] - rope.posY[3], 2),
          );
          expect(lastSegLen, closeTo(10.0, 0.6));
        },
      );

      test(
        'SpriteAnimationTicker frame events, AttachmentSocket2D, SpringBone2D '
        '& SpringBone3D + AnimationStateTree one-shot return',
        () {
          final img = _makeTinyImageSync(16, 16, const Color(0xFFFFFFFF));
          try {
            final sprite = Sprite(img);
            final idleAnim = SpriteAnimation.spriteList(
              <Sprite>[sprite, sprite],
              stepTime: 0.1,
            );
            final attackAnim = SpriteAnimation.spriteList(
              <Sprite>[sprite, sprite, sprite],
              stepTime: 0.05,
              loop: false,
            );

            final firedEvents = <String>[];
            final tree = AnimationStateTree<String>(
              initialState: 'idle',
              onAnimationEvent: (state, frame, name) {
                firedEvents.add('$state:$frame:$name');
              },
            )..registerState('idle', idleAnim);
            tree
                .registerState('attack', attackAnim)
                .registerFrameEvent(
                  1,
                  'slash_sfx',
                );

            tree.playOneShot('attack');
            expect(tree.currentState, 'attack');
            tree.update(0.06); // advances to frame 1 -> fires slash_sfx!
            expect(firedEvents, <String>['attack:1:slash_sfx']);

            tree.update(0.20); // finishes attack -> auto-returns to idle!
            expect(tree.currentState, 'idle');

            // AttachmentSocket2D rotates localOffset with host angle.
            final host = PositionComponent(
              position: Vector2(100, 50),
              angle: math.pi / 2,
              scale: Vector2.all(2.0),
            );
            final follower = PositionComponent();
            AttachmentSocket2D(
              name: 'hand_r',
              localOffset: Vector2(10, 0),
            ).syncFollower(host, follower);
            expect(follower.position.x, closeTo(100.0, 1e-4));
            expect(follower.position.y, closeTo(70.0, 1e-4));

            // SpringBone2D & SpringBone3D react to sudden anchor displacement.
            final spring2d = SpringBone2D()
              ..update(0.016, 0, 0)
              ..update(0.016, 20, 0);
            expect(spring2d.offsetX, lessThan(0));

            final spring3d = SpringBone3D()
              ..update(0.016, 0, 0, 0)
              ..update(0.016, 0, 0, 1.0);
            expect(spring3d.offsetZ, lessThan(0));
          } finally {
            img.dispose();
          }
        },
      );

      test(
        'Light2DLayer renders PointLight2D, SpotLight2D & extruded '
        'ShadowOccluder2D quads',
        () {
          final layer = Light2DLayer(
            bounds: const Rect.fromLTWH(0, 0, 400, 300),
            respectGraphicsQuality: false,
          );
          layer.pointLights.add(
            PointLight2D(position: Vector2(120, 120), radius: 150),
          );
          layer.spotLights.add(
            SpotLight2D(position: Vector2(260, 140), radius: 160),
          );
          layer.occluders.add(
            ShadowOccluder2D.rect(const Rect.fromLTWH(160, 100, 24, 40)),
          );

          layer.update(0.016);
          final rec = ui.PictureRecorder();
          layer.render(ui.Canvas(rec));
          rec.endRecording().dispose();

          expect(layer.lastRenderedLights, 2);
          expect(layer.lastShadowQuads, greaterThan(0));
        },
      );

      test(
        'Standard GPU PostProcess effects & OutlineDecorator execute cleanly '
        'without external .frag assets',
        () async {
          final game = FlameGame()..onGameResize(Vector2(320, 240));
          final box = RectangleComponent(
            position: Vector2(80, 60),
            size: Vector2(40, 40),
            paint: Paint()..color = const Color(0xFFFFCA28),
          );
          box.decorator.addLast(OutlineDecorator(thickness: 3.0));
          game.world.add(box);

          final pipeline = PostProcessPipeline(
            stages: <PostProcessStage>[
              PostProcessStage(
                name: 'bloom',
                postProcess: BloomPostProcess(intensity: 0.6),
              ),
              PostProcessStage(
                name: 'aberration',
                postProcess: ChromaticAberrationPostProcess(offsetPx: 2.0),
              ),
              PostProcessStage(
                name: 'grade',
                postProcess: ColorGradingPostProcess(
                  preset: ColorGradingPreset.warmSunset,
                ),
              ),
              PostProcessStage(
                name: 'vignette',
                postProcess: VignettePostProcess(intensity: 0.4),
              ),
            ],
          );
          game.camera.postProcess = pipeline;
          await game.ready();

          game.update(0.016);
          final rec = ui.PictureRecorder();
          game.render(ui.Canvas(rec));
          rec.endRecording().dispose();

          game.camera.postProcess = null;
          game.update(0.016);
        },
      );

      test(
        'Canvas3D Mesh3D UV mapping, Node3D hierarchy & Decal3D batch into '
        'BatchMeshRenderer3D',
        () {
          final tex = _makeTinyImageSync(64, 64, const Color(0xFF4FC3F7));
          try {
            final shader = ui.ImageShader(
              tex,
              TileMode.clamp,
              TileMode.clamp,
              Float64List.fromList(<double>[
                1, 0, 0, 0, //
                0, 1, 0, 0, //
                0, 0, 1, 0, //
                0, 0, 0, 1, //
              ]),
            );
            try {
              final box = Mesh3D.box();
              expect(box.uvs, isNotNull);
              expect(box.uvs!.length, box.vertexCount * 2);

              final root = Node3D(
                name: 'tower',
                localX: 2.0,
                localYawRad: math.pi / 2,
                mesh: box,
                uvRectPx: const Rect.fromLTWH(0, 0, 32, 32),
              );
              final child = Node3D(
                name: 'sail',
                localX: 1.0,
                localZ: 2.0,
                mesh: Mesh3D.plane(sizeX: 0.8, sizeY: 0.8),
                uvRectPx: const Rect.fromLTWH(32, 0, 32, 32),
              );
              root.addChild(child);
              root.updateWorldTransforms();

              // Local +1 X rotated by +90 deg around Z from (2, 0) -> (2, 1)!
              expect(child.worldX, closeTo(2.0, 1e-4));
              expect(child.worldY, closeTo(1.0, 1e-4));
              expect(child.worldZ, closeTo(2.0, 1e-4));
              expect(root.findByName('sail'), same(child));

              final cam = CameraRig3D();
              final renderer = BatchMeshRenderer3D(frustumCullMeshes: false);
              root.enqueueHierarchy(renderer, camera: cam);
              Decal3D(
                worldX: 0,
                worldY: 0,
                uvRectPx: const Rect.fromLTWH(0, 32, 32, 32),
              ).enqueue(renderer, camera: cam);

              final rec = ui.PictureRecorder();
              renderer.flushBatch(ui.Canvas(rec), textureShader: shader);
              rec.endRecording().dispose();
              expect(renderer.lastFlushDrawCalls, 1);
            } finally {
              shader.dispose();
            }
          } finally {
            tex.dispose();
          }
        },
      );
    },
  );
}
