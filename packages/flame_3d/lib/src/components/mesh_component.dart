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
/// instanced draw per surface.
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
}) extends Object3D {
  /// The mesh resource.
  Mesh get mesh => _mesh;
  @override
  Aabb3? computeLocalAabb() => mesh.aabb;

  @override
  void draw(covariant RenderContext3D context) {
    context.drawMesh(mesh, transform: worldTransformMatrix, color: color);
  }
}
