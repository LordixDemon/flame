import 'dart:io';
import 'dart:typed_data';

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/shader_bundle_reflection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

const _shaders = 'packages/flame_3d/assets/shaders';

ByteData _bundle(String name) {
  final bytes = File('assets/shaders/$name.shaderbundle').readAsBytesSync();
  return ByteData.sublistView(bytes);
}

void main() {
  group('OpenGL ES requirements of shader bundles', () {
    test('count uniform vectors, textures and extensions per stage', () {
      final water = reflectShaderBundleGlesRequirements(
        _bundle('water_material'),
      )!;
      final fragment = water['TextureFragment']!;
      expect(fragment.stage, GpuShaderStage.fragment);
      // StylizedPass 2176 + WaterMaterial 944 + 16 + 16 bytes.
      expect(fragment.uniformVectors, 197);
      expect(fragment.samplers, 3);
      expect(fragment.extensions, isEmpty);
      final vertex = water['TextureVertex']!;
      expect(vertex.stage, GpuShaderStage.vertex);
      // WaterVertex 48 + CameraMatrices 192 bytes, and the y flip float.
      expect(vertex.uniformVectors, 16);
      expect(vertex.samplers, 0);
    });

    test('read the extensions the source requires', () {
      final pbr = reflectShaderBundleGlesRequirements(
        _bundle('spatial_material_pbr'),
      )!;
      expect(pbr['TextureFragment']!.extensions, [
        'GL_OES_standard_derivatives',
        'GL_EXT_shader_texture_lod',
      ]);
      final simple = reflectShaderBundleGlesRequirements(
        _bundle('spatial_material'),
      )!;
      expect(simple['TextureFragment']!.extensions, [
        'GL_OES_standard_derivatives',
      ]);
    });

    test('count the joint matrices of skinned vertex stages', () {
      final skinned = reflectShaderBundleGlesRequirements(
        _bundle('stylized_material_skinned'),
      )!;
      expect(skinned['TextureVertex']!.uniformVectors, greaterThan(256));
    });

    test('are null for data that is not a shader bundle', () {
      expect(reflectShaderBundleGlesRequirements(ByteData(16)), isNull);
    });

    test('loose uniforms and required extensions are parsed from GLSL', () {
      const source = '''
#version 100
#extension GL_OES_standard_derivatives : require
#extension GL_EXT_frag_depth : enable
uniform float _impeller_y_flip;
uniform highp mat4 model;
uniform vec4 colors[3];
uniform sampler2D tex;
uniform Material _Material;
''';
      expect(looseUniformVectors(source), 1 + 4 + 3);
      expect(requiredExtensions(source), ['GL_OES_standard_derivatives']);
    });
  });

  group('shader support', () {
    const requirements = GpuShaderRequirements(
      stage: GpuShaderStage.fragment,
      uniformVectors: 200,
      samplers: 9,
      extensions: ['GL_EXT_shader_texture_lod'],
    );

    test('lists what the device lacks', () {
      const support = GpuShaderSupport(
        requirements: requirements,
        missingExtensions: ['GL_EXT_shader_texture_lod'],
        uniformVectorLimit: 128,
        samplerLimit: 8,
      );
      expect(support.isSupported, isFalse);
      expect(support.exceedsUniformVectors, isTrue);
      expect(support.exceedsSamplers, isTrue);
      const lacks =
          'needs the extension GL_EXT_shader_texture_lod, which the device '
          'lacks';
      const vectors =
          'uses 200 uniform vectors in its fragment stage, the device allows '
          '128';
      const textures =
          'samples 9 textures in its fragment stage, the device allows 8';
      expect(support.problems, [lacks, vectors, textures]);
    });

    test('is assumed without known limits', () {
      const support = GpuShaderSupport(requirements: requirements);
      expect(support.isSupported, isTrue);
      expect(support.problems, isEmpty);
    });

    test("compares a backend's requirements with its capabilities", () {
      final backend = FakeGpuBackend();
      expect(backend.shaderSupport('a', 'TextureFragment'), isNull);
      backend.fakeRequirements['a'] = {'TextureFragment': requirements};

      // Unknown limits and extensions: nothing is checked.
      expect(backend.shaderSupport('a', 'TextureFragment')!.isSupported, true);

      backend.fakeCapabilities = const GpuDeviceCapabilities(
        api: GpuGraphicsApi.openGLES,
        shaderExtensions: {'GL_EXT_shader_texture_lod'},
        shaderExtensionsKnown: true,
        maxFragmentUniformVectors: 224,
        maxFragmentSamplers: 16,
        maxVertexUniformVectors: 64,
      );
      expect(backend.shaderSupport('a', 'TextureFragment')!.isSupported, true);

      backend.fakeCapabilities = const GpuDeviceCapabilities(
        api: GpuGraphicsApi.openGLES,
        // Listed by the driver, but no shader can require it.
        extensions: {'GL_EXT_shader_texture_lod'},
        extensionsKnown: true,
        shaderExtensionsKnown: true,
        maxFragmentUniformVectors: 128,
      );
      final support = backend.shaderSupport('a', 'TextureFragment')!;
      expect(support.missingExtensions, ['GL_EXT_shader_texture_lod']);
      expect(support.uniformVectorLimit, 128);
      expect(support.isSupported, isFalse);
    });
  });

  group('materials', () {
    late FakeGpuBackend backend;

    setUp(() {
      backend = FakeGpuBackend()
        ..fakeCapabilities = const GpuDeviceCapabilities(
          api: GpuGraphicsApi.openGLES,
          renderer: 'Test GPU',
          shaderExtensions: {'GL_OES_standard_derivatives'},
          shaderExtensionsKnown: true,
          maxVertexUniformVectors: 512,
          maxFragmentUniformVectors: 224,
          maxVertexSamplers: 16,
          maxFragmentSamplers: 16,
        );
    });

    test('a material the device cannot run throws when it is created', () {
      backend.fakeRequirements['$_shaders/unlit_material.shaderbundle'] = {
        'TextureFragment': const GpuShaderRequirements(
          stage: GpuShaderStage.fragment,
          uniformVectors: 300,
          samplers: 1,
        ),
      };
      expect(
        UnlitMaterial.new,
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('UnlitMaterial'),
              contains('openGLES, Test GPU'),
              contains('unlit_material.shaderbundle'),
              contains(
                'uses 300 uniform vectors in its fragment stage, the '
                'device allows 224',
              ),
            ),
          ),
        ),
      );
    });

    test('a material the device can run is created', () {
      backend.fakeRequirements['$_shaders/unlit_material.shaderbundle'] = {
        'TextureFragment': const GpuShaderRequirements(
          stage: GpuShaderStage.fragment,
          uniformVectors: 1,
          samplers: 1,
        ),
      };
      expect(UnlitMaterial.new, returnsNormally);
    });

    test('SpatialMaterial falls back to its simple shader when the full '
        'one needs an extension the device lacks', () {
      expect(SpatialMaterial().usesSimpleShader, isFalse);

      backend.fakeRequirements
        ..['$_shaders/spatial_material_pbr.shaderbundle'] = {
          'TextureFragment': const GpuShaderRequirements(
            stage: GpuShaderStage.fragment,
            uniformVectors: 163,
            samplers: 11,
            extensions: [
              'GL_OES_standard_derivatives',
              'GL_EXT_shader_texture_lod',
            ],
          ),
        }
        ..['$_shaders/spatial_material.shaderbundle'] = {
          'TextureFragment': const GpuShaderRequirements(
            stage: GpuShaderStage.fragment,
            uniformVectors: 110,
            samplers: 7,
            extensions: ['GL_OES_standard_derivatives'],
          ),
        };
      final material = SpatialMaterial();
      expect(material.usesSimpleShader, isTrue);
      expect(
        material.fragmentShader.assetName,
        '$_shaders/spatial_material.shaderbundle',
      );
      expect(
        material.vertexShader.assetName,
        '$_shaders/spatial_material.shaderbundle',
      );
    });
  });

  test('capabilities are reported as JSON', () {
    const caps = GpuDeviceCapabilities(
      api: GpuGraphicsApi.openGLES,
      renderer: 'GPU',
      extensions: {'b', 'a'},
      extensionsKnown: true,
      maxFragmentUniformVectors: 224,
      halfFloatTextureTargets: true,
      floatTargetDetection: 'probe',
      notes: {'rgbaFloat16': 'ok'},
    );
    final json = caps.toJson();
    expect(json['api'], 'openGLES');
    expect(json['renderer'], 'GPU');
    expect(json['extensions'], ['a', 'b']);
    expect(json['maxFragmentUniformVectors'], 224);
    expect(json['halfFloatTextureTargets'], isTrue);
    expect(json['floatTextureTargets'], isFalse);
    expect(json['floatTargetDetection'], 'probe');
    expect(json['notes'], {'rgbaFloat16': 'ok'});
    expect(caps.hasExtension('a'), isTrue);
    expect(GpuDeviceCapabilities.unknown.api, GpuGraphicsApi.unknown);
  });
}
