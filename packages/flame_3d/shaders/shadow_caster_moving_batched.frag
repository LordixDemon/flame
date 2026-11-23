#version 460 core

#include <flame_3d/shadow_caster_moving.glsl>

in vec4 fragClipPosition;

void main() {
  writeMovingCasterDepth(
    fragClipPosition.xy / fragClipPosition.w,
    fragClipPosition.z / fragClipPosition.w
  );
}
