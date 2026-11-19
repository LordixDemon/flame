#version 460 core

// Unified final scene compositor: combines optional 5-tap edge-aware FXAA,
// SSAO, 3D DoF, additive bloom, exposure, ACES/AgX/Reinhard tone mapping,
// contrast, saturation, color tint, 3D ColorLut3D trilinear grading, vignette,
// and RenderDebugMode3D visualization in a single pass.
//
// The scene texture holds premultiplied colors. With HDR (`lutParams.z`) they
// are sRGB-encoded with an extended range (values above 1 are kept), as every
// material writes them; they are decoded to linear light for exposure, bloom
// and tone mapping, then encoded again for display. The output keeps the
// scene's alpha, and the response of the grading to black is removed from the
// uncovered part of each pixel, so a transparent pixel stays transparent over
// the 2D content drawn behind a layer.

in vec2 fragUv;

out vec4 outColor;

uniform sampler2D sceneTexture;
uniform sampler2D bloomTexture;
uniform sampler2D depthNormalTexture;
uniform sampler2D lutTexture;

uniform BloomComposite {
  // x: bloomIntensity, y: exposure, z: contrast, w: saturation
  vec4 params;
  // x: toneMapMode (0=none, 1=reinhard, 2=aces, 3=agx),
  // y: vignetteIntensity, z: vignetteSmoothness, w: fxaa (1=on, 0=off)
  vec4 grading;
  // rgb: color tint, a: unused
  vec4 tint;
  // xy: 1 / resolution, zw: unused
  vec4 texel;
  // x: ssaoIntensity, y: ssaoRadius (in pixels), z: hasDepthNormal, w: unused
  vec4 ssao;
  // x: dofBlurStrength, y: dofFocusDepth [0..1], z: dofFocusRange, w: unused
  vec4 dof;
  // x: lutIntensity, y: lutSize (16.0), z: hdr (1=scene texture is extended
  // sRGB, decoded before and encoded after tone mapping), w: debugMode
  vec4 lutParams;
} composite;

float decodeDepth16(vec4 dn) {
  return (dn.r * 255.0 * 256.0 + dn.g * 255.0) / 65535.0;
}

vec3 decodeViewNormal(vec4 dn) {
  vec2 xy = dn.ba * 2.0 - 1.0;
  float z = sqrt(max(0.0, 1.0 - dot(xy, xy)));
  return normalize(vec3(xy, z));
}

float computeSpiralSsao(
  vec2 uv,
  vec2 invRes,
  float dCenter,
  vec3 nCenter,
  float strength
) {
  if (strength <= 1e-4 || composite.ssao.z < 0.5 || dCenter >= 0.999) {
    return 1.0;
  }
  float radiusPx = max(composite.ssao.y, 0.5) * 4.0;
  float occ = 0.0;
  for (int i = 0; i < 8; i++) {
    float fi = float(i) + 0.5;
    float ang = fi * 2.39996323;
    float r = (fi / 8.0) * radiusPx;
    vec2 sUv = clamp(
      uv + vec2(cos(ang), sin(ang)) * invRes * r,
      vec2(0.001),
      vec2(0.999)
    );
    vec4 sDn = texture(depthNormalTexture, sUv);
    float dSample = decodeDepth16(sDn);
    float diff = dCenter - dSample;
    if (diff > 0.0006 && diff < 0.065) {
      vec3 sNorm = decodeViewNormal(sDn);
      float crease = clamp(1.0 - dot(nCenter, sNorm), 0.15, 1.0);
      float rangeW = 1.0 - smoothstep(0.015, 0.065, diff);
      occ += crease * rangeW;
    }
  }
  float ao = 1.0 - clamp((occ / 8.0) * strength * 2.4, 0.0, 0.88);
  return ao;
}

vec4 sampleDofBokeh(vec2 uv, vec2 invRes, vec4 sharpColor, float dCenter) {
  if (composite.dof.x <= 1e-4 || composite.ssao.z < 0.5) {
    return sharpColor;
  }
  float distFromFocus = abs(dCenter - composite.dof.y);
  float coc = clamp(
    (distFromFocus - composite.dof.z) / max(composite.dof.z, 0.02),
    0.0,
    1.0
  ) * composite.dof.x;
  if (coc <= 0.01) {
    return sharpColor;
  }
  float radiusPx = coc * 5.5;
  vec4 acc = sharpColor;
  float wSum = 1.0;
  for (int i = 0; i < 8; i++) {
    float fi = float(i) + 1.0;
    float ang = fi * 2.39996323;
    float r = sqrt(fi / 8.0) * radiusPx;
    vec2 bUv = clamp(
      uv + vec2(cos(ang), sin(ang)) * invRes * r,
      vec2(0.001),
      vec2(0.999)
    );
    acc += texture(sceneTexture, bUv);
    wSum += 1.0;
  }
  // Premultiplied colors blur with their alpha.
  return acc / wSum;
}

float luma(vec3 rgb) {
  return dot(rgb, vec3(0.299, 0.587, 0.114));
}

vec4 sampleSceneFxaa(vec2 uv, vec2 invRes) {
  vec4 cM = texture(sceneTexture, uv);
  if (composite.grading.w < 0.5) {
    return cM;
  }
  vec3 nw = texture(sceneTexture, uv + vec2(-invRes.x, -invRes.y)).rgb;
  vec3 ne = texture(sceneTexture, uv + vec2(invRes.x, -invRes.y)).rgb;
  vec3 sw = texture(sceneTexture, uv + vec2(-invRes.x, invRes.y)).rgb;
  vec3 se = texture(sceneTexture, uv + vec2(invRes.x, invRes.y)).rgb;

  float lM = luma(cM.rgb);
  float lNW = luma(nw);
  float lNE = luma(ne);
  float lSW = luma(sw);
  float lSE = luma(se);

  float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
  float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
  float range = lMax - lMin;
  if (range < max(0.0312, lMax * 0.125)) {
    return cM;
  }

  vec2 dir = vec2(
    -((lNW + lNE) - (lSW + lSE)),
    ((lNW + lSW) - (lNE + lSE))
  );
  float dirReduce = max((lNW + lNE + lSW + lSE) * (0.25 * 0.125), 1.0 / 128.0);
  float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
  dir = clamp(dir * rcpDirMin, vec2(-4.0), vec2(4.0)) * invRes;

  // Premultiplied colors are filtered with their alpha.
  vec4 rgbA = 0.5 * (
    texture(sceneTexture, uv + dir * (1.0 / 3.0 - 0.5)) +
    texture(sceneTexture, uv + dir * (2.0 / 3.0 - 0.5))
  );
  vec4 rgbB = rgbA * 0.5 + 0.25 * (
    texture(sceneTexture, uv + dir * -0.5) +
    texture(sceneTexture, uv + dir * 0.5)
  );
  float lB = luma(rgbB.rgb);
  return (lB < lMin || lB > lMax) ? rgbA : rgbB;
}

vec3 acesFilmic(vec3 x) {
  const float a = 2.51;
  const float b = 0.03;
  const float c = 2.43;
  const float d = 0.59;
  const float e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// AgX base look (Blender's AgX, minimal approximation by B. Wrensch): inset,
// log2 encoding over [-12.47, 4.03] EV, 6th-order sigmoid fit, outset. The
// result is display-encoded (gamma 2.2), not linear.
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

vec3 sampleColorLut3D(vec3 rgb, float size) {
  vec3 c = clamp(rgb, 0.0, 1.0) * (size - 1.0);
  float b0 = floor(c.b);
  float b1 = min(b0 + 1.0, size - 1.0);
  float bf = c.b - b0;
  float invW = 1.0 / (size * size);
  float invH = 1.0 / size;
  vec2 uv0 = vec2((b0 * size + c.r + 0.5) * invW, (c.g + 0.5) * invH);
  vec2 uv1 = vec2((b1 * size + c.r + 0.5) * invW, (c.g + 0.5) * invH);
  return mix(
    texture(lutTexture, uv0).rgb,
    texture(lutTexture, uv1).rgb,
    bf
  );
}

vec3 linearToSrgb(vec3 linear) {
  vec3 clamped = clamp(linear, 0.0, 1.0);
  vec3 lo = clamped * 12.92;
  vec3 hi = 1.055 * pow(max(clamped, vec3(1e-6)), vec3(1.0 / 2.4)) - 0.055;
  return mix(lo, hi, step(vec3(0.0031308), clamped));
}

// Decodes an sRGB-encoded color whose range extends above 1 (the HDR scene
// texture) to linear light.
vec3 extendedSrgbToLinear(vec3 encoded) {
  vec3 c = max(encoded, vec3(0.0));
  vec3 lo = c / 12.92;
  vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
  return mix(lo, hi, step(vec3(0.04045), c));
}

// Exposure, tone mapping, display encoding and color grading of a color in
// the scene's space (linear light with HDR, display-encoded without),
// multiplied by `vignette`.
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

  // Linear light -> sRGB display encoding before display-referred grading.
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

  float lutStrength = composite.lutParams.x;
  if (lutStrength > 1e-4 && composite.lutParams.y >= 2.0) {
    vec3 graded = sampleColorLut3D(color, composite.lutParams.y);
    color = mix(color, graded, clamp(lutStrength, 0.0, 1.0));
  }

  return clamp(color * vignette, 0.0, 1.0);
}

void main() {
  float debugMode = composite.lutParams.w;
  vec4 base = sampleSceneFxaa(fragUv, composite.texel.xy);

  if (composite.ssao.z > 0.5) {
    vec4 dn = texture(depthNormalTexture, fragUv);
    float dCenter = decodeDepth16(dn);
    vec3 nCenter = decodeViewNormal(dn);
    // RenderDebugMode3D.depth == 2
    if (abs(debugMode - 2.0) < 0.25) {
      float visD = clamp(1.0 - dCenter, 0.0, 1.0);
      outColor = vec4(vec3(visD), dCenter < 0.999 ? 1.0 : base.a);
      return;
    }
    // RenderDebugMode3D.ssao == 3
    if (abs(debugMode - 3.0) < 0.25) {
      float dbgAo = computeSpiralSsao(
        fragUv,
        composite.texel.xy,
        dCenter,
        nCenter,
        max(composite.ssao.x, 1.0)
      );
      outColor = vec4(vec3(dbgAo), dCenter < 0.999 ? 1.0 : base.a);
      return;
    }
  }
  // Pass through per-fragment diagnostic views (`normals`, `cascadeSplits`,
  // `wireframe`, `overdraw`, `roughnessMetallic`, `albedo`) without grading!
  if (debugMode > 0.5) {
    outColor = vec4(clamp(base.rgb, 0.0, 1.0), base.a);
    return;
  }

  float ao = 1.0;
  if (composite.ssao.z > 0.5) {
    vec4 dn = texture(depthNormalTexture, fragUv);
    float dCenter = decodeDepth16(dn);
    vec3 nCenter = decodeViewNormal(dn);
    base = sampleDofBokeh(fragUv, composite.texel.xy, base, dCenter);
    ao = computeSpiralSsao(
      fragUv,
      composite.texel.xy,
      dCenter,
      nCenter,
      composite.ssao.x
    );
  }
  bool hdr = composite.lutParams.z > 0.5;
  vec3 glow = composite.params.x > 0.0
      ? texture(bloomTexture, fragUv).rgb * composite.params.x
      : vec3(0.0);
  vec3 sceneColor = hdr ? extendedSrgbToLinear(base.rgb) : base.rgb;
  vec3 color = sceneColor * ao + glow;

  float vignette = 1.0;
  float vigAmt = composite.grading.y;
  if (vigAmt > 0.0) {
    vec2 centered = fragUv * 2.0 - 1.0;
    float d = length(centered) * 0.70710678;
    float smoothW = max(composite.grading.z, 0.05);
    vignette = clamp(1.0 - smoothstep(1.0 - smoothW, 1.05, d) * vigAmt, 0.0, 1.0);
  }

  // Grading may lift black (contrast below 1, a LUT whose black is not
  // black): that lift belongs to the covered part of the pixel only, so the
  // 2D content behind an uncovered part is left as it is.
  vec3 graded = grade(color, hdr, vignette);
  if (base.a < 1.0) {
    vec3 blackLift = grade(vec3(0.0), hdr, vignette);
    graded = max(graded - (1.0 - base.a) * blackLift, 0.0);
  }
  outColor = vec4(graded, base.a);
}
