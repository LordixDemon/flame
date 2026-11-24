#version 460 core

#define FLAME_RIGID_BATCH_TRANSFORMS_ONLY

in vec3 vertexPosition;
in vec3 vertexNormal;

#include <flame_3d/camera.glsl>
#include <flame_3d/rigid_batch.glsl>

out vec3 fragWorldNormal;

void main() {
  int id = int(vertexObjectId + 0.5);
  mat4 model = batchObjectModelMatrix(id);
  vec4 worldPosition = model * vec4(vertexPosition, 1.0);
  gl_Position = camera.viewProjection * worldPosition;
  fragWorldNormal = normalize(mat3(model) * vertexNormal);
}
