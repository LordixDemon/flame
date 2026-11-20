#version 460 core

// shadow_caster_paraboloid_moving.vert for surfaces whose vertices have
// joints and joint weights: they are skinned first.

in vec3 vertexPosition;

#include <flame_3d/skinning.glsl>
#include <flame_3d/instancing.glsl>

uniform ParaboloidLight {
  vec4 posInvRange;
  vec4 params;
} paraboloid;

out float fragDepth;
out float fragHemisphereZ;
out vec2 fragTilePosition;

void main() {
  vec4 skinned = computeSkinMatrix() * vec4(vertexPosition, 1.0);
  vec4 worldPos = instanceModelMatrix() * vec4(skinned.xyz, 1.0);
  vec3 local = worldPos.xyz - paraboloid.posInvRange.xyz;
  local.z *= paraboloid.params.x;

  float dist = length(local);
  vec3 dir = dist > 1e-5 ? local / dist : vec3(0.0, 0.0, 1.0);
  fragHemisphereZ = dir.z;
  float denom = max(dir.z + 1.0, 0.02);
  vec2 p = (dir.xy / denom) * 0.96;
  float linearDepth = clamp(dist * paraboloid.posInvRange.w, 0.0, 1.0);
  fragDepth = linearDepth;
  fragTilePosition = p;
  gl_Position = vec4(p.x, p.y, linearDepth, 1.0);
}
