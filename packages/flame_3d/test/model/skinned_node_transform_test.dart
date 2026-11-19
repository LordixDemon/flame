import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

/// A material with faked shaders that declares the joint matrices block.
class _SkinnedTestMaterial() extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          'test',
          slots: [
            RenderContext3D.cameraMatricesBlock,
            RenderContext3D.jointMatricesBlock,
          ],
        ),
        fragmentShader: FragmentShader.fromAsset('test', slots: ['Material']),
      );

  @override
  void apply(RenderContext context) {}
}

/// An armature node with a non-identity transform, a bone and a skinned mesh
/// node as its children, as Blender and Mixamo exports have them.
///
/// The inverse bind matrix of the bone is `inverse(boneBind) * meshBind`,
/// which is the identity here, so glTF places every vertex at
/// `armature * vertex`.
Model _armatureModel(Matrix4 armature, {List<ModelAnimation>? animations}) {
  final surface = Surface(
    vertices: [
      Vertex(
        position: Vector3(1, 0, 0),
        texCoord: Vector2.zero(),
        joints: Vector4.zero(),
        weights: Vector4(1, 0, 0, 0),
      ),
      Vertex(
        position: Vector3(0, 1, 0),
        texCoord: Vector2.zero(),
        joints: Vector4.zero(),
        weights: Vector4(1, 0, 0, 0),
      ),
      Vertex(
        position: Vector3(0, 0, 1),
        texCoord: Vector2.zero(),
        joints: Vector4.zero(),
        weights: Vector4(1, 0, 0, 0),
      ),
    ],
    indices: [0, 1, 2],
    material: _SkinnedTestMaterial(),
    jointMap: {0: 0},
  );
  return Model(
    nodes: {
      0: ModelNode(
        name: 'Armature',
        nodeIndex: 0,
        parentNodeIndex: null,
        transform: armature,
        mesh: null,
        joints: {},
      ),
      1: ModelNode(
        name: 'Bone',
        nodeIndex: 1,
        parentNodeIndex: 0,
        transform: Matrix4.identity(),
        mesh: null,
        joints: {},
      ),
      2: ModelNode(
        name: 'Body',
        nodeIndex: 2,
        parentNodeIndex: 0,
        transform: Matrix4.identity(),
        mesh: Mesh()..addSurface(surface),
        joints: {
          0: ModelJoint(nodeIndex: 1, inverseBindMatrix: Matrix4.identity()),
        },
      ),
    },
    animations: animations ?? const [],
  );
}

final Matrix4 _armature = Matrix4.compose(
  Vector3(10, 0, 0),
  Quaternion.axisAngle(Vector3(0, 0, 1), 1.0),
  Vector3.all(2),
);

/// Where glTF puts [vertex]: `boneCombined * inverseBind * vertex`.
Vector3 _expected(Vector3 vertex) => _armature.transformed3(vertex);

/// What a renderer computes: `world * nodeCombined * joint * vertex`.
Vector3 _rendered(Matrix4 nodeCombined, Matrix4 joint, Vector3 vertex) {
  return (nodeCombined.clone()..multiply(joint)).transformed3(vertex);
}

void main() {
  group('skinned mesh under a transformed node', () {
    test('Model.evaluateInto ignores the transform of the mesh node', () {
      final model = _armatureModel(_armature);
      final workspace = ModelPoseWorkspace.forModel(model);
      model.evaluateInto(AnimationState(), workspace);

      final body = workspace.nodesByIndex[2]!;
      final joint = body.jointTransforms[0]![0];
      for (final v in [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]) {
        final got = _rendered(body.combinedTransform, joint, v);
        expect(got.distanceTo(_expected(v)), lessThan(1e-4), reason: '$v');
      }
    });

    test('Model.processNodes matches evaluateInto', () {
      final model = _armatureModel(_armature);
      final processed = model.processNodes(AnimationState());
      final body = processed[2]!;
      final v = Vector3(1, 0, 0);
      final got = _rendered(
        body.combinedTransform,
        body.jointTransforms[0]![0],
        v,
      );
      expect(got.distanceTo(_expected(v)), lessThan(1e-4));
    });

    test('ModelComponent draws the skinned vertex where glTF puts it', () {
      final backend = FakeGpuBackend();
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device);
      final model = _armatureModel(_armature);
      final component = ModelComponent(
        model: model,
        position: Vector3(0, 5, -20),
      );

      device.begin();
      context.setCamera(
        Matrix4.identity(),
        Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
      );
      device.beginPass(const Size(16, 16), frontFace: context.frontFace);
      component.draw(context);
      context.flush();
      device
        ..endPass()
        ..end();

      final instance = Matrix4.fromFloat32List(
        backend.instancesOf(0).first.sublist(0, 16),
      );
      final shader = model.nodes[2]!.mesh!.surfaces.first.material.vertexShader;
      final base =
          shader
              .slot(RenderContext3D.jointMatricesBlock)
              .getMemberOffsetInBytes('joints')! ~/
          4;
      final jointData = backend.uniforms[RenderContext3D.jointMatricesBlock]!;
      final joint = Matrix4.fromFloat32List(
        jointData.sublist(base, base + 16),
      );

      final v = Vector3(1, 0, 0);
      final got = _rendered(instance, joint, v);
      final want = _expected(v)..add(Vector3(0, 5, -20));
      expect(got.distanceTo(want), lessThan(1e-4));
    });

    test('Model.animatedAabb bounds the skinned pose once', () {
      final idle = ModelAnimation(
        name: 'idle',
        nodes: {
          1: NodeAnimation(
            channels: [
              AnimationController(
                animation: TranslationAnimationSpline.from(
                  interpolation: AnimationInterpolation.linear,
                  times: [0, 1],
                  values: [Vector3.zero(), Vector3.zero()],
                ),
              ),
            ],
          ),
        },
      );
      final model = _armatureModel(_armature, animations: [idle]);
      final box = model.animatedAabb;
      final skinned = [
        for (final v in [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)])
          _expected(v),
      ];
      // The joint expansion transforms the surface's bounds, so the box may be
      // larger than the triangle, but never as far as the doubled transform.
      final padded = Aabb3.copy(box)
        ..min.sub(Vector3.all(1e-4))
        ..max.add(Vector3.all(1e-4));
      for (final p in skinned) {
        expect(padded.containsVector3(p), isTrue, reason: '$p');
      }
      expect(box.max.x, lessThan(13));
    });
  });
}
