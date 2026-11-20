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

    group('impact slots', () {
      test('are raised to eight, then replace the oldest', () {
        final material = BarrierMaterial(impactSlots: 8);
        final at = Vector3.zero();
        for (var i = 0; i < BarrierMaterial.maxImpactSlots; i++) {
          material.time = i * 0.05;
          expect(material.impact(at), i);
        }
        expect(material.activeImpactCount, 8);
        material.time = 0.41;
        expect(material.impact(at), 0);
      });

      test('are clamped to [1, maxImpactSlots], and slots beyond are not '
          'shown', () {
        final material = BarrierMaterial(impactSlots: 20);
        for (var i = 0; i < 10; i++) {
          material.impact(Vector3.zero());
        }
        expect(material.activeImpactCount, BarrierMaterial.maxImpactSlots);
        material.impactSlots = 2;
        expect(material.activeImpactCount, 2);
        expect(material.isImpactActive(5), isFalse);
        material.impactSlots = 0;
        expect(material.activeImpactCount, 1);
      });

      test('take the impact color when given none', () {
        final material = BarrierMaterial(
          impactColor: const Color(0x80FF0000),
        )..impact(Vector3.zero(), strength: 2);
        expect(material.activeImpactCount, 1);
        material.impactColor = const Color(0x00FF0000);
        material.impact(Vector3.zero());
        // A transparent color shows nothing.
        expect(material.activeImpactCount, 1);
      });
    });

    group('pulse', () {
      test('rises over its attack and falls back over the rest', () {
        final material = BarrierMaterial(pulseDuration: 1, pulseAttack: 0.2)
          ..time = 10;
        expect(material.pulseValue, 0);
        material.pulse(strength: 2);
        expect(material.pulseValue, 0);
        material.time = 10.1;
        expect(material.pulseValue, closeTo(1, 1e-9));
        material.time = 10.2;
        expect(material.pulseValue, closeTo(2, 1e-9));
        material.time = 10.6;
        expect(material.pulseValue, closeTo(2 * 0.25, 1e-9));
        material.time = 11;
        expect(material.pulseValue, 0);
      });

      test('started again, rises from where it is', () {
        final material = BarrierMaterial(pulseDuration: 1, pulseAttack: 0.5)
          ..pulse();
        material.time = 0.75;
        final now = material.pulseValue;
        expect(now, closeTo(0.25, 1e-9));
        material.pulse(duration: 2);
        expect(material.pulseValue, closeTo(now, 1e-9));
        material.time = 1.75;
        expect(material.pulseValue, closeTo(1, 1e-9));
        material.clearPulse();
        expect(material.pulseValue, 0);
      });
    });

    group('near points', () {
      test('are set, counted and cleared', () {
        final material = BarrierMaterial()
          ..setNearPoint(0, Vector3(1, 0, 0))
          ..setNearPoint(3, Vector3(0, 1, 0), strength: 0.5);
        expect(material.activeNearPointCount, 2);
        expect(material.isNearPointActive(3), isTrue);
        material.clearNearPoint(0);
        expect(material.activeNearPointCount, 1);
        material.setNearPoint(2, Vector3.zero(), strength: 0);
        expect(material.activeNearPointCount, 1);
        material.clearNearPoints();
        expect(material.activeNearPointCount, 0);
        expect(
          () => material.setNearPoint(4, Vector3.zero()),
          throwsRangeError,
        );
      });
    });

    group('reaction in front', () {
      test('draws only with a reaction to show', () {
        final material = BarrierMaterial();
        expect(material.drawsReactionInFront, isFalse);
        material.impact(Vector3.zero());
        expect(material.drawsReactionInFront, isFalse);
        material.reactionInFront = 0.5;
        expect(material.drawsReactionInFront, isTrue);
        material.appear = 0;
        expect(material.drawsReactionInFront, isFalse);
        material
          ..appear = 1
          ..heightScale = 0;
        expect(material.drawsReactionInFront, isFalse);
        material
          ..heightScale = 1
          ..clearImpacts();
        expect(material.drawsReactionInFront, isFalse);
        material.setNearPoint(0, Vector3.zero());
        expect(material.drawsReactionInFront, isTrue);
      });

      test('has a material depth tested where something is in front', () {
        final material = BarrierMaterial()..translucentOrder = 2;
        final front = material.reactionInFrontMaterial;
        expect(identical(front, material.reactionInFrontMaterial), isTrue);
        expect(front.renderState.blend, BlendState.additive);
        expect(front.renderState.depthCompare, CompareFunction.greater);
        expect(front.renderState.depthTest, isTrue);
        expect(front.renderState.depthWrite, isFalse);
        expect(front.renderState.translucent, isTrue);
        expect(front.castsShadows, isFalse);
        expect(front.translucentOrder, 2);
        material.renderState = RenderState.singlePiecePremultipliedAlphaBlend;
        final state = material.reactionInFrontMaterial.renderState;
        expect(state.blend, BlendState.premultipliedAlpha);
        expect(state.depthCompare, CompareFunction.greater);
        expect(state.depthPrepass, isFalse);
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
          blockSizes: {'BarrierLook': 32768, 'BarrierShape': 8192},
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

      test('the active impacts first, and their number to both stages', () {
        final material = BarrierMaterial(impactDuration: 1)
          ..impact(Vector3(1, 1, 1))
          ..time = 0.5
          ..impact(Vector3(2, 2, 2), strength: 0.5)
          ..time = 0.6
          ..impact(Vector3(3, 3, 3), color: const Color(0xFF00FF00))
          // The first impact has ended: slots 1 and 2 show.
          ..time = 1.2;
        final uniforms = draw(material);
        expect(member(material, uniforms, 'extra')[3], 2);
        expect(
          member(material, uniforms, 'params', block: 'BarrierShape')[3],
          2,
        );
        expect(
          member(material, uniforms, 'impactPositions'),
          orderedEquals([2, 2, 2, closeTo(0.7, 1e-6)]),
        );
        expect(
          member(material, uniforms, 'impactPositions', index: 1),
          orderedEquals([3, 3, 3, closeTo(0.6, 1e-6)]),
        );
        expect(
          member(material, uniforms, 'impactColors', index: 1),
          orderedEquals([0, 1, 0, 1]),
        );
        expect(
          member(material, uniforms, 'impactPositions', index: 2)[3],
          -1,
        );
        expect(
          member(
            material,
            uniforms,
            'impactPositions',
            index: 1,
            block: 'BarrierShape',
          ),
          orderedEquals([3, 3, 3, closeTo(0.6, 1e-6)]),
        );
        expect(
          member(material, uniforms, 'impactStrengths', block: 'BarrierShape'),
          orderedEquals([0.5, 1, 0, 0]),
        );
      });

      test('nothing that turns an option on, by default', () {
        final material = BarrierMaterial()..time = 3;
        final uniforms = draw(material);
        // The fade is not remapped, the flicker is 1.
        expect(
          member(material, uniforms, 'profile'),
          orderedEquals([0, 1, 0, 1]),
        );
        expect(
          member(material, uniforms, 'topEdge'),
          orderedEquals([0, 0, 0, 0]),
        );
        expect(member(material, uniforms, 'fill')[3], 0);
        expect(member(material, uniforms, 'mode'), orderedEquals([0, 0, 0, 0]));
        expect(member(material, uniforms, 'noise')[0], 0);
        expect(
          member(material, uniforms, 'pulse'),
          orderedEquals([0, 0, 0, 0]),
        );
        expect(member(material, uniforms, 'proximity')[2], 0);
        expect(
          member(material, uniforms, 'rings'),
          orderedEquals([1, closeTo(0.15, 1e-6), 1, 0]),
        );
        expect(
          member(material, uniforms, 'flash'),
          orderedEquals([closeTo(0.8, 1e-6), 3, 0, 0]),
        );
        expect(
          member(material, uniforms, 'patternStyle'),
          orderedEquals([1, 1, 0.25, 0]),
        );
        expect(member(material, uniforms, 'patternColor')[3], 0);
        final params = member(
          material,
          uniforms,
          'params',
          block: 'BarrierShape',
        );
        expect(params.sublist(0, 3), orderedEquals([1, 1, 0]));
      });

      test('the options that are on', () {
        final material =
            BarrierMaterial(
                fadeStart: 0.2,
                fadeEnd: 0.6,
                topEdgeStrength: 0.5,
                topEdgeWidth: 0.1,
                topEdgeColor: const Color(0xFF00FF00),
                fillOpacity: 0.4,
                fillColor: const Color(0x80FF0000),
                patternRows: 3,
                patternRiseSpeed: 2,
                patternColor: const Color(0xFF0000FF),
                noiseStrength: 0.5,
                preserveHue: true,
                heightScale: 1.5,
                wobbleAmplitude: 0.05,
                wobbleWavelength: 0.5,
                wobbleFrequency: 4,
                impactRingCount: 9,
              )
              ..fitPatternTo(10.3)
              ..time = 9.5
              ..setNearPoint(
                2,
                Vector3(1, 2, 3),
                color: const Color(0xFFFF0000),
              )
              ..pulse();
        material.time = 9.5 + 0.05;
        final uniforms = draw(material);
        final profile = member(material, uniforms, 'profile');
        expect(profile[0], closeTo(0.2, 1e-6));
        expect(profile[1], closeTo(2.5, 1e-5));
        expect(profile[2], 1);
        expect(
          member(material, uniforms, 'topEdge'),
          orderedEquals([0, 0.5, 0, closeTo(10, 1e-5)]),
        );
        expect(
          member(material, uniforms, 'fill'),
          orderedEquals([1, 0, 0, closeTo(0.2, 1e-2)]),
        );
        final mode = member(material, uniforms, 'mode');
        expect(mode.sublist(1, 4), orderedEquals([1, 1, 0]));
        final style = member(material, uniforms, 'patternStyle');
        expect(style[0], 3);
        // 19.1 rows wrapped to 16.
        expect(style[3], closeTo(3.1, 1e-4));
        expect(
          member(material, uniforms, 'patternColor'),
          orderedEquals([0, 0, 1, 1]),
        );
        // The noise fitted to the loop: 31 cells over 10.3 units.
        final noise = member(material, uniforms, 'noise');
        expect(noise[1], closeTo(31 / 10.3, 1e-5));
        expect(member(material, uniforms, 'noiseExtra')[0], 31);
        // At most four rings.
        expect(member(material, uniforms, 'rings')[0], 4);
        // The near point in the first slot, in its own color.
        expect(member(material, uniforms, 'proximity')[2], 1);
        expect(
          member(material, uniforms, 'nearPositions'),
          orderedEquals([1, 2, 3, 1]),
        );
        expect(
          member(material, uniforms, 'nearColors').sublist(0, 3),
          orderedEquals([1, 0, 0]),
        );
        expect(member(material, uniforms, 'pulse')[3], greaterThan(0));
        final params = member(
          material,
          uniforms,
          'params',
          block: 'BarrierShape',
        );
        expect(params.sublist(0, 3), [1, 1.5, closeTo(0.05, 1e-6)]);
        final wobble = member(
          material,
          uniforms,
          'wobble',
          block: 'BarrierShape',
        );
        expect(wobble[0], closeTo(4 * 3.14159265, 1e-4));
        expect(wobble[1], closeTo(2, 1e-6));
      });

      test('the reaction-only scale with the reaction material', () {
        final material = BarrierMaterial(reactionInFront: 0.6)
          ..impact(Vector3.zero());
        final front = material.reactionInFrontMaterial;
        final ring = BarrierMesh.ring(
          radius: 1,
          height: 1,
          segments: 8,
          material: material,
        );
        device.begin();
        context.setCamera(Matrix4.identity(), Matrix4.identity());
        device.beginPass(const Size(8, 8));
        context
          ..drawSurface(ring.surfaces.first, material: front)
          ..flush();
        device
          ..endPass()
          ..end();
        final offset =
            front.fragmentShader
                .slot('BarrierLook')
                .getMemberOffsetInBytes('mode')! ~/
            Float32List.bytesPerElement;
        expect(
          backend.uniforms['BarrierLook']![offset + 3],
          closeTo(0.6, 1e-6),
        );
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
