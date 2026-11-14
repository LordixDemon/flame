import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _OrderRecorderComponent(
  final String label,
  final List<String> renderLog, {
  super.priority,
  super.sortKey,
  super.size,
}) extends PositionComponent {
  int updateTicks = 0;

  @override
  void update(double dt) {
    updateTicks++;
  }

  @override
  void render(Canvas canvas) {
    renderLog.add(label);
  }
}

class _PassiveTileComponent() extends Component with PassiveComponent {
  int updateTicks = 0;
  int renderCalls = 0;

  @override
  void update(double dt) {
    updateTicks++;
  }

  @override
  void render(Canvas canvas) {
    renderCalls++;
  }
}

void main() {
  group('Continuous double sortKey (#2)', () {
    testWithFlameGame(
      'orders siblings by priority first, then continuous sortKey',
      (game) async {
        final renderLog = <String>[];
        final a = _OrderRecorderComponent(
          'a',
          renderLog,
          priority: 10,
          sortKey: 204.75,
        );
        final b = _OrderRecorderComponent(
          'b',
          renderLog,
          priority: 10,
          sortKey: 204.12,
        );
        final c = _OrderRecorderComponent(
          'c',
          renderLog,
          priority: 9,
          sortKey: 999.9,
        );
        final d = _OrderRecorderComponent(
          'd',
          renderLog,
          priority: 10,
          sortKey: 204.12,
        );

        await game.world.ensureAddAll([a, b, c, d]);

        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(renderLog, ['c', 'b', 'd', 'a']);
      },
    );

    testWithFlameGame(
      'mutating sortKey every frame reorders render & hit-test without '
      'rebuilding flatUpdateList',
      (game) async {
        final renderLog = <String>[];
        final a = _OrderRecorderComponent(
          'tokenA',
          renderLog,
          priority: 5,
          sortKey: 10.0,
          size: Vector2.all(40),
        );
        final b = _OrderRecorderComponent(
          'tokenB',
          renderLog,
          priority: 5,
          sortKey: 20.0,
          size: Vector2.all(40),
        );
        await game.world.ensureAddAll([a, b]);
        game.camera.viewfinder.position = Vector2.all(20);

        game.update(1 / 60);
        final initialRebuilds = game.flatRebuildCount;

        for (var frame = 0; frame < 60; frame++) {
          renderLog.clear();
          a.sortKey = frame.isEven ? 30.5 : 5.25;
          b.sortKey = 15.0;

          game.update(1 / 60);
          final recorder = PictureRecorder();
          game.render(Canvas(recorder));
          recorder.endRecording().dispose();

          expect(
            renderLog,
            frame.isEven ? ['tokenB', 'tokenA'] : ['tokenA', 'tokenB'],
          );
        }

        expect(game.flatRebuildCount, equals(initialRebuilds));

        a.sortKey = 50.0;
        b.sortKey = 10.0;
        final hits = game.world.componentsAtPoint(Vector2.all(20)).toList();
        expect(hits.first, same(a));
      },
    );
  });

  group('Sleeping & PassiveComponent update exclusion (#6)', () {
    testWithFlameGame(
      'PassiveComponent and sleepUpdates exclude components from '
      'flatUpdateList while keeping rendering active',
      (game) async {
        final renderLog = <String>[];
        final active = _OrderRecorderComponent('active', renderLog);
        final sleeping = _OrderRecorderComponent('sleeping', renderLog)
          ..sleepUpdates();
        final passive = _PassiveTileComponent();

        await game.world.ensureAddAll([active, sleeping, passive]);

        game.update(1 / 60);
        final baselineCount = game.activeUpdateCount;

        for (var i = 0; i < 10; i++) {
          game.update(1 / 60);
        }
        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(active.updateTicks, equals(11));
        expect(sleeping.updateTicks, equals(0));
        expect(passive.updateTicks, equals(0));
        expect(passive.renderCalls, equals(1));
        expect(renderLog, containsAll(['active', 'sleeping']));

        sleeping.wakeUpdates();
        game.update(1 / 60);
        expect(game.activeUpdateCount, equals(baselineCount + 1));
        expect(sleeping.updateTicks, equals(1));
      },
    );

    testWithFlameGame(
      'sleepSubtreeUpdates and wakeSubtreeUpdates toggle entire hierarchies',
      (game) async {
        final renderLog = <String>[];
        final root = PositionComponent();
        final child1 = _OrderRecorderComponent('c1', renderLog);
        final child2 = _OrderRecorderComponent('c2', renderLog);
        root.addAll([child1, child2]);
        await game.world.ensureAdd(root);
        await game.ready();

        game.update(1 / 60);
        expect(child1.updateTicks, equals(1));
        expect(child2.updateTicks, equals(1));

        root.sleepSubtreeUpdates();
        game.update(1 / 60);
        game.update(1 / 60);
        expect(child1.updateTicks, equals(1));
        expect(child2.updateTicks, equals(1));

        root.wakeSubtreeUpdates();
        game.update(1 / 60);
        expect(child1.updateTicks, equals(2));
        expect(child2.updateTicks, equals(2));
      },
    );
  });
}
