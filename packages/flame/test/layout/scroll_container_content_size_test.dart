import 'package:flame/components.dart';
import 'package:flame/layout.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScrollContainerComponent.setContentSize', () {
    test('sets an extent on a container that was created without one', () {
      final scroll = ScrollContainerComponent(size: Vector2(100, 100));
      expect(scroll.maxScrollY, 0);

      scroll.setContentSize(Vector2(100, 500));
      expect(scroll.maxScrollY, 400);
      expect(scroll.effectiveContentSize, Vector2(100, 500));
    });

    test('replaces the extent that the container was created with', () {
      final scroll = ScrollContainerComponent(
        size: Vector2(100, 100),
        contentSize: Vector2(100, 300),
      );
      final next = Vector2(100, 700);
      scroll.setContentSize(next);
      expect(scroll.maxScrollY, 600);

      // The container keeps its own copy.
      next.y = 5000;
      expect(scroll.maxScrollY, 600);
    });

    testWithFlameGame(
      'null goes back to measuring the content children',
      (game) async {
        final scroll = ScrollContainerComponent(
          size: Vector2(100, 100),
          contentSize: Vector2(100, 300),
          contentChildren: [
            PositionComponent(
              position: Vector2(0, 900),
              size: Vector2(100, 100),
            ),
          ],
        );
        await game.world.ensureAdd(scroll);
        await game.ready();
        expect(scroll.maxScrollY, 200);

        scroll.setContentSize(null);
        expect(scroll.maxScrollY, 900);
        scroll.scrollTo(y: 900);
        expect(scroll.scrollOffset.y, 900);
      },
    );

    test('clamps the scroll offset to a smaller extent', () {
      final scroll = ScrollContainerComponent(
        size: Vector2(100, 100),
        contentSize: Vector2(100, 1000),
      )..scrollTo(y: 800);
      expect(scroll.scrollOffset.y, 800);

      scroll.setContentSize(Vector2(100, 400));
      expect(scroll.scrollOffset.y, 300);
      expect(scroll.content.position.y, -300);
    });
  });
}
