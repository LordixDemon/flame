import 'dart:math' as math;

import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tower3DComponent({
  required final String name,
  required final List<String> tapLog,
  required final double minZ,
  required final double maxZ,
  super.position,
  super.size,
}) extends PositionComponent with TapCallbacks, SpatialHitbox3D {
  @override
  double? intersectRay3D(Ray3D ray) {
    return intersectWorldAabb3D(
      ray,
      minX: position.x,
      minY: position.y,
      minZ: minZ,
      maxX: position.x + size.x,
      maxY: position.y + size.y,
      maxZ: maxZ,
    );
  }

  @override
  void onTapDown(TapDownEvent event) {
    tapLog.add(name);
  }
}

class _Flat2DFallbackTile(
  final List<String> tapLog, {
  super.position,
  super.size,
}) extends PositionComponent with TapCallbacks {
  @override
  void onTapDown(TapDownEvent event) {
    tapLog.add('flat2d');
  }
}

void main() {
  group('Native 3D Raycast Hit-Testing', () {
    testWidgets(
      'CameraComponent.rayProjector3D picks closer tall 3D tower in front of '
      'rear tile even when 2D ground footprints do not overlap',
      (tester) async {
        final tapLog = <String>[];
        final game = FlameGame();

        final invSqrt2 = 1.0 / math.sqrt(2.0);
        game.camera.rayProjector3D = (viewportPt, worldPt) {
          return Ray3D(
            ox: worldPt.x,
            oy: worldPt.y + 100.0,
            oz: 100.0,
            dx: 0.0,
            dy: -invSqrt2,
            dz: -invSqrt2,
          );
        };

        final rearLowTile = _Tower3DComponent(
          name: 'rearLowTile',
          tapLog: tapLog,
          position: Vector2(-15, -10),
          size: Vector2(30, 20),
          minZ: 0,
          maxZ: 10,
        );

        final frontTallSpire = _Tower3DComponent(
          name: 'frontTallSpire',
          tapLog: tapLog,
          position: Vector2(-15, 40),
          size: Vector2(30, 20),
          minZ: 0,
          maxZ: 65,
        );

        final fallback2D = _Flat2DFallbackTile(
          tapLog,
          position: Vector2(120, -10),
          size: Vector2(40, 40),
        );

        await tester.pumpWidget(
          SizedBox(
            width: 800,
            height: 600,
            child: GameWidget(game: game),
          ),
        );
        await tester.pump();
        game.world.addAll([rearLowTile, frontTallSpire, fallback2D]);
        await game.ready();
        game.camera.viewfinder.position = Vector2.zero();
        await tester.pump();

        await tester.tapAt(const Offset(400, 300));
        await tester.pump(const Duration(seconds: 1));

        expect(tapLog, ['frontTallSpire']);
        final frontDist = frontTallSpire.lastHitDistance3D;
        final rearDist = rearLowTile.lastHitDistance3D;
        expect(frontDist, isNotNull);
        expect(rearDist, isNotNull);
        expect(frontDist, lessThan(rearDist!));
        expect(frontTallSpire.lastHitPoint3D!.$3, greaterThan(40.0));

        tapLog.clear();
        await tester.tapAt(const Offset(540, 300));
        await tester.pump(const Duration(seconds: 1));
        expect(tapLog, ['flat2d']);
      },
    );
  });
}
