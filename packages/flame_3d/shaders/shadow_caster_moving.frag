#version 460 core

// shadow_caster.frag for the casters drawn over the kept depths of the still
// casters, see flame_3d/shadow_caster_moving.glsl.

#include <flame_3d/shadow_caster_moving.glsl>

in vec4 fragClipPosition;

void main() {
  writeMovingCasterDepth(
    fragClipPosition.xy / fragClipPosition.w,
    fragClipPosition.z / fragClipPosition.w
  );
}
