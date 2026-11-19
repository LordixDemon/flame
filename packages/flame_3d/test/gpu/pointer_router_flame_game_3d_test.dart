import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart' show CullMode;
import 'package:flame_3d/input.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

class _Piece({required super.mesh})
    extends MeshComponent
    with TapCallbacks3D, DragCallbacks3D {
  final List<String> log = [];

  @override
  Vector3? get dragPlaneNormal => Vector3(0, 0, 1);

  @override
  void onTapDown3D(TapDownEvent3D event) => log.add('tapDown');

  @override
  void onTapUp3D(TapUpEvent3D event) => log.add('tapUp');

  @override
  void onTapCancel3D(TapCancelEvent3D event) => log.add('tapCancel');

  @override
  void onDragStart3D(DragStartEvent3D event) => log.add('dragStart');

  @override
  void onDragUpdate3D(DragUpdateEvent3D event) =>
      position.add(event.worldDelta);

  @override
  void onDragEnd3D(DragEndEvent3D event) => log.add('dragEnd');
}

void main() {
  setUpGpu();

  group('PointerRouter3D in a rendering FlameGame3D', () {
    testGpu('taps and drags a piece with real pointer events', (tester) async {
      final piece = _Piece(mesh: CuboidMesh(size: Vector3.all(1)));
      final game = FlameGame3D();
      game.camera
        ..position = Vector3(0, 0, 10)
        ..target = Vector3.zero();
      game.world.add(piece);
      final router = PointerRouter3D.forCamera(
        world: game.world,
        camera: game.camera,
        cullMode: CullMode.none,
      );
      game.add(router);
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await tester.pump();
      expect(router.isMounted, isTrue);

      Offset screenOf(Vector3 p) {
        final v = game.camera.worldToViewportPoint(p);
        return Offset(v.x, v.y);
      }

      await tester.tapAt(screenOf(Vector3(0.2, 0.2, 0.5)));
      await tester.pump(const Duration(seconds: 1));
      expect(piece.log, ['tapDown', 'tapUp']);

      piece.log.clear();
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(seconds: 1));
      expect(piece.log, isEmpty);

      // Drag the top face (z = 0.5) by (2, 1) on its plane.
      final from = screenOf(Vector3(0, 0, 0.5));
      final to = screenOf(Vector3(2, 1, 0.5));
      await tester.dragFrom(from, to - from);
      await tester.pump(const Duration(seconds: 1));
      expect(piece.log, ['tapDown', 'tapCancel', 'dragStart', 'dragEnd']);
      expect(piece.position.x, closeTo(2, 1e-3));
      expect(piece.position.y, closeTo(1, 1e-3));
    });
  });
}
