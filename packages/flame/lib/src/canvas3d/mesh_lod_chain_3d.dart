import 'dart:math' as math;

import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';

/// Single entry in a [MeshLodChain3D] pairing a [mesh] with the minimum
/// projected screen diameter (`minScreenPixels`) required to use it.
class const MeshLodLevel3D({
  required final Mesh3D mesh,
  required final double minScreenPixels,
});

/// Progressive 3D mesh Level-of-Detail chain for `BatchMeshRenderer3D`.
class MeshLodChain3D({
  required final List<MeshLodLevel3D> levels,
  final double cullBelowPixels = 2.0,
}) {
  this : assert(levels.isNotEmpty, 'levels must not be empty');

  /// Builds a standard 1–3 tier progressive LOD chain ordered from highest to
  /// lowest detail.
  factory MeshLodChain3D.progressive({
    required Mesh3D high,
    Mesh3D? medium,
    Mesh3D? low,
    double highMinPixels = 64.0,
    double mediumMinPixels = 24.0,
    double cullBelowPixels = 2.0,
  }) {
    final built = <MeshLodLevel3D>[
      MeshLodLevel3D(
        mesh: high,
        minScreenPixels: medium != null || low != null
            ? highMinPixels
            : cullBelowPixels,
      ),
      if (medium != null)
        MeshLodLevel3D(
          mesh: medium,
          minScreenPixels: low != null ? mediumMinPixels : cullBelowPixels,
        ),
      if (low != null)
        MeshLodLevel3D(
          mesh: low,
          minScreenPixels: cullBelowPixels,
        ),
    ];
    return MeshLodChain3D(levels: built, cullBelowPixels: cullBelowPixels);
  }

  /// Highest-detail mesh (`levels.first.mesh`).
  Mesh3D get highMesh => levels.first.mesh;

  /// Estimates projected screen diameter in pixels and returns the matching
  /// [Mesh3D], or `null` when projected diameter falls below [cullBelowPixels].
  Mesh3D? selectMesh({
    required CameraRig3D camera,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double scaleZ = 1.0,
    double lodBias = 0.0,
  }) {
    final maxScale = math.max(
      scaleX.abs(),
      math.max(scaleY.abs(), scaleZ.abs()),
    );
    final baseRadius = levels.first.mesh.boundingRadius * maxScale;
    final biasFactor = lodBias == 0.0
        ? 1.0
        : math.pow(2.0, lodBias * 0.5).toDouble();
    final projectedDiameterPx =
        2.0 * baseRadius * camera.focalScalePx * camera.camZoom * biasFactor;

    if (projectedDiameterPx < cullBelowPixels) {
      return null;
    }
    for (var i = 0; i < levels.length; i++) {
      if (projectedDiameterPx >= levels[i].minScreenPixels) {
        return levels[i].mesh;
      }
    }
    return levels.last.mesh;
  }
}
