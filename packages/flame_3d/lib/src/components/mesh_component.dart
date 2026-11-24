import 'dart:ui';

import 'package:flame_3d/camera.dart' show RayHit3D, World3D;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// {@template mesh_component}
/// An [Object3D] that renders a [Mesh] at the [position] with the [rotation]
/// and [scale] applied.
///
/// This is a commonly used subclass of [Object3D]. Components sharing one
/// [Mesh] (and so its surfaces and materials) are drawn with a single
/// instanced draw per surface, whatever their [color] and [instanceData].
/// {@endtemplate}
class MeshComponent({
  required final Mesh _mesh,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.castsShadows,
  super.depthLayer,
  super.cameraMask,

  Color color = const Color(0xFFFFFFFF),

  /// The initial value of [instanceData], zero when `null`.
  Vector4? instanceData,
  Map<int, List<Matrix4>>? jointTransforms,
}) extends Object3D {
  /// {@macro mesh_component}
  this {
    this.instanceData.addListener(_onInstanceDataChanged);
  }

  /// The mesh resource.
  Mesh get mesh => _mesh;

  /// The per-instance color of this component, available to the material's
  /// shaders (the built-in materials multiply their base color by it).
  ///
  /// Changing it marks the enclosing [World3D] dirty.
  Color get color => _color;
  set color(Color value) {
    if (value == _color) {
      return;
    }
    _color = value;
    markDrawDirty(shadows: false);
  }

  Color _color = color;

  /// Four floats of per-instance data, zero by default, that reach the
  /// material's vertex shader as `instanceData` (see
  /// `shaders/flame_3d/instancing.glsl`).
  ///
  /// What they mean is up to the material: see [StylizedMaterial] for the
  /// built-in material that reads them. They may be changed at any time,
  /// in place; the values at the time the component is drawn are used, and
  /// every change marks the enclosing [World3D] dirty.
  final NotifyingVector4 instanceData = NotifyingVector4.zero()
    ..setFrom(instanceData ?? Vector4.zero());

  void _onInstanceDataChanged() => markDrawDirty(shadows: false);

  /// The joint matrices of the mesh's skinned surfaces, by surface index: a
  /// [StylizedMaterial] surface built with joints and weights, or a skinned
  /// surface of a model. `null` (the default) draws every surface unskinned.
  ///
  /// The matrices are read when the component is drawn, so they can be
  /// updated in place every frame to animate the mesh; the engine cannot see
  /// such writes, so call [markDrawDirty] after them (assigning a new map
  /// marks the world dirty by itself). Without that, a
  /// `Scene3DCacheMode.retained` layer and a cached static shadow map keep
  /// the previous pose. The component's bounds are the mesh's: give the
  /// surfaces bounds that hold every pose (see [StylizedMaterial.buildSurface])
  /// for culling to stay right.
  Map<int, List<Matrix4>>? get jointTransforms => _jointTransforms;
  set jointTransforms(Map<int, List<Matrix4>>? value) {
    if (identical(value, _jointTransforms)) {
      return;
    }
    _jointTransforms = value;
    markDrawDirty(shadows: castsShadows);
  }

  Map<int, List<Matrix4>>? _jointTransforms = jointTransforms;

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == MeshComponent;

  @override
  Aabb3? computeLocalAabb() => mesh.aabb;

  @override
  void draw(covariant RenderContext3D context) {
    context.drawMesh(
      mesh,
      transform: worldTransformMatrix,
      color: color,
      instanceData: instanceData,
      jointTransforms: jointTransforms,
      mirrored: hasNegativeScale,
    );
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    return RayHit3D.intersectMesh(
      owner: this,
      mesh: mesh,
      modelMatrix: worldTransformMatrix,
      worldRay: worldRay,
      maxDistance: maxDistance,
      cullMode: cullMode,
    );
  }

  @override
  void visitCollisionMeshes(
    bool Function(Mesh mesh, Matrix4 worldMatrix) visitor,
  ) {
    visitor(mesh, worldTransformMatrix);
  }

  @override
  Component3D cloneSelf() {
    if (runtimeType != MeshComponent) {
      return super.cloneSelf();
    }
    return MeshComponent(
      mesh: mesh,
      castsShadows: castsShadows,
      color: color,
      instanceData: instanceData.clone(),
      jointTransforms: jointTransforms == null
          ? null
          : {
              for (final entry in jointTransforms!.entries)
                entry.key: [for (final m in entry.value) m.clone()],
            },
    );
  }
}
