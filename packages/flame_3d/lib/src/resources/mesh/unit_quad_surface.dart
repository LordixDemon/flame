import 'dart:typed_data';

import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/backend.dart';
import 'package:meta/meta.dart';

/// Vertex layout shared by unit quad billboarding, decal, and particle
/// surfaces (`vertexPosition: 3`, `vertexTexCoord: 2`).
@internal
final VertexLayout unitQuadVertexLayout = VertexLayout(const [
  VertexAttribute(VertexLayout.positionAttribute, 3),
  VertexAttribute('vertexTexCoord', 2),
]);

/// Shared unit XY quad (`[-0.5, 0.5]^2`) with downward-growing texture V
/// coordinates used by `BillboardBatch3D`, `DecalBatch3D`, and
/// `ParticleSystem3D`.
@internal
final Surface unitQuadSurface3D = Surface.fromBuffers(
  vertices: Float32List.fromList(const [
    -0.5, -0.5, 0.0, 0.0, 1.0, //
    0.5, -0.5, 0.0, 1.0, 1.0, //
    0.5, 0.5, 0.0, 1.0, 0.0, //
    -0.5, 0.5, 0.0, 0.0, 0.0, //
  ]),
  indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
  layout: unitQuadVertexLayout,
);
