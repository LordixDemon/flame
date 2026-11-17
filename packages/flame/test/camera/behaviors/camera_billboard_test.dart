import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';

/// Records where and at which angle the component ends up on screen.
class _ScreenProbe({super.position, super.size}) extends PositionComponent {
  this : super(anchor: Anchor.center);

  /// On-screen rotation (radians) of this component's local X axis.
  double? screenRotation;

  /// On-screen axis-aligned box of the component.
  Rect? screenBounds;

  @override
  void render(Canvas canvas) {
    final m = canvas.getTransform();
    screenRotation = math.atan2(m[1], m[0]);
    final xs = <double>[];
    final ys = <double>[];
    for (final corner in [
      (0.0, 0.0),
      (size.x, 0.0),
      (0.0, size.y),
      (size.x, size.y),
    ]) {
      xs.add(m[0] * corner.$1 + m[4] * corner.$2 + m[12]);
      ys.add(m[1] * corner.$1 + m[5] * corner.$2 + m[13]);
    }
    screenBounds = Rect.fromLTRB(
      xs.reduce(math.min),
      ys.reduce(math.min),
      xs.reduce(math.max),
      ys.reduce(math.max),
    );
  }
}

class _Billboard({super.position, super.size})
    extends _ScreenProbe
    with CameraBillboard;

class _Pin({super.position, super.size})
    extends _ScreenProbe
    with ViewportClampedPin;

class _BillboardThenPin({super.position, super.size})
    extends _ScreenProbe
    with CameraBillboard, ViewportClampedPin;

class _PinThenBillboard({super.position, super.size})
    extends _ScreenProbe
    with ViewportClampedPin, CameraBillboard;

void main() {
  const screen = Rect.fromLTWH(0, 0, 400, 300);

  Future<FlameGame> makeGame() async {
    final game = FlameGame(
      camera: CameraComponent(viewport: FixedSizeViewport(400, 300)),
    )..onGameResize(Vector2(400, 300));
    await game.start();
    return game;
  }

  void renderOnce(FlameGame game) {
    final rec = PictureRecorder();
    game.camera.renderTree(Canvas(rec, screen));
    rec.endRecording().dispose();
  }

  group('CameraBillboard', () {
    test('stays upright on screen while the viewfinder is rotated', () async {
      final game = await makeGame();
      final plain = _ScreenProbe(
        position: Vector2(10, 0),
        size: Vector2(40, 20),
      );
      final billboard = _Billboard(
        position: Vector2(-10, 0),
        size: Vector2(40, 20),
      );
      game.world.addAll([plain, billboard]);
      await game.ready();

      renderOnce(game);
      expect(plain.screenRotation, closeTo(0.0, 1e-9));
      expect(billboard.screenRotation, closeTo(0.0, 1e-9));

      for (final roll in [0.14, -0.6, 2.0]) {
        game.camera.viewfinder.angle = roll;
        renderOnce(game);

        // An ordinary world component follows the camera roll ...
        expect(plain.screenRotation, closeTo(-roll, 1e-6));
        // ... a billboard cancels it.
        expect(billboard.screenRotation, closeTo(0.0, 1e-6));
      }
    });

    test('keeps following the camera roll when compensation is off', () async {
      final game = await makeGame();
      final billboard = _Billboard(size: Vector2(40, 20))
        ..compensateCameraRotation = false;
      game.world.add(billboard);
      await game.ready();

      game.camera.viewfinder.angle = 0.3;
      renderOnce(game);
      expect(billboard.screenRotation, closeTo(-0.3, 1e-6));
    });

    test('rotates around its own position', () async {
      final game = await makeGame();
      final billboard = _Billboard(
        position: Vector2(60, -30),
        size: Vector2(40, 20),
      );
      game.world.add(billboard);
      await game.ready();

      renderOnce(game);
      game.camera.viewfinder.angle = 0.5;
      renderOnce(game);

      // World point (60, -30) seen through a camera rotated by 0.5 rad.
      final expectedX = 200 + 60 * math.cos(-0.5) - (-30) * math.sin(-0.5);
      final expectedY = 150 + 60 * math.sin(-0.5) + (-30) * math.cos(-0.5);
      expect(billboard.screenBounds!.center.dx, closeTo(expectedX, 1e-3));
      expect(billboard.screenBounds!.center.dy, closeTo(expectedY, 1e-3));
      expect(billboard.screenBounds!.width, closeTo(40, 1e-3));
    });
  });

  group('ViewportClampedPin', () {
    test('leaves a visible pin under a positioned parent alone', () async {
      final game = await makeGame();
      // A carrier far away from the world origin; the camera looks at it.
      final carrier = PositionComponent(position: Vector2(1000, 1000));
      final pin = _Pin(position: Vector2(0, -20), size: Vector2(40, 20))
        ..viewportPinMargin = const EdgeInsets.all(10);
      carrier.add(pin);
      game.world.add(carrier);
      game.camera.viewfinder.position = Vector2(1000, 1000);
      await game.ready();

      renderOnce(game);

      // World position (1000, 980): 20 px above the centre of the view.
      expect(pin.lastClampDelta, Vector2.zero());
      expect(pin.screenBounds!.center.dx, closeTo(200, 1e-3));
      expect(pin.screenBounds!.center.dy, closeTo(130, 1e-3));
    });

    test('clamps an off-screen pin under a positioned parent', () async {
      final game = await makeGame();
      // The carrier is 800 px right of the right screen edge, while the pin's
      // local position is close to (0, 0).
      final carrier = PositionComponent(position: Vector2(1000, 0));
      final pin = _Pin(position: Vector2(0, -20), size: Vector2(40, 20))
        ..viewportPinMargin = const EdgeInsets.all(10);
      carrier.add(pin);
      game.world.add(carrier);
      await game.ready();

      renderOnce(game);

      expect(pin.lastClampDelta.x, closeTo(-830, 1e-3));
      expect(pin.lastClampDelta.y, closeTo(0, 1e-3));
      expect(pin.screenBounds!.right, closeTo(390, 1e-3));
      expect(pin.screenBounds!.center.dy, closeTo(130, 1e-3));
    });

    test('clamps through scaled and rotated ancestors', () async {
      final game = await makeGame();
      final carrier = PositionComponent(
        position: Vector2(40, 10),
        scale: Vector2.all(2),
        angle: math.pi / 2,
      );
      final inner = PositionComponent(position: Vector2(5, 5));
      // Carrier frame: local (x, y) -> world (40 - 2y, 10 + 2x). The pin sits
      // at carrier-local (305, 5), i.e. world (30, 620): far below the view.
      final pin = _Pin(position: Vector2(300, 0), size: Vector2(10, 10))
        ..viewportPinMargin = const EdgeInsets.all(10);
      inner.add(pin);
      carrier.add(inner);
      game.world.add(carrier);
      await game.ready();

      renderOnce(game);

      // Drawn 20x20 (parent scale 2); pushed up to the bottom safe margin and
      // left where it was horizontally (world x = 30 -> screen x = 230).
      expect(pin.screenBounds!.bottom, closeTo(290, 1e-3));
      expect(pin.screenBounds!.center.dx, closeTo(230, 1e-3));
      expect(pin.screenBounds!.width, closeTo(20, 1e-3));
    });

    test('still clamps a direct child of the world', () async {
      final game = await makeGame();
      final pin = _Pin(position: Vector2(500, -400), size: Vector2(40, 20))
        ..viewportPinMargin = const EdgeInsets.all(10);
      game.world.add(pin);
      await game.ready();

      renderOnce(game);

      expect(pin.screenBounds!.right, closeTo(390, 1e-3));
      expect(pin.screenBounds!.top, closeTo(10, 1e-3));
    });

    final orders = <String, _ScreenProbe Function(Vector2)>{
      'CameraBillboard, ViewportClampedPin': (p) =>
          _BillboardThenPin(position: p, size: Vector2(40, 20)),
      'ViewportClampedPin, CameraBillboard': (p) =>
          _PinThenBillboard(position: p, size: Vector2(40, 20)),
    };
    for (final MapEntry(key: name, value: make) in orders.entries) {
      test('lands on the safe margin with mixin order "$name"', () async {
        final game = await makeGame();
        final carrier = PositionComponent(position: Vector2(700, 0));
        final pin = make(Vector2(0, -20));
        (pin as ViewportClampedPin).viewportPinMargin = const EdgeInsets.all(
          10,
        );
        carrier.add(pin);
        game.world.add(carrier);
        game.camera.viewfinder
          ..zoom = 2.0
          ..angle = 0.0;
        await game.ready();

        renderOnce(game);

        // Zoom 2 with full zoom compensation: 40x20 on screen, right edge on
        // the 10 px margin, vertical position untouched (world y = -20).
        expect(pin.screenBounds!.width, closeTo(40, 1e-3));
        expect(pin.screenBounds!.right, closeTo(390, 1e-3));
        expect(pin.screenBounds!.center.dy, closeTo(110, 1e-3));
      });
    }
  });
}
