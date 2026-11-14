import 'dart:isolate' show RemoteError;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/camera.dart';
import 'package:flame/canvas3d.dart';
import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/geometry.dart';
import 'package:flame/layout.dart' as flame_layout;
import 'package:flame/rendering.dart';
import 'package:flame/text.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

int _throwingIsolateTask(int code) {
  if (code < 0) {
    throw ArgumentError.value(code, 'code', 'Negative task code rejected');
  }
  return code * 7;
}

Future<int> _slowIsolateTask(int delayMs) async {
  await Future<void>.delayed(Duration(milliseconds: delayMs));
  return delayMs;
}

class _ScaleInterpolatedSprite()
    extends PositionComponent
    with HasFixedUpdate, FixedTransformInterpolation {
  Vector2? targetPos;
  Vector2? targetScale;
  double? renderedScaleX;
  double? renderedScaleY;
  double? renderedTx;
  double? renderedTy;

  @override
  void fixedUpdate(double dt) {
    if (targetPos != null) {
      position.setFrom(targetPos!);
    }
    if (targetScale != null) {
      scale.setFrom(targetScale!);
    }
  }

  @override
  void render(ui.Canvas canvas) {
    final m = canvas.getTransform();
    renderedScaleX = math.sqrt(m[0] * m[0] + m[1] * m[1]);
    renderedScaleY = math.sqrt(m[4] * m[4] + m[5] * m[5]);
    renderedTx = m[12];
    renderedTy = m[13];
  }
}

class _SimpleProbeComponent({
  super.position,
  super.size,
  super.cameraMask,
}) extends PositionComponent
    with HasVisibility, HasPaint, HasTags, TapCallbacks {
  int renders = 0;
  int taps = 0;

  @override
  void render(ui.Canvas canvas) {
    renders++;
  }

  @override
  void onTapDown(TapDownEvent event) {
    taps++;
  }
}

class _QuadTreeNegSpaceGame()
    extends FlameGame
    with HasQuadTreeCollisionDetection;

void _renderOnce(FlameGame game, [double w = 400, double h = 300]) {
  final rec = ui.PictureRecorder();
  game.render(ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, w, h)));
  game.onFrameRendered();
  rec.endRecording().dispose();
}

void main() {
  group('Wave 7 — Exhaustive Architectural & Mathematical Edge Cases', () {
    test(
      'Edge 1: splitRetained invalidates on viewport resize, mode switch, and '
      'deep HUD grandchild mount/remove',
      () async {
        final world = World();
        final camera = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          layerCacheMode: CameraLayerCacheMode.splitRetained,
        );
        final game = FlameGame(world: world, camera: camera);
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final worldBox = _SimpleProbeComponent(size: Vector2(20, 20));
        final hudRoot = PositionComponent();
        final hudGrandchild = _SimpleProbeComponent(size: Vector2(30, 15));
        hudRoot.add(hudGrandchild);
        world.add(worldBox);
        camera.viewport.add(hudRoot);
        await game.ready();

        _renderOnce(game);
        expect(camera.worldCacheRebuildCount, 1);
        expect(camera.viewportCacheRebuildCount, 1);

        // Resize canvas -> invalidates retained Pictures so next frame rebuilds
        game.onGameResize(Vector2(800, 600));
        _renderOnce(game, 800, 600);
        expect(camera.worldCacheRebuildCount, 2);
        expect(camera.viewportCacheRebuildCount, 2);

        // Deep HUD grandchild removal bumps viewport.subtreeVersion ONLY!
        hudGrandchild.removeFromParent();
        await game.ready();
        _renderOnce(game, 800, 600);
        expect(camera.worldCacheHitCount, 1);
        expect(camera.viewportCacheRebuildCount, 3);

        // Switching back to CameraLayerCacheMode.none renders live every frame!
        camera.layerCacheMode = CameraLayerCacheMode.none;
        final beforeLive = worldBox.renders;
        _renderOnce(game, 800, 600);
        _renderOnce(game, 800, 600);
        expect(worldBox.renders, beforeLive + 2);
      },
    );

    test(
      'Edge 2: HasVisibility, RichBatchedTextComponent, PaintDecorator, and '
      'idempotent registerDirtyVersionSource wake IdleRenderMode.onDemand',
      () async {
        final game = FlameGame()..idleRenderMode = IdleRenderMode.onDemand;
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final atlas = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 14),
          charset: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789! ',
        );
        addTearDown(atlas.dispose);

        final richText = RichBatchedTextComponent(
          atlas: atlas,
          markup: 'READY 1',
        );
        final visBox = _SimpleProbeComponent(size: Vector2(20, 20));
        final paintDec = PaintDecorator.tint(const ui.Color(0x44FF0000));
        visBox.decorator.addLast(paintDec);

        game.world.addAll([richText, visBox]);
        await game.ready();
        _renderOnce(game);
        expect(game.shouldRenderThisTick(1 / 60), isFalse);

        // 1. HasVisibility toggle wakes onDemand:
        visBox.isVisible = false;
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _renderOnce(game);
        expect(game.shouldRenderThisTick(1 / 60), isFalse);

        // 2. RichBatchedTextComponent markup change wakes onDemand & subtree:
        final prevSubtreeV = richText.subtreeVersion;
        richText.markup = 'READY 2!';
        expect(richText.subtreeVersion, greaterThan(prevSubtreeV));
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _renderOnce(game);
        expect(game.shouldRenderThisTick(1 / 60), isFalse);

        // 3. PaintDecorator.setTint / addBlur wakes onDemand:
        paintDec.setTint(const ui.Color(0x8800FF00));
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _renderOnce(game);
        expect(game.shouldRenderThisTick(1 / 60), isFalse);

        paintDec.addBlur(2.5);
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _renderOnce(game);

        // 4. Duplicate DirtyVersionSource registration is idempotent:
        const v = 1;
        int source() => v;
        game.registerDirtyVersionSource(source);
        game.registerDirtyVersionSource(source);
        expect(game.dirtyVersionSourceCount, 1);
      },
    );

    test(
      'Edge 3: FixedTransformInterpolation scale interpolation, '
      'interpolationEnabled toggle & clean remount priming',
      () async {
        final world = World();
        final camera = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          viewfinder: Viewfinder()..anchor = Anchor.topLeft,
        );
        final game = FlameGame(world: world, camera: camera)
          ..fixedTimeStep = 0.1;
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final sprite = _ScaleInterpolatedSprite()
          ..position = Vector2(10, 20)
          ..scale = Vector2(1, 1);
        world.add(sprite);
        await game.ready();

        // Step 1 fixed tick (dt = 0.1) to (50, 100) and scale (3, 5):
        sprite
          ..targetPos = Vector2(50, 100)
          ..targetScale = Vector2(3, 5);
        game.update(0.1);
        sprite
          ..targetPos = null
          ..targetScale = null;

        // Advance 0.025s -> alpha = 0.25!
        game.update(0.025);
        expect(game.renderInterpolationAlpha, closeTo(0.25, 1e-5));
        _renderOnce(game);

        // At alpha = 0.25: pos = (20, 40), scale = (1.5, 2.0)!
        expect(sprite.renderedTx, closeTo(20.0, 1e-3));
        expect(sprite.renderedTy, closeTo(40.0, 1e-3));
        expect(sprite.renderedScaleX, closeTo(1.5, 1e-3));
        expect(sprite.renderedScaleY, closeTo(2.0, 1e-3));
        // Logical transform untouched!
        expect(sprite.scale, Vector2(3, 5));

        // Disabling fixedInterpolationEnabled renders exact logical transform:
        sprite.fixedInterpolationEnabled = false;
        _renderOnce(game);
        expect(sprite.renderedTx, closeTo(50.0, 1e-3));
        expect(sprite.renderedScaleX, closeTo(3.0, 1e-3));

        // Remounting resets priming cleanly without stale jump:
        sprite.fixedInterpolationEnabled = true;
        sprite.removeFromParent();
        await game.ready();
        sprite.position.setValues(200, 150);
        world.add(sprite);
        await game.ready();
        _renderOnce(game);
        expect(sprite.renderedTx, closeTo(200.0, 1e-3));
        expect(sprite.renderedTy, closeTo(150.0, 1e-3));

        // When stationary (prev == curr), varying renderInterpolationAlpha
        // MUST NOT falsely wake IdleRenderMode.onDemand!
        game.idleRenderMode = IdleRenderMode.onDemand;
        _renderOnce(game);
        game.update(0.016);
        expect(game.shouldRenderThisTick(0.016), isFalse);
      },
    );

    test(
      'Edge 4: In-world RenderTextureComponent self-capture recursion guard & '
      'live runtime cameraMask switching',
      () async {
        final world = World();
        final cam = CameraComponent.withFixedResolution(
          width: 200,
          height: 150,
          world: world,
          cameraMask: 0x01,
        );
        final game = FlameGame(world: world, camera: cam);
        game.onGameResize(Vector2(200, 150));
        await game.start();
        addTearDown(game.onRemove);

        // Place a RenderTextureComponent INSIDE the very world its sourceCamera
        // renders ("hall of mirrors") — must NOT recurse infinitely!
        final mirror = RenderTextureComponent(
          sourceCamera: cam,
          size: Vector2(64, 48),
        );
        final actor = _SimpleProbeComponent(
          size: Vector2(20, 20),
          cameraMask: 0x02, // Initially hidden from cam (0x01)!
        );
        world.addAll([mirror, actor]);
        await game.ready();

        _renderOnce(game, 200, 150);
        expect(mirror.captureCount, 1);
        expect(actor.renders, 0);

        // Live runtime cameraMask mutation exposes actor to cam!
        actor.cameraMask = 0x01;
        _renderOnce(game, 200, 150);
        expect(actor.renders, greaterThanOrEqualTo(1));
      },
    );

    test(
      'Edge 5: WorldSpatialIndex parallax exclusion, subtree removal cleanup, '
      'and WorldQuery(includeSubtree: false) isolation',
      () async {
        final world = World(spatialIndexEnabled: true, spatialCellSize: 128);
        final cam = CameraComponent.withFixedResolution(
          width: 200,
          height: 150,
          world: world,
          viewfinder: Viewfinder()..anchor = Anchor.topLeft,
        );
        final game = FlameGame(world: world, camera: cam);
        game.onGameResize(Vector2(200, 150));
        await game.start();
        addTearDown(game.onRemove);

        final directOnlyQuery = world.registerQuery(
          WorldQuery<_SimpleProbeComponent>(
            withTags: const ['prop'],
            includeSubtree: false,
          ),
        );
        final deepQuery = world.registerQuery(
          WorldQuery<_SimpleProbeComponent>(withTags: const ['prop']),
        );

        final directProp = _SimpleProbeComponent(size: Vector2(16, 16))
          ..addTag('prop');
        final nestedGroup = PositionComponent();
        final nestedProp = _SimpleProbeComponent(
          position: Vector2(20, 20),
          size: Vector2(16, 16),
        )..addTag('prop');
        nestedGroup.add(nestedProp);

        // Parallax != 1.0 layer must NOT be flattened into world-grid cells:
        final parallaxLayer = SceneLayerComponent(
          name: 'clouds',
          parallaxFactor: Vector2(0.5, 0.5),
        );
        final cloudLeaf = _SimpleProbeComponent(size: Vector2(32, 16));
        parallaxLayer.add(cloudLeaf);

        world.addAll([directProp, nestedGroup, parallaxLayer]);
        await game.ready();

        expect(directOnlyQuery.length, 1);
        expect(deepQuery.length, 2);

        _renderOnce(game, 200, 150);
        expect(world.spatialIndex.containsIndexed(directProp), isTrue);
        expect(world.spatialIndex.containsIndexed(nestedProp), isTrue);
        expect(world.spatialIndex.containsIndexed(cloudLeaf), isFalse);

        // Removing the parent container cleans up all nested descendants!
        nestedGroup.removeFromParent();
        await game.ready();
        expect(deepQuery.length, 1);
        _renderOnce(game, 200, 150);
        expect(world.spatialIndex.containsIndexed(nestedProp), isFalse);
      },
    );

    test(
      'Edge 6: ClipComponent.circle clips corner pointer hits & bidirectional '
      'ScrollContainerComponent handles 2D bounds and onDragCancel',
      () async {
        final world = World();
        final cam = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          viewfinder: Viewfinder()..anchor = Anchor.topLeft,
        );
        final game = FlameGame(world: world, camera: cam);
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final circleClip = ClipComponent.circle(
          position: Vector2(0, 0),
          size: Vector2(100, 100), // Center (50, 50), radius 50
        );
        final fullSquare = _SimpleProbeComponent(size: Vector2(100, 100));
        circleClip.add(fullSquare);

        final biScroll = flame_layout.ScrollContainerComponent(
          scrollDirection: flame_layout.ScrollDirection.both,
          position: Vector2(150, 20),
          size: Vector2(100, 80),
          contentSize: Vector2(500, 400),
        );
        world.addAll([circleClip, biScroll]);
        await game.ready();

        // Center (50, 50) is inside circle -> hits fullSquare!
        expect(
          game.componentsAtPoint(Vector2(50, 50)).contains(fullSquare),
          isTrue,
        );
        // Corner (4, 4) has distance sqrt(46^2 + 46^2) = 65.05 > 50 -> clipped!
        expect(
          game.componentsAtPoint(Vector2(4, 4)).contains(fullSquare),
          isFalse,
        );

        // Bidirectional scroll clamping & drag cancel:
        biScroll.scrollTo(x: 999, y: 999);
        expect(biScroll.scrollOffset.x, closeTo(400.0, 1e-5));
        expect(biScroll.scrollOffset.y, closeTo(320.0, 1e-5));

        biScroll.onDragStart(
          DragStartEvent(1, game, DragStartDetails()),
        );
        biScroll.onDragEnd(
          DragEndEvent(
            1,
            DragEndDetails(
              velocity: const Velocity(pixelsPerSecond: ui.Offset(-500, -500)),
            ),
          ),
        );
        expect(biScroll.scrollVelocity.length, greaterThan(100));
        biScroll.onDragCancel(DragCancelEvent(1));
        expect(biScroll.scrollVelocity.length, 0.0);
      },
    );

    test(
      'Edge 7: AffineMatrix2D singular zero-determinant safety & self-aliased '
      'setMultiplyTransform2D',
      () {
        final singular = AffineMatrix2D()
          ..m00 = 0.0
          ..m01 = 0.0
          ..m10 = 0.0
          ..m11 = 0.0
          ..tx = 42.0
          ..ty = -17.0;
        expect(singular.determinant, 0.0);
        final safeLocal = singular.inverseTransformPoint(Vector2(100, 200));
        expect(safeLocal.x.isFinite, isTrue);
        expect(safeLocal.y.isFinite, isTrue);

        final parentTx = Transform2D()
          ..position = Vector2(12, -8)
          ..angle = 0.7
          ..scale = Vector2(1.4, 0.9);
        final childTx = Transform2D()
          ..position = Vector2(-5, 19)
          ..angle = -1.1
          ..scale = Vector2(0.6, 2.2);

        final separateParent = AffineMatrix2D()..setFromTransform2D(parentTx);
        final separateOut = AffineMatrix2D()
          ..setMultiplyTransform2D(separateParent, childTx);

        // Self-aliased (`parent` is `this`) MUST match separate multiplication!
        final aliased = AffineMatrix2D()..setFromTransform2D(parentTx);
        aliased.setMultiplyTransform2D(aliased, childTx);

        expect(aliased.m00, closeTo(separateOut.m00, 1e-12));
        expect(aliased.m01, closeTo(separateOut.m01, 1e-12));
        expect(aliased.m10, closeTo(separateOut.m10, 1e-12));
        expect(aliased.m11, closeTo(separateOut.m11, 1e-12));
        expect(aliased.tx, closeTo(separateOut.tx, 1e-12));
        expect(aliased.ty, closeTo(separateOut.ty, 1e-12));
      },
    );

    testWidgets(
      'Edge 8 & 9: SemanticsComponent decrease/checked/disabled states & '
      'PointerHardwareSample normalizedPressure clamping',
      (tester) async {
        // PointerHardwareSample normalization & degenerate range guard:
        final sample = PointerHardwareSample(
          pressure: 0.7,
          pressureMin: 0.2,
          pressureMax: 1.2,
        );
        expect(sample.normalizedPressure, closeTo(0.5, 1e-6));
        final degen = PointerHardwareSample(
          pressure: 2.5,
          pressureMin: 1.0,
        );
        expect(degen.normalizedPressure, 1.0);

        final game = FlameGame();
        var sliderVal = 5;
        final sliderComp = PositionComponent(
          position: Vector2(20, 20),
          size: Vector2(120, 40),
        );
        final toggleNode = _TestSemanticsToggle(
          position: Vector2(20, 80),
          size: Vector2(100, 40),
          onDecreaseCb: () => sliderVal--,
        );
        game.camera.viewport.addAll([sliderComp, toggleNode]);

        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 300,
              height: 200,
              child: GameWidget(game: game),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        final semNode = find.semantics.byLabel('Volume').evaluate().single;
        expect(
          semNode.getSemanticsData().flagsCollection.isChecked,
          ui.CheckedState.isTrue,
        );

        tester.semantics.performAction(
          find.semantics.byLabel('Volume'),
          SemanticsAction.decrease,
        );
        expect(sliderVal, 4);

        // Disabling semanticsEnabled keeps disabled state & 0 actions:
        toggleNode.semanticsEnabled = false;
        await tester.pump();
        final disabledData = find.semantics
            .byLabel('Volume')
            .evaluate()
            .single
            .getSemanticsData();
        expect(disabledData.hasAction(SemanticsAction.decrease), isFalse);
        expect(
          disabledData.flagsCollection.isEnabled,
          ui.Tristate.isFalse,
        );

        // Excluding via semanticsExcluded removes node from tree completely:
        toggleNode.semanticsExcluded = true;
        await tester.pump();
        expect(find.semantics.byLabel('Volume'), findsNothing);

        handle.dispose();
      },
    );

    test(
      'Edge 10–13: 70k-vertex Mesh3D.partitionByVertexLimit, all-behind-near '
      'perspective reject, antipodal slerp & negative-scale mirrored BVH ray',
      () {
        // 10. Partition a 70,200-vertex 32-bit mesh into <= 30,000-vertex parts
        const triCount = 23400; // 70,200 unique vertices (> 65,535!)
        const vertCount = triCount * 3;
        final pos = Float32List(vertCount * 3);
        final nrm = Float32List(vertCount * 3);
        final uvs = Float32List(vertCount * 2);
        final ao = Float32List(vertCount);
        final cols = Int32List(vertCount);
        final idx32 = Uint32List(vertCount);
        for (var i = 0; i < vertCount; i++) {
          pos[i * 3] = (i % 300).toDouble();
          pos[i * 3 + 1] = (i ~/ 300).toDouble();
          nrm[i * 3 + 2] = 1.0;
          uvs[i * 2] = 0.5;
          uvs[i * 2 + 1] = 0.25;
          ao[i] = 0.9;
          cols[i] = 0xFFFFFFFF;
          idx32[i] = i;
        }
        final parts = Mesh3D.partitionByVertexLimit(
          positions: pos,
          normals: nrm,
          indices: idx32,
          uvs: uvs,
          ambientOcclusion: ao,
          vertexColors: cols,
          maxVerticesPerPart: 30000,
        );
        expect(parts.length, 3);
        var sumTris = 0;
        for (final p in parts) {
          expect(p.vertexCount, lessThanOrEqualTo(30000));
          expect(p.uvs, isNotNull);
          expect(p.ambientOcclusion, isNotNull);
          expect(p.vertexColors, isNotNull);
          sumTris += p.triangleCount;
        }
        expect(sumTris, triCount);

        // 11. Triangle completely behind perspective camera nearClip emits 0
        // triangles cleanly without NaN!
        final rig = CameraRig3D(
          projectionMode: CameraProjectionMode3D.perspective,
          cameraDistance: 10.0,
          nearClip: 1.0,
        );
        final behindX = rig.viewX * 20.0;
        final behindY = rig.viewY * 20.0;
        final behindZ = rig.viewZ * 20.0;
        final quad = Mesh3D.plane();
        final renderer = BatchMeshRenderer3D(
          backfaceCulling: false,
          frustumCullMeshes: false,
        )..beginBatch();
        renderer.enqueueMesh(
          quad,
          camera: rig,
          worldX: behindX,
          worldY: behindY,
          worldZ: behindZ,
        );
        expect(renderer.pendingGeometryTriangleCount, 0);

        // 12. Non-looping AnimationClip3D clamps at duration & antipodal
        // quaternion (q vs -q) slerps along shortest hemisphere!
        final baseTri = Mesh3D.plane();
        final bones = <Bone3D>[Bone3D(name: 'hip')];
        final skinWs = SkinnedMeshWorkspace3D(
          baseMesh: baseTri,
          bones: bones,
          boneIndices0: Uint16List(baseTri.vertexCount),
          boneIndices1: Uint16List(baseTri.vertexCount),
          boneWeights0: Float32List(baseTri.vertexCount)
            ..fillRange(0, baseTri.vertexCount, 1.0),
        );
        final clip = AnimationClip3D(
          name: 'oneshot',
          duration: 0.5,
          looping: false,
          tracks: <TransformTrack3D>[
            TransformTrack3D(
              targetIndex: 0,
              targetName: 'hip',
              times: Float32List.fromList([0.0, 0.5]),
              // Identity (0,0,0,1) -> antipodal identity (0,0,0,-1)!
              rotations: Float32List.fromList([
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                -1,
              ]),
            ),
          ],
        );
        final mixer = AnimationMixer3D(skinnedWorkspace: skinWs)..play(clip);
        mixer.update(0.25); // Midpoint between +q and -q must stay at identity!
        skinWs.evaluateIfDirty();
        expect(skinWs.skinnedPositions[0], closeTo(baseTri.positions[0], 1e-5));
        expect(skinWs.skinnedPositions[1], closeTo(baseTri.positions[1], 1e-5));
        mixer.update(1.0); // Past 0.5s non-looping duration -> clamped at 0.5!
        expect(mixer.currentTime, closeTo(0.5, 1e-5));

        // 13. Negative scale (scaleX = -1.5, mirrored winding!) BVH raycast
        // matches brute-force backface-culled raycast!
        final box = Mesh3D.box(sizeX: 2, sizeY: 2, sizeZ: 2);
        const mirrorRay = Ray3D(
          ox: -6.0,
          oy: 0.2,
          oz: 0.1,
          dx: 1.0,
          dy: 0.0,
          dz: 0.0,
        );
        final bvhMirror = Raycaster3D.raycastMeshTransform(
          mirrorRay,
          box,
          worldX: 0,
          worldY: 0,
          scaleX: -1.5,
          scaleY: 1.2,
        );
        final bruteMirror = Raycaster3D.raycastMeshTransform(
          mirrorRay,
          box,
          worldX: 0,
          worldY: 0,
          scaleX: -1.5,
          scaleY: 1.2,
          useBvh: false,
        );
        expect(bvhMirror, isNotNull);
        expect(bruteMirror, isNotNull);
        expect(bvhMirror!.$1, closeTo(bruteMirror!.$1, 1e-5));
      },
    );

    test(
      'Edge 14 & 15: QuadTree negative-coordinate raycast parity, '
      'EngineComputePool RemoteError recovery & SdfTextComponent dynamic style',
      () async {
        // 14. Out-of-bounds negative-coordinate hitbox in QuadTree is STILL hit
        // by raycast (zero false negatives from conservative outer slab!):
        final qtGame = _QuadTreeNegSpaceGame();
        qtGame.initializeCollisionDetection(
          mapDimensions: const ui.Rect.fromLTWH(0, 0, 1000, 1000),
        );
        qtGame.onGameResize(Vector2(1000, 1000));
        await qtGame.start();
        addTearDown(qtGame.onRemove);

        final negHitbox = RectangleHitbox(
          size: Vector2(30, 30),
          collisionType: CollisionType.passive,
        );
        qtGame.world.add(
          PositionComponent(
            position: Vector2(-200, -150),
            size: Vector2(30, 30),
            children: [negHitbox],
          ),
        );
        await qtGame.ready();
        qtGame.update(1 / 60);

        final negRay = Ray2(
          origin: Vector2(-185, -300),
          direction: Vector2(0, 1), // Vertical axis-aligned ray (dx == 0)!
        );
        final negHit = qtGame.collisionDetection.raycast(negRay);
        expect(negHit, isNotNull);
        expect(negHit!.hitbox, same(negHitbox));
        expect(negHit.distance, closeTo(150.0, 1e-3));

        // 15A. EngineComputePool worker RemoteError recovery & dispose cancel:
        final pool = EngineComputePool(workerCount: 1);
        await expectLater(
          pool.schedule(_throwingIsolateTask, -9),
          throwsA(isA<RemoteError>()),
        );
        // Same single worker recovers immediately and processes next task!
        expect(await pool.schedule(_throwingIsolateTask, 6), 42);

        final inFlight = pool.schedule(_slowIsolateTask, 200);
        final cancelExpectation = expectLater(
          inFlight,
          throwsA(isA<ComputeCancelledException>()),
        );
        await pool.dispose();
        await cancelExpectation;

        // 15B. SdfTextComponent dynamic text & style mutation:
        final sdfAtlas = await SdfFontAtlas.bake(
          style: const TextStyle(fontSize: 20),
          charset: 'ABCDXYZ',
          spreadPx: 4.0,
        );
        addTearDown(sdfAtlas.dispose);

        final sdfComp = SdfTextComponent(
          atlas: sdfAtlas,
          text: 'AB',
          textAlign: TextAlign.right,
        );
        final wBefore = sdfComp.size.x;
        final mutBefore = Game.visualMutationCount;
        sdfComp.text = 'ABCDXYZ';
        expect(sdfComp.size.x, greaterThan(wBefore));
        expect(Game.visualMutationCount, greaterThan(mutBefore));
      },
    );
  });
}

class _TestSemanticsToggle({
  required this.onDecreaseCb,
  super.position,
  super.size,
}) extends PositionComponent with SemanticsComponent {
  final VoidCallback onDecreaseCb;

  this {
    semanticsLabel = 'Volume';
    semanticsValue = '50%';
    isSemanticsChecked = true;
    isSemanticsLiveRegion = true;
    semanticsSortOrder = 1.0;
    onSemanticsDecrease = onDecreaseCb;
  }
}
