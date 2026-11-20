#version 460 core

// shadow_caster.vert for the casters drawn over the kept depths of the still
// casters (`ShadowSettings.cacheStillCasters`): the same position, and the
// whole clip-space position for the fragment stage, which finds the texel of
// the kept depths it covers from it.

in vec3 vertexPosition;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

out vec4 fragClipPosition;

void main() {
  vec4 worldPosition = instanceModelMatrix() * vec4(vertexPosition, 1.0);
  gl_Position = camera.viewProjection * worldPosition;
  fragClipPosition = gl_Position;
}
