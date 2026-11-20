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

  group('WaterFoamSources', () {
    test('adds sources into free slots, and throws when full', () {
      final sources = WaterFoamSources();
      expect(sources.capacity, 8);
      for (var i = 0; i < sources.capacity; i++) {
        final slot = i.isEven
            ? sources.addCircle(Vector3.zero(), radius: 0.2)
            : sources.addRectangle(
                Vector3.zero(),
                halfLength: 0.5,
                halfWidth: 0.3,
              );
        expect(slot, i);
        expect(sources.isUsed(i), isTrue);
      }
      expect(sources.length, sources.capacity);
      expect(
        () => sources.addCircle(Vector3.zero(), radius: 0.2),
        throwsStateError,
      );
      sources.remove(3);
      expect(sources.isUsed(3), isFalse);
      expect(sources.addCircle(Vector3.zero(), radius: 0.1), 3);
      // A larger set, up to 16.
      final large = WaterFoamSources(capacity: WaterFoamSources.maxCapacity);
      for (var i = 0; i < 16; i++) {
        expect(large.addCircle(Vector3.zero(), radius: 0.1), i);
      }
      expect(
        () => large.addCircle(Vector3.zero(), radius: 0.1),
        throwsStateError,
      );
      expect(() => large.isUsed(16), throwsRangeError);
      expect(() => WaterFoamSources(capacity: 0), throwsRangeError);
      expect(() => WaterFoamSources(capacity: 17), throwsRangeError);
      // A slot can be set directly, used or not.
      sources
        ..clear()
        ..setCircle(5, Vector3(1, 0, 0), radius: 0.4);
      expect(sources.length, 1);
      expect(sources.isUsed(5), isTrue);
      expect(sources.addCircle(Vector3.zero(), radius: 0.1), 0);
    });

    test('moves and changes its sources, changing its version only when '
        'something changes', () {
      final sources = WaterFoamSources();
      final versions = <int>{sources.version};
      final slot = sources.addCircle(Vector3(1, 0, 2), radius: 0.3);
      versions.add(sources.version);
      sources.move(slot, Vector3(1, 0, 2));
      sources.setStrength(slot, 1);
      sources.setCircle(slot, Vector3(1, 0, 2), radius: 0.3);
      expect(versions, hasLength(2));
      sources.move(slot, Vector3(1.5, 0, 2));
      versions.add(sources.version);
      sources.move(slot, Vector3(1.5, 0, 2), axis: Vector3(0, 0, 1));
      versions.add(sources.version);
      sources.setStrength(slot, 0.25);
      versions.add(sources.version);
      expect(sources.strengthOf(slot), 0.25);
      sources.remove(slot);
      versions.add(sources.version);
      sources.remove(slot);
      expect(versions, hasLength(6));
      expect(() => sources.move(slot, Vector3.zero()), throwsStateError);
      expect(() => sources.setStrength(slot, 1), throwsStateError);
      expect(() => sources.isUsed(-1), throwsRangeError);
      expect(() => sources.remove(sources.capacity), throwsRangeError);
    });

    test('rejects shapes it cannot draw', () {
      final sources = WaterFoamSources();
      final zero = Vector3.zero();
      expect(() => sources.addCircle(zero, radius: -1), throwsArgumentError);
      expect(
        () => sources.addCircle(zero, radius: 1, width: 0),
        throwsArgumentError,
      );
      expect(
        () => sources.addCircle(zero, radius: 1, strength: -0.5),
        throwsArgumentError,
      );
      expect(
        () => sources.addCircle(zero, radius: double.nan),
        throwsArgumentError,
      );
      expect(
        () => sources.addRectangle(zero, halfLength: -1, halfWidth: 1),
        throwsArgumentError,
      );
      expect(
        () => sources.addRectangle(
          zero,
          halfLength: 1,
          halfWidth: 1,
          cornerRadius: -0.1,
        ),
        throwsArgumentError,
      );
      expect(sources.length, 0);
    });

    test(
      'writes the sources in their slots, in plane coordinates and widths',
      () {
        final sources = WaterFoamSources()
          ..addCircle(Vector3(9, 9, 9), radius: 1, strength: 0)
          ..addCircle(Vector3(1, 2, 3), radius: 0.3, width: 0.25)
          ..addRectangle(
            Vector3(4, 5, 6),
            halfLength: 1,
            halfWidth: 0.5,
            // More than the smaller half: clamped to it.
            cornerRadius: 0.75,
            axis: Vector3(0, 2, 0),
            width: 0.5,
            strength: 0.8,
          )
          ..addRectangle(
            Vector3(0, 0, 1),
            halfLength: 0.4,
            halfWidth: 0.2,
            // Along the up axis: the first axis of the plane.
            axis: Vector3(0, 0, 3),
          );
        final positions = List.generate(16, (_) => Vector4.zero());
        final shapes = List.generate(16, (_) => Vector4.zero());
        // A +Z-up plane: the plane axes are +X and +Y.
        final count = sources.writeUniforms(
          Vector3(1, 0, 0),
          Vector3(0, 1, 0),
          positions,
          shapes,
        );
        expect(count, 4);
        // The hidden source keeps its slot, with a strength of 0.
        expect(positions[0].storage, [0, 0, 0, 0]);
        expect(shapes[0].storage, [0, 0, 0, 0]);
        // A circle is a rectangle with no straight part and round corners;
        // its axis is world x, divided by the width.
        expect(positions[1].storage, [1, 2, 4, 0]);
        expect(shapes[1].storage, [0, 0, 1.2000000476837158, 1]);
        // Along +Y, divided by the width.
        expect(positions[2].storage, [4, 5, 0, 2]);
        expect(shapes[2].storage, [1, 0, 1, 0.800000011920929]);
        expect(
          positions[3].storage,
          [0, 0, 1 / 0.3, 0].map((v) {
            return closeTo(v, 1e-6);
          }).toList(),
        );
        expect(shapes[3].storage.sublist(0, 3), [
          closeTo(0.4 / 0.3, 1e-6),
          closeTo(0.2 / 0.3, 1e-6),
          0,
        ]);

        // Up to the last source above 0; a source that carries its pattern
        // is sent with a negative strength.
        sources
          ..setStrength(3, 0)
          ..setCarryPattern(2, carry: true);
        expect(
          sources.writeUniforms(
            Vector3(1, 0, 0),
            Vector3(0, 1, 0),
            positions,
            shapes,
          ),
          3,
        );
        expect(shapes[2].w, closeTo(-0.8, 1e-6));
        expect(shapes[1].w, 1);
      },
    );

    test('carries the pattern of the sources that ask for it', () {
      final sources = WaterFoamSources();
      final circle = sources.addCircle(Vector3.zero(), radius: 0.2);
      final carried = sources.addRectangle(
        Vector3.zero(),
        halfLength: 0.4,
        halfWidth: 0.2,
        carryPattern: true,
      );
      expect(sources.carriesPattern(circle), isFalse);
      expect(sources.carriesPattern(carried), isTrue);
      final version = sources.version;
      sources.setCarryPattern(carried, carry: true);
      expect(sources.version, version);
      sources.setCarryPattern(circle, carry: true);
      expect(sources.version, isNot(version));
      expect(sources.carriesPattern(circle), isTrue);
      // Setting a slot again sets it as asked.
      sources.setCircle(circle, Vector3.zero(), radius: 0.2);
      expect(sources.carriesPattern(circle), isFalse);
      sources.remove(carried);
      expect(() => sources.carriesPattern(carried), throwsStateError);
      expect(
        () => sources.setCarryPattern(carried, carry: true),
        throwsStateError,
      );
    });

    test('writes the circles beyond which the sources have no foam', () {
      final sources = WaterFoamSources()
        ..addCircle(Vector3(1, 2, 3), radius: 0.3, width: 0.25)
        ..addRectangle(
          Vector3(4, 5, 6),
          halfLength: 1,
          halfWidth: 0.5,
          cornerRadius: 0.1,
          axis: Vector3(1, 1, 0),
          width: 0.5,
        )
        ..addCircle(Vector3(9, 9, 9), radius: 1, strength: 0);
      final bounds = List.generate(16, (_) => Vector4.zero());
      final origin = Vector2.zero();
      final count = sources.writeBounds(
        Vector3(1, 0, 0),
        Vector3(0, 1, 0),
        bounds,
        origin,
      );
      expect(count, 2);
      // The middle of the centers of the sources above 0, and the centers
      // relative to it.
      expect(origin.storage, [2.5, 3.5]);
      expect(bounds[0].storage.sublist(0, 2), [-1.5, -1.5]);
      expect(bounds[1].storage.sublist(0, 2), [1.5, 1.5]);
      // |q|² + z, at the plane point q (relative to the origin), is below 0
      // wherever a source has foam: on the circle's reach, and at the far
      // end of the rectangle's turned corner, its foam's width out.
      double gate(int i, double u, double v) {
        final qu = u - origin.x;
        final qv = v - origin.y;
        final b = bounds[i];
        return qu * qu + qv * qv + b.z - 2 * (qu * b.x + qv * b.y);
      }

      for (var k = 0; k < 16; k++) {
        final angle = k * math.pi / 8;
        expect(
          gate(0, 1 + 0.55 * math.cos(angle), 2 + 0.55 * math.sin(angle)),
          lessThan(0),
        );
      }
      final along = Vector2(1, 1)..normalize();
      final across = Vector2(-along.y, along.x);
      final corner = Vector2(4, 5)
        ..addScaled(along, 0.9)
        ..addScaled(across, 0.4);
      final out = (corner - Vector2(4, 5))..normalize();
      corner.addScaled(out, 0.1 + 0.5);
      expect(gate(1, corner.x, corner.y), lessThan(0));
      // Far from them, above 0.
      expect(gate(0, 1 + 0.75, 2), greaterThan(0));
      expect(gate(1, 4 + 2, 5), greaterThan(0));
      // No source above 0: none, and the origin at 0.
      sources
        ..setStrength(0, 0)
        ..setStrength(1, 0);
      expect(
        sources.writeBounds(Vector3(1, 0, 0), Vector3(0, 1, 0), bounds, origin),
        0,
      );
      expect(origin.storage, [0, 0]);
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

    test('moves the foam with a phase of its own', () {
      for (final time in [0.0, 1.3, 7.9, 123.4]) {
        // At its own pace, the phase of the other patterns, exactly.
        expect(
          WaterMaterial.edgeFoamPhase(time, 8, 1),
          WaterMaterial.patternPhase(time, 8),
        );
        expect(WaterMaterial.edgeFoamPhase(time, 8, 0), 0);
        expect(WaterMaterial.edgeFoamPhase(time, 8, -1), 0);
        expect(
          WaterMaterial.edgeFoamPhase(time, 8, 0.5),
          WaterMaterial.patternPhase(time * 0.5, 8),
        );
      }
      expect(WaterMaterial.edgeFoamPhase(3, 8, double.nan), 0);
    });

    test('draws large sets and carried patterns with its full stage', () {
      final water = WaterMaterial();
      final lean = water.fragmentShader;
      final small = WaterFoamSources();
      water.foamSources = small;
      expect(water.fragmentShader, same(lean));
      // More than 8 sources: the full stage.
      water.foamSources = WaterFoamSources(capacity: 12);
      final full = water.fragmentShader;
      expect(full, isNot(same(lean)));
      water.foamSources = WaterFoamSources(capacity: 16);
      expect(water.fragmentShader, same(full));
      water.foamSources = null;
      expect(water.fragmentShader, same(lean));
      // A source that carries its pattern: the full stage, as long as it
      // does.
      water.foamSources = small;
      final slot = small.addCircle(Vector3.zero(), radius: 0.2);
      expect(water.fragmentShader, same(lean));
      small.setCarryPattern(slot, carry: true);
      expect(water.fragmentShader, same(full));
      small.remove(slot);
      expect(water.fragmentShader, same(lean));
      expect(
        WaterMaterial(foamSources: WaterFoamSources(capacity: 9))
            .fragmentShader,
        isNot(same(WaterMaterial().fragmentShader)),
      );
      // A fragment shader set by hand stays.
      final custom = WaterMaterial().fragmentShader;
      water
        ..fragmentShader = custom
        ..foamSources = WaterFoamSources(capacity: 16);
      expect(water.fragmentShader, same(custom));
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

      List<double> vertexMember(
        WaterMaterial material,
        Map<String, Float32List> uniforms,
        String name,
      ) {
        final offset =
            material.vertexShader
                .slot('WaterVertex')
                .getMemberOffsetInBytes(name)! ~/
            4;
        return uniforms['WaterVertex']!.sublist(offset, offset + 4);
      }

      test('turns every option off by default', () {
        final water = WaterMaterial();
        final uniforms = draw(water);
        expect(member(water, uniforms, 'causticColor')[3], 0);
        expect(member(water, uniforms, 'pattern')[2], 0);
        expect(member(water, uniforms, 'detail')[0], 0);
        // Nothing adds light.
        expect(member(water, uniforms, 'detail')[3], 0);
        // No depth ramp, no ripple, no foam source.
        expect(member(water, uniforms, 'ramp')[0], 0);
        expect(member(water, uniforms, 'ramp')[2], 0);
        expect(member(water, uniforms, 'ramp')[3], 0);
        expect(vertexMember(water, uniforms, 'surface'), [1, 0, 0, 0]);
        // The foam takes the color of the light and moves at its pace, and
        // its light falls to half its color at least.
        final shore = member(water, uniforms, 'shoreParams');
        expect(shore[2], member(water, uniforms, 'pattern')[0]);
        expect(shore[3], 1);
        expect(member(water, uniforms, 'upAxis'), [0, 1, 0, 0.5]);
      });

      test('writes the foam controls', () {
        final sources = WaterFoamSources()
          ..addCircle(Vector3(1, 0, 2), radius: 0.5, width: 0.25)
          ..addCircle(Vector3(3, 0, 0), radius: 0.1, strength: 0);
        final water = WaterMaterial(
          time: 3,
          foamLightTint: 0.25,
          foamLightFloor: 0.85,
          edgeFoamMotion: 0.5,
          foamSources: sources,
        );
        var uniforms = draw(water);
        var shore = member(water, uniforms, 'shoreParams');
        // Half the pace: 1.5 s of an 8 s period.
        expect(shore[2], closeTo(math.pi * 3 / 8, 1e-6));
        expect(shore[3], 0.25);
        expect(member(water, uniforms, 'upAxis')[3], closeTo(0.85, 1e-6));
        // The pattern keeps its own phase: 3 s of 8.
        expect(
          member(water, uniforms, 'pattern')[0],
          closeTo(math.pi * 3 / 4, 1e-6),
        );
        // Only the source above 0 is sent. Up is +Y: the plane axes are +Z
        // and +X, and world x (the circle's axis) is the second.
        expect(member(water, uniforms, 'ramp')[2], 1);
        expect(member(water, uniforms, 'foamSourcePositions'), [2, 1, 0, 4]);
        expect(member(water, uniforms, 'foamSourceShapes'), [0, 0, 2, 1]);
        // The vertices get its circle, around its own center: the reach of
        // 0.75, a little enlarged.
        final surface = vertexMember(water, uniforms, 'surface');
        expect(surface.sublist(1), [1, 2, 1]);
        final bound = vertexMember(water, uniforms, 'foamSourceBounds');
        expect(bound.sublist(0, 2), [0, 0]);
        expect(-bound[2], greaterThan(0.75 * 0.75));
        expect(-bound[2], lessThan(0.85 * 0.85));

        water
          ..foamLightTint = 3
          ..edgeFoamMotion = 0;
        uniforms = draw(water);
        shore = member(water, uniforms, 'shoreParams');
        expect(shore[2], 0);
        expect(shore[3], 1);
        water.foamLightTint = -1;
        expect(member(water, draw(water), 'shoreParams')[3], 0);
        water.foamLightFloor = -1;
        expect(member(water, draw(water), 'upAxis')[3], 0);
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
