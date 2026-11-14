import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/camera.dart';
import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/text.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingVisualComponent({
  super.position,
  super.size,
  super.cameraMask,
}) extends PositionComponent with HasPaint, TapCallbacks {
  int renderCalls = 0;
  int tapCount = 0;

  @override
  void render(ui.Canvas canvas) {
    renderCalls++;
    canvas.drawRect(size.toRect(), paint);
  }

  @override
  void onTapDown(TapDownEvent event) {
    tapCount++;
  }
}

class _CustomDirtyHookGame() extends FlameGame {
  bool customShaderUniformDirty = false;

  @override
  bool pollSceneDirtyForRender() {
    return super.pollSceneDirtyForRender() || customShaderUniformDirty;
  }

  @override
  void onFrameRendered() {
    super.onFrameRendered();
    customShaderUniformDirty = false;
  }
}

class _InterpolatedMover()
    extends PositionComponent
    with HasFixedUpdate, FixedTransformInterpolation {
  Vector2 stepDelta = Vector2.zero();
  double? nextAngle;
  double? lastRenderedTx;
  double? lastRenderedTy;
  double? lastRenderedAngle;

  @override
  void fixedUpdate(double dt) {
    if (!stepDelta.isZero()) {
      position.add(stepDelta);
    }
    if (nextAngle != null) {
      angle = nextAngle!;
    }
  }

  @override
  void render(ui.Canvas canvas) {
    final m = canvas.getTransform();
    lastRenderedTx = m[12];
    lastRenderedTy = m[13];
    lastRenderedAngle = math.atan2(m[1], m[0]);
  }
}

class _NestedCameraCheckComponent({
  required this.innerCamera,
  super.cameraMask,
}) extends PositionComponent {
  final CameraComponent innerCamera;
  CameraComponent? beforeNestedCamera;
  CameraComponent? afterNestedCamera;

  @override
  void render(ui.Canvas canvas) {
    beforeNestedCamera = CameraComponent.currentCamera;
    final img = innerCamera.renderToImageSync(width: 64, height: 64);
    img.dispose();
    afterNestedCamera = CameraComponent.currentCamera;
  }
}

class _Selectable3DBox({
  super.cameraMask,
}) extends Component with TapCallbacks, SpatialHitbox3D {
  int taps = 0;

  @override
  double? intersectRay3D(Ray3D ray) {
    return intersectWorldAabb3D(
      ray,
      minX: -1.0,
      minY: -1.0,
      minZ: 0.0,
      maxX: 1.0,
      maxY: 1.0,
      maxZ: 2.0,
    );
  }

  @override
  void onTapDown(TapDownEvent event) {
    taps++;
  }
}

ui.Canvas _makeRecorderCanvas(
  ui.PictureRecorder recorder, [
  double w = 800,
  double h = 600,
]) {
  return ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h));
}

void _pumpRender(FlameGame game, [double w = 800, double h = 600]) {
  final recorder = ui.PictureRecorder();
  final canvas = _makeRecorderCanvas(recorder, w, h);
  game.render(canvas);
  game.onFrameRendered();
  recorder.endRecording().dispose();
}

void main() {
  group('Wave 7 — Subsystems 1–4: Retained Layer Caching, Dirty Sources, '
      'Fixed Transform Interpolation & Multi-Camera Masks', () {
    test(
      'Subsystem 1: CameraLayerCacheMode.splitRetained isolates backdrop, '
      'world, and viewport HUD re-recording via subtreeVersion',
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

        final backdropComp = _CountingVisualComponent(size: Vector2(400, 300));
        final worldComp = _CountingVisualComponent(
          position: Vector2(-20, -20),
          size: Vector2(40, 40),
        );
        final hudComp = _CountingVisualComponent(
          position: Vector2(10, 10),
          size: Vector2(80, 24),
        );

        camera.backdrop.add(backdropComp);
        world.add(worldComp);
        camera.viewport.add(hudComp);
        await game.ready();
        game.update(1 / 60);

        // Frame 1: initial build of all three retained layers.
        _pumpRender(game, 400, 300);
        expect(camera.backdropCacheRebuildCount, 1);
        expect(camera.worldCacheRebuildCount, 1);
        expect(camera.viewportCacheRebuildCount, 1);
        expect(worldComp.renderCalls, 1);
        expect(hudComp.renderCalls, 1);

        // Frame 2: completely calm frame — all 3 layers hit retained pictures!
        game.update(1 / 60);
        _pumpRender(game, 400, 300);
        expect(camera.backdropCacheHitCount, 1);
        expect(camera.worldCacheHitCount, 1);
        expect(camera.viewportCacheHitCount, 1);
        expect(worldComp.renderCalls, 1);
        expect(hudComp.renderCalls, 1);

        // Frame 3: mutate ONLY HUD — world & backdrop reuse retained Pictures!
        hudComp.position.x += 12;
        game.update(1 / 60);
        _pumpRender(game, 400, 300);
        expect(camera.worldCacheHitCount, 2);
        expect(camera.backdropCacheHitCount, 2);
        expect(camera.viewportCacheRebuildCount, 2);
        expect(worldComp.renderCalls, 1);
        expect(hudComp.renderCalls, 2);

        // Frame 4: mutate ONLY world — viewport HUD reuses retained Picture!
        worldComp.position.y += 15;
        game.update(1 / 60);
        _pumpRender(game, 400, 300);
        expect(camera.worldCacheRebuildCount, 2);
        expect(camera.viewportCacheHitCount, 2);
        expect(worldComp.renderCalls, 2);
        expect(hudComp.renderCalls, 2);

        // Frame 5: pan viewfinder — world rebuilds, HUD still hits cache!
        camera.viewfinder.position = Vector2(25, -10);
        game.update(1 / 60);
        _pumpRender(game, 400, 300);
        expect(camera.worldCacheRebuildCount, 3);
        expect(camera.viewportCacheHitCount, 3);
        expect(hudComp.renderCalls, 2);

        camera.invalidateLayerCaches(resetCounters: true);
        expect(camera.worldCacheHitCount, 0);
        expect(camera.worldCacheRebuildCount, 0);
      },
    );

    test(
      'Subsystem 2: DirtyVersionSource, @protected pollSceneDirtyForRender, '
      'and BatchedTextComponent / HasPaint visual dirty wakeups',
      () async {
        final game = _CustomDirtyHookGame()
          ..idleRenderMode = IdleRenderMode.onDemand;
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final atlas = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 16),
          charset: 'Score:0123456789 ',
        );
        addTearDown(atlas.dispose);

        final label = BatchedTextComponent(atlas: atlas, text: 'Score: 0');
        final tintBox = _CountingVisualComponent(size: Vector2(20, 20));
        game.world.addAll([label, tintBox]);
        await game.ready();

        // Initial render clears dirty flags.
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _pumpRender(game, 400, 300);

        // Calm tick skips render.
        game.update(1 / 60);
        expect(game.shouldRenderThisTick(1 / 60), isFalse);
        expect(game.skippedCleanPaints, 1);

        // External DirtyVersionSource wakes render without markSceneDirty().
        var externalBoardVersion = 10;
        int readVersion() => externalBoardVersion;
        game.registerDirtyVersionSource(readVersion);
        expect(game.dirtyVersionSourceCount, 1);
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _pumpRender(game, 400, 300);

        // Unchanged external version stays asleep.
        expect(game.shouldRenderThisTick(1 / 60), isFalse);

        // Incrementing external version wakes render automatically!
        externalBoardVersion++;
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _pumpRender(game, 400, 300);

        // Subclass @protected pollSceneDirtyForRender() wakes render.
        game.customShaderUniformDirty = true;
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _pumpRender(game, 400, 300);
        expect(game.shouldRenderThisTick(1 / 60), isFalse);

        // BatchedTextComponent.text mutation wakes IdleRenderMode.onDemand!
        label.text = 'Score: 1';
        game.update(1 / 60);
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _pumpRender(game, 400, 300);

        // HasPaint.setColor mutation wakes IdleRenderMode.onDemand!
        tintBox.setColor(const ui.Color(0xFFFF3366));
        game.update(1 / 60);
        expect(game.shouldRenderThisTick(1 / 60), isTrue);
        _pumpRender(game, 400, 300);

        expect(game.unregisterDirtyVersionSource(readVersion), isTrue);
        expect(game.dirtyVersionSourceCount, 0);
      },
    );

    test(
      'Subsystem 3: FixedTransformInterpolation renders exact alpha midpoint, '
      'wraps shortest-arc angle across +-pi, and supports teleportFixedState',
      () async {
        final world = World();
        final camera = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          viewfinder: Viewfinder()..anchor = Anchor.topLeft,
        );
        final game = FlameGame(world: world, camera: camera)
          ..fixedTimeStep = 1 / 60;
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final mover = _InterpolatedMover()
          ..position = Vector2(0, 0)
          ..angle = 3.0;
        world.add(mover);
        await game.ready();

        // Advance one full fixed step (1/60s): moves to (100, 200), wraps angle
        // from +3.0 rad across pi (~3.14159) to -3.0 rad!
        mover
          ..stepDelta = Vector2(100, 200)
          ..nextAngle = -3.0;
        game.update(1 / 60);
        expect(mover.position, Vector2(100, 200));

        // Advance half a fixed step (1/120s) -> renderInterpolationAlpha == 0.5!
        mover
          ..stepDelta = Vector2.zero()
          ..nextAngle = null;
        game.update(1 / 120);
        expect(game.renderInterpolationAlpha, closeTo(0.5, 1e-5));

        _pumpRender(game, 400, 300);
        // Logical simulation state MUST remain untouched at (100, 200)!
        expect(mover.position.x, closeTo(100.0, 1e-6));
        expect(mover.position.y, closeTo(200.0, 1e-6));
        // Rendered canvas matrix MUST sit at exact midpoint (50, 100)!
        expect(mover.lastRenderedTx, closeTo(50.0, 1e-3));
        expect(mover.lastRenderedTy, closeTo(100.0, 1e-3));
        // Shortest arc between +3.0 and -3.0 passes through pi (not 0!):
        expect(mover.lastRenderedAngle!.abs(), greaterThan(2.9));

        // Teleporting snaps history immediately so alpha=0.5 is at 500,600!
        mover.position.setValues(500, 600);
        mover.teleportFixedState();
        _pumpRender(game, 400, 300);
        expect(mover.lastRenderedTx, closeTo(500.0, 1e-3));
        expect(mover.lastRenderedTy, closeTo(600.0, 1e-3));
      },
    );

    test(
      'Subsystem 4: Component.cameraMask 2D/3D isolation, nested '
      'CameraComponent.currentCamera, and RenderTextureComponent lifecycle',
      () async {
        const maskMain = 0x01;
        const maskMinimap = 0x02;

        final world = World();
        final mainCamera = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          cameraMask: maskMain,
        )..viewfinder.anchor = Anchor.topLeft;

        final minimapCamera = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          cameraMask: maskMinimap,
        )..viewfinder.anchor = Anchor.topLeft;

        final game = FlameGame(world: world, camera: mainCamera);
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final mainOnly = _CountingVisualComponent(
          position: Vector2(20, 20),
          size: Vector2(40, 40),
          cameraMask: maskMain,
        );
        final minimapOnly = _CountingVisualComponent(
          position: Vector2(20, 20),
          size: Vector2(40, 40),
          cameraMask: maskMinimap,
        );
        final nestedProbe = _NestedCameraCheckComponent(
          innerCamera: minimapCamera,
          cameraMask: maskMain,
        );

        final rig = CameraRig3D(groundOriginY: 160);
        mainCamera.rayProjector3D = (_, worldPt) =>
            rig.unprojectWorldRay(worldPt.toOffset());
        minimapCamera.rayProjector3D = mainCamera.rayProjector3D;

        final boxMain3D = _Selectable3DBox(cameraMask: maskMain);
        final boxMinimap3D = _Selectable3DBox(cameraMask: maskMinimap);

        final rtMinimap = RenderTextureComponent(
          sourceCamera: minimapCamera,
          size: Vector2(100, 75),
          refreshFps: 10,
        );

        world.addAll([
          mainOnly,
          minimapOnly,
          nestedProbe,
          boxMain3D,
          boxMinimap3D,
        ]);
        mainCamera.viewport.add(rtMinimap);
        await game.ready();

        // Render main camera (which also renders rtMinimap -> minimapCamera!).
        _pumpRender(game, 400, 300);

        // mainOnly rendered ONLY by mainCamera; minimapOnly rendered ONLY by
        // minimapCamera (via rtMinimap & nestedProbe)!
        expect(mainOnly.renderCalls, 1);
        expect(minimapOnly.renderCalls, 2); // nestedProbe + rtMinimap

        // Nested camera render inside mainCamera MUST preserve currentCamera!
        expect(nestedProbe.beforeNestedCamera, same(mainCamera));
        expect(nestedProbe.afterNestedCamera, same(mainCamera));

        // 2D tap through mainCamera at (30, 30) ONLY hits mainOnly!
        final hits2D = game
            .componentsAtPoint(Vector2(30, 30))
            .whereType<_CountingVisualComponent>()
            .toList();
        expect(hits2D, [mainOnly]);

        // 3D spatial ray pick through mainCamera ONLY hits boxMain3D!
        final projected = rig.projectWorldPoint(0, 0, 1);
        final hits3D = game
            .componentsAtPoint(Vector2(projected.dx, projected.dy))
            .whereType<_Selectable3DBox>()
            .toList();
        expect(hits3D, [boxMain3D]);

        // RenderTextureComponent throttles captures to refreshFps (10 Hz):
        expect(rtMinimap.texture, isNotNull);
        expect(rtMinimap.captureCount, 1);
        game.update(0.04);
        _pumpRender(game, 400, 300);
        expect(rtMinimap.captureCount, 1);
        game.update(0.07);
        _pumpRender(game, 400, 300);
        expect(rtMinimap.captureCount, 2);

        // Removing RenderTextureComponent disposes GPU texture cleanly.
        rtMinimap.removeFromParent();
        await game.ready();
        expect(rtMinimap.texture, isNull);
      },
    );
  });
}
