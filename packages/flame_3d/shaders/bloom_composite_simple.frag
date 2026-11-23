#version 460 core

// Lean final scene compositor when SSAO, DoF, FXAA, 3D LUT, and debug views
// are disabled: samples only sceneTexture and bloomTexture.

in vec2 fragUv;

out vec4 outColor;

uniform sampler2D sceneTexture;
uniform sampler2D bloomTexture;

uniform BloomComposite {
  vec4 params;
  vec4 grading;
  vec4 tint;
  vec4 texel;
  vec4 ssao;
  vec4 dof;
  vec4 lutParams;
  vec4 frame;
} composite;

float luma(vec3 rgb) {
  return dot(rgb, vec3(0.299, 0.587, 0.114));
}

vec3 acesFilmic(vec3 x) {
  const float a = 2.51;
  const float b = 0.03;
  const float c = 2.43;
  const float d = 0.59;
  const float e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

vec3 agx(vec3 x) {
  mat3 inset = mat3(
    0.842479062253094, 0.0423282422610123, 0.0423756549057051,
    0.0784335999999992, 0.878468636469772, 0.0784336,
    0.0792237451477643, 0.0791661274605434, 0.879142973793104
  );
  mat3 outset = mat3(
    1.19687900512017, -0.0528968517574562, -0.0529716355144438,
    -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
    -0.0990297440797205, -0.0989611768448433, 1.15107367264116
  );
  vec3 v = max(inset * x, vec3(1e-10));
  v = clamp((log2(v) + 12.47393) / 16.5, 0.0, 1.0);
  vec3 v2 = v * v;
  vec3 v4 = v2 * v2;
  vec3 s = 15.5 * v4 * v2 - 40.14 * v4 * v + 31.96 * v4 - 6.868 * v2 * v +
    0.4298 * v2 + 0.1191 * v - 0.00232;
  return clamp(outset * s, 0.0, 1.0);
}

vec3 linearToSrgb(vec3 linear) {
  vec3 clamped = clamp(linear, 0.0, 1.0);
  vec3 lo = clamped * 12.92;
  vec3 hi = 1.055 * pow(max(clamped, vec3(1e-6)), vec3(1.0 / 2.4)) - 0.055;
  return mix(lo, hi, step(vec3(0.0031308), clamped));
}

vec3 extendedSrgbToLinear(vec3 encoded) {
  vec3 c = max(encoded, vec3(0.0));
  vec3 lo = c / 12.92;
  vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
  return mix(lo, hi, step(vec3(0.04045), c));
}

vec3 grade(vec3 color, bool hdr, float vignette) {
  color *= composite.params.y;

  float mode = composite.grading.x;
  bool displayEncoded = false;
  if (mode > 2.5) {
    color = agx(max(color, vec3(0.0)));
    displayEncoded = true;
  } else if (mode > 1.5) {
    color = acesFilmic(max(color, vec3(0.0)));
  } else if (mode > 0.5) {
    color = max(color, vec3(0.0));
    color = color / (color + vec3(1.0));
  }

  if (hdr && !displayEncoded) {
    color = linearToSrgb(color);
  }

  float contrast = composite.params.z;
  if (abs(contrast - 1.0) > 1e-4) {
    color = (color - 0.5) * contrast + 0.5;
  }

  float sat = composite.params.w;
  if (abs(sat - 1.0) > 1e-4) {
    float lum = luma(color);
    color = mix(vec3(lum), color, sat);
  }

  color *= composite.tint.rgb;
  return clamp(color * vignette, 0.0, 1.0);
}

void main() {
  vec4 base = texture(sceneTexture, fragUv);
  bool hdr = composite.lutParams.z > 0.5;
  vec3 glow = composite.params.x > 0.0
      ? texture(bloomTexture, fragUv).rgb * composite.params.x
      : vec3(0.0);
  vec3 color = (hdr ? extendedSrgbToLinear(base.rgb) : base.rgb) + glow;

  float vignette = 1.0;
  float vigAmt = composite.grading.y;
  if (vigAmt > 0.0) {
    vec2 centered = (fragUv - composite.frame.xy) * composite.frame.zw;
    float d = length(centered) * 0.70710678;
    float smoothW = max(composite.grading.z, 0.05);
    vignette = clamp(1.0 - smoothstep(1.0 - smoothW, 1.05, d) * vigAmt, 0.0, 1.0);
  }

  vec3 graded = grade(color, hdr, vignette);
  if (base.a < 1.0) {
    vec3 blackLift = grade(vec3(0.0), hdr, vignette);
    graded = max(graded - (1.0 - base.a) * blackLift, 0.0);
  }
  outColor = vec4(graded, base.a);
}
