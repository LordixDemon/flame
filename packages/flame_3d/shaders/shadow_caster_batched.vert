#version 460 core

#define FLAME_RIGID_BATCH_TRANSFORMS_ONLY

in vec3 vertexPosition;

#include <flame_3d/camera.glsl>
#include <flame_3d/rigid_batch.glsl>

out vec2 fragClipDepth;

void main() {
  int id = int(vertexObjectId + 0.5);
  vec4 worldPosition = batchObjectModelMatrix(id) * vec4(vertexPosition, 1.0);
  gl_Position = camera.viewProjection * worldPosition;
  fragClipDepth = gl_Position.zw;
}
