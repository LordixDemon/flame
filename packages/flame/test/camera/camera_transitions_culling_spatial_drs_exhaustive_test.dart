import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _TickCounterComponent() extends Component {
  int loadCount = 0;
  int mountCount = 0;
  int tickCount = 0;

  @override
  Future<void> onLoad() async {
    loadCount++;
  }

  @override
  void onMount() {
    super.onMount();
    mountCount++;
  }

  @override
  void update(double dt) {
    tickCount++;
  }
}

class _TimePulseGame() extends FlameGame with HasTimeScale;

void main() {
  group('TactileCameraController soft bounds, gesture hold & spring reset', () {
    test(
      'clamps pan/zoom, pauses return during active gesture & snaps home',
      () {
        final ctrl = TactileCameraController(
          maxPanX: 120,
          maxPanY: 80,
          minZoomFactor: 0.6,
          maxZoomFactor: 2.0,
          returnSpringRate: 10.0,
        );
        expect(ctrl.hasManualOverride, isFalse);

        ctrl.beginGesture();
        expect(ctrl.isGestureActive, isTrue);
        ctrl.panByWorld(500, -400);
        ctrl.zoomByFactor(10.0);
        expect(ctrl.panX, 120.0);
        expect(ctrl.panY, -80.0);
        expect(ctrl.zoomFactor, 2.0);
        expect(ctrl.hasManualOverride, isTrue);

        // Requesting reset while gesture is still active pauses spring motion
        // until endGesture() is called!
        ctrl.reset();
        ctrl.update(0.1);
        expect(ctrl.panX, 120.0);

        ctrl.endGesture();
        for (var i = 0; i < 60; i++) {
          ctrl.update(1 / 30);
        }
        expect(ctrl.panX, 0.0);
        expect(ctrl.panY, 0.0);
        expect(ctrl.zoomFactor, 1.0);
        expect(ctrl.hasManualOverride, isFalse);

        // Instant reset snaps immediately in 0 frames.
        ctrl
          ..panByWorld(-60, 45)
          ..zoomByFactor(0.1)
          ..reset(instant: true);
        expect(ctrl.panOffset, Offset.zero);
        expect(ctrl.zoomFactor, 1.0);
      },
    );
  });

  group('WorldSpatialIndex + CustomTraversal & OffscreenTickPolicy', () {
    test(
      'World children load, mount & update identically with spatialIndex on/off',
      () async {
        for (final spatial in <bool>[false, true]) {
          final world = World(spatialIndexEnabled: spatial);
          final game = FlameGame(world: world)..onGameResize(Vector2(400, 300));
          final plainChild = _TickCounterComponent();
          final nestedPlain = _TickCounterComponent();
          final posParent = PositionComponent(
            position: Vector2(10, 10),
            size: Vector2(20, 20),
            children: <Component>[nestedPlain],
          );

          world.addAll(<Component>[plainChild, posParent]);
          await game.start();
          await game.ready();

          expect(plainChild.loadCount, 1);
          expect(plainChild.mountCount, 1);
          expect(nestedPlain.loadCount, 1);
          expect(nestedPlain.mountCount, 1);
          plainChild.tickCount = 0;
          nestedPlain.tickCount = 0;

          for (var i = 0; i < 5; i++) {
            game.update(1 / 60);
          }
          expect(plainChild.tickCount, 5);
          expect(nestedPlain.tickCount, 5);
        }
      },
    );
  });

  group('TimelineComponent choreography, skipToEnd & generation cancel', () {
    test(
      'TimelineComponent runs parallel/stagger, sleeps idle & cancels async',
      () async {
        final game = FlameGame()..onGameResize(Vector2(400, 300));
        await game.start();

        var idleCount = 0;
        final timeline = TimelineComponent(
          playbackRate: 2.0,
          onIdle: () => idleCount++,
        );
        game.world.add(timeline);
        await game.ready();

        // PassiveComponent starts with ticksEnabled == false when idle!
        expect(timeline.ticksEnabled, isFalse);

        final events = <String>[];
        var tweenFinal = 0.0;
        final actor = PositionComponent(position: Vector2.zero());
        game.world.add(actor);
        await game.ready();

        final fut = timeline.enqueue((b) {
          b.doSync(() => events.add('start'));
          b.parallel(<void Function(TimelineBuilder)>[
            (p) => p.tween(0.2, (t) => tweenFinal = t),
            (p) => p.stagger<String>(
              const <String>['a', 'b', 'c'],
              0.05,
              (sb, item, _) => sb.doSync(() => events.add('item:$item')),
            ),
          ]);
          b.animate(
            actor,
            MoveToEffect(Vector2(80, 0), EffectController(duration: 0.2)),
          );
          b.doSync(() => events.add('done'));
        });

        expect(timeline.ticksEnabled, isTrue);
        for (var i = 0; i < 30; i++) {
          game.update(1 / 60);
        }
        await fut;

        expect(tweenFinal, closeTo(1.0, 1e-6));
        expect(actor.position.x, closeTo(80.0, 1e-3));
        expect(
          events,
          <String>['start', 'item:a', 'item:b', 'item:c', 'done'],
        );
        expect(idleCount, 1);
        expect(timeline.ticksEnabled, isFalse);

        // skipToEnd fast-forwards wait/tween/effect and invokes onSkip!
        var skippedWait = false;
        timeline.enqueue((b) {
          b.wait(10.0, onSkip: () => skippedWait = true);
          b.tween(5.0, (t) => tweenFinal = t * 2.0);
        });
        timeline.skipToEnd();
        expect(skippedWait, isTrue);
        expect(tweenFinal, closeTo(2.0, 1e-6));
        expect(timeline.isBusy, isFalse);

        // cancel() bumps generation so suspended runBeat sees isCancelled()!
        var observedCancelled = false;
        timeline.play((b) {
          b.runBeat((isCancelled) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            observedCancelled = isCancelled();
          });
        });
        game.update(0.016);
        final genBefore = timeline.generation;
        timeline.cancel();
        expect(timeline.generation, greaterThan(genBefore));
        await Future<void>.delayed(const Duration(milliseconds: 35));
        expect(observedCancelled, isTrue);
      },
    );
  });

  group('HasTimeScale 0.0 freeze hit-stop & DRS floor/ceiling bounds', () {
    test(
      'applyTimePulse(scale: 0.0) freezes simulation then self-recovers',
      () async {
        final game = _TimePulseGame()
          ..timeScale = 1.5
          ..onGameResize(Vector2(300, 200));
        var accumulatedDt = 0.0;
        game.world.add(
          TimerComponent(
            period: 100,
            onTick: () {},
          ),
        );
        final probe = PositionComponent();
        game.world.add(probe);
        await game.start();
        await game.ready();

        probe.add(
          MoveByEffect(
            Vector2(100, 0),
            EffectController(duration: 1.0),
          ),
        );
        await game.ready();

        // Trigger pure 0.0 freeze-frame hit-stop for 0.10 real seconds, then
        // 0.10s smoothstep ramp back to baseline 1.5x!
        game.applyTimePulse(
          scale: 0.0,
          realDuration: 0.10,
          rampBackDuration: 0.10,
        );
        expect(game.isTimePulseActive, isTrue);
        expect(game.timeScale, 0.0);

        // During first 0.08s of freeze, probe does NOT move at all!
        game.update(0.04);
        game.update(0.04);
        accumulatedDt += probe.position.x;
        expect(accumulatedDt, 0.0);

        // Advance past hold + ramp using real unscaled dt -> recovers to 1.5x!
        for (var i = 0; i < 10; i++) {
          game.update(0.03);
        }
        expect(game.isTimePulseActive, isFalse);
        expect(game.timeScale, closeTo(1.5, 1e-5));
        expect(probe.position.x, greaterThan(10.0));
      },
    );

    test(
      'DynamicQualityGovernor clamps at minRenderScale & maxRenderScale',
      () {
        final ctrl = GraphicsSettingsController();
        ctrl.governor
          ..enabled = true
          ..minRenderScale = 0.60
          ..overBudgetFramesThreshold = 2
          ..underBudgetFramesThreshold = 2
          ..cooldownSeconds = 0.0
          ..scaleStepDown = 0.25
          ..scaleStepUp = 0.30;

        // Repeated heavy spikes never push renderScale below minRenderScale!
        for (var i = 0; i < 12; i++) {
          ctrl.recordFrameSample(
            frameTimeMs: 40.0,
            targetBudgetMs: 16.67,
            dtSeconds: 0.04,
          );
        }
        expect(ctrl.effectiveRenderScale, closeTo(0.60, 1e-5));

        // Repeated fast frames recover cleanly back to tier baseline (1.0)
        // without exceeding 1.0!
        for (var i = 0; i < 12; i++) {
          ctrl.recordFrameSample(
            frameTimeMs: 4.0,
            targetBudgetMs: 16.67,
            dtSeconds: 0.016,
          );
        }
        expect(ctrl.effectiveRenderScale, closeTo(1.0, 1e-5));
      },
    );
  });
}
