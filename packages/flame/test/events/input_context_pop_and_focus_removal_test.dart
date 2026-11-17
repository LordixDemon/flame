import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Item({
  required super.position,
  this.label = '',
}) extends PositionComponent with FocusableComponent {
  this : super(size: Vector2.all(20));

  final String label;
  int gains = 0;
  int losses = 0;

  @override
  void onFocusGain() => gains++;

  @override
  void onFocusLost() => losses++;
}

void main() {
  group('InputContextStack.pop', () {
    test('removes the top-most enabled context and leaves disabled ones', () {
      final gameplay = InputContext(name: 'gameplay');
      final dialog = InputContext(name: 'dialog', priority: 10);
      final tutorial = InputContext(
        name: 'tutorial',
        priority: 20,
        enabled: false,
      );
      final stack = InputContextStack()
        ..push(gameplay)
        ..push(dialog)
        ..push(tutorial);
      expect(stack.contexts.map((c) => c.name), [
        'tutorial',
        'dialog',
        'gameplay',
      ]);

      // The disabled tutorial layer routes nothing, so the dialog is on top.
      expect(stack.pop(), same(dialog));
      expect(stack.contexts.map((c) => c.name), ['tutorial', 'gameplay']);
      expect(stack.pop(), same(gameplay));
      expect(stack.pop(), isNull);
      expect(stack.contexts.single, same(tutorial));

      tutorial.isEnabled = true;
      expect(stack.pop(), same(tutorial));
      expect(stack.pop(), isNull);
      expect(stack.contexts, isEmpty);
    });
  });

  group('FocusNavigationGroup and removed components', () {
    testWithFlameGame(
      'a removed component gives up focus, leaves the candidates and comes '
      'back when it is mounted again',
      (game) async {
        final a = _Item(position: Vector2(0, 0), label: 'a');
        final b = _Item(position: Vector2(100, 0), label: 'b');
        final c = _Item(position: Vector2(200, 0), label: 'c');
        await game.world.ensureAddAll([a, b, c]);

        final group = FocusNavigationGroup()
          ..register(a)
          ..register(b)
          ..register(c);
        expect(group.requestFocus(b), isTrue);
        expect(b.isFocused, isTrue);

        b.removeFromParent();
        await game.ready();

        expect(b.isFocused, isFalse);
        expect(b.losses, 1);
        expect(group.focused, isNull);
        expect(group.candidates, [a, c]);

        // Navigation only ever reaches components that are still there.
        expect(group.moveFocus(FocusDirection.next), same(a));
        expect(group.moveFocus(FocusDirection.right), same(c));
        expect(group.moveFocus(FocusDirection.next), same(a));

        await game.world.ensureAdd(b);
        expect(group.candidates, containsAll(<_Item>[a, b, c]));
        expect(group.moveFocus(FocusDirection.right), same(b));
      },
    );

    testWithFlameGame(
      'an unregistered component stays out after being mounted again',
      (game) async {
        final a = _Item(position: Vector2(0, 0));
        final b = _Item(position: Vector2(100, 0));
        await game.world.ensureAddAll([a, b]);
        final group = FocusNavigationGroup()
          ..register(a)
          ..register(b)
          ..unregister(b);

        b.removeFromParent();
        await game.ready();
        await game.world.ensureAdd(b);

        expect(group.candidates, [a]);
      },
    );

    test('components that were never mounted can still be navigated', () {
      final a = _Item(position: Vector2(0, 0));
      final b = _Item(position: Vector2(100, 0));
      final group = FocusNavigationGroup()
        ..register(a)
        ..register(b);
      expect(group.moveFocus(FocusDirection.next), same(a));
      expect(group.moveFocus(FocusDirection.right), same(b));
    });
  });
}
