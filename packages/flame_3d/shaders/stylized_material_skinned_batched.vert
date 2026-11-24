#version 460 core

#include <flame_3d/stylized_material_vertex_core.glsl>
#define FLAME_RIGID_BATCH_MAX_OBJECTS 8
#include <flame_3d/rigid_batch.glsl>
#include <flame_3d/skinning.glsl>

void main() {
  int id = int(vertexObjectId + 0.5);
  mat4 skin = computeSkinMatrix();
  emitStylizedVertexCore(
    (skin * vec4(vertexPosition, 1.0)).xyz,
    (skin * vec4(vertexNormal, 0.0)).xyz,
    batchObjectModelMatrix(id),
    batchObjects.colors[id],
    batchObjects.data[id]
  );
}
