import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _NavButton({
  required final String label,
  required super.position,
  int order = 0,
}) extends PositionComponent with FocusableComponent {
  int activations = 0;

  this : super(size: Vector2(40, 24)) {
    focusOrder = order;
  }

  @override
  void onFocusActivate() {
    activations++;
  }
}

void main() {
  group('InputMap, InputContextStack, FocusNavigationGroup & HapticEngine', () {
    test(
      'InputMap tracks key chords, gamepad axes, edge transitions & JSON '
      'persistence',
      () {
        final map = InputMap()
          ..bind(
            'boost_roll',
            ActionBinding.key(
              LogicalKeyboardKey.space,
              modifiers: <LogicalKeyboardKey>[LogicalKeyboardKey.shiftLeft],
            ),
          )
          ..bind('fire', const ActionBinding.mouseButton(1))
          ..bind('left', ActionBinding.key(LogicalKeyboardKey.keyA))
          ..bind('right', ActionBinding.key(LogicalKeyboardKey.keyD))
          ..bind('up', ActionBinding.key(LogicalKeyboardKey.keyW))
          ..bind('down', ActionBinding.key(LogicalKeyboardKey.keyS))
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
              responseExponent: 1.0,
            ),
          );

        // Space alone does not trigger chord `Shift + Space`.
        map.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration.zero,
          ),
        );
        expect(map.isPressed('boost_roll'), isFalse);

        // Pressing Shift completes the chord -> justPressed!
        map.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.shiftLeft,
            logicalKey: LogicalKeyboardKey.shiftLeft,
            timeStamp: Duration.zero,
          ),
        );
        expect(map.isPressed('boost_roll'), isTrue);
        expect(map.justPressed('boost_roll'), isTrue);

        map.endFrame();
        expect(map.isPressed('boost_roll'), isTrue);
        expect(map.justPressed('boost_roll'), isFalse);

        map.handleKeyEvent(
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration.zero,
          ),
        );
        expect(map.isPressed('boost_roll'), isFalse);
        expect(map.justReleased('boost_roll'), isTrue);
        map.endFrame();

        // Analog stick radial deadzone & activeDevice switching.
        final axisOut = Vector2.zero();
        map.setGamepadAxis('lx', 0.1);
        map.setGamepadAxis('ly', 0.1);
        map.readAxis2D('move', axisOut);
        expect(axisOut.length, 0.0);

        map.setGamepadAxis('lx', 0.6);
        map.setGamepadAxis('ly', 0.0);
        expect(map.activeDevice, InputDeviceKind.gamepad);
        map.readAxis2D('move', axisOut);
        expect(axisOut.x, closeTo(0.5, 1e-4));

        // JSON export/import roundtrip.
        final exported = map.exportBindingsJson();
        final restored = InputMap()..importBindingsJson(exported);
        expect(restored.bindingsFor('boost_roll').length, 1);
        expect(restored.bindingsFor('fire').single.mouseButton, 1);

        map.dispose();
        restored.dispose();
      },
    );

    test(
      'InputContextStack blocks lower modal actions & spotlights tutorial '
      'targets, plus InputBuffer grace window',
      () {
        final allowedTile = PositionComponent();
        final blockedTile = PositionComponent();
        final childOfAllowed = PositionComponent();
        allowedTile.add(childOfAllowed);

        final stack = InputContextStack()
          ..push(InputContext(name: 'gameplay'))
          ..push(
            InputContext(
              name: 'tutorial_spotlight',
              priority: 10,
              allowedActions: const <String>['confirm'],
              allowedTargets: <Component>[allowedTile],
            ),
          );

        expect(stack.isActionAllowed('confirm'), isTrue);
        expect(stack.isActionAllowed('pause_menu'), isFalse);
        expect(stack.isTargetAllowed(allowedTile), isTrue);
        expect(stack.isTargetAllowed(childOfAllowed), isTrue);
        expect(stack.isTargetAllowed(blockedTile), isFalse);

        stack.pop();
        expect(stack.isActionAllowed('pause_menu'), isTrue);
        expect(stack.isTargetAllowed(blockedTile), isTrue);

        // InputBuffer 150ms grace window.
        final buffer = InputBuffer()..buffer('roll');
        buffer.update(0.10);
        expect(buffer.hasBuffered('roll'), isTrue);
        expect(buffer.consume('roll'), isTrue);
        expect(buffer.hasBuffered('roll'), isFalse);

        buffer.buffer('jump');
        buffer.update(0.20);
        expect(buffer.consume('jump'), isFalse);
      },
    );

    test(
      'FocusNavigationGroup navigates 2D spatial cones and wraps sequential '
      'Tab order',
      () {
        final topLeft = _NavButton(
          label: 'tl',
          position: Vector2(0, 0),
        );
        final topRight = _NavButton(
          label: 'tr',
          position: Vector2(120, 0),
          order: 1,
        );
        final bottomRight = _NavButton(
          label: 'br',
          position: Vector2(120, 90),
          order: 2,
        );

        final group = FocusNavigationGroup()
          ..register(topLeft)
          ..register(topRight)
          ..register(bottomRight);

        group.requestFocus(topLeft);
        expect(topLeft.isFocused, isTrue);

        expect(group.moveFocus(FocusDirection.right), topRight);
        expect(topLeft.isFocused, isFalse);
        expect(topRight.isFocused, isTrue);

        expect(group.moveFocus(FocusDirection.down), bottomRight);
        expect(group.activateFocused(), isTrue);
        expect(bottomRight.activations, 1);

        // Sequential wrap: bottomRight (order 2) -> next -> topLeft (order 0).
        expect(group.moveFocus(FocusDirection.next), topLeft);
      },
    );

    test(
      'HapticEngine coalesces same-frame patterns to highest rank and enforces '
      'cooldown',
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

        // Within 50ms cooldown -> throttled.
        haptics
          ..request(HapticPattern.mediumImpact)
          ..flushFrame(0.020);
        expect(backend.emitted.length, 1);

        // Past cooldown -> emitted.
        haptics
          ..request(HapticPattern.successPulse)
          ..flushFrame(0.040);
        expect(
          backend.emitted,
          <HapticPattern>[
            HapticPattern.heavyImpact,
            HapticPattern.successPulse,
          ],
        );
      },
    );
  });
}
