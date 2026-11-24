#version 460 core

#define FLAME_RIGID_BATCH_TRANSFORMS_ONLY

in vec3 vertexPosition;

#include <flame_3d/camera.glsl>
#define FLAME_RIGID_BATCH_MAX_OBJECTS 8
#include <flame_3d/rigid_batch.glsl>
#include <flame_3d/skinning.glsl>

out vec4 fragClipPosition;

void main() {
  int id = int(vertexObjectId + 0.5);
  vec4 localPosition = computeSkinMatrix() * vec4(vertexPosition, 1.0);
  vec4 worldPosition = batchObjectModelMatrix(id) * vec4(localPosition.xyz, 1.0);
  gl_Position = camera.viewProjection * worldPosition;
  fragClipPosition = gl_Position;
}
