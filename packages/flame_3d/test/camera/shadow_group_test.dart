import 'package:flame/game.dart' show Game;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/core.dart';
import 'package:flutter_test/flutter_test.dart';

/// A camera looking from [x] along -z.
Matrix4 _view(double x) => Matrix4.translationValues(-x, 0, 0);

final Matrix4 _projection = Matrix4.identity()..setEntry(2, 2, -0.1);

void main() {
  group('ShadowGroup', () {
    test('holds the worlds that join it, in order', () {
      final group = ShadowGroup();
      final a = World3D();
      final b = World3D();
      expect(group.worlds, isEmpty);
      a.shadowGroup = group;
      b.shadowGroup = group;
      expect(group.worlds, [a, b]);
      expect(a.shadowGroup, same(group));
      // Joining again changes nothing.
      a.shadowGroup = group;
      expect(group.worlds, [a, b]);
      expect(() => group.worlds.add(a), throwsUnsupportedError);
    });

    test('a world leaves its group, or moves to another', () {
      final first = ShadowGroup();
      final second = ShadowGroup();
      final a = World3D()..shadowGroup = first;
      final b = World3D()..shadowGroup = first;
      a.shadowGroup = second;
      expect(first.worlds, [b]);
      expect(second.worlds, [a]);
      b.shadowGroup = null;
      expect(first.worlds, isEmpty);
      expect(b.shadowGroup, isNull);
    });
  });

  group('ShadowGroup.viewsVersion', () {
    test('follows the cameras the worlds are drawn with, frame by frame', () {
      final group = ShadowGroup();
      final a = World3D()..shadowGroup = group;
      final b = World3D()..shadowGroup = group;

      // Two frames drawing a, then b: the cameras are gathered when a is
      // drawn, b's from the frame before.
      for (var frame = 0; frame < 2; frame++) {
        group
          ..noteView(a, _view(0), _projection)
          ..noteView(b, _view(10), _projection);
      }
      final version = group.viewsVersion;

      // Frames that draw the worlds with the same cameras change nothing,
      // whether they render or reuse an image.
      for (var frame = 0; frame < 3; frame++) {
        group
          ..noteView(a, _view(0), _projection)
          ..noteView(b, _view(10), _projection);
      }
      expect(group.viewsVersion, version);

      // b moves: the frame it moves in keeps the cameras of the frame, and
      // asks for the next one to be painted, which takes b's new camera.
      final mutations = Game.visualMutationCount;
      group
        ..noteView(a, _view(0), _projection)
        ..noteView(b, _view(12), _projection);
      expect(group.viewsVersion, version);
      expect(Game.visualMutationCount, greaterThan(mutations));
      group.noteView(a, _view(0), _projection);
      expect(group.viewsVersion, version + 1);
      group.noteView(b, _view(12), _projection);

      // a, drawn first, moves: its camera is taken at once.
      group.noteView(a, _view(1), _projection);
      expect(group.viewsVersion, version + 2);
      group.noteView(b, _view(12), _projection);
    });

    test('drops the camera of a world no longer drawn, or gone', () {
      final group = ShadowGroup();
      final a = World3D()..shadowGroup = group;
      final b = World3D()..shadowGroup = group;
      for (var frame = 0; frame < 2; frame++) {
        group
          ..noteView(a, _view(0), _projection)
          ..noteView(b, _view(10), _projection);
      }
      var version = group.viewsVersion;

      // A frame without b still holds b's camera of the frame before; the
      // next one no longer does.
      group.noteView(a, _view(0), _projection);
      expect(group.viewsVersion, version);
      group.noteView(a, _view(0), _projection);
      expect(group.viewsVersion, version + 1);

      group.noteView(b, _view(10), _projection);
      group.noteView(a, _view(0), _projection);
      version = group.viewsVersion;
      // A world that left the group is left out from the next frame on, and
      // reports nothing to it any more.
      b.shadowGroup = null;
      group.noteView(b, _view(20), _projection);
      expect(group.viewsVersion, version);
      group.noteView(a, _view(0), _projection);
      expect(group.viewsVersion, version + 1);
    });

    test('takes a camera that several worlds share once', () {
      final group = ShadowGroup();
      final a = World3D()..shadowGroup = group;
      final b = World3D()..shadowGroup = group;
      for (var frame = 0; frame < 2; frame++) {
        group
          ..noteView(a, _view(0), _projection)
          ..noteView(b, _view(0), _projection);
      }
      final version = group.viewsVersion;
      // Leaving b out removes no camera.
      group
        ..noteView(a, _view(0), _projection)
        ..noteView(a, _view(0), _projection);
      expect(group.viewsVersion, version);
    });
  });
}
