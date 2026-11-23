import 'package:vector_math/vector_math.dart' show Aabb3, Matrix4;

/// Software or portal occlusion culler queried by `World3D` and `Object3D`
/// during main-pass traversal.
abstract interface class SceneOcclusionCuller3D() {
  /// Whether any occluders are currently registered.
  bool get hasOccluders;

  /// Number of occluders rasterized during the last [rasterizeOccluders]
  /// pass.
  int get rasterizedOccluderCount;

  /// Clears depth and rasterizes registered occluders for [viewProjection].
  void rasterizeOccluders(Matrix4 viewProjection);

  /// Returns `true` when any corner of [worldAabb] may be visible under
  /// [viewProjection].
  bool isAabbVisible(Aabb3 worldAabb, Matrix4 viewProjection);
}
