import 'dart:ui' show Canvas, PointerDeviceKind;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart' show CullMode;
import 'package:flame_3d/input.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests send real pointer events (through the Flutter gesture
/// pipeline and Flame's dispatchers) to a `PointerRouter3D`. The 3D layers
/// draw nothing, so the tests run without Flutter GPU; the same for a
/// `FlameGame3D`, which needs Flutter GPU, is in
/// `test/gpu/pointer_router_flame_game_3d_test.dart`.

class _Piece({required super.mesh})
    extends MeshComponent
    with TapCallbacks3D, DragCallbacks3D, HoverCallbacks3D {
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

  @override
  void onHoverEnter3D(HoverEnterEvent3D event) => log.add('hoverEnter');

  @override
  void onHoverMove3D(HoverMoveEvent3D event) {}

  @override
  void onHoverExit3D(HoverExitEvent3D event) => log.add('hoverExit');
}

class _Ground() extends PositionComponent with TapCallbacks {
  int taps = 0;

  @override
  bool containsLocalPoint(Vector2 point) => true;

  @override
  void onTapDown(TapDownEvent event) => taps++;
}

class _Layer({required super.projection, super.position, super.scale})
    extends Scene3DComponent {
  @override
  void render(Canvas canvas) {}
}

// 40 px per scene unit, scene +Y up, looking down -Z.
Scene3DProjection _topDown() {
  return Scene3DProjection.affine(
    origin: Vector2.zero(),
    xAxis: Vector2(40, 0),
    yAxis: Vector2(0, -40),
    zAxis: Vector2.zero(),
    towardsViewer: Vector3(0, 0, 1),
    near: -50,
    far: 50,
  );
}

/// Screen point of [scenePoint] of [layer] in a game whose layer lives in
/// the 2D world seen through the 2D camera.
Offset _screenOf(FlameGame game, Scene3DComponent layer, Vector3 scenePoint) {
  final local = layer.scenePointToLocal(scenePoint);
  final world = layer.absolutePositionOf(local);
  final screen = game.camera.localToGlobal(world);
  return Offset(screen.x, screen.y);
}

Future<(FlameGame, _Layer, _Piece, _Ground)> _pumpLayerGame(
  WidgetTester tester, {
  required bool routerIsChild,
}) async {
  final piece = _Piece(mesh: CuboidMesh(size: Vector3.all(1)));
  final layer = _Layer(
    projection: _topDown(),
    position: Vector2(60, -40),
    scale: Vector2.all(1.5),
  );
  layer.world.add(piece);
  final router = PointerRouter3D.forScene(layer, cullMode: CullMode.none);
  final ground = _Ground()..priority = -10;
  final game = FlameGame();
  game.world.addAll([ground, layer]);
  if (routerIsChild) {
    layer.add(router);
  } else {
    game.world.add(router);
  }
  game.camera.viewfinder
    ..zoom = 1.25
    ..position = Vector2(20, 10);
  await tester.pumpWidget(GameWidget(game: game));
  await tester.pump();
  await tester.pump();
  expect(router.isMounted, isTrue);
  expect(router.isDropPayload, isFalse);
  return (game, layer, piece, ground);
}

void main() {
  group('PointerRouter3D through real pointer events', () {
    for (final routerIsChild in [true, false]) {
      final where = routerIsChild ? 'child of' : 'sibling of';
      testWidgets('taps a piece in a moved, scaled layer (router $where it) '
          'through a zoomed, panned 2D camera', (tester) async {
        final (game, layer, piece, ground) = await _pumpLayerGame(
          tester,
          routerIsChild: routerIsChild,
        );

        await tester.tapAt(_screenOf(game, layer, Vector3(0.3, -0.2, 0)));
        await tester.pump(const Duration(seconds: 1));
        expect(piece.log, ['tapDown', 'tapUp']);
        expect(ground.taps, 0, reason: 'a hit is consumed by the router');

        piece.log.clear();
        await tester.tapAt(_screenOf(game, layer, Vector3(3, 2, 0)));
        await tester.pump(const Duration(seconds: 1));
        expect(piece.log, isEmpty);
        expect(ground.taps, 1, reason: 'a miss reaches the 2D ground');
      });
    }

    testWidgets('drags a piece on its plane by the pointer motion', (
      tester,
    ) async {
      final (game, layer, piece, _) = await _pumpLayerGame(
        tester,
        routerIsChild: false,
      );
      final from = _screenOf(game, layer, Vector3.zero());
      final to = _screenOf(game, layer, Vector3(2, 1, 0));
      await tester.dragFrom(from, to - from);
      await tester.pump(const Duration(seconds: 1));
      // The press is first a tap down, cancelled when the drag starts.
      expect(piece.log, ['tapDown', 'tapCancel', 'dragStart', 'dragEnd']);
      // The piece follows the pointer exactly: it ends where it is.
      expect(piece.position.x, closeTo(2, 1e-3));
      expect(piece.position.y, closeTo(1, 1e-3));
      expect(piece.position.z, closeTo(0, 1e-6));
    });

    testWidgets('hovers with a mouse: enter over the piece, exit off it', (
      tester,
    ) async {
      final (game, layer, piece, _) = await _pumpLayerGame(
        tester,
        routerIsChild: true,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(_screenOf(game, layer, Vector3(0.1, 0.1, 0)));
      await tester.pump();
      expect(piece.log, ['hoverEnter']);
      await mouse.moveTo(_screenOf(game, layer, Vector3(3, 2, 0)));
      await tester.pump();
      expect(piece.log, ['hoverEnter', 'hoverExit']);
    });
  });
}
