import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe({super.position, super.size, super.cameraMask})
    extends PositionComponent {
  int renderCount = 0;

  @override
  void render(Canvas canvas) => renderCount++;
}

class _CullProbe({super.position, super.size})
    extends _Probe
    with CullWhenOffscreen;

class _BillboardProbe({super.size})
    extends PositionComponent
    with CameraBillboard {
  double? bakedScale;

  @override
  void render(Canvas canvas) {
    bakedScale = canvas.getTransform()[0];
  }
}

class _MultiPassProbe() extends PositionComponent with MultiPassComponent {
  final List<String> passes = [];

  @override
  void renderPass(Canvas canvas, RenderPass pass) => passes.add(pass.name);
}

class _SnapshotGroup({super.children}) extends PositionComponent with Snapshot;

class _SnapshotLeaf({super.cameraMask}) extends _Probe with Snapshot;

class _PaintedSnapshot({super.cameraMask})
    extends PositionComponent
    with Snapshot {
  this : super(size: Vector2.all(200), anchor: Anchor.center);

  int renderCount = 0;

  @override
  void render(Canvas canvas) {
    renderCount++;
    canvas.drawRect(size.toRect(), Paint()..color = const Color(0xFFFFFFFF));
  }
}

void main() {
  Future<FlameGame> makeGame({
    bool spatialIndex = false,
    int? cameraMask,
  }) async {
    final world = World(spatialIndexEnabled: spatialIndex);
    final game = FlameGame(
      world: world,
      camera: CameraComponent(
        world: world,
        viewport: FixedSizeViewport(400, 300),
        cameraMask: cameraMask,
      ),
    )..onGameResize(Vector2(400, 300));
    await game.start();
    await game.ready();
    return game;
  }

  void render(CameraComponent camera) {
    final rec = PictureRecorder();
    camera.renderTree(Canvas(rec, const Rect.fromLTWH(0, 0, 400, 300)));
    rec.endRecording().dispose();
  }

  group('Snapshot is independent of the camera that bakes it', () {
    for (final spatialIndex in [false, true]) {
      final mode = spatialIndex ? 'with' : 'without';
      test(
        'children that are off screen at bake time are part of the snapshot '
        '($mode the spatial index)',
        () async {
          final game = await makeGame(spatialIndex: spatialIndex);
          final near = _Probe(position: Vector2(0, 0), size: Vector2(20, 20));
          final far = _Probe(position: Vector2(3000, 0), size: Vector2(20, 20));
          final farCullable = _CullProbe(
            position: Vector2(3000, 40),
            size: Vector2(20, 20),
          );
          final group = _SnapshotGroup(children: [near, far, farCullable]);
          game.world.add(group);
          await game.ready();

          render(game.camera);
          expect(near.renderCount, 1);
          expect(far.renderCount, 1);
          expect(farCullable.renderCount, 1);

          // The camera travels to the other end: the cache is replayed and
          // nothing is recorded again.
          game.camera.viewfinder.position = Vector2(3000, 0);
          game.update(0);
          render(game.camera);
          render(game.camera);
          expect(near.renderCount, 1);
          expect(far.renderCount, 1);
          expect(farCullable.renderCount, 1);
          expect(group.hasSnapshot, isTrue);
        },
      );
    }

    test('a billboard child is baked at its natural size', () async {
      final game = await makeGame();
      final label = _BillboardProbe(size: Vector2(20, 10));
      game.world.add(_SnapshotGroup(children: [label]));
      await game.ready();

      game.camera.viewfinder.zoom = 2.0;
      render(game.camera);
      expect(label.bakedScale, closeTo(1.0, 1e-9));
    });

    test(
      'a MultiPassComponent child records all of its fallback passes',
      () async {
        final game = await makeGame();
        final prop = _MultiPassProbe();
        game.world.add(_SnapshotGroup(children: [prop]));
        await game.ready();
        game.camera.renderPasses = const [
          RenderPass.shadows,
          RenderPass.opaque,
        ];

        render(game.camera);
        render(game.camera);

        expect(prop.passes, [
          'shadows',
          'opaque',
          'translucent',
          'emissive',
          'overlay',
        ]);
        expect(CameraComponent.currentRenderPass, isNull);
      },
    );

    test('descendant cameraMask values do not empty the snapshot', () async {
      final game = await makeGame(cameraMask: 0x1);
      final child = _Probe(size: Vector2(20, 20), cameraMask: 0x2);
      game.world.add(_SnapshotGroup(children: [child]));
      await game.ready();

      render(game.camera);
      expect(child.renderCount, 1);
    });
  });

  group('Snapshot honours its own cameraMask', () {
    const mainBit = 0x1;
    const minimapBit = 0x2;

    Future<(FlameGame, CameraComponent)> twoCameras() async {
      final game = await makeGame(cameraMask: mainBit);
      final minimap = CameraComponent(
        world: game.world,
        viewport: FixedSizeViewport(64, 64),
        cameraMask: minimapBit,
      );
      game.add(minimap);
      await game.ready();
      return (game, minimap);
    }

    test(
      'an excluded camera that renders first does not bake it empty',
      () async {
        final (game, minimap) = await twoCameras();
        final decor = _SnapshotLeaf(cameraMask: mainBit);
        game.world.add(decor);
        await game.ready();

        render(minimap);
        expect(decor.renderCount, 0);
        expect(decor.hasSnapshot, isFalse);

        render(game.camera);
        render(game.camera);
        expect(decor.renderCount, 1);
        expect(decor.hasSnapshot, isTrue);
      },
    );

    test('an excluded camera does not replay a baked snapshot', () async {
      final (game, minimap) = await twoCameras();
      final decor = _PaintedSnapshot(cameraMask: mainBit);
      game.world.add(decor);
      await game.ready();

      Future<int> centreRed(CameraComponent camera) async {
        final image = camera.renderToImageSync(
          width: 40,
          height: 40,
          backgroundColor: const Color(0xFF000000),
        );
        final bytes = await image.toByteData();
        image.dispose();
        return bytes!.getUint8((20 * 40 + 20) * 4);
      }

      // The allowed camera bakes and shows the white square ...
      expect(await centreRed(game.camera), 255);
      expect(decor.hasSnapshot, isTrue);
      // ... the excluded camera shows nothing of it ...
      expect(await centreRed(minimap), 0);
      // ... and the cache is still good for the allowed one.
      expect(await centreRed(game.camera), 255);
      expect(decor.renderCount, 1);

      // Changing the mask at runtime takes effect at once.
      decor.cameraMask = minimapBit;
      expect(await centreRed(game.camera), 0);
      expect(await centreRed(minimap), 255);
      expect(decor.renderCount, 1);
    });
  });
}
