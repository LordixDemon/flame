#ifndef FLAME_SHADOWS_GLSL_
#define FLAME_SHADOWS_GLSL_

// The shadows of the render pass, filled by flame_3d once per pass for every
// fragment shader that declares them. A material whose shader receives
// shadows lists the `Shadows` block and the `shadowMap` sampler in its slots,
// and calls shadowVisibility() for the directional light that casts shadows,
// spotShadowFactor() for each spot light and pointShadowFactor() for each
// point light.

// The depths of the shadow casters, seen from the lights.
uniform sampler2D shadowMap;

// The map is either one light's map (a directional light with one cascade,
// or a lone spot light), or a shared atlas of tiles (`atlas.x` is 1): the
// cascades of the directional light, up to 2 spot lights and the two halves
// of one point light, packed side by side in `shadowMap`.
//
// `lightViewProjection` maps world space to the light's clip space: x and y
// in [-1, 1] across the map, the depth from 0 to 1 along the light.
// `toLight.xyz` is the unit vector from surfaces towards the directional
// light and `toLight.w` the index of that light among the directional
// lights, `100 + index` for a lone spot light, or -1 when the pass has no
// shadows (or, with the atlas, no directional shadows). That light's shadowed
// light is multiplied by `mix(1, color.rgb, color.a)`, `color.a` being the
// strength. `map.xy` is the size of the map in texels and `map.zw` its
// inverse. `bias.x` is the size of a texel in world units, `bias.y` the depth
// bias and `bias.z` the normal bias (in texels), `bias.w` the radius of the
// filter in texels. `decode` turns a texel of the map into a depth:
// `dot(texel, decode)`.
//
// With the atlas: `atlas.y` is the number of cascades, `atlas.z` the number
// of spot light tiles, `atlas.w` the index of the point light whose shadows
// the atlas holds, or -1. Each tile has a rectangle of the map
// (`xy` offset, `zw` size, in texture coordinates). Cascade `c` has its
// matrix, its texel size in world units (`atlasCascadeParams[c].x`) and the
// fraction of its border over which it blends into the next one
// (`atlasCascadeParams[c].y`). Spot tile `s` has its matrix, its light's
// index, texel size, depth bias and strength (`atlasSpotParams[s]`), its
// light's position and filter radius (`atlasSpotPositions[s]`) and its
// shadow color. The point light has its position and `1 / range`, a tile per
// hemisphere (`+z`, `-z`), its depth bias, filter radius and strength
// (`atlasPointParams`) and its shadow color.
//
// A shader that reads these values from a block of its own (as
// StylizedMaterial does, to bind fewer blocks) defines
// `FLAME_SHADOWS(member)` to the expression of the member named `member`
// before including this file, which then declares no Shadows block. A shader
// that only ever receives a single map (the web variant of SpatialMaterial)
// defines `FLAME_SHADOWS_SINGLE_MAP` first: its block has no atlas members
// and it receives no shadows on frames that use the atlas.
#ifndef FLAME_SHADOWS
uniform Shadows {
  mat4 lightViewProjection;
  mat4 cascadeViewProjection;
  vec4 toLight;
  vec4 color;
  vec4 map;
  vec4 bias;
  vec4 decode;
  // Unused, always (1, 0, 0, 0).
  vec4 cascadeParams;
#ifndef FLAME_SHADOWS_SINGLE_MAP
  vec4 atlas;
  mat4 atlasCascadeViewProjections[4];
  vec4 atlasCascadeRects[4];
  vec4 atlasCascadeParams[4];
  mat4 atlasSpotViewProjections[2];
  vec4 atlasSpotRects[2];
  vec4 atlasSpotParams[2];
  vec4 atlasSpotPositions[2];
  vec4 atlasSpotColors[2];
  vec4 atlasPointPosition;
  vec4 atlasPointRects[2];
  vec4 atlasPointParams;
  vec4 atlasPointColor;
#endif
} shadows;
#define FLAME_SHADOWS(member) shadows.member
#endif

// The filter radius of `value` (a radius in texels from the uniforms), from
// 0 to 3 (ShadowSettings.maxSoftness): a whole number in a float, as the
// filters below take it.
float flameShadowFilterRadius(float value) {
  return clamp(floor(value), 0.0, 3.0);
}

// The filters below read a box of `2 * radius + 2` texels on a side, blended
// bilinearly. Their loops have constant bounds, those of the largest radius
// (8 taps, from -3 to 4), and skip the taps beyond `radius`: the radius comes
// from a uniform, and OpenGL ES drivers (GLSL ES 1.00, appendix A) need not
// run a loop whose bounds come from a uniform as written. The taps are added
// in the same order as with bounds from the radius, so the result is the same.

// The visibility of the single map (not the atlas) at `worldPosition`.
float flameSingleMapVisibility(vec3 worldPosition, vec3 normal) {
  float radius = flameShadowFilterRadius(FLAME_SHADOWS(bias).w);
  vec3 l = FLAME_SHADOWS(toLight).xyz;
  float cosine = clamp(dot(normal, l), 0.0, 1.0);
  float sine = sqrt(1.0 - cosine * cosine);
  float texel = FLAME_SHADOWS(bias).x;
  float reach = FLAME_SHADOWS(bias).z + 1.4142 * (radius + 1.0);
  vec3 position = worldPosition +
    normal * (texel * reach * sine) +
    l * (texel * FLAME_SHADOWS(bias).y);

  vec4 clip = FLAME_SHADOWS(lightViewProjection) * vec4(position, 1.0);
  if (FLAME_SHADOWS(toLight).w >= 99.0 && clip.w <= 0.0) {
    return 1.0;
  }
  vec3 ndc = clip.xyz / clip.w;
  vec2 uv = vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y);
  float depth = ndc.z;
  if (FLAME_SHADOWS(toLight).w >= 99.0 && depth < 0.0) {
    return 1.0;
  }
  bool inside = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0 &&
    depth <= 1.0;
  if (!inside) {
    return 1.0;
  }

  vec2 texelPosition = uv * FLAME_SHADOWS(map).xy - 0.5;
  vec2 base = floor(texelPosition);
  vec2 f = texelPosition - base;
  float lit = 0.0;
  for (int row = 0; row < 8; row++) {
    float y = float(row) - 3.0;
    if (y >= -radius && y <= radius + 1.0) {
      float wy = y == -radius ? 1.0 - f.y : (y == radius + 1.0 ? f.y : 1.0);
      for (int column = 0; column < 8; column++) {
        float x = float(column) - 3.0;
        if (x >= -radius && x <= radius + 1.0) {
          float wx =
            x == -radius ? 1.0 - f.x : (x == radius + 1.0 ? f.x : 1.0);
          vec2 sampleUv = (base + vec2(x, y) + 0.5) * FLAME_SHADOWS(map).zw;
          float stored =
            dot(texture(shadowMap, sampleUv), FLAME_SHADOWS(decode));
          lit += wx * wy * step(depth, stored);
        }
      }
    }
  }
  float side = 2.0 * radius + 1.0;
  return lit / (side * side);
}

#ifndef FLAME_SHADOWS_SINGLE_MAP
// Whether the shadow map of the pass is the atlas.
bool shadowAtlasActive() {
  return FLAME_SHADOWS(atlas).x > 0.5;
}

// The filtered visibility of `depth` at `tileUv` (from 0 to 1 across the
// tile) in the atlas tile `rect`, with a filter of `radius` texels (see
// flameShadowFilterRadius) that does not read the neighbouring tiles.
float flameSampleAtlasTile(
  vec2 tileUv,
  vec4 rect,
  float depth,
  float radius
) {
  vec2 mapSize = FLAME_SHADOWS(map).xy;
  vec2 invMap = FLAME_SHADOWS(map).zw;
  vec2 atlasUv = rect.xy + tileUv * rect.zw;
  vec2 minUv = rect.xy + invMap * 0.5;
  vec2 maxUv = rect.xy + rect.zw - invMap * 0.5;

  vec2 texelPos = atlasUv * mapSize - 0.5;
  vec2 base = floor(texelPos);
  vec2 f = texelPos - base;
  float lit = 0.0;
  for (int row = 0; row < 8; row++) {
    float y = float(row) - 3.0;
    if (y >= -radius && y <= radius + 1.0) {
      float wy = y == -radius ? 1.0 - f.y : (y == radius + 1.0 ? f.y : 1.0);
      for (int column = 0; column < 8; column++) {
        float x = float(column) - 3.0;
        if (x >= -radius && x <= radius + 1.0) {
          float wx =
            x == -radius ? 1.0 - f.x : (x == radius + 1.0 ? f.x : 1.0);
          vec2 sUv = clamp((base + vec2(x, y) + 0.5) * invMap, minUv, maxUv);
          float stored = dot(texture(shadowMap, sUv), FLAME_SHADOWS(decode));
          lit += wx * wy * step(depth, stored);
        }
      }
    }
  }
  float side = 2.0 * radius + 1.0;
  return lit / (side * side);
}

// The visibility of the directional light from its cascades in the atlas,
// blending into the next cascade near the border of each; `cascade` is set to
// the cascade used, or -1 outside all of them.
float flameAtlasCascadeVisibility(
  vec3 worldPosition,
  vec3 normal,
  out int cascade
) {
  cascade = -1;
  int count = int(FLAME_SHADOWS(atlas).y);
  if (count <= 0) {
    return 1.0;
  }
  float radius = flameShadowFilterRadius(FLAME_SHADOWS(bias).w);
  vec3 l = FLAME_SHADOWS(toLight).xyz;
  float cosine = clamp(dot(normal, l), 0.0, 1.0);
  float sine = sqrt(1.0 - cosine * cosine);
  float reach = FLAME_SHADOWS(bias).z + 1.4142 * (radius + 1.0);

  for (int c = 0; c < 4; c++) {
    if (c >= count) {
      break;
    }
    float texel = FLAME_SHADOWS(atlasCascadeParams)[c].x;
    vec3 biasedPos = worldPosition +
      normal * (texel * reach * sine) +
      l * (texel * FLAME_SHADOWS(bias).y);
    vec4 clip =
      FLAME_SHADOWS(atlasCascadeViewProjections)[c] * vec4(biasedPos, 1.0);
    vec3 ndc = clip.xyz / max(clip.w, 1e-6);
    vec2 uv = vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y);
    float margin = c < count - 1 ? 0.02 : 0.0;
    if (uv.x >= margin && uv.x <= 1.0 - margin &&
        uv.y >= margin && uv.y <= 1.0 - margin &&
        ndc.z >= 0.0 && ndc.z <= 1.0) {
      cascade = c;
      float vis0 = flameSampleAtlasTile(
        uv,
        FLAME_SHADOWS(atlasCascadeRects)[c],
        ndc.z,
        radius
      );
      float blendBand = FLAME_SHADOWS(atlasCascadeParams)[c].y;
      if (blendBand > 1e-3 && c + 1 < count) {
        float edgeDist = min(
          min(uv.x - margin, (1.0 - margin) - uv.x),
          min(uv.y - margin, (1.0 - margin) - uv.y)
        );
        if (edgeDist < blendBand) {
          float nextTexel = FLAME_SHADOWS(atlasCascadeParams)[c + 1].x;
          vec3 nextPos = worldPosition +
            normal * (nextTexel * reach * sine) +
            l * (nextTexel * FLAME_SHADOWS(bias).y);
          vec4 nextClip = FLAME_SHADOWS(atlasCascadeViewProjections)[c + 1] *
            vec4(nextPos, 1.0);
          vec3 nextNdc = nextClip.xyz / max(nextClip.w, 1e-6);
          vec2 nextUv = vec2(0.5 + 0.5 * nextNdc.x, 0.5 - 0.5 * nextNdc.y);
          if (nextUv.x >= 0.0 && nextUv.x <= 1.0 &&
              nextUv.y >= 0.0 && nextUv.y <= 1.0 &&
              nextNdc.z >= 0.0 && nextNdc.z <= 1.0) {
            float vis1 = flameSampleAtlasTile(
              nextUv,
              FLAME_SHADOWS(atlasCascadeRects)[c + 1],
              nextNdc.z,
              radius
            );
            float t = 1.0 - clamp(edgeDist / blendBand, 0.0, 1.0);
            return mix(vis0, vis1, t);
          }
        }
      }
      return vis0;
    }
  }
  return 1.0;
}

// The visibility of the spot light of atlas tile `slot` at `worldPosition`.
float flameAtlasSpotVisibility(int slot, vec3 worldPosition, vec3 normal) {
  vec4 params = FLAME_SHADOWS(atlasSpotParams)[slot];
  vec4 light = FLAME_SHADOWS(atlasSpotPositions)[slot];
  float texel = params.y;
  vec3 toSpot = normalize(light.xyz - worldPosition);
  vec3 position =
    worldPosition + normal * (texel * 1.2) + toSpot * (texel * params.z);
  vec4 clip =
    FLAME_SHADOWS(atlasSpotViewProjections)[slot] * vec4(position, 1.0);
  if (clip.w <= 0.0) {
    return 1.0;
  }
  vec3 ndc = clip.xyz / clip.w;
  vec2 uv = vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y);
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 ||
      ndc.z < 0.0 || ndc.z > 1.0) {
    return 1.0;
  }
  return flameSampleAtlasTile(
    uv,
    FLAME_SHADOWS(atlasSpotRects)[slot],
    ndc.z,
    flameShadowFilterRadius(light.w)
  );
}

// The atlas tile of the spot light at `index`, or -1.
int flameAtlasSpotSlot(int index) {
  int count = int(FLAME_SHADOWS(atlas).z);
  for (int s = 0; s < 2; s++) {
    if (s >= count) {
      break;
    }
    if (abs(FLAME_SHADOWS(atlasSpotParams)[s].x - float(index)) < 0.25) {
      return s;
    }
  }
  return -1;
}

// The visibility of the point light whose shadows the atlas holds.
float flameAtlasPointVisibility(vec3 worldPosition, vec3 normal) {
  vec4 light = FLAME_SHADOWS(atlasPointPosition);
  vec4 params = FLAME_SHADOWS(atlasPointParams);
  vec3 fromLight = worldPosition + normal * 0.03 - light.xyz;
  float dist = length(fromLight);
  float linearDepth = dist * light.w - params.x * 0.004;
  if (linearDepth >= 1.0 || dist <= 1e-4) {
    return 1.0;
  }
  vec3 dir = fromLight / dist;
  vec4 rect = dir.z >= 0.0
    ? FLAME_SHADOWS(atlasPointRects)[0]
    : FLAME_SHADOWS(atlasPointRects)[1];
  float hz = abs(dir.z);
  vec2 p = (dir.xy / (hz + 1.0)) * 0.96;
  vec2 tileUv = vec2(0.5 + 0.5 * p.x, 0.5 - 0.5 * p.y);
  float radius = flameShadowFilterRadius(min(params.y, 2.0));
  return flameSampleAtlasTile(
    tileUv,
    rect,
    clamp(linearDepth, 0.0, 1.0),
    radius
  );
}
#endif

// The fraction of the light of the directional light that casts shadows (or
// of a lone spot light, see spotShadowFactor) reaching a surface at
// `worldPosition` whose unit normal is `normal`: from 0 (in shadow) to 1
// (lit), with soft edges, and 1 when the pass has no shadows. `cascade` is
// set to the cascade of the atlas that gave it, or -1.
float shadowCascadeVisibility(
  vec3 worldPosition,
  vec3 normal,
  out int cascade
) {
  cascade = -1;
  if (FLAME_SHADOWS(toLight).w < 0.0) {
    return 1.0;
  }
#ifndef FLAME_SHADOWS_SINGLE_MAP
  if (shadowAtlasActive()) {
    return flameAtlasCascadeVisibility(worldPosition, normal, cascade);
  }
#endif
  return flameSingleMapVisibility(worldPosition, normal);
}

// The fraction of the light of the directional light that casts shadows
// reaching a surface at `worldPosition` whose unit normal is `normal`: from
// 0 (in shadow) to 1 (lit), with soft edges, and 1 when the pass has no
// shadows. See shadowCascadeVisibility.
float shadowVisibility(vec3 worldPosition, vec3 normal) {
  int cascade;
  return shadowCascadeVisibility(worldPosition, normal, cascade);
}

// What the light that casts shadows is multiplied by where `visibility` of
// it reaches a surface: 1 where it is lit, `mix(1, color, strength)` where it
// is in shadow.
vec3 shadowFactor(float visibility) {
  return mix(
    vec3(1.0),
    FLAME_SHADOWS(color).rgb,
    FLAME_SHADOWS(color).a * (1.0 - visibility)
  );
}

// Whether the directional light at `index` is the one that casts shadows.
bool castsShadows(int index) {
  return float(index) == FLAME_SHADOWS(toLight).w;
}

// Whether the spot light at `index` casts shadows in this pass.
bool spotCastsShadows(int index) {
#ifndef FLAME_SHADOWS_SINGLE_MAP
  if (shadowAtlasActive()) {
    return flameAtlasSpotSlot(index) >= 0;
  }
#endif
  return abs(FLAME_SHADOWS(toLight).w - (100.0 + float(index))) < 0.25;
}

// What the light of the spot light at `index` is multiplied by at
// `worldPosition` (whose unit normal is `normal`): 1 where it is lit or casts
// no shadows, `mix(1, color, strength)` where it is in shadow.
vec3 spotShadowFactor(int index, vec3 worldPosition, vec3 normal) {
#ifndef FLAME_SHADOWS_SINGLE_MAP
  if (shadowAtlasActive()) {
    int slot = flameAtlasSpotSlot(index);
    if (slot < 0) {
      return vec3(1.0);
    }
    float visibility = flameAtlasSpotVisibility(slot, worldPosition, normal);
    return mix(
      vec3(1.0),
      FLAME_SHADOWS(atlasSpotColors)[slot].rgb,
      FLAME_SHADOWS(atlasSpotParams)[slot].w * (1.0 - visibility)
    );
  }
#endif
  return spotCastsShadows(index)
    ? shadowFactor(shadowVisibility(worldPosition, normal))
    : vec3(1.0);
}

// Whether the point light at `index` casts shadows in this pass.
bool pointCastsShadows(int index) {
#ifndef FLAME_SHADOWS_SINGLE_MAP
  return shadowAtlasActive() &&
    abs(FLAME_SHADOWS(atlas).w - float(index)) < 0.25;
#else
  return false;
#endif
}

// What the light of the point light at `index` is multiplied by at
// `worldPosition` (whose unit normal is `normal`): 1 where it is lit or casts
// no shadows, `mix(1, color, strength)` where it is in shadow.
vec3 pointShadowFactor(int index, vec3 worldPosition, vec3 normal) {
#ifndef FLAME_SHADOWS_SINGLE_MAP
  if (pointCastsShadows(index)) {
    float visibility = flameAtlasPointVisibility(worldPosition, normal);
    return mix(
      vec3(1.0),
      FLAME_SHADOWS(atlasPointColor).rgb,
      FLAME_SHADOWS(atlasPointParams).z * (1.0 - visibility)
    );
  }
#endif
  return vec3(1.0);
}

#ifndef FLAME_SHADOWS_SINGLE_MAP
// The largest `strength * (1 - visibility)` of the spot and point lights of
// the atlas at `worldPosition`, without their reach or cone; 0 without the
// atlas.
float atlasSpotAndPointOcclusion(vec3 worldPosition, vec3 normal) {
  float occlusion = 0.0;
  if (!shadowAtlasActive()) {
    return occlusion;
  }
  int spots = int(FLAME_SHADOWS(atlas).z);
  for (int s = 0; s < 2; s++) {
    if (s >= spots) {
      break;
    }
    float visibility = flameAtlasSpotVisibility(s, worldPosition, normal);
    occlusion = max(
      occlusion,
      FLAME_SHADOWS(atlasSpotParams)[s].w * (1.0 - visibility)
    );
  }
  if (FLAME_SHADOWS(atlas).w >= 0.0) {
    float visibility = flameAtlasPointVisibility(worldPosition, normal);
    occlusion = max(
      occlusion,
      FLAME_SHADOWS(atlasPointParams).z * (1.0 - visibility)
    );
  }
  return occlusion;
}
#endif

// How much shadow, of any light that casts shadows in this pass, falls on a
// surface at `worldPosition` whose unit normal is `normal`: the largest
// `strength * (1 - visibility)` of the lights, from 0 (lit by all of them)
// to 1, without their reach or cone (what ShadowCatcherMaterial shows).
float shadowOcclusion(vec3 worldPosition, vec3 normal) {
  float occlusion = FLAME_SHADOWS(color).a *
    (1.0 - shadowVisibility(worldPosition, normal));
#ifndef FLAME_SHADOWS_SINGLE_MAP
  occlusion = max(
    occlusion,
    atlasSpotAndPointOcclusion(worldPosition, normal)
  );
#endif
  return occlusion;
}

#endif
