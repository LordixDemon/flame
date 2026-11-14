import 'package:flame/components.dart';
import 'package:flame/input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

KeyDownEvent _down(LogicalKeyboardKey key) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  timeStamp: Duration.zero,
);

KeyUpEvent _up(LogicalKeyboardKey key) => KeyUpEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  timeStamp: Duration.zero,
);

class _MenuButton({
  required super.position,
  required super.size,
  super.anchor,
}) extends PositionComponent with FocusableComponent {
  final List<String> events = <String>[];

  @override
  void onFocusGain() => events.add('gain');

  @override
  void onFocusLost() => events.add('lose');

  @override
  void onFocusActivate() => events.add('activate');
}

void main() {
  group('InputMap chords, axes, releaseAllInputs & JSON rebinding', () {
    test('multi-key chord, OR-bindings & releaseAllInputs on window blur', () {
      final map = InputMap()
        ..bind(
          'undo',
          ActionBinding.key(
            LogicalKeyboardKey.keyZ,
            modifiers: <LogicalKeyboardKey>[
              LogicalKeyboardKey.controlLeft,
              LogicalKeyboardKey.shiftLeft,
            ],
          ),
        )
        ..bind('fire', ActionBinding.key(LogicalKeyboardKey.space))
        ..bind('fire', const ActionBinding.mouseButton(1))
        ..bind('fire', const ActionBinding.gamepadButton('south'));

      // Partial chord does not trigger.
      map.handleKeyEvent(_down(LogicalKeyboardKey.controlLeft));
      map.handleKeyEvent(_down(LogicalKeyboardKey.shiftLeft));
      expect(map.isPressed('undo'), isFalse);

      // Completing the 3-key chord triggers justPressed!
      map.handleKeyEvent(_down(LogicalKeyboardKey.keyZ));
      expect(map.isPressed('undo'), isTrue);
      expect(map.justPressed('undo'), isTrue);
      expect(map.activeDevice, InputDeviceKind.mouseKeyboard);
      map.endFrame();
      expect(map.justPressed('undo'), isFalse);
      expect(map.isPressed('undo'), isTrue);

      // OR-bindings: holding space + mouse button 1 keeps `fire` pressed when
      // space releases!
      map.handleKeyEvent(_down(LogicalKeyboardKey.space));
      map.setMouseButtonsMask(1);
      map.endFrame();
      map.handleKeyEvent(_up(LogicalKeyboardKey.space));
      expect(map.isPressed('fire'), isTrue);
      expect(map.justReleased('fire'), isFalse);

      // Simulated Alt-Tab / OS window focus loss releases all held inputs
      // cleanly and populates justReleased!
      map.setGamepadButton('south', isDown: true);
      map.setTouchAction('fire', isDown: true);
      expect(map.activeDeviceListenable.value, InputDeviceKind.touch);
      map.endFrame();
      map.releaseAllInputs();
      expect(map.isPressed('undo'), isFalse);
      expect(map.isPressed('fire'), isFalse);
      expect(map.justReleased('undo'), isTrue);
      expect(map.justReleased('fire'), isTrue);

      map.endFrame();
      expect(map.justReleased('fire'), isFalse);
    });

    test(
      'InputAxis2D opposite cancel, diagonal norm & JSON rebinding IO',
      () {
        final map = InputMap()
          ..bind('left', ActionBinding.key(LogicalKeyboardKey.keyA))
          ..bind('right', ActionBinding.key(LogicalKeyboardKey.keyD))
          ..bind('up', ActionBinding.key(LogicalKeyboardKey.keyW))
          ..bind('down', ActionBinding.key(LogicalKeyboardKey.keyS))
          ..bind(
            'right',
            const ActionBinding.gamepadAxis('lx', threshold: 0.2),
          )
          ..registerAxis2D(
            'move',
            const InputAxis2D(
              leftAction: 'left',
              rightAction: 'right',
              upAction: 'up',
              downAction: 'down',
              analogAxisX: 'lx',
              analogAxisY: 'ly',
              deadzone: 0.2,
              responseExponent: 2.0,
            ),
          );

        final dir = Vector2.zero();
        // Opposite horizontal keys cancel to 0.
        map.handleKeyEvent(_down(LogicalKeyboardKey.keyA));
        map.handleKeyEvent(_down(LogicalKeyboardKey.keyD));
        map.readAxis2D('move', dir);
        expect(dir.length, closeTo(0.0, 1e-6));

        // Diagonal digital input normalizes to unit circle (length == 1.0).
        map.handleKeyEvent(_up(LogicalKeyboardKey.keyA));
        map.handleKeyEvent(_down(LogicalKeyboardKey.keyW));
        map.readAxis2D('move', dir);
        expect(dir.length, closeTo(1.0, 1e-5));
        expect(dir.x, closeTo(0.707106, 1e-4));
        expect(dir.y, closeTo(-0.707106, 1e-4));

        // Analog stick inside deadzone outputs zero; outside deadzone curves.
        map.releaseAllInputs();
        map.setGamepadAxis('lx', 0.15);
        map.readAxis2D('move', dir);
        expect(dir.length, 0.0);

        map.setGamepadAxis('lx', 0.6); // (0.6 - 0.2) / 0.8 = 0.5 -> 0.5^2=0.25!
        expect(map.activeDevice, InputDeviceKind.gamepad);
        map.readAxis2D('move', dir);
        expect(dir.x, closeTo(0.25, 1e-5));

        // Roundtrip exportBindingsJson / importBindingsJson across types.
        final json = map.exportBindingsJson();
        final cloned = InputMap()..importBindingsJson(json);
        expect(cloned.bindingsFor('right').length, 2);
        cloned.rebind('left', <ActionBinding>[
          ActionBinding.key(LogicalKeyboardKey.arrowLeft),
        ]);
        expect(
          cloned.bindingsFor('left').single.keyId,
          LogicalKeyboardKey.arrowLeft.keyId,
        );
        cloned.clearAction('left');
        expect(cloned.bindingsFor('left'), isEmpty);
      },
    );
  });

  group(
    'InputContextStack, InputBuffer, FocusNavigationGroup & HapticEngine',
    () {
      test(
        'InputContextStack handles priority, pass-through & ancestor spotlight',
        () {
          final rootPanel = Component();
          final childBtn = Component();
          final outsideBtn = Component();
          rootPanel.add(childBtn);

          final stack = InputContextStack()
            ..push(
              InputContext(
                name: 'gameplay',
                priority: 10,
                allowedActions: const <String>['move', 'jump', 'pause'],
              ),
            )
            ..push(
              InputContext(
                name: 'hud_overlay',
                priority: 20,
                blocksLowerContexts: false,
                allowedActions: const <String>['ping'],
              ),
            );

          // Non-blocking overlay allows its own 'ping' AND lower 'jump', while
          // gameplay still blocks unknown 'cheat'.
          expect(stack.isActionAllowed('ping'), isTrue);
          expect(stack.isActionAllowed('jump'), isTrue);
          expect(stack.isActionAllowed('cheat'), isFalse);

          // Tutorial spotlight modal blocks lower contexts and permits
          // descendants of `rootPanel`!
          final tutorial = InputContext(
            name: 'tutorial',
            priority: 100,
            allowedActions: const <String>['confirm'],
            allowedTargets: <Component>[rootPanel],
          );
          stack.push(tutorial);
          expect(stack.isActionAllowed('jump'), isFalse);
          expect(stack.isActionAllowed('confirm'), isTrue);
          expect(stack.isTargetAllowed(childBtn), isTrue);
          expect(stack.isTargetAllowed(outsideBtn), isFalse);

          // Disabling top context falls through transparently!
          tutorial.isEnabled = false;
          expect(stack.isActionAllowed('jump'), isTrue);
          expect(stack.removeByName('tutorial'), isTrue);
          expect(stack.pop()?.name, 'hud_overlay');
          stack.clear();
          expect(stack.isActionAllowed('anything'), isTrue);
        },
      );

      test('InputBuffer expires stale actions and consumes once', () {
        final buf = InputBuffer(defaultWindowSeconds: 0.12)
          ..buffer('jump')
          ..buffer('dash', windowSeconds: 0.05);
        expect(buf.hasBuffered('jump'), isTrue);
        expect(buf.hasBuffered('dash'), isTrue);

        buf.update(0.06);
        expect(buf.hasBuffered('dash'), isFalse);
        expect(buf.consume('dash'), isFalse);
        expect(buf.consume('jump'), isTrue);
        expect(buf.consume('jump'), isFalse);
      });

      test(
        'FocusNavigationGroup handles Anchor.center, non-wrap & disabled focus',
        () {
          final topLeft = _MenuButton(
            position: Vector2(50, 50),
            size: Vector2(80, 30),
            anchor: Anchor.center,
          );
          final topRight = _MenuButton(
            position: Vector2(200, 50),
            size: Vector2(80, 30),
            anchor: Anchor.center,
          );
          final bottomRight = _MenuButton(
            position: Vector2(200, 150),
            size: Vector2(80, 30),
            anchor: Anchor.center,
          );

          final nav = FocusNavigationGroup(wrapSequential: false)
            ..register(topLeft)
            ..register(topRight)
            ..register(bottomRight);

          expect(nav.moveFocus(FocusDirection.next), same(topLeft));
          expect(nav.moveFocus(FocusDirection.right), same(topRight));
          expect(nav.moveFocus(FocusDirection.down), same(bottomRight));
          // wrapSequential == false clamps at the ends!
          expect(nav.moveFocus(FocusDirection.next), same(bottomRight));

          // Disabling focused item and navigating away fires onFocusLost!
          bottomRight.canFocus = false;
          expect(nav.moveFocus(FocusDirection.up), same(topLeft));
          expect(bottomRight.isFocused, isFalse);
          expect(bottomRight.events, contains('lose'));

          expect(nav.activateFocused(), isTrue);
          expect(topLeft.events.last, 'activate');
        },
      );

      test(
        'HapticEngine coalesces strongest rank, throttles & respects toggle',
        () {
          final backend = RecordingHapticBackend();
          final haptics = HapticEngine(
            backend: backend,
            minCooldownSeconds: 0.05,
          );

          haptics
            ..request(HapticPattern.selectionTick)
            ..request(HapticPattern.heavyImpact)
            ..request(HapticPattern.lightImpact)
            ..flushFrame(0.016);
          expect(backend.emitted, <HapticPattern>[HapticPattern.heavyImpact]);
          expect(haptics.suppressedCount, 2);

          // Request inside 50 ms cooldown is suppressed.
          haptics
            ..request(HapticPattern.mediumImpact)
            ..flushFrame(0.020);
          expect(backend.emitted.length, 1);
          expect(haptics.suppressedCount, 3);

          // Once cooldown elapses, next burst emits cleanly.
          haptics
            ..request(HapticPattern.errorBuzz)
            ..flushFrame(0.040);
          expect(backend.emitted.last, HapticPattern.errorBuzz);

          // Disabled engine suppresses all requests.
          haptics.enabled = false;
          haptics
            ..request(HapticPattern.warningBuzz)
            ..flushFrame(0.2);
          expect(backend.emitted.length, 2);
        },
      );
    },
  );
}
