import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

void main() {
  group('WaterRipples', () {
    test('adds ripples into free slots, then replaces the weakest', () {
      final ripples = WaterRipples();
      for (var i = 0; i < WaterRipples.capacity; i++) {
        expect(ripples.add(Vector3.zero(), time: i.toDouble()), i);
      }
      expect(ripples.length, WaterRipples.capacity);
      // At time 20 every ripple is over: the first that started goes.
      expect(ripples.add(Vector3.zero(), time: 20), 0);
      expect(ripples.add(Vector3.zero(), time: 21), 1);
      expect(ripples.length, WaterRipples.capacity);

      // A full set of living ripples: a strong one in slot 3, faint drops
      // elsewhere. New drops replace the faintest, never the strong one.
      ripples.clear();
      for (var i = 0; i < WaterRipples.capacity; i++) {
        ripples.add(
          Vector3.zero(),
          time: 30 + i * 0.01,
          strength: i == 3 ? 1 : 0.1,
          lifetime: 2,
        );
      }
      for (var k = 0; k < 20; k++) {
        final slot = ripples.add(
          Vector3.zero(),
          time: 30.2 + k * 0.01,
          strength: 0.1,
          lifetime: 2,
        );
        expect(slot, isNot(3));
      }
      expect(ripples.frontRadius(3, 30.5), isNotNull);
      // A faint ripple of the same strength that started earlier is weaker
      // now: it goes first.
      final early = WaterRipples();
      for (var i = 0; i < WaterRipples.capacity; i++) {
        early.add(Vector3.zero(), time: i * 0.1, strength: 0.1, lifetime: 2);
      }
      expect(early.add(Vector3.zero(), time: 1, strength: 0.1), 0);
    });

    test('a front leaves its radius at its speed and dies with its life', () {
      final ripples = WaterRipples();
      final slot = ripples.add(
        Vector3(1, 0, 2),
        time: 3,
        speed: 0.5,
        radius: 0.2,
        lifetime: 2,
      );
      expect(ripples.frontRadius(slot, 2.9), isNull);
      expect(ripples.frontRadius(slot, 3), closeTo(0.2, 1e-12));
      expect(ripples.frontRadius(slot, 4), closeTo(0.7, 1e-12));
      expect(ripples.aliveAt(4.99), 1);
      expect(ripples.frontRadius(slot, 5), isNull);
      expect(ripples.aliveAt(5), 0);
    });

    test('removes and clears, changing its version', () {
      final ripples = WaterRipples();
      final versions = <int>{ripples.version};
      final a = ripples.add(Vector3.zero(), time: 0);
      versions.add(ripples.version);
      ripples.add(Vector3.zero(), time: 0);
      versions.add(ripples.version);
      ripples.remove(a);
      versions.add(ripples.version);
      expect(ripples.length, 1);
      expect(ripples.add(Vector3.zero(), time: 1), a);
      ripples.clear();
      versions.add(ripples.version);
      expect(ripples.length, 0);
      expect(versions, hasLength(5));
      expect(() => ripples.remove(WaterRipples.capacity), throwsRangeError);
    });

    test('rejects shapes it cannot draw', () {
      final ripples = WaterRipples();
      expect(
        () => ripples.add(Vector3.zero(), time: 0, speed: 0),
        throwsArgumentError,
      );
      expect(
        () => ripples.add(Vector3.zero(), time: 0, wavelength: -1),
        throwsArgumentError,
      );
      expect(
        () => ripples.add(Vector3.zero(), time: 0, lifetime: 0),
        throwsArgumentError,
      );
      expect(
        () => ripples.add(Vector3.zero(), time: 0, trail: 0),
        throwsArgumentError,
      );
      expect(
        () => ripples.add(Vector3.zero(), time: 0, radius: -0.1),
        throwsArgumentError,
      );
    });

    test('writes the living ripples first, in plane coordinates', () {
      final ripples = WaterRipples()
        ..add(Vector3(1, 2, 3), time: 0, lifetime: 1)
        ..add(
          Vector3(4, 5, 6),
          time: 1,
          strength: 2,
          speed: 0.5,
          wavelength: 0.25,
          trail: 2,
          lifetime: 4,
          radius: 0.1,
        );
      final positions = List.generate(8, (_) => Vector4.zero());
      final shapes = List.generate(8, (_) => Vector4.zero());
      // At time 2 the first ripple is dead.
      final count = ripples.writeUniforms(
        2,
        Vector3(1, 0, 0),
        Vector3(0, 1, 0),
        positions,
        shapes,
      );
      expect(count, 1);
      // Age 1 of 4: three quarters of its life left, squared.
      expect(positions[0].storage, [4, 5, 1, 2 * 0.75 * 0.75]);
      expect(shapes[0].storage, [0.6000000238418579, 4, 2, 0]);
    });
  });

  group('WaterMaterial', () {
    test('wraps the time into the phase of its period', () {
      expect(WaterMaterial.patternPhase(0, 8), 0);
      expect(WaterMaterial.patternPhase(2, 8), closeTo(math.pi / 2, 1e-12));
      expect(WaterMaterial.patternPhase(10, 8), closeTo(math.pi / 2, 1e-12));
      expect(
        WaterMaterial.patternPhase(-2, 8),
        closeTo(3 * math.pi / 2, 1e-12),
      );
      expect(WaterMaterial.patternPhase(1e9 + 2, 8), lessThan(2 * math.pi));
      expect(WaterMaterial.patternPhase(3, 0), 0);
      expect(WaterMaterial.patternPhase(double.infinity, 8), 0);
    });

    test('builds surfaces in its vertex layout', () {
      expect(WaterMaterial.vertexLayout.strideInFloats, 10);
      expect(
        WaterMaterial.vertexLayout.offsetOf(WaterMaterial.waterAttribute),
        7,
      );
      final water = WaterMaterial();
      final surface = WaterMaterial.buildSurface(
        positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
        depths: [0.5, 1, 2],
        foam: [1, 0, 0],
        indices: [0, 1, 2],
        material: water,
      );
      expect(surface.layout, WaterMaterial.vertexLayout);
      expect(water.vertexShaderFor(surface.layout), isNot(water.vertexShader));
      expect(
        water.vertexShaderFor(VertexLayout.standard),
        same(water.vertexShader),
      );
      expect(
        () => WaterMaterial.buildSurface(
          positions: [0, 0, 0],
          depths: [1, 2],
          indices: [0, 0, 0],
          material: water,
        ),
        throwsArgumentError,
      );
    });

    group('uniforms', () {
      late FakeGpuBackend backend;
      late GraphicsDevice device;
      late RenderContext3D context;

      setUp(() {
        // The fake backend lays members out 1024 bytes apart.
        backend = FakeGpuBackend(
          blockSizes: {
            'WaterMaterial': 32 * 1024,
            'WaterVertex': 4 * 1024,
            RenderContext3D.stylizedPassBlock: 64 * 1024,
          },
        );
        device = GraphicsDevice(backend: backend);
        context = RenderContext3D(device);
      });

      Map<String, Float32List> draw(WaterMaterial material) {
        final surface = Surface(
          vertices: [
            Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
            Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
            Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
          ],
          indices: [0, 1, 2],
          material: material,
        );
        device.begin();
        context.setCamera(Matrix4.identity(), Matrix4.identity());
        device.beginPass(const Size(8, 8));
        context
          ..drawSurface(surface)
          ..flush();
        device
          ..endPass()
          ..end();
        return backend.uniforms;
      }

      List<double> member(
        WaterMaterial material,
        Map<String, Float32List> uniforms,
        String name, {
        int index = 0,
      }) {
        final offset =
            material.fragmentShader
                .slot('WaterMaterial')
                .getMemberOffsetInBytes(name)! ~/
            4;
        final data = uniforms['WaterMaterial']!;
        return data.sublist(offset + index * 4, offset + index * 4 + 4);
      }

      test('turns every option off by default', () {
        final water = WaterMaterial();
        final uniforms = draw(water);
        expect(member(water, uniforms, 'causticColor')[3], 0);
        expect(member(water, uniforms, 'pattern')[2], 0);
        expect(member(water, uniforms, 'detail')[0], 0);
        // Nothing adds light.
        expect(member(water, uniforms, 'detail')[3], 0);
        // No depth ramp, no ripple.
        expect(member(water, uniforms, 'ramp')[0], 0);
        expect(member(water, uniforms, 'ramp')[3], 0);
        // The foam takes the color of the light.
        expect(member(water, uniforms, 'shoreParams')[3], 1);
      });

      test('writes the foam light tint', () {
        final water = WaterMaterial(foamLightTint: 0.25);
        expect(member(water, draw(water), 'shoreParams')[3], 0.25);
        water.foamLightTint = 3;
        expect(member(water, draw(water), 'shoreParams')[3], 1);
        water.foamLightTint = -1;
        expect(member(water, draw(water), 'shoreParams')[3], 0);
      });

      test('writes the options it is given', () {
        final ripples = WaterRipples()
          ..add(Vector3(1, 0, 2), time: 1, speed: 2, radius: 0.5)
          ..add(Vector3(3, 0, 0), time: 9);
        final water = WaterMaterial(
          time: 3,
          causticStrength: 0.5,
          causticScale: 0.25,
          causticColor: const Color(0xFFFF0000),
          sparkleStrength: 2,
          sparkleScale: 0.5,
          detailStrength: 0.6,
          detailScale: 2,
          edgeFoamScale: 0.4,
          animationPeriod: 4,
          depthRange: 0.5,
          shallowOpacity: 0.3,
          ripples: ripples,
        );
        final uniforms = draw(water);
        expect(member(water, uniforms, 'causticColor'), [1, 0, 0, 0.5]);
        final pattern = member(water, uniforms, 'pattern');
        // 3 s of a 4 s period.
        expect(pattern[0], closeTo(3 * math.pi / 2, 1e-6));
        expect(pattern.sublist(1), [4, 2, 2]);
        final detail = member(water, uniforms, 'detail');
        expect(detail[0], closeTo(0.6, 1e-6));
        expect(detail.sublist(1), [0.5, 2.5, 1]);
        final ramp = member(water, uniforms, 'ramp');
        expect(ramp[0], 2);
        expect(ramp[1], closeTo(0.3, 1e-6));
        // The second ripple starts at 9: only the first is alive.
        expect(ramp[3], 1);
        // Up is +Y: the plane axes are +Z and +X (see water_vertex.glsl).
        // Age 2 of 2.4: a sixth of its life left, squared.
        final position = member(water, uniforms, 'ripplePositions');
        expect(position.sublist(0, 3), [2, 1, 2]);
        expect(position[3], closeTo(1 / 36, 1e-6));
        expect(
          member(water, uniforms, 'rippleShapes').sublist(0, 2),
          [
            4.5,
            1 / 0.22,
          ].map((v) => closeTo(v, 1e-5)).toList(),
        );
      });
    });
  });
}
