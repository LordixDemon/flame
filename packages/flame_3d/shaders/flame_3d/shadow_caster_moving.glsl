#ifndef FLAME_SHADOW_CASTER_MOVING_GLSL_
#define FLAME_SHADOW_CASTER_MOVING_GLSL_

// The fragment stage of the casters drawn over the kept depths of the still
// casters (`ShadowSettings.cacheStillCasters`): the map already holds a copy
// of those depths when a moving caster is drawn, and a fragment that is not
// nearer to the light than the kept depth at its texel is discarded. The map
// then holds the nearer of both at every texel, as if every caster had been
// drawn in one pass.

out vec4 outColor;

uniform ShadowCaster {
  float packDepth;
} caster;

// The kept depths of the still casters of the view being rendered, a texture
// of the size of the view, encoded as this stage encodes depths.
uniform sampler2D shadowStillCasters;

// 24 bits of depth in red, green and blue, most significant first, as
// flame_3d/shadow_caster_fragment.glsl stores them.
vec4 packShadowDepth(float depth) {
  float d = floor(clamp(depth, 0.0, 1.0) * 16777215.0 + 0.5);
  float high = floor(d / 65536.0);
  d -= high * 65536.0;
  float middle = floor(d / 256.0);
  float low = d - middle * 256.0;
  return vec4(high, middle, low, 255.0) / 255.0;
}

// Writes [depth] like the stage of the still casters does, unless the kept
// depth of the still casters at [ndc] (the fragment's position in the clip
// space of the view) is as near or nearer: then the fragment is discarded.
// Packed depths are compared as the 24-bit integers the map stores, so the
// result is the one a single pass would give.
void writeMovingCasterDepth(vec2 ndc, float depth) {
  vec4 still = texture(
    shadowStillCasters,
    vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y)
  );
  if (caster.packDepth > 0.5) {
    float own = floor(clamp(depth, 0.0, 1.0) * 16777215.0 + 0.5);
    vec3 bytes = floor(still.rgb * 255.0 + 0.5);
    float kept = bytes.r * 65536.0 + bytes.g * 256.0 + bytes.b;
    if (own >= kept) {
      discard;
    }
    outColor = packShadowDepth(depth);
  } else {
    if (depth >= still.r) {
      discard;
    }
    outColor = vec4(depth, 0.0, 0.0, 1.0);
  }
}

#endif
