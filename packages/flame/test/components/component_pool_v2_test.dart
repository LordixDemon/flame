import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecyclableParticle() extends PositionComponent with RecyclableComponent {
  int acquireCalls = 0;
  int releaseCalls = 0;

  @override
  void onAcquire() {
    acquireCalls++;
  }

  @override
  void onRelease() {
    releaseCalls++;
  }
}

void main() {
  group('ComponentPool v2 & RecyclableComponent', () {
    test(
      'invokes onAcquire/onRelease synchronously, tracks inUseCount, and '
      'prewarms up to maxSize',
      () async {
        final pool = ComponentPool<_RecyclableParticle>(
          factory: _RecyclableParticle.new,
          maxSize: 4,
          initialSize: 2,
        );
        expect(pool.availableCount, 2);
        expect(pool.inUseCount, 0);

        pool.prewarm(10);
        expect(pool.availableCount, 4);

        final game = FlameGame()..onGameResize(Vector2(200, 200));
        await game.start();

        final p1 = pool.acquire();
        expect(p1.acquireCalls, 1);
        expect(p1.releaseCalls, 0);
        expect(pool.availableCount, 3);
        expect(pool.inUseCount, 1);

        game.world.add(p1);
        await game.ready();
        expect(p1.isMounted, isTrue);

        p1.removeFromParent();
        game.processLifecycleEvents();

        expect(p1.releaseCalls, 1);
        expect(pool.availableCount, 4);
        expect(pool.inUseCount, 0);

        // Re-acquiring pops p1 in LIFO order
        final p2 = pool.acquire();
        expect(identical(p2, p1), isTrue);
        expect(p2.acquireCalls, 2);
      },
    );

    test(
      'cancelling queued component before mount returns it to pool and '
      'reparenting mounted component does NOT prematurely release it',
      () async {
        final pool = ComponentPool<_RecyclableParticle>(
          factory: _RecyclableParticle.new,
          maxSize: 4,
        );
        final layerA = Component();
        final layerB = Component();
        final game = FlameGame(children: [layerA, layerB])
          ..onGameResize(Vector2(200, 200));
        await game.start();

        // 1. Add then immediately remove before processLifecycleEvents mounts
        final cancelled = pool.acquire();
        layerA.add(cancelled);
        layerA.remove(cancelled);
        expect(cancelled.releaseCalls, 1);
        expect(pool.availableCount, 1);
        expect(pool.inUseCount, 0);

        // 2. Mount under layerA, then move to layerB -> must NOT release!
        final moved = pool.acquire();
        expect(identical(moved, cancelled), isTrue);
        layerA.add(moved);
        await game.ready();
        expect(pool.inUseCount, 1);

        moved.parent = layerB;
        game.processLifecycleEvents();
        expect(moved.parent, layerB);
        expect(moved.isMounted, isTrue);
        expect(moved.releaseCalls, 1);
        expect(pool.inUseCount, 1);
        expect(pool.availableCount, 0);

        // Removing from layerB now returns it to pool cleanly.
        moved.removeFromParent();
        game.processLifecycleEvents();
        expect(moved.releaseCalls, 2);
        expect(pool.inUseCount, 0);
        expect(pool.availableCount, 1);
      },
    );
  });
}
