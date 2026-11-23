import 'package:meta/meta.dart';

/// {@template render_stats}
/// Counters of the GPU work recorded during one frame.
///
/// A `GraphicsDevice` resets its live counters when a frame begins and copies
/// them into its last-frame statistics when the frame ends, so the statistics
/// of the last complete frame can be read at any time (for example from a
/// game's `renderStats`).
/// {@endtemplate}
class RenderStats() {
  /// The number of render passes.
  int renderPasses = 0;

  /// The number of draw calls issued to the GPU (an instanced draw counts
  /// once).
  int drawCalls = 0;

  /// The number of instances drawn, summed over all draw calls.
  int instances = 0;

  /// The number of triangles drawn, summed over all instances.
  int triangles = 0;

  /// The number of times a different pipeline was bound.
  int pipelineChanges = 0;

  /// The number of render state changes applied: each change of the blend
  /// state, the depth state, the cull mode, the winding order, the stencil
  /// state, the polygon mode or the primitive topology counts once, and so
  /// does each viewport and scissor set.
  int stateChanges = 0;

  /// The number of times the bound material changed.
  int materialChanges = 0;

  /// The number of uniform blocks uploaded to the GPU.
  int uniformUploads = 0;

  /// The number of bytes of uniform and instance data uploaded.
  int uploadedBytes = 0;

  /// The number of particles drawn by particle systems (a mesh particle
  /// counts once, however many surfaces its mesh has).
  int particles = 0;

  /// The number of the [renderPasses] that rendered a shadow map.
  int shadowPasses = 0;

  /// The number of the [drawCalls] issued by the passes that rendered a
  /// shadow map.
  int shadowDrawCalls = 0;

  /// The number of the [triangles] drawn by the passes that rendered a
  /// shadow map.
  int shadowTriangles = 0;

  /// The number of shadow maps or atlas tiles whose kept layer of still
  /// casters (`ShadowSettings.cacheStillCasters`) was reused: copied under
  /// the moving casters, or reused with the whole map.
  int shadowLayersReused = 0;

  /// The number of shadow maps or atlas tiles whose kept layer of still
  /// casters was rendered again.
  int shadowLayersRendered = 0;

  /// The number of draw calls the reused layers and maps hold: what
  /// rendering them again would have issued (the casters were not drawn
  /// again).
  int shadowReusedDrawCalls = 0;

  /// The number of triangles the reused layers and maps hold, see
  /// [shadowReusedDrawCalls].
  int shadowReusedTriangles = 0;

  /// The number of materials whose values changed, through their setters
  /// (or `Material.markChanged`), since the world drew them last: the
  /// changes a render shows besides animations. A world counts them each
  /// time it renders; a retained layer that renders again because of them
  /// shows them in its `Scene3DComponent.renderStats`.
  ///
  /// Not to be confused with [materialChanges], the number of times the
  /// bound material changed.
  int updatedMaterials = 0;

  /// The number of the materials a render drew that animate: those whose
  /// animation time (`WaterMaterial.time`, `BarrierMaterial.time`,
  /// `StylizedMaterial.windTime`, ...) advanced, and nothing else, since the
  /// world drew them last, and those marked `Material.animated`.
  ///
  /// A retained layer whose stats show animated materials on every frame
  /// renders every frame because of them: move them to a layer of their own
  /// for the rest of the scene to keep its image, or stop advancing their
  /// time while they should hold still.
  int animatedMaterials = 0;

  /// Resets every counter to zero.
  void reset() {
    renderPasses = 0;
    drawCalls = 0;
    instances = 0;
    triangles = 0;
    pipelineChanges = 0;
    stateChanges = 0;
    materialChanges = 0;
    uniformUploads = 0;
    uploadedBytes = 0;
    particles = 0;
    shadowPasses = 0;
    shadowDrawCalls = 0;
    shadowTriangles = 0;
    shadowLayersReused = 0;
    shadowLayersRendered = 0;
    shadowReusedDrawCalls = 0;
    shadowReusedTriangles = 0;
    updatedMaterials = 0;
    animatedMaterials = 0;
  }

  /// Copies every counter from [other].
  void setFrom(RenderStats other) {
    renderPasses = other.renderPasses;
    drawCalls = other.drawCalls;
    instances = other.instances;
    triangles = other.triangles;
    pipelineChanges = other.pipelineChanges;
    stateChanges = other.stateChanges;
    materialChanges = other.materialChanges;
    uniformUploads = other.uniformUploads;
    uploadedBytes = other.uploadedBytes;
    particles = other.particles;
    shadowPasses = other.shadowPasses;
    shadowDrawCalls = other.shadowDrawCalls;
    shadowTriangles = other.shadowTriangles;
    shadowLayersReused = other.shadowLayersReused;
    shadowLayersRendered = other.shadowLayersRendered;
    shadowReusedDrawCalls = other.shadowReusedDrawCalls;
    shadowReusedTriangles = other.shadowReusedTriangles;
    updatedMaterials = other.updatedMaterials;
    animatedMaterials = other.animatedMaterials;
  }

  /// Stores `after - before` for every counter into `this`.
  @internal
  void setDifference(RenderStats after, RenderStats before) {
    renderPasses = after.renderPasses - before.renderPasses;
    drawCalls = after.drawCalls - before.drawCalls;
    instances = after.instances - before.instances;
    triangles = after.triangles - before.triangles;
    pipelineChanges = after.pipelineChanges - before.pipelineChanges;
    stateChanges = after.stateChanges - before.stateChanges;
    materialChanges = after.materialChanges - before.materialChanges;
    uniformUploads = after.uniformUploads - before.uniformUploads;
    uploadedBytes = after.uploadedBytes - before.uploadedBytes;
    particles = after.particles - before.particles;
    shadowPasses = after.shadowPasses - before.shadowPasses;
    shadowDrawCalls = after.shadowDrawCalls - before.shadowDrawCalls;
    shadowTriangles = after.shadowTriangles - before.shadowTriangles;
    shadowLayersReused = after.shadowLayersReused - before.shadowLayersReused;
    shadowLayersRendered =
        after.shadowLayersRendered - before.shadowLayersRendered;
    shadowReusedDrawCalls =
        after.shadowReusedDrawCalls - before.shadowReusedDrawCalls;
    shadowReusedTriangles =
        after.shadowReusedTriangles - before.shadowReusedTriangles;
    updatedMaterials = after.updatedMaterials - before.updatedMaterials;
    animatedMaterials = after.animatedMaterials - before.animatedMaterials;
  }

  @override
  String toString() {
    return 'RenderStats(passes: $renderPasses, drawCalls: $drawCalls, '
        'instances: $instances, triangles: $triangles, '
        'pipelineChanges: $pipelineChanges, stateChanges: $stateChanges, '
        'materialChanges: $materialChanges, uniformUploads: $uniformUploads, '
        'uploadedBytes: $uploadedBytes, particles: $particles, '
        'shadowPasses: $shadowPasses, shadowDrawCalls: $shadowDrawCalls, '
        'shadowTriangles: $shadowTriangles, '
        'shadowLayersReused: $shadowLayersReused, '
        'shadowLayersRendered: $shadowLayersRendered, '
        'shadowReusedDrawCalls: $shadowReusedDrawCalls, '
        'shadowReusedTriangles: $shadowReusedTriangles, '
        'updatedMaterials: $updatedMaterials, '
        'animatedMaterials: $animatedMaterials)';
  }
}
