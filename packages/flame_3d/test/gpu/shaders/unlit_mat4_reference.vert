#version 460 core

// unlit_material.vert with the whole joint matrices of before, see
// reference/skinning_mat4.glsl.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;
in vec3 vertexNormal;

#include <reference/skinning_mat4.glsl>
#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

out vec2 fragTexCoord;
out vec4 fragColor;
out vec3 fragPosition;
out vec3 fragNormal;
out vec4 fragInstanceColor;

void main() {
  mat4 skinMatrix = computeSkinMatrix();
  vec3 position = (skinMatrix * vec4(vertexPosition, 1.0)).xyz;
  vec3 normal = normalize((skinMatrix * vec4(vertexNormal, 0.0)).xyz);

  mat4 model = instanceModelMatrix();
  vec4 worldPosition = model * vec4(position, 1.0);
  gl_Position = camera.viewProjection * worldPosition;

  fragTexCoord = vertexTexCoord;
  fragColor = vertexColor;
  fragPosition = worldPosition.xyz;
  fragNormal = mat3(transpose(inverse(model))) * normal;
  fragInstanceColor = instanceColor;
}
