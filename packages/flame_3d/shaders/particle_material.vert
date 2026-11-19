#version 460 core

// One camera-facing quad per particle, drawn instanced, see
// <flame_3d/particle_vertex.glsl>.

in vec3 vertexPosition;
in vec2 vertexTexCoord;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/particle_vertex.glsl>

out vec2 fragTexCoord;
out vec2 fragNextTexCoord;
out vec2 fragCorner;
out vec4 fragColor;
out vec4 fragParams;
out vec4 fragClipPos;

void main() {
  vec3 worldPosition = particleCorner(vertexPosition.xy);
  gl_Position = camera.viewProjection * vec4(worldPosition, 1.0);

  vec4 texCoords = particleTexCoords(vertexTexCoord);
  fragTexCoord = texCoords.xy;
  fragNextTexCoord = texCoords.zw;
  fragCorner = vertexPosition.xy * 2.0;
  fragColor = instanceColor;
  fragParams = particleParams();
  fragClipPos = gl_Position;
}
