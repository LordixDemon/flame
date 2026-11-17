import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tracked(final String name) extends Component {
  int updates = 0;
  int paints = 0;
  int mounts = 0;
  int removes = 0;

  @override
  void update(double dt) => updates++;

  @override
  void render(Canvas canvas) => paints++;

  @override
  void onMount() => mounts++;

  @override
  void onRemove() => removes++;

  @override
  String toString() => name;
}

void _render(Component component) {
  final recorder = PictureRecorder();
  component.renderTree(Canvas(recorder));
  recorder.endRecording().dispose();
}

void main() {
  group('Re-parenting a component', () {
    testWithFlameGame(
      'and removing it in the same tick takes it out of the tree',
      (game) async {
        final sectorA = _Tracked('a');
        final sectorB = _Tracked('b');
        final tile = _Tracked('tile');
        game.world.addAll([sectorA, sectorB]);
        sectorA.add(tile);
        await game.ready();

        tile.parent = sectorB;
        tile.removeFromParent();
        game.update(0.01);

        expect(tile.isMounted, isFalse);
        expect(tile.parent, isNull);
        expect(sectorA.children.contains(tile), isFalse);
        expect(sectorB.children.contains(tile), isFalse);

        tile
          ..updates = 0
          ..paints = 0;
        game.update(0.01);
        _render(sectorB);
        expect(tile.updates, 0);
        expect(tile.paints, 0);
        expect(tile.mounts, tile.removes, reason: 'every mount was undone');
      },
    );

    testWithFlameGame(
      'after asking for its removal cancels the removal',
      (game) async {
        final sectorA = _Tracked('a');
        final sectorB = _Tracked('b');
        final tile = _Tracked('tile');
        game.world.addAll([sectorA, sectorB]);
        sectorA.add(tile);
        await game.ready();

        tile.removeFromParent();
        tile.parent = sectorB;
        game.update(0.01);

        expect(tile.isMounted, isTrue);
        expect(tile.parent, sectorB);
        expect(sectorA.children.contains(tile), isFalse);
        expect(sectorB.children.contains(tile), isTrue);
      },
    );

    testWithFlameGame(
      'together with one of its descendants mounts each of them once',
      (game) async {
        final target = _Tracked('target');
        final parent = _Tracked('parent');
        final sibling = _Tracked('sibling');
        final child = _Tracked('child');
        game.world.addAll([target, parent]);
        parent.addAll([sibling, child]);
        await game.ready();
        expect(child.mounts, 1);

        // The parent moves under `target`, and in the same tick its child
        // moves under its sibling.
        parent.parent = target;
        child.parent = sibling;
        expect(() => game.update(0.01), returnsNormally);
        expect(() => game.update(0.01), returnsNormally);
        await game.ready();

        expect(parent.parent, target);
        expect(sibling.parent, parent);
        expect(child.parent, sibling);
        expect(child.isMounted, isTrue);
        expect(parent.children.contains(child), isFalse);
        expect(sibling.children.contains(child), isTrue);
        expect(child.mounts, 2);
        expect(child.removes, 1);
        expect(game.hasLifecycleEvents, isFalse);
      },
    );

    testWithFlameGame(
      'whose old parent is removed in the same tick runs onRemove once',
      (game) async {
        final carrier = _Tracked('carrier');
        final passenger = _Tracked('passenger');
        game.world.add(carrier);
        carrier.add(passenger);
        await game.ready();

        carrier.removeFromParent();
        passenger.parent = game.world;
        game.update(0.01);

        expect(passenger.isMounted, isTrue);
        expect(passenger.parent, game.world);
        expect(carrier.children.contains(passenger), isFalse);
        expect(passenger.removes, 1);
        expect(passenger.mounts, 2);
      },
    );

    testWithFlameGame(
      'that is still waiting to be mounted ends up under the new parent only',
      (game) async {
        final first = _Tracked('first');
        final second = _Tracked('second');
        final late_ = _Tracked('late');
        game.world.addAll([first, second]);
        await game.ready();

        first.add(late_);
        late_.parent = second;
        game.update(0.01);
        await game.ready();

        expect(late_.isMounted, isTrue);
        expect(late_.parent, second);
        expect(first.children.contains(late_), isFalse);
        expect(second.children.contains(late_), isTrue);
        expect(late_.mounts - late_.removes, 1);
        expect(game.hasLifecycleEvents, isFalse);
      },
    );
  });
}
