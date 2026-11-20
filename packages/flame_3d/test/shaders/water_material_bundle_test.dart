import 'dart:io';
import 'dart:typed_data';

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/shader_bundle_reflection.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, int> _vertexInputs(String bundle) {
  final bytes = File('assets/shaders/$bundle.shaderbundle').readAsBytesSync();
  final inputs = reflectShaderBundleInputs(ByteData.sublistView(bytes))!;
  return {
    for (final input in inputs['TextureVertex']!) input.name: input.components,
  };
}

void main() {
  final instanceInputs = {
    for (final a in VertexLayout.instanceAttributes) a.name: a.components,
  };

  group('WaterMaterial shader bundles', () {
    test('the masked variant reads WaterMaterial.vertexLayout', () {
      expect(_vertexInputs('water_material_masked'), {
        for (final a in WaterMaterial.vertexLayout.attributes)
          a.name: a.components,
        ...instanceInputs,
      });
    });

    test('the main variant reads only standard attributes', () {
      final standard = {
        for (final a in VertexLayout.standard.attributes) a.name: a.components,
        ...instanceInputs,
      };
      final inputs = _vertexInputs('water_material');
      expect(inputs.keys, isNot(contains(WaterMaterial.waterAttribute)));
      for (final MapEntry(:key, :value) in inputs.entries) {
        expect(standard[key], value, reason: key);
      }
    });
  });
}
