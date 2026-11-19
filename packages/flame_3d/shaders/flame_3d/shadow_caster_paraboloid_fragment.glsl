#ifndef FLAME_SHADOW_CASTER_PARABOLOID_FRAGMENT_GLSL_
#define FLAME_SHADOW_CASTER_PARABOLOID_FRAGMENT_GLSL_

in float fragDepth;
in float fragHemisphereZ;

out vec4 outColor;

uniform ShadowCaster {
  float packDepth;
} caster;

vec4 packShadowDepth(float depth) {
  float d = floor(clamp(depth, 0.0, 1.0) * 16777215.0 + 0.5);
  float high = floor(d / 65536.0);
  d -= high * 65536.0;
  float middle = floor(d / 256.0);
  float low = d - middle * 256.0;
  return vec4(high, middle, low, 255.0) / 255.0;
}

void main() {
  if (fragHemisphereZ < -0.05 || fragDepth > 1.0) {
    discard;
  }
  if (caster.packDepth > 0.5) {
    outColor = packShadowDepth(fragDepth);
  } else {
    outColor = vec4(clamp(fragDepth, 0.0, 1.0), 0.0, 0.0, 1.0);
  }
}

#endif
