import 'dart:ui' show Color;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/scene.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

class _PlainMeshSubclass({required super.mesh}) extends MeshComponent;

class _MeshSubclassWithState({required super.mesh, required final int code})
    extends MeshComponent {
  @override
  Component3D cloneSelf() => _MeshSubclassWithState(mesh: mesh, code: code);
}

Model _model() {
  return Model(
    nodes: {
      0: ModelNode(
        name: 'Body',
        nodeIndex: 0,
        parentNodeIndex: null,
        transform: Matrix4.identity(),
        mesh: CuboidMesh(size: Vector3.all(1)),
        joints: {},
      ),
    },
    animations: [],
  );
}

void main() {
  setUp(FakeGpuBackend.new);

  group('Component3D.clone and prototype prefabs', () {
    test('InstancedGroup3D copies the colors and data of its instances', () {
      final group = InstancedGroup3D(mesh: CuboidMesh(size: Vector3.all(1)))
        ..addInstance(
          transform: Matrix4.translationValues(1, 2, 3),
          color: const Color(0xFF204060),
          instanceData: Vector4(0.1, 0.2, 0.3, 0.4),
        )
        ..addInstance(
          transform: Matrix4.translationValues(-1, 0, 0),
          color: const Color(0x80FF0000),
          instanceData: Vector4(1, 0, 0, 1),
        );
      final copy = group.clone() as InstancedGroup3D;
      expect(copy.length, 2);
      for (var i = 0; i < 2; i++) {
        expect(copy.instanceTransform(i), group.instanceTransform(i));
        expect(copy.instanceColor(i), group.instanceColor(i));
        expect(copy.instanceDataAt(i), group.instanceDataAt(i));
      }
    });

    test('a point light keeps its shadows and cascade settings', () {
      final light = LightComponent(
        source: PointLight(
          color: const Color(0xFFFFFFFF),
          intensity: 2,
          shadows: ShadowSettings(
            resolution: 256,
            cascadeSplits: [0.2],
            cascadeBlendRange: 0.3,
          ),
        ),
      );
      final copy = (light.clone() as LightComponent).source as PointLight;
      expect(copy.shadows, isNotNull);
      expect(copy.shadows, isNot(same((light.source as PointLight).shadows)));
      expect(copy.shadows!.resolution, 256);
      expect(copy.shadows!.cascadeSplits, [0.2]);
      expect(copy.shadows!.cascadeBlendRange, closeTo(0.3, 1e-9));
    });

    test('a ModelComponent prototype clones into ModelComponents', () {
      final model = _model();
      final registry = PrefabRegistry3D()
        ..registerPrototype(
          'statue',
          ModelComponent(
            model: model,
            color: const Color(0xFF808080),
            instanceData: Vector4(1, 2, 3, 4),
            castsShadows: false,
          ),
        );
      final instance = registry.instantiate('statue');
      expect(instance, isA<ModelComponent>());
      instance as ModelComponent;
      expect(instance.model, same(model));
      expect(instance.color, const Color(0xFF808080));
      expect(instance.instanceData, Vector4(1, 2, 3, 4));
      expect(instance.castsShadows, isFalse);
    });

    test('a ModelComponent bound to bone modifiers refuses to clone', () {
      final model = ModelComponent(model: _model())
        ..boneModifiers.add(_NoopModifier());
      expect(model.clone, throwsUnsupportedError);
    });

    test('types without a copy refuse to clone instead of becoming groups', () {
      final particles = ParticleSystem3D(material: ParticleMaterial());
      expect(
        () => PrefabRegistry3D().registerPrototype('sparks', particles),
        throwsUnsupportedError,
      );
      expect(FoliageSystem3D(capacity: 4).clone, throwsUnsupportedError);
      final mesh = CuboidMesh(size: Vector3.all(1));
      expect(_PlainMeshSubclass(mesh: mesh).clone, throwsUnsupportedError);
      expect(
        _MeshSubclassWithState(mesh: mesh, code: 7).clone(),
        isA<_MeshSubclassWithState>(),
      );
      // Children that cannot be cloned make the whole clone fail.
      expect(
        Group3D(children: [particles]).clone,
        throwsUnsupportedError,
      );
    });
  });
}

class _NoopModifier() extends BoneModifier3D {
  @override
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  ) {}
}
