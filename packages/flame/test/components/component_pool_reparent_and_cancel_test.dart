import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Pooled() extends Component with RecyclableComponent {
  int acquired = 0;
  int released = 0;
  int mounts = 0;
  int removes = 0;

  @override
  void onAcquire() => acquired++;

  @override
  void onRelease() => released++;

  @override
  void onMount() {
    super.onMount();
    mounts++;
  }

  @override
  void onRemove() {
    removes++;
    super.onRemove();
  }
}

void main() {
  group('ComponentPool with a component cancelled before it mounts', () {
    testWithFlameGame('returns a fresh component', (game) async {
      final pool = ComponentPool<_Pooled>(factory: _Pooled.new);
      final label = pool.acquire();
      game.world.add(label);
      label.removeFromParent();
      game.update(0);
      await game.ready();

      expect(label.isMounted, isFalse);
      expect(pool.availableCount, 1);
      expect(pool.inUseCount, 0);
    });

    testWithFlameGame('returns a recycled component', (game) async {
      final pool = ComponentPool<_Pooled>(factory: _Pooled.new);

      // First life: mount, then remove, which puts it back into the pool.
      final label = pool.acquire();
      game.world.add(label);
      await game.ready();
      label.removeFromParent();
      game.update(0);
      expect(pool.availableCount, 1);
      expect(label.released, 1);

      // Second life: added and cancelled within the same tick.
      final again = pool.acquire();
      expect(identical(again, label), isTrue);
      game.world.add(again);
      pool.release(again);
      game.update(0);
      await game.ready();

      expect(again.isMounted, isFalse);
      expect(again.parent, isNull);
      expect(game.world.children.contains(again), isFalse);
      expect(again.mounts, 1, reason: 'the second life never mounted');
      expect(again.released, 2);
      expect(pool.availableCount, 1);
      expect(pool.inUseCount, 0);
    });

    testWithFlameGame(
      'a recycled plain component can be removed before it mounts',
      (game) async {
        final component = _Pooled();
        game.world.add(component);
        await game.ready();
        component.removeFromParent();
        game.update(0);
        expect(component.isRemoved, isTrue);

        game.world.add(component);
        component.removeFromParent();
        game.update(0);
        await game.ready();

        expect(component.isMounted, isFalse);
        expect(component.mounts, 1);
        expect(game.hasLifecycleEvents, isFalse);
      },
    );
  });

  group('ComponentPool with a component that is re-parented', () {
    testWithFlameGame(
      'keeps it checked out when it is moved before its old parent is removed',
      (game) async {
        final pool = ComponentPool<_Pooled>(factory: _Pooled.new);
        final carrier = Component();
        game.world.add(carrier);
        final trail = pool.acquire();
        carrier.add(trail);
        await game.ready();

        trail.parent = game.world;
        carrier.removeFromParent();
        game.update(0);

        expect(trail.isMounted, isTrue);
        expect(trail.released, 0);
        expect(pool.availableCount, 0);
      },
    );

    testWithFlameGame(
      'keeps it checked out when its old parent is removed first',
      (game) async {
        final pool = ComponentPool<_Pooled>(factory: _Pooled.new);
        final carrier = Component();
        game.world.add(carrier);
        final trail = pool.acquire();
        carrier.add(trail);
        await game.ready();
        expect(trail.mounts, 1);

        // The carrier goes away; its trail is handed to the world.
        carrier.removeFromParent();
        trail.parent = game.world;
        game.update(0);

        expect(trail.isMounted, isTrue);
        expect(trail.parent, game.world);
        expect(carrier.children.contains(trail), isFalse);
        expect(trail.released, 0);
        expect(trail.removes, 1, reason: 'removed once, with its old parent');
        expect(trail.mounts, 2);
        expect(pool.availableCount, 0);
        expect(pool.inUseCount, 1);

        final next = pool.acquire();
        expect(identical(next, trail), isFalse);
        expect(next.isMounted, isFalse);

        // The moved component is still returned when it is removed for good.
        trail.removeFromParent();
        game.update(0);
        expect(trail.released, 1);
        expect(pool.availableCount, 1);
      },
    );

    testWithFlameGame(
      'still returns a pooled descendant that is not moved',
      (game) async {
        final pool = ComponentPool<_Pooled>(factory: _Pooled.new);
        final carrier = Component();
        game.world.add(carrier);
        final moved = pool.acquire();
        final left = pool.acquire();
        carrier.addAll([moved, left]);
        await game.ready();

        carrier.removeFromParent();
        moved.parent = game.world;
        game.update(0);

        expect(moved.isMounted, isTrue);
        expect(moved.released, 0);
        expect(left.isMounted, isFalse);
        expect(left.released, 1);
        expect(pool.availableCount, 1);
      },
    );
  });

  group('ComponentPool bookkeeping', () {
    testWithFlameGame(
      'a component dropped by a full pool no longer reports to it',
      (game) async {
        final pool = ComponentPool<_Pooled>(factory: _Pooled.new, maxSize: 1);
        final first = pool.acquire();
        final second = pool.acquire();
        game.world.addAll([first, second]);
        await game.ready();

        first.removeFromParent();
        second.removeFromParent();
        game.update(0);
        expect(pool.availableCount, 1);
        expect(pool.inUseCount, 0);

        // The dropped instance is an ordinary component from now on.
        final dropped = first.isInComponentPool ? second : first;
        final acquired = pool.acquire();
        game.world.add(dropped);
        await game.ready();
        dropped.removeFromParent();
        game.update(0);

        expect(dropped.released, 1, reason: 'not released a second time');
        expect(pool.inUseCount, 1);
        expect(acquired.isInComponentPool, isFalse);
      },
    );
  });
}
