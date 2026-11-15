import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _MultiPassPropComponent(
  final String id,
  final List<String> log, {
  final Set<RenderPass>? passes,
  super.priority,
}) extends PositionComponent with MultiPassComponent {
  @override
  Set<RenderPass>? get activeRenderPasses => passes;

  @override
  void renderPass(Canvas canvas, RenderPass pass) {
    log.add('$id:${pass.name}');
  }
}

class _PlainFloorComponent(final List<String> log) extends Component {
  @override
  void render(Canvas canvas) {
    log.add('floor:${CameraComponent.currentRenderPass?.name ?? "single"}');
  }
}

void main() {
  group('Multi-Pass World Rendering', () {
    testWithFlameGame(
      'groups MultiPassComponent draws by pass across components and invokes '
      'World hooks',
      (game) async {
        final log = <String>[];
        game.world
          ..beforePassCallback = (_, pass) {
            log.add('before:${pass.name}');
          }
          ..afterPassCallback = (_, pass) {
            log.add('after:${pass.name}');
          };
        game.camera.renderPasses = const [
          RenderPass.shadows,
          RenderPass.opaque,
          RenderPass.emissive,
        ];

        final towerA = _MultiPassPropComponent(
          'A',
          log,
          priority: 1,
          passes: const {RenderPass.shadows, RenderPass.opaque},
        );
        final towerB = _MultiPassPropComponent(
          'B',
          log,
          priority: 2,
          passes: const {
            RenderPass.shadows,
            RenderPass.opaque,
            RenderPass.emissive,
          },
        );
        await game.world.ensureAddAll([towerA, towerB]);

        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(log, [
          'before:shadows',
          'A:shadows',
          'B:shadows',
          'after:shadows',
          'before:opaque',
          'A:opaque',
          'B:opaque',
          'after:opaque',
          'before:emissive',
          'B:emissive',
          'after:emissive',
        ]);
        expect(CameraComponent.currentRenderPass, isNull);
      },
    );

    testWithFlameGame(
      'exclusiveToMultiPass pass (RenderPass.emissiveMask) skips ordinary '
      'components while rendering nested MultiPassComponents',
      (game) async {
        final log = <String>[];
        final floor = _PlainFloorComponent(log);
        final container = PositionComponent();
        final lantern = _MultiPassPropComponent(
          'lantern',
          log,
          passes: const {RenderPass.opaque, RenderPass.emissiveMask},
        );
        container.add(lantern);
        await game.world.ensureAddAll([floor, container]);
        await game.ready();

        game.camera.renderPasses = const [
          RenderPass.opaque,
          RenderPass.emissiveMask,
        ];

        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(log, [
          'floor:opaque',
          'lantern:opaque',
          'lantern:emissiveMask',
        ]);
      },
    );

    testWithFlameGame(
      'single-pass camera falls back to MultiPassComponent.fallbackPasses',
      (game) async {
        final log = <String>[];
        final prop = _MultiPassPropComponent(
          'solo',
          log,
          passes: const {RenderPass.shadows, RenderPass.opaque},
        );
        await game.world.ensureAdd(prop);

        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(log, ['solo:shadows', 'solo:opaque']);
      },
    );
  });

  group('Anchored Camera Zoom (#9 part 1)', () {
    testWithFlameGame(
      'zoomAtViewportPoint keeps the world point under cursor invariant',
      (game) async {
        game.onGameResize(Vector2(800, 600));
        game.camera.viewfinder
          ..position = Vector2(120, -45)
          ..zoom = 1.0;

        final cursorViewportPt = Vector2(230, 140);
        final worldBefore = game.camera.viewfinder.globalToLocal(
          cursorViewportPt,
        );

        game.camera.zoomAtViewportPoint(
          cursorViewportPt,
          2.75,
          minZoom: 0.5,
          maxZoom: 4.0,
        );
        final worldAfterZoomIn = game.camera.viewfinder.globalToLocal(
          cursorViewportPt,
        );
        expect(worldAfterZoomIn.x, closeTo(worldBefore.x, 1e-4));
        expect(worldAfterZoomIn.y, closeTo(worldBefore.y, 1e-4));

        game.camera.zoomAtViewportPoint(
          cursorViewportPt,
          0.65,
          minZoom: 0.5,
          maxZoom: 4.0,
        );
        final worldAfterZoomOut = game.camera.viewfinder.globalToLocal(
          cursorViewportPt,
        );
        expect(worldAfterZoomOut.x, closeTo(worldBefore.x, 1e-4));
        expect(worldAfterZoomOut.y, closeTo(worldBefore.y, 1e-4));
      },
    );

    test(
      'TactileCameraController.zoomByFactorAnchored keeps focal world point '
      'stationary',
      () {
        final controller = TactileCameraController(
          maxPanX: 500,
          maxPanY: 500,
          minZoomFactor: 0.5,
          maxZoomFactor: 3.0,
        );
        const baseZoom = 1.25;
        const deltaX = 160.0;
        const deltaY = -95.0;

        // World point under (deltaX, deltaY) relative to canonical center (0,0)
        // is pan + delta / (baseZoom * zoomFactor).
        final beforeX =
            controller.panX + deltaX / (baseZoom * controller.zoomFactor);
        final beforeY =
            controller.panY + deltaY / (baseZoom * controller.zoomFactor);

        controller.zoomByFactorAnchored(
          1.8,
          viewportDeltaX: deltaX,
          viewportDeltaY: deltaY,
          baseZoom: baseZoom,
        );

        final afterX =
            controller.panX + deltaX / (baseZoom * controller.zoomFactor);
        final afterY =
            controller.panY + deltaY / (baseZoom * controller.zoomFactor);

        expect(afterX, closeTo(beforeX, 1e-6));
        expect(afterY, closeTo(beforeY, 1e-6));
      },
    );
  });
}
