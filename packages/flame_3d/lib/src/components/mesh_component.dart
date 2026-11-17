import 'dart:ui';

import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
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

  /// The per-instance color of this component, available to the material's
  /// shaders (the built-in materials multiply their base color by it).
  var Color color = const Color(0xFFFFFFFF),

  /// The initial value of [instanceData], zero when `null`.
  Vector4? instanceData,
}) extends Object3D {
  /// The mesh resource.
  Mesh get mesh => _mesh;

  /// Four floats of per-instance data, zero by default, that reach the
  /// material's vertex shader as `instanceData` (see
  /// `shaders/flame_3d/instancing.glsl`).
  ///
  /// What they mean is up to the material: see [StylizedMaterial] for the
  /// built-in material that reads them. They may be changed at any time; the
  /// values at the time the component is drawn are used.
  final Vector4 instanceData = instanceData?.clone() ?? Vector4.zero();

  @override
  Aabb3? computeLocalAabb() => mesh.aabb;

  @override
  void draw(covariant RenderContext3D context) {
    context.drawMesh(
      mesh,
      transform: worldTransformMatrix,
      color: color,
      instanceData: instanceData,
    );
  }
}
