import 'package:flame/game.dart';
import 'package:flame/layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FloatingCombatTextPool under IdleRenderMode.onDemand', () {
    test('repaints from the spawn of a popup until it has expired, and not '
        'while the pool is empty', () async {
      final game = FlameGame()
        ..idleRenderMode = IdleRenderMode.onDemand
        ..onGameResize(Vector2(320, 240));
      final pool = FloatingCombatTextPool();
      game.world.add(pool);
      await game.start();

      // Settle: paint the initial frame, then nothing changes.
      expect(game.shouldRenderThisTick(0.016), isTrue);
      game.onFrameRendered();
      for (var i = 0; i < 3; i++) {
        game.update(0.016);
        expect(game.shouldRenderThisTick(0.016), isFalse);
      }

      pool.spawn(text: '+50', worldX: 10, worldY: 20, durationSeconds: 0.5);
      expect(pool.activeCount, 1);

      // While the popup rises and fades, every tick has to be painted.
      var elapsed = 0.0;
      while (pool.activeCount > 0) {
        game.update(0.05);
        elapsed += 0.05;
        expect(
          game.shouldRenderThisTick(0.05),
          isTrue,
          reason: 'frame at ${elapsed.toStringAsFixed(2)} s',
        );
        game.onFrameRendered();
      }
      expect(elapsed, closeTo(0.5, 0.051));

      // The frame that removed it was painted; after that the pool is idle.
      for (var i = 0; i < 3; i++) {
        game.update(0.05);
        expect(game.shouldRenderThisTick(0.05), isFalse);
      }
    });

    test('clearing live popups asks for one more paint', () async {
      final game = FlameGame()
        ..idleRenderMode = IdleRenderMode.onDemand
        ..onGameResize(Vector2(320, 240));
      final pool = FloatingCombatTextPool();
      game.world.add(pool);
      await game.start();
      expect(game.shouldRenderThisTick(0.016), isTrue);
      game.onFrameRendered();

      pool.spawn(
        text: 'MISS',
        worldX: 0,
        worldY: 0,
        kind: CombatPopupKind.miss,
      );
      game.update(0.016);
      expect(game.shouldRenderThisTick(0.016), isTrue);
      game.onFrameRendered();

      pool.clear();
      expect(pool.activeCount, 0);
      expect(game.shouldRenderThisTick(0.016), isTrue);
      game.onFrameRendered();

      // Clearing an empty pool changes nothing on screen.
      pool.clear();
      game.update(0.016);
      expect(game.shouldRenderThisTick(0.016), isFalse);
    });
  });
}
