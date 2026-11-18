import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Transform2D and the vectors it owns', () {
    test('a change of a vector updates the matrix before the listeners of '
        'the vector run', () {
      final transform = Transform2D();
      final seen = <double>[];
      transform.position.addListener(
        () => seen.add(transform.transformMatrix.storage[12]),
      );
      transform.position.setValues(5, 6);
      transform.position.x = 7;
      expect(seen, [5, 7]);
    });

    test('notifies its own listeners once per change of a vector', () {
      final transform = Transform2D();
      var notified = 0;
      transform.addListener(() => notified++);
      transform.position.setValues(1, 2);
      transform.scale.setFrom(Vector2(2, 3));
      transform.offset.add(Vector2(1, 1));
      transform.angle = 0.5;
      expect(notified, 4);
      expect(transform.version, 4);
    });

    test('reports changes to onMutated with and without listeners', () {
      final transform = Transform2D();
      var mutated = 0;
      transform.onMutated = () => mutated++;
      transform.position.setValues(1, 2);
      void listener() {}
      transform.addListener(listener);
      transform.scale.setValues(2, 2);
      transform.removeListener(listener);
      transform.offset.setValues(3, 3);
      expect(mutated, 3);
      expect(transform.position, Vector2(1, 2));
      expect(transform.transformMatrix.storage[12], 1 + 2 * 3);
    });

    test('keeps following its vectors after their listeners are removed', () {
      final transform = Transform2D();
      void listener() {}
      transform.position.addListener(listener);
      transform.position.removeListener(listener);
      transform.position.setValues(9, 8);
      expect(transform.transformMatrix.storage[12], 9);
      expect(transform.transformMatrix.storage[13], 8);
    });

    test('a copy follows its own vectors', () {
      final source = Transform2D()..position.setValues(1, 2);
      final copy = Transform2D.copy(source);
      copy.position.setValues(3, 4);
      expect(copy.transformMatrix.storage[12], 3);
      expect(source.transformMatrix.storage[12], 1);
    });

    test('a component moves when its position is changed in place', () {
      final component = PositionComponent();
      final before = component.transform.version;
      component.position.x += 4;
      component.position.y -= 2;
      expect(component.transform.version, before + 2);
      expect(component.transformMatrix.storage[12], 4);
      expect(component.transformMatrix.storage[13], -2);
    });
  });

  group('NotifyingVector2', () {
    test('calls its owner listener before the other listeners', () {
      final vector = NotifyingVector2.zero();
      final calls = <String>[];
      vector.addListener(() => calls.add('listener'));
      vector.ownerListener = () => calls.add('owner');
      vector.setValues(1, 1);
      expect(calls, ['owner', 'listener']);
    });

    test('calls its owner listener when nothing else listens', () {
      final vector = NotifyingVector2.zero();
      var owner = 0;
      vector.ownerListener = () => owner++;
      vector
        ..setValues(1, 1)
        ..x = 2
        ..add(Vector2(1, 1));
      expect(owner, 3);
    });
  });
}
