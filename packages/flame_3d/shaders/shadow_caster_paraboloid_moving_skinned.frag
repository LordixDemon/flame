#version 460 core

// The same fragment stage as shadow_caster_paraboloid_moving.frag.

#include <flame_3d/shadow_caster_moving.glsl>

in float fragDepth;
in float fragHemisphereZ;
in vec2 fragTilePosition;

void main() {
  if (fragHemisphereZ < -0.05 || fragDepth > 1.0) {
    discard;
  }
  writeMovingCasterDepth(fragTilePosition, clamp(fragDepth, 0.0, 1.0));
}
