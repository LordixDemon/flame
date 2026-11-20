#version 460 core

// A custom lit material: a world position and a normal for its fragment
// stage, see light_grid_custom.frag.

in vec3 vertexPosition;
in vec3 vertexNormal;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

out vec3 fragPosition;
out vec3 fragNormal;

void main() {
  mat4 model = instanceModelMatrix();
  vec4 worldPosition = model * vec4(vertexPosition, 1.0);
  fragPosition = worldPosition.xyz;
  fragNormal = mat3(model) * vertexNormal;
  gl_Position = camera.viewProjection * worldPosition;
}
