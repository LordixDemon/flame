import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _GlowTarget() extends PositionComponent with HasPaint;

void main() {
  group('SpringEffectController & GlowEffect / ColorEffect safety', () {
    test('bouncy spring overshoots > 1.0 and settles to exact 1.0', () {
      final spring = SpringEffectController.bouncy(
        stiffness: 280,
        dampingRatio: 0.42,
      );
      expect(spring.duration, greaterThan(0.2));
      expect(spring.progress, 0.0);

      var maxProgress = 0.0;
      const step = 1 / 120;
      while (!spring.completed) {
        spring.advance(step);
        if (spring.progress > maxProgress) {
          maxProgress = spring.progress;
        }
      }

      expect(maxProgress, greaterThan(1.12));
      expect(spring.completed, isTrue);
      expect(spring.progress, 1.0);

      // Recede & reset support
      final leftOver = spring.recede(spring.duration + 0.25);
      expect(leftOver, closeTo(0.25, 1e-6));
      expect(spring.progress, 0.0);
    });

    test('criticallyDamped spring approaches 1.0 monotonically', () {
      final critical = SpringEffectController.criticallyDamped(stiffness: 320);
      var prev = 0.0;
      while (!critical.completed) {
        critical.advance(1 / 120);
        expect(critical.progress, greaterThanOrEqualTo(prev - 1e-6));
        expect(critical.progress, lessThanOrEqualTo(1.0 + 1e-4));
        prev = critical.progress;
      }
      expect(critical.progress, 1.0);
    });

    test(
      'composes inside SequenceEffectController and drives ScaleEffect',
      () async {
        final comp = PositionComponent(scale: Vector2.all(0.5));
        final game = FlameGame(children: [comp])
          ..onGameResize(Vector2(300, 300));
        await game.start();

        final seq = SequenceEffectController([
          SpringEffectController.snappy(),
          LinearEffectController(0.1),
        ]);
        comp.add(ScaleEffect.to(Vector2.all(1.0), seq));
        await game.ready();

        var sawOvershoot = false;
        for (var i = 0; i < 180; i++) {
          game.update(1 / 60);
          if (comp.scale.x > 1.01) {
            sawOvershoot = true;
          }
        }
        expect(sawOvershoot, isTrue);
        expect(comp.scale.x, closeTo(1.0, 1e-3));
      },
    );

    test(
      'GlowEffect clears maskFilter safely when spring progress <= 0',
      () async {
        final target = _GlowTarget();
        final game = FlameGame(children: [target])
          ..onGameResize(Vector2(200, 200));
        await game.start();

        final spring = SpringEffectController(
          stiffness: 240,
          damping: 10,
          initialVelocity: -4.0,
        );
        target.add(GlowEffect(12.0, spring));
        await game.ready();

        // Initial negative velocity dips progress < 0 without throwing on
        // MaskFilter.blur(sigma <= 0)!
        for (var i = 0; i < 60; i++) {
          game.update(1 / 120);
        }
        expect(target.paint.maskFilter, isNotNull);
      },
    );
  });
}
