import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

/// A custom outline that leans its vertices along x before extruding them
/// with `flame_3d/outline.glsl`.
class _LeanOutline(final double lean, final double thickness) extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          'test/outline_lean.shaderbundle',
          slots: [RenderContext3D.cameraMatricesBlock, 'Lean'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          'test/outline_lean.shaderbundle',
        ),
      ) {
    renderState = const RenderState(cullMode: CullMode.frontFace);
  }

  @override
  void apply(RenderContext context) {
    vertexShader.setVector4('Lean.params', Vector4(lean, thickness, 0, 0));
  }
}

/// A small square at the origin, wound to face -z (so that the outline, which
/// culls front faces, draws it for the default camera), whose vertex normals
/// all point along [normal].
Surface _square(Material material, Vector3 normal, {double half = 0.04}) {
  final stride = VertexLayout.standard.strideInFloats;
  final vertices = Float32List(4 * stride);
  const corners = [(-1, -1), (-1, 1), (1, 1), (1, -1)];
  for (final (i, (x, y)) in corners.indexed) {
    vertices
      ..setRange(i * stride, i * stride + 3, [x * half, y * half, 0])
      ..setRange(i * stride + 5, i * stride + 9, [1, 1, 1, 1])
      ..setRange(i * stride + 9, i * stride + 12, [normal.x, normal.y, 0]);
  }
  return Surface.fromBuffers(
    vertices: vertices,
    indices: Uint16List.fromList([0, 1, 2, 2, 3, 0]),
    material: material,
  );
}

/// The mean position, in the default camera's view, of the lit pixels.
(double, double) _centroid(Pixels pixels) {
  var sx = 0.0;
  var sy = 0.0;
  var n = 0;
  for (var y = 0; y < pixels.height; y++) {
    for (var x = 0; x < pixels.width; x++) {
      if (pixels.at(x, y).$1 > 128) {
        sx += x + 0.5;
        sy += y + 0.5;
        n++;
      }
    }
  }
  expect(n, greaterThan(0));
  return (
    sx / n / pixels.width * 2 - 1,
    1 - sy / n / pixels.height * 2,
  );
}

void main() {
  setUpGpu();

  setUpAll(() async {
    if (gpuAvailable) {
      await registerTestShaders(['outline_lean']);
    }
  });

  group('OutlineMaterial', () {
    testGpuEngine('pushes along the normal of the scaled surface', () async {
      // A normal at 45 degrees in model space, scaled 4 times along y: the
      // surface it is the normal of leans towards x in the world, so its
      // world normal is mostly along x, (1, 1/4) normalized.
      final material = OutlineMaterial(
        color: const Color(0xFFFFFFFF),
        thickness: 0.5,
        depthBias: 0,
      );
      final surface = _square(
        material,
        Vector3(1, 1, 0)..normalize(),
      );
      final frame = await renderFrame(
        width: 128,
        height: 128,
        draw: (context) => context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -1)
            ..scaleByVector3(Vector3(1, 4, 1)),
        ),
      );
      final (cx, cy) = _centroid(frame.pixels);
      final expected = Vector2(1, 0.25)..normalize();
      expect(cx, closeTo(expected.x * 0.5, 0.03));
      expect(cy, closeTo(expected.y * 0.5, 0.03));
      expect(math.atan2(cy, cx), lessThan(math.pi / 8));
    });

    testGpuEngine(
      'outline.glsl gives a displacing material the outline of what it draws',
      () async {
        // The custom material leans the sphere by 0.6 in its vertex shader;
        // OutlineMaterial draws the same sphere leaned by its transform.
        const lean = 0.6;
        const thickness = 0.08;
        final place = Matrix4.translationValues(0, 0, -3)
          ..scaleByVector3(Vector3(1, 1.5, 1));
        final leanMatrix = Matrix4.identity()..setEntry(0, 1, lean);

        Future<Pixels> render(Material material, Matrix4 transform) async {
          final frame = await renderFrame(
            width: 128,
            height: 128,
            draw: (context) => context.drawSurface(
              SphereMesh(radius: 0.4, material: material).surfaces.single,
              transform: transform,
            ),
          );
          return frame.pixels;
        }

        final custom = await render(
          _LeanOutline(lean, thickness),
          place,
        );
        final reference = await render(
          OutlineMaterial(
            color: const Color(0xFFFFFFFF),
            thickness: thickness,
            depthBias: 0,
          ),
          place.multiplied(leanMatrix),
        );
        expect(
          reference.count((r, g, b, a) => r > 128),
          greaterThan(1000),
        );
        expect(differingPixels(custom, reference), lessThan(8));
      },
    );
  });
}
