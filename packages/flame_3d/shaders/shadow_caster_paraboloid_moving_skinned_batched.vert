#version 460 core

#define FLAME_RIGID_BATCH_TRANSFORMS_ONLY

in vec3 vertexPosition;

#define FLAME_RIGID_BATCH_MAX_OBJECTS 8
#include <flame_3d/rigid_batch.glsl>
#include <flame_3d/skinning.glsl>

uniform ParaboloidLight {
  // xyz: point light world position, w: 1.0 / lightRange
  vec4 posInvRange;
  // x: hemisphere sign (+1 for +Z, -1 for -Z), yzw: unused
  vec4 params;
} paraboloid;

out float fragDepth;
out float fragHemisphereZ;
out vec2 fragTilePosition;

void main() {
  int id = int(vertexObjectId + 0.5);
  vec4 localPosition = computeSkinMatrix() * vec4(vertexPosition, 1.0);
  vec4 worldPos = batchObjectModelMatrix(id) * vec4(localPosition.xyz, 1.0);
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
