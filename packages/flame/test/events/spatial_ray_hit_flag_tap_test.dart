// The 3D-ray hit flag must be false again once a gesture whose hit tests
// stopped early (tap-down is delivered to the first handler only) is over.
import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tile3D() extends Component with SpatialHitbox3D, TapCallbacks {
  int tapDowns = 0;
  int tapCancels = 0;

  @override
  (double, double, double, double)? get boundingSphere3D =>
      (0.0, 0.0, -0.5, 4.0);

  @override
  double? intersectRay3D(Ray3D ray) => intersectWorldAabb3D(
    ray,
    minX: -2.0,
    minY: -2.0,
    minZ: -1.0,
    maxX: 2.0,
    maxY: 2.0,
    maxZ: 0.0,
  );

  @override
  void onTapDown(TapDownEvent event) => tapDowns++;

  @override
  void onTapCancel(TapCancelEvent event) => tapCancels++;
}

void main() {
  testWidgets('isActiveSpatialRayHit is false again after a cancelled tap', (
    tester,
  ) async {
    final tile = _Tile3D();
    final world = World(children: [tile]);
    final camera = CameraComponent(world: world)
      ..rayProjector3D = (viewportPt, _) => Ray3D(
        ox: (viewportPt.x - 400.0) / 25.0,
        oy: (viewportPt.y - 300.0) / 25.0,
        oz: 10.0,
        dx: 0.0,
        dy: 0.0,
        dz: -1.0,
      );
    final game = FlameGame(world: world, camera: camera);
    await tester.pumpWidget(GameWidget(game: game));
    await tester.pump();
    await tester.pump();

    expect(tile.isActiveSpatialRayHit, isFalse);
    // Press on the tile (tap-down is delivered at once), slide far away
    // before the long-tap delay (the tap is cancelled) and lift.
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(const Offset(700, 550));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tile.tapDowns, 1);
    expect(tile.tapCancels, 1);
    expect(
      tile.isActiveSpatialRayHit,
      isFalse,
      reason: 'no hit test is in progress any more',
    );
  });
}
