#version 460 core

in vec3 vertexPosition;
in vec3 vertexNormal;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

out vec3 fragWorldNormal;

void main() {
  mat4 model = instanceModelMatrix();
  vec4 worldPosition = model * vec4(vertexPosition, 1.0);
  gl_Position = camera.viewProjection * worldPosition;
  fragWorldNormal = normalize(mat3(model) * vertexNormal);
}
