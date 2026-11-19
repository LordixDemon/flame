#version 460 core

// The opaque particles of `ParticleMaterial` in the depth-normal prepass,
// placed as in particle_material.vert.

in vec3 vertexPosition;
in vec2 vertexTexCoord;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/particle_vertex.glsl>

out vec3 fragViewPos;
out vec2 fragTexCoord;
out vec2 fragNextTexCoord;
out vec2 fragCorner;
out vec4 fragColor;
out vec4 fragParams;

void main() {
  vec4 viewPos =
      camera.view * vec4(particleCorner(vertexPosition.xy), 1.0);
  gl_Position = camera.projection * viewPos;
  fragViewPos = viewPos.xyz;

  vec4 texCoords = particleTexCoords(vertexTexCoord);
  fragTexCoord = texCoords.xy;
  fragNextTexCoord = texCoords.zw;
  fragCorner = vertexPosition.xy * 2.0;
  fragColor = instanceColor;
  fragParams = particleParams();
}
