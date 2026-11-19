#version 460 core

// Renders the depth of shadow casters, seen from the light that casts
// shadows, into its shadow map. It reads only the position, so it draws the
// surfaces of every vertex layout that has one; shadow_caster_skinned.vert
// skins those whose vertices have joints and joint weights. The camera is the
// light's view.

in vec3 vertexPosition;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

// The light's clip-space depth and w, divided per pixel by the fragment
// stage: z / w interpolated across a triangle would only be right for an
// orthographic light, not for a spot light's perspective.
out vec2 fragClipDepth;

void main() {
  vec4 worldPosition = instanceModelMatrix() * vec4(vertexPosition, 1.0);
  gl_Position = camera.viewProjection * worldPosition;
  fragClipDepth = gl_Position.zw;
}
