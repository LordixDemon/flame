#version 460 core

#include <flame_3d/stylized_material_vertex_core.glsl>
#include <flame_3d/rigid_batch.glsl>

void main() {
  int id = int(vertexObjectId + 0.5);
  emitStylizedVertexCore(
    vertexPosition,
    vertexNormal,
    batchObjectModelMatrix(id),
    batchObjects.colors[id],
    batchObjects.data[id]
  );
}
