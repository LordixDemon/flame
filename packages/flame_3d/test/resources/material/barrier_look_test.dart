import 'dart:convert';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BarrierLook', () {
    test('holds the defaults of BarrierMaterial', () {
      expect(BarrierMaterial().look, BarrierLook.standard);
      expect(BarrierMaterial().look.hashCode, BarrierLook.standard.hashCode);
    });

    test('names its presets, each a look of its own', () {
      expect(BarrierLook.presets.keys, [
        'standard',
        'softVeil',
        'solidWall',
        'lowFence',
        'electricCage',
      ]);
      final looks = BarrierLook.presets.values.toList();
      for (var i = 0; i < looks.length; i++) {
        for (var j = i + 1; j < looks.length; j++) {
          expect(looks[i], isNot(looks[j]));
        }
      }
      // The presets that lay over the scene keep their hue.
      expect(BarrierLook.solidWall.blend, BlendState.premultipliedAlpha);
      expect(BarrierLook.solidWall.preserveHue, isTrue);
      expect(BarrierLook.solidWall.reactionInFront, 1);
      expect(BarrierLook.electricCage.pattern, BarrierPattern.grid);
    });

    test('copies with some settings replaced', () {
      const look = BarrierLook(patternColor: Color(0xFF00FF00));
      final copy = look.copyWith(intensity: 2, patternRows: 3);
      expect(copy.intensity, 2);
      expect(copy.patternRows, 3);
      expect(copy.patternColor, const Color(0xFF00FF00));
      expect(copy.copyWith(intensity: 0.8, patternRows: 1), look);
      expect(look.copyWith(clearPatternColor: true).patternColor, isNull);
      expect(look.copyWith(), look);
    });

    group('lerp', () {
      const a = BarrierLook(
        footColor: Color(0xFF000000),
        intensity: 1,
        pattern: BarrierPattern.diamonds,
      );
      const b = BarrierLook(
        footColor: Color(0xFFFF8000),
        intensity: 3,
        patternRows: 4,
        pattern: BarrierPattern.hexagons,
        blend: BlendState.premultipliedAlpha,
        preserveHue: true,
      );

      test('gives each end at 0 and 1', () {
        expect(BarrierLook.lerp(a, b, 0), a);
        expect(BarrierLook.lerp(a, b, 1), b);
        for (final preset in BarrierLook.presets.values) {
          expect(BarrierLook.lerp(preset, BarrierLook.solidWall, 0), preset);
          expect(BarrierLook.lerp(BarrierLook.solidWall, preset, 1), preset);
        }
      });

      test('interpolates numbers and colors, rounds whole numbers', () {
        final half = BarrierLook.lerp(a, b, 0.5);
        expect(half.intensity, 2);
        expect(half.patternRows, 3);
        expect(half.footColor.r, closeTo(0.5, 1e-9));
        expect(half.footColor.g, closeTo(0.5 * 0x80 / 0xFF, 1e-9));
        expect(half.footColor.b, 0);
        expect(BarrierLook.lerp(a, b, 0.25).intensity, 1.5);
      });

      test('switches the pattern, the blend and the hue at 0.5', () {
        final before = BarrierLook.lerp(a, b, 0.49);
        final after = BarrierLook.lerp(a, b, 0.5);
        expect(before.pattern, BarrierPattern.diamonds);
        expect(before.blend, BlendState.additive);
        expect(before.preserveHue, isFalse);
        expect(after.pattern, BarrierPattern.hexagons);
        expect(after.blend, BlendState.premultipliedAlpha);
        expect(after.preserveHue, isTrue);
      });

      test('blends a missing motif color as the color it stands for', () {
        expect(BarrierLook.lerp(a, a, 0.5).patternColor, isNull);
        final green = a.copyWith(patternColor: const Color(0xFF00FF00));
        final half = BarrierLook.lerp(a, green, 0.5);
        // The foot (black) lightened by a third towards white: 0.35 grey.
        expect(half.patternColor!.r, closeTo(0.175, 1e-9));
        expect(half.patternColor!.g, closeTo(0.675, 1e-9));
      });
    });

    group('JSON', () {
      test('round-trips every preset through text', () {
        for (final preset in BarrierLook.presets.values) {
          final text = jsonEncode(preset.toJson());
          final back = BarrierLook.fromJson(
            jsonDecode(text) as Map<String, Object?>,
          );
          expect(back, preset);
        }
      });

      test('writes colors as integers and enums by name', () {
        final json = BarrierLook.solidWall.toJson();
        expect(json['footColor'], 0xFFFFA640);
        expect(json['blend'], 'premultipliedAlpha');
        expect(json['pattern'], 'hexagons');
        expect(BarrierLook.standard.toJson()['patternColor'], isNull);
        expect(json, hasLength(65));
      });

      test('keeps the defaults of missing keys and takes whole numbers', () {
        final look = BarrierLook.fromJson(const {
          'intensity': 2,
          'patternRows': 3,
        });
        expect(look, const BarrierLook(intensity: 2, patternRows: 3));
        expect(BarrierLook.fromJson(const {}), BarrierLook.standard);
      });

      test('rejects values of the wrong type and unknown names', () {
        expect(
          () => BarrierLook.fromJson(const {'intensity': 'bright'}),
          throwsFormatException,
        );
        expect(
          () => BarrierLook.fromJson(const {'patternRows': 1.5}),
          throwsFormatException,
        );
        expect(
          () => BarrierLook.fromJson(const {'footColor': '#FFFFFF'}),
          throwsFormatException,
        );
        expect(
          () => BarrierLook.fromJson(const {'pattern': 'spirals'}),
          throwsFormatException,
        );
        expect(
          () => BarrierLook.fromJson(const {'preserveHue': 1}),
          throwsFormatException,
        );
      });
    });
  });

  group('BarrierMaterial looks', () {
    test('takes every setting of a look and gives it back', () {
      for (final preset in BarrierLook.presets.values) {
        final material = BarrierMaterial.fromLook(preset);
        expect(material.look, preset);
        expect(material.renderState.blend, preset.blend);
      }
    });

    test('blends two looks as BarrierLook.lerp does', () {
      final material = BarrierMaterial();
      for (final t in const [0.0, 0.3, 0.5, 0.8, 1.0]) {
        material.applyLookLerp(
          BarrierLook.softVeil,
          BarrierLook.electricCage,
          t,
        );
        expect(
          material.look,
          BarrierLook.lerp(BarrierLook.softVeil, BarrierLook.electricCage, t),
          reason: 't $t',
        );
      }
    });

    test('keeps its state: impacts, time, appear, near points, the loop', () {
      final material = BarrierMaterial(appear: 0.4)
        ..time = 2
        ..fitPatternTo(10.3, motifLength: 0.45)
        ..impact(Vector3.zero())
        ..setNearPoint(1, Vector3(1, 2, 3));
      material.look = BarrierLook.solidWall;
      expect(material.appear, 0.4);
      expect(material.time, 2);
      expect(material.activeImpactCount, 1);
      expect(material.isNearPointActive(1), isTrue);
      expect(material.patternLoopLength, 10.3);
      // The look's 3 motifs per unit, rounded to 31 on the loop.
      expect(material.patternScale, closeTo(31 / 10.3, 1e-12));
    });

    test('switches between the standard render states without copies', () {
      final material = BarrierMaterial()..look = BarrierLook.softVeil;
      expect(
        identical(material.renderState, RenderState.premultipliedAlphaBlend),
        isTrue,
      );
      material.look = BarrierLook.standard;
      expect(identical(material.renderState, RenderState.additive), isTrue);
      material
        ..renderState = const RenderState(
          blend: BlendState.additive,
          depthWrite: false,
          cullMode: CullMode.backFace,
        )
        ..look = BarrierLook.softVeil;
      expect(material.renderState.blend, BlendState.premultipliedAlpha);
      expect(material.renderState.cullMode, CullMode.backFace);
    });
  });
}
