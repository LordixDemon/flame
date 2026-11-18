import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:flame/game.dart';
import 'package:flame/rendering.dart';
import 'package:flame/src/cache/matrix_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes the matrix of the canvas into [matrices] every time it is drawn.
class _Probe({
  required this.matrices,
  super.position,
  super.angle,
  super.scale,
  super.anchor,
  super.children,
}) extends PositionComponent {
  this : super(size: Vector2(10, 6));

  final List<Float64List> matrices;

  @override
  void render(Canvas canvas) => matrices.add(canvas.getTransform());
}

/// A decorator that draws as it is told, and records what it was given.
class _Passthrough() extends Decorator {
  int applied = 0;
  Rect? lastBounds;

  @override
  void applyBounded(void Function(Canvas) draw, Canvas canvas, Rect? bounds) {
    applied++;
    lastBounds = bounds;
    draw(canvas);
  }
}

/// A canvas that only records the transform calls made on it.
class _TransformLog() implements Canvas {
  final List<String> calls = [];

  @override
  void translate(double dx, double dy) => calls.add('translate($dx, $dy)');

  @override
  void transform(Float64List matrix4) =>
      calls.add('transform(${matrix4.join(', ')})');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A tree of probes with every kind of transform: none, a translation, a
/// rotation, a scale, a mirror, an anchor and a sub-pixel offset.
List<_Probe> _tree(List<Float64List> matrices) {
  return [
    _Probe(
      matrices: matrices,
      position: Vector2(12.5, -3.25),
      children: [
        _Probe(matrices: matrices),
        _Probe(
          matrices: matrices,
          position: Vector2(4, 4),
          angle: math.pi / 7,
          children: [
            _Probe(
              matrices: matrices,
              scale: Vector2(1.5, -0.5),
              anchor: Anchor.center,
              children: [_Probe(matrices: matrices, position: Vector2(0.1, 0))],
            ),
          ],
        ),
      ],
    ),
    _Probe(matrices: matrices, scale: Vector2.all(2), position: Vector2(1, 1)),
    _Probe(matrices: matrices, anchor: Anchor.bottomRight),
  ];
}

void _render(List<_Probe> roots) {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder)
    ..translate(7, 9)
    ..scale(1.25);
  for (final root in roots) {
    root.renderTree(canvas);
  }
  expect(canvas.getSaveCount(), 1);
  recorder.endRecording().dispose();
}

void main() {
  group('PositionComponent rendering its transform', () {
    test('draws every child at the same matrix as through the decorator '
        'chain', () {
      final direct = <Float64List>[];
      _render(_tree(direct));

      final chained = <Float64List>[];
      final roots = _tree(chained);
      for (final probe in [
        for (final root in roots) ...[root, ...root.descendants()],
      ].whereType<PositionComponent>()) {
        // Anything chained makes the component go through the chain.
        probe.decorator.addLast(_Passthrough());
      }
      _render(roots);

      expect(direct, hasLength(chained.length));
      for (var i = 0; i < direct.length; i++) {
        expect(direct[i], chained[i], reason: 'probe $i');
      }
    });

    test(
      'goes back to the plain path when the chained decorator is removed',
      () {
        final matrices = <Float64List>[];
        final probe = _Probe(
          matrices: matrices,
          position: Vector2(3, 4),
          angle: 0.3,
        );
        final passthrough = _Passthrough();
        probe.decorator.addLast(passthrough);
        _render([probe]);
        expect(passthrough.applied, 1);

        probe.decorator.removeLast();
        _render([probe]);
        expect(passthrough.applied, 1);
        expect(matrices, hasLength(2));
        expect(matrices[1], matrices[0]);
      },
    );

    test('uses a decorator that replaces the default one', () {
      final matrices = <Float64List>[];
      final replacement = _Passthrough();
      final probe = _Probe(matrices: matrices, position: Vector2(30, 40))
        ..decorator = replacement;
      _render([probe]);
      expect(replacement.applied, 1);
      // The replacement does not transform the canvas.
      final expected =
          (Matrix4.identity()
                ..translateByDouble(7.0, 9.0, 0.0, 1.0)
                ..scaleByDouble(1.25, 1.25, 1.0, 1.0))
              .storage;
      expect(matrices.single, Float64List.fromList(expected));
    });

    test('hands the decorator bounds to a chained decorator', () {
      final probe = _Probe(matrices: [], position: Vector2(1, 2))
        ..decoratorBounds = const Rect.fromLTRB(-5, -6, 7, 8);
      final passthrough = _Passthrough();
      probe.decorator.addLast(passthrough);
      _render([probe]);
      expect(passthrough.lastBounds, const Rect.fromLTRB(-5, -6, 7, 8));
    });

    test('applies a decorator chain in order', () {
      final order = <int>[];
      final probe = _Probe(matrices: [], position: Vector2(1, 2));
      for (var i = 0; i < 3; i++) {
        probe.decorator.addLast(_Ordered(i, order));
      }
      _render([probe]);
      expect(order, [0, 1, 2]);
    });
  });

  group('PositionComponent in a pass that only multi-pass components paint '
      'in', () {
    test('draws the multi-pass components at the same matrices as in a '
        'pass that everything paints in', () {
      final matrices = <(RenderPass, Float64List)>[];
      final leaf = _PassProbe(position: Vector2(1, 2));
      final multi = _MultiPassProbe(
        matrices: matrices,
        position: Vector2(5, 6),
        children: [_PassProbe(position: Vector2(7, 8))],
      );
      final nestedMulti = _MultiPassProbe(
        matrices: matrices,
        position: Vector2(-2, 3),
      );
      final container = _PassProbe(
        position: Vector2(10, 20),
        children: [
          _PassProbe(position: Vector2(1, 1)),
          PositionComponent(position: Vector2(2, 2), children: [nestedMulti]),
        ],
      );
      final roots = [leaf, multi, container];

      _renderInPass(roots, RenderPass.opaque);
      final opaque = [for (final (_, m) in matrices) m];
      matrices.clear();
      _renderInPass(roots, RenderPass.emissiveMask);
      expect(
        [for (final (pass, _) in matrices) pass],
        [
          RenderPass.emissiveMask,
          RenderPass.emissiveMask,
        ],
      );
      expect([for (final (_, m) in matrices) m], opaque);
      expect(leaf.rendered, 1);
      expect(container.rendered, 1);
    });

    test('still draws the debug view of a leaf and calls the hook after the '
        'children of an empty children container', () {
      final debugLeaf = _PassProbe()..debugMode = true;
      final emptied = _PassProbe();
      // Reading the children creates their (empty) container.
      expect(emptied.children, isEmpty);
      _renderInPass([debugLeaf, emptied], RenderPass.emissiveMask);
      expect(debugLeaf.rendered, 0);
      expect(debugLeaf.debugRendered, 1);
      expect(emptied.afterChildren, 1);
    });

    test('leaves a component with a decorator chain to the chain', () {
      final passthrough = _Passthrough();
      final probe = _PassProbe()..decorator.addLast(passthrough);
      _renderInPass([probe], RenderPass.emissiveMask);
      expect(passthrough.applied, 1);
      expect(probe.rendered, 0);
    });

    test('draws an ordinary leaf in a pass that everything paints in', () {
      final leaf = _PassProbe();
      _renderInPass([leaf], null);
      _renderInPass([leaf], RenderPass.opaque);
      expect(leaf.rendered, 2);
    });
  });

  group('canvasTransform', () {
    Float32List matrixOf(Transform2D transform) =>
        transform.transformMatrix.storage;

    test('applies a translation with translate', () {
      final log = _TransformLog();
      canvasTransform(log, matrixOf(Transform2D()..position.setValues(3, -4)));
      expect(log.calls, ['translate(3.0, -4.0)']);
    });

    test('does not apply the identity', () {
      final log = _TransformLog();
      canvasTransform(log, matrixOf(Transform2D()));
      expect(log.calls, isEmpty);
    });

    test('applies any other matrix with transform, entry for entry', () {
      for (final transform in [
        Transform2D()..angle = 0.5,
        Transform2D()..scale.setValues(2, 3),
        Transform2D()..scale.setValues(-1, 1),
        Transform2D()
          ..position.setValues(1, 2)
          ..angle = -1.25
          ..offset.setValues(-4, 5),
      ]) {
        final log = _TransformLog();
        final matrix = matrixOf(transform);
        canvasTransform(log, matrix);
        expect(log.calls, [
          'transform(${Float64List.fromList(matrix).join(', ')})',
        ]);
      }
    });

    test('applies a matrix that is not two-dimensional with transform', () {
      final log = _TransformLog();
      final matrix = Matrix4.identity()..setEntry(2, 2, 2);
      canvasTransform(log, matrix.storage);
      expect(log.calls.single, startsWith('transform('));
    });

    test('asserts that a translation is finite, like Canvas.transform', () {
      final log = _TransformLog();
      final matrix = Matrix4.identity()..setTranslationRaw(double.nan, 0, 0);
      expect(
        () => canvasTransform(log, matrix.storage),
        throwsA(isA<AssertionError>()),
      );
    });

    test('gives a canvas the same picture as a full matrix would', () async {
      final transform = Transform2D()..position.setValues(10.5, 20.25);
      final viaHelper = PictureRecorder();
      Canvas(viaHelper)
        ..transform2D(transform)
        ..drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint());
      final viaMatrix = PictureRecorder();
      Canvas(viaMatrix)
        ..transform(Float64List.fromList(transform.transformMatrix.storage))
        ..drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint());
      final a = await viaHelper.endRecording().toImage(40, 40);
      final b = await viaMatrix.endRecording().toImage(40, 40);
      final bytesA = await a.toByteData();
      final bytesB = await b.toByteData();
      expect(
        bytesA!.buffer.asUint8List(),
        orderedEquals(bytesB!.buffer.asUint8List()),
      );
    });
  });
}

class _Ordered(final int index, final List<int> order) extends Decorator {
  @override
  void apply(void Function(Canvas) draw, Canvas canvas) {
    order.add(index);
    draw(canvas);
  }
}

/// Counts what is drawn of it, in every pass.
class _PassProbe({super.position, super.children}) extends PositionComponent {
  this : super(size: Vector2(10, 6));

  int rendered = 0;
  int debugRendered = 0;
  int afterChildren = 0;

  @override
  void render(Canvas canvas) => rendered++;

  @override
  void renderDebugMode(Canvas canvas) => debugRendered++;

  @override
  void afterChildrenRendered(Canvas canvas) => afterChildren++;
}

/// Writes its canvas matrix in every pass it is drawn in.
class _MultiPassProbe({
  required this.matrices,
  super.position,
  super.children,
}) extends PositionComponent with MultiPassComponent {
  final List<(RenderPass, Float64List)> matrices;

  @override
  void renderPass(Canvas canvas, RenderPass pass) =>
      matrices.add((pass, canvas.getTransform()));
}

void _renderInPass(List<Component> roots, RenderPass? pass) {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder)..translate(3, 4);
  if (pass != null) {
    CameraComponent.pushRenderPass(pass);
  }
  try {
    for (final root in roots) {
      root.renderTree(canvas);
    }
  } finally {
    if (pass != null) {
      CameraComponent.popRenderPass();
    }
  }
  expect(canvas.getSaveCount(), 1);
  recorder.endRecording().dispose();
}
