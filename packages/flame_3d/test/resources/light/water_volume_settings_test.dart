import 'dart:math' as math;
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

void main() {
  group('WaterVolumeSettings', () {
    test('is active with an absorption, caustics or a waterline', () {
      expect(WaterVolumeSettings().isActive, isTrue);
      final none = WaterVolumeSettings(absorption: 0);
      expect(none.isActive, isFalse);
      none.causticStrength = 0.5;
      expect(none.isActive, isTrue);
      none
        ..causticStrength = 0
        ..waterlineWidth = 0.1;
      expect(none.isActive, isTrue);
    });

    test('copies its up axis and wraps its time into a phase', () {
      final up = Vector3(0, 0, 1);
      final water = WaterVolumeSettings(up: up, time: 6, animationPeriod: 4);
      up.setValues(1, 0, 0);
      expect(water.up, Vector3(0, 0, 1));
      expect(water.phase, closeTo(math.pi, 1e-12));
      water.animationPeriod = 0;
      expect(water.phase, 0);
    });

    test('fills the water volume block of a pass', () {
      final backend = FakeGpuBackend();
      final context = RenderContext3D(GraphicsDevice(backend: backend));
      final block = UniformBlock(
        FakeUniformSlot(RenderContext3D.waterVolumeBlock, 8 * 1024),
      );
      List<double> read(String member) {
        final offset = block.memberOffset(member)!;
        return block.data.sublist(offset, offset + 4);
      }

      // Without a volume, it is off.
      RenderContext3D.writeWaterVolumeUniforms(context, block);
      expect(read('deep')[3], 0);

      context.waterVolume = WaterVolumeSettings(
        level: 0.5,
        up: Vector3(0, 0, 2),
        shallowColor: const Color(0xFF00FF00),
        deepColor: const Color(0xFF0000FF),
        absorption: 1.5,
        causticStrength: 0.75,
        causticScale: 0.5,
        animationPeriod: 2,
        time: 0.5,
        waterlineWidth: 0.04,
        waterlineColor: const Color(0x80FFFFFF),
        bounds: Aabb3.minMax(Vector3(-1, -2, -3), Vector3(1, 2, 3)),
      );
      RenderContext3D.writeWaterVolumeUniforms(context, block);
      expect(read('plane'), [0, 0, 1, 0.5]);
      expect(read('shallow'), [0, 1, 0, 1.5]);
      expect(read('deep'), [0, 0, 1, 1]);
      final caustics = read('caustics');
      expect(caustics[0], 0.75);
      expect(caustics[1], 2);
      expect(caustics[2], closeTo(math.pi / 2, 1e-6));
      expect(caustics[3], closeTo(0.04, 1e-6));
      expect(read('waterline')[3], closeTo(128 / 255, 1e-6));
      // The waterline takes the color of the light by default.
      expect(read('causticColor')[3], 1);
      expect(read('boundsMin'), [-1, -2, -3, 1]);
      expect(read('boundsMax'), [1, 2, 3, 0]);

      context.waterVolume!.waterlineLightTint = 0.3;
      RenderContext3D.writeWaterVolumeUniforms(context, block);
      expect(read('causticColor')[3], closeTo(0.3, 1e-6));
      context.waterVolume!.waterlineLightTint = 2;
      RenderContext3D.writeWaterVolumeUniforms(context, block);
      expect(read('causticColor')[3], 1);

      // An inactive volume is off.
      context.waterVolume = WaterVolumeSettings(absorption: 0);
      RenderContext3D.writeWaterVolumeUniforms(context, block);
      expect(read('deep')[3], 0);
    });
  });
}
