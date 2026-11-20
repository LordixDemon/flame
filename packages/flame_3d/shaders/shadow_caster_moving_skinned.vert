#version 460 core

// shadow_caster_moving.vert for surfaces whose vertices have joints and joint
// weights: they are skinned first, as shadow_caster_skinned.vert skins them.

in vec3 vertexPosition;

#include <flame_3d/skinning.glsl>
#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

out vec4 fragClipPosition;

void main() {
  vec4 position = computeSkinMatrix() * vec4(vertexPosition, 1.0);
  vec4 worldPosition = instanceModelMatrix() * vec4(position.xyz, 1.0);
  gl_Position = camera.viewProjection * worldPosition;
  fragClipPosition = gl_Position;
}
