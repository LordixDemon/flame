#version 460 core

// Soft-knee bright-pass extraction + 4-tap bilinear downsample for GPU bloom.
// With HDR the scene texture holds extended-range sRGB, decoded here so the
// threshold applies to linear light.

in vec2 fragUv;

out vec4 outColor;

uniform sampler2D sourceTexture;

uniform BloomPrefilter {
  // x: threshold, y: threshold - knee, z: 2 * knee, w: 0.25 / max(knee, 1e-5).
  vec4 curve;
  // xy: inverse source resolution (1 / width, 1 / height), z: 1 when the
  // source is the HDR scene texture (extended-range sRGB).
  vec4 texel;
} prefilter;

vec3 extendedSrgbToLinear(vec3 encoded) {
  vec3 c = max(encoded, vec3(0.0));
  vec3 lo = c / 12.92;
  vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
  return mix(lo, hi, step(vec3(0.04045), c));
}

vec3 extractBright(vec3 c) {
  float brightness = max(c.r, max(c.g, c.b));
  float soft = clamp(brightness - prefilter.curve.y, 0.0, prefilter.curve.z);
  soft = soft * soft * prefilter.curve.w;
  float contribution = max(soft, brightness - prefilter.curve.x) /
      max(brightness, 1e-4);
  return c * max(0.0, contribution);
}

void main() {
  vec2 d = prefilter.texel.xy * 0.5;
  vec3 c0 = texture(sourceTexture, fragUv + vec2(-d.x, -d.y)).rgb;
  vec3 c1 = texture(sourceTexture, fragUv + vec2( d.x, -d.y)).rgb;
  vec3 c2 = texture(sourceTexture, fragUv + vec2(-d.x,  d.y)).rgb;
  vec3 c3 = texture(sourceTexture, fragUv + vec2( d.x,  d.y)).rgb;
  if (prefilter.texel.z > 0.5) {
    c0 = extendedSrgbToLinear(c0);
    c1 = extendedSrgbToLinear(c1);
    c2 = extendedSrgbToLinear(c2);
    c3 = extendedSrgbToLinear(c3);
  }
  vec3 avg = 0.25 * (c0 + c1 + c2 + c3);
  outColor = vec4(extractBright(avg), 1.0);
}
