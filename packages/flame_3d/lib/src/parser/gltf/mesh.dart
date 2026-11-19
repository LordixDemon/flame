import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart' as flame_3d;
import 'package:flame_3d/src/parser/gltf/gltf_node.dart';
import 'package:flame_3d/src/parser/gltf/gltf_root.dart';
import 'package:flame_3d/src/parser/gltf/gltf_warnings.dart';
import 'package:flame_3d/src/parser/gltf/primitive.dart';

/// A set of primitives to be rendered.
class Mesh({
  required super.root,
  required final List<Primitive> primitives,
  required final List<double>? weights,
}) extends GltfNode {
  Mesh.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        primitives:
            Parser.objectList(root, map, 'primitives', Primitive.parse) ?? [],
        weights: Parser.floatList(map, 'weights'),
      );

  /// Builds the surfaces of every drawable primitive (points and lines are
  /// skipped and reported, see [GltfWarnings]) and applies the morph
  /// [weights] of the node that instantiates the mesh, or the mesh's own
  /// [weights] when `null`.
  flame_3d.Mesh toFlameMesh([
    Matrix4? transform,
    List<double>? nodeWeights,
  ]) {
    final mesh = flame_3d.Mesh();
    final initialWeights = nodeWeights ?? weights;
    for (final primitive in primitives) {
      if (!primitive.isTriangles) {
        GltfWarnings.report(
          'primitives of mode ${primitive.mode.name} are skipped: only '
          'triangles, triangle strips and triangle fans can be drawn',
        );
        continue;
      }
      for (final surface in primitive.toFlameSurfaces(transform)) {
        if (initialWeights != null && initialWeights.isNotEmpty) {
          surface.applyMorphWeights(initialWeights);
        }
        mesh.addSurface(surface);
      }
    }
    return mesh;
  }
}
