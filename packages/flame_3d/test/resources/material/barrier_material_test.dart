import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

void main() {
  group('BarrierMaterial', () {
    test('is additive, two-sided, translucent and casts no shadows', () {
      final material = BarrierMaterial();
      expect(material.renderState, RenderState.additive);
      expect(material.renderState.translucent, isTrue);
      expect(material.renderState.depthWrite, isFalse);
      expect(material.renderState.depthTest, isTrue);
      expect(material.renderState.cullMode, CullMode.none);
      expect(material.castsShadows, isFalse);
      expect(material.instancesHoldModelMatrices, isTrue);
      expect(material.depthNormalMaterial, isNull);
    });

    group('impacts', () {
      test('take free slots, then replace the oldest', () {
        final material = BarrierMaterial();
        final at = Vector3.zero();
        final slots = <int>[];
        for (var i = 0; i < BarrierMaterial.maxImpacts; i++) {
          material.time = i * 0.1;
          slots.add(material.impact(at));
        }
        expect(slots, [0, 1, 2, 3]);
        expect(material.activeImpactCount, 4);

        material.time = 0.45;
        // Slot 0 holds the oldest impact.
        expect(material.impact(at), 0);
        material.time = 0.5;
        expect(material.impact(at), 1);
      });

      test('end after their duration, and reuse finished slots first', () {
        final material = BarrierMaterial(impactDuration: 0.5)
          ..impact(Vector3.zero());
        material.time = 0.2;
        material.impact(Vector3.zero());
        expect(material.isImpactActive(0), isTrue);
        material.time = 0.5;
        expect(material.isImpactActive(0), isFalse);
        expect(material.isImpactActive(1), isTrue);
        expect(material.activeImpactCount, 1);
        // The finished slot 0 is taken before the free slots after it.
        expect(material.impact(Vector3.zero()), 0);
      });

      test('with no strength or a transparent color are not shown', () {
        final material = BarrierMaterial()
          ..impact(Vector3.zero(), strength: 0)
          ..impact(Vector3.zero(), color: const Color(0x00FFFFFF));
        expect(material.activeImpactCount, 0);
      });

      test('are removed by clearImpacts', () {
        final material = BarrierMaterial()
          ..impact(Vector3.zero())
          ..impact(Vector3.zero());
        expect(material.activeImpactCount, 2);
        material.clearImpacts();
        expect(material.activeImpactCount, 0);
      });
    });

    group('pattern', () {
      test('fits a whole number of motifs to a closed loop', () {
        final material = BarrierMaterial()
          ..fitPatternTo(10.3, motifLength: 0.45);
        // 10.3 / 0.45 = 22.9: 23 motifs.
        expect(material.patternScale, closeTo(23 / 10.3, 1e-12));
        expect(material.patternLoopLength, 10.3);
        expect(material.patternPeriod, 23);
      });

      test('repeats after the open-wall period on a wall that is not '
          'closed', () {
        final material = BarrierMaterial();
        expect(material.patternPeriod, BarrierMaterial.openWallPeriod);
      });

      test('travels at its speed, wrapped to its period', () {
        final material = BarrierMaterial(patternScale: 2, patternSpeed: 0.25)
          ..time = 3;
        expect(material.patternOffset, closeTo(1.5, 1e-12));
        // After a long time the offset stays small and keeps its phase.
        material.time = 1e6 + 3;
        final period = material.patternPeriod;
        expect(material.patternOffset, lessThan(period));
        expect(
          material.patternOffset,
          closeTo((1e6 * 0.5 + 1.5) % period, 1e-6),
        );
        // Travelling the other way gives offsets in the same range.
        material
          ..patternSpeed = -0.25
          ..time = 3;
        expect(material.patternOffset, closeTo(period - 1.5, 1e-9));
      });
    });

    group('writes', () {
      late FakeGpuBackend backend;
      late GraphicsDevice device;
      late RenderContext3D context;

      setUp(() {
        backend = FakeGpuBackend(
          blockSizes: {'BarrierLook': 16384, 'BarrierShape': 1024},
        );
        device = GraphicsDevice(backend: backend);
        context = RenderContext3D(device);
      });

      /// Draws a ring with [material] through [projection] and [view] and
      /// returns the data bound to each uniform block.
      Map<String, Float32List> draw(
        BarrierMaterial material, {
        Matrix4? view,
        Matrix4? projection,
      }) {
        final ring = BarrierMesh.ring(
          radius: 1,
          height: 1,
          segments: 8,
          material: material,
        );
        device.begin();
        context.setCamera(
          view ?? Matrix4.identity(),
          projection ?? Matrix4.identity(),
        );
        device.beginPass(const Size(8, 8));
        context
          ..drawSurface(ring.surfaces.first)
          ..flush();
        device
          ..endPass()
          ..end();
        return backend.uniforms;
      }

      Float32List member(
        BarrierMaterial material,
        Map<String, Float32List> uniforms,
        String name, {
        int index = 0,
        String block = 'BarrierLook',
      }) {
        final shader = block == 'BarrierShape'
            ? material.vertexShader
            : material.fragmentShader;
        final offset =
            shader.slot(block).getMemberOffsetInBytes(name)! ~/
                Float32List.bytesPerElement +
            index * 4;
        return uniforms[block]!.sublist(offset, offset + 4);
      }

      test('the appear factor, clamped, to both stages', () {
        final material = BarrierMaterial(appear: 1.7);
        final uniforms = draw(material);
        expect(
          member(material, uniforms, 'params', block: 'BarrierShape')[0],
          1,
        );
        expect(member(material, uniforms, 'shape')[0], 1);
      });

      test('the age of active impacts and nothing for the others', () {
        final material = BarrierMaterial()
          ..time = 2
          ..impact(Vector3(1, 2, 3), color: const Color(0xFFFF0000))
          ..time = 2.25;
        final uniforms = draw(material);
        expect(
          member(material, uniforms, 'impactPositions'),
          orderedEquals([1, 2, 3, 0.25]),
        );
        expect(
          member(material, uniforms, 'impactColors'),
          orderedEquals([1, 0, 0, 1]),
        );
        for (var i = 1; i < BarrierMaterial.maxImpacts; i++) {
          expect(member(material, uniforms, 'impactColors', index: i)[3], 0);
          expect(
            member(material, uniforms, 'impactPositions', index: i)[3],
            -1,
          );
        }
      });

      test('the pattern offset and period', () {
        final material = BarrierMaterial(
          pattern: BarrierPattern.dashes,
          patternScale: 2,
          patternSpeed: -0.25,
        )..time = 3;
        final uniforms = draw(material);
        final pattern = member(material, uniforms, 'pattern');
        expect(pattern[0], BarrierPattern.dashes.index);
        expect(pattern[1], 2);
        expect(pattern[2], closeTo(256 - 1.5, 1e-4));
        final extra = member(material, uniforms, 'patternExtra');
        expect(extra[1], 256);
        expect(extra[2], -1);
        expect(extra[3], inInclusiveRange(0, 2 * math.pi));
      });

      test('the direction towards the viewer of a parallel projection', () {
        final material = BarrierMaterial();
        // Looking down -z from +z, depth growing away from the viewer.
        final uniforms = draw(
          material,
          projection: Matrix4.identity()..setEntry(2, 2, -0.1),
        );
        final viewer = member(material, uniforms, 'viewer');
        expect(viewer[0], closeTo(0, 1e-6));
        expect(viewer[1], closeTo(0, 1e-6));
        expect(viewer[2], closeTo(1, 1e-6));
        expect(viewer[3], 0);
      });

      test('the same direction when the projection mirrors the scene', () {
        final material = BarrierMaterial();
        final uniforms = draw(
          material,
          projection: Matrix4.diagonal3Values(-1, 1, -0.1),
        );
        final viewer = member(material, uniforms, 'viewer');
        expect(viewer[2], closeTo(1, 1e-6));
        expect(viewer[3], 0);
      });

      test(
        'the direction along the line of sight of an oblique projection',
        () {
          final material = BarrierMaterial();
          final projection = _oblique();
          final uniforms = draw(material, projection: projection);
          final viewer = member(material, uniforms, 'viewer');
          // Points of the line of sight through the origin all land on the
          // same spot: moving along the direction changes only the depth.
          final direction = Vector3(viewer[0], viewer[1], viewer[2]);
          final moved = projection.transformed(
            Vector4(direction.x, direction.y, direction.z, 0),
          );
          expect(moved.x, closeTo(0, 1e-6));
          expect(moved.y, closeTo(0, 1e-6));
          // Towards the viewer: the depth decreases.
          expect(moved.z, lessThan(0));
          expect(viewer[3], 0);
        },
      );

      test('the eye of a perspective camera', () {
        final material = BarrierMaterial();
        final view = Matrix4.identity()
          ..setAsViewMatrix(
            Vector3(2, 3, 4),
            Vector3.zero(),
            Vector3(0, 1, 0),
          );
        final projection = Matrix4.identity()..setAsPerspective(60, 1, 0.1, 50);
        final uniforms = draw(material, view: view, projection: projection);
        final viewer = member(material, uniforms, 'viewer');
        expect(viewer[0], closeTo(2, 1e-3));
        expect(viewer[1], closeTo(3, 1e-3));
        expect(viewer[2], closeTo(4, 1e-3));
        expect(viewer[3], 1);
      });
    });
  });
}

/// A parallel projection whose line of sight is not along an axis, with
/// depth from 0 to 1 over 20 units.
Matrix4 _oblique() {
  // Columns: the images of x, y and z, then the translation.
  return Matrix4(
    0.7,
    0.35,
    -0.03,
    0, //
    -0.7,
    0.35,
    -0.03,
    0, //
    0,
    -0.87,
    -0.025,
    0, //
    0,
    0,
    0.5,
    1, //
  );
}
