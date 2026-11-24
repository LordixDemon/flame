#ifndef FLAME_STYLIZED_MATERIAL_FRAGMENT_GLSL_
#define FLAME_STYLIZED_MATERIAL_FRAGMENT_GLSL_

// The fragment stage of StylizedMaterial: vertex-colored surfaces lit by the
// hemisphere, directional, point and spot lights of the scene (and those of
// its light grid, see flame_3d/light_grid.glsl), with per-vertex
// masks for the instance tint, the accent color, emission and gloss, and per
// instance data for an emissive boost, a highlight, a fade and optional
// per-instance accent and rim palette indices. The emissive mask glows in the
// material's emissive color or in a color of the instance.

in vec3 fragPosition;
in vec3 fragNormal;
in vec4 fragColor;
in vec4 fragMasks;
in float fragOcclusion;
in vec4 fragInstanceColor;
// x: the emissive boost, y: the highlight, z: the palette slot, w: the fade,
// decoded by the vertex stage, see flame_3d/stylized_instance_data.glsl.
in vec4 fragInstanceData;
// The instance color less its nearest multiple of 2^-16, see
// flame_3d/stylized_instance_data.glsl. Last, so that the inputs of before
// keep their locations.
in vec3 fragInstanceColorFine;
#ifdef FLAME_STYLIZED_TEXTURED
// The texture coordinates of the base color texture, in the textured stages
// (StylizedMaterial.baseColorTexture) only.
in vec2 fragTexCoord;
#endif

out vec4 outColor;

#ifdef FLAME_STYLIZED_MATCAP_ATLAS
uniform sampler2D matCapAtlasTexture;
#else
uniform sampler2D matCapTexture;
uniform sampler2D gemMatCapTexture;
#endif
#ifdef FLAME_STYLIZED_TEXTURED
uniform sampler2D baseColorTexture;
#endif

uniform Material {
  vec4 albedoColor;
  vec4 accentColor;
  vec4 accentPalette[16];
  // rgb: color, a: strength.
  vec4 rimPalette[8];
  vec4 emissiveColor;
  vec4 emissiveBoostColor;
  vec4 ambientBase;
  vec4 skyFill;
  vec4 rimColor;
  vec4 highlightColor;
  vec4 overlayColor;
  float emissiveStrength;
  float groundBounce;
  float pointLightWrap;
  float specularStrength;
  float specularPower;
  float specularThreshold;
  float rimStrength;
  float rimPower;
  float matCapStrength;
  float matCapThreshold;
  float matCapGlossWeight;
  float gemMatCapStrength;
  float gemThreshold;
  float matCapMetallic;
  float saturation;
  float accentPaletteCount;
  float ditherFade;
  float rimPaletteCount;
  float rimPalettePower;
  float rimPaletteStrength;
  // Where the emissive mask takes its glow color (the color the boost moves
  // from), StylizedMaterial.emissiveColorSource: 0 emissiveColor, 1 the
  // instance color, 2 the instance's accent, 3 its rim palette entry.
  float emissiveColorSource;
  // 1 when the boost moves towards that same color (emissiveBoostColor is
  // null), 0 when it moves towards emissiveBoostColor.
  float emissiveBoostFollows;
#ifdef FLAME_STYLIZED_TEXTURED
  // StylizedMaterial.baseColorTextureMode: 0 when the texture multiplies the
  // vertex color, 1 when it replaces it.
  float baseColorReplace;
  // StylizedMaterial.alphaCutoff: pixels whose alpha is below it are
  // discarded (0 keeps every pixel).
  float alphaCutoff;
#endif
} material;

// The camera, the lights, the shadows and the fog of the render pass, filled
// by flame_3d once per pass.
uniform StylizedPass {
  mat4 Camera_view;
  mat4 Camera_projection;
  mat4 Shadows_lightViewProjection;
  mat4 Shadows_cascadeViewProjection;
  vec4 Shadows_toLight;
  vec4 Shadows_color;
  vec4 Shadows_map;
  vec4 Shadows_bias;
  vec4 Shadows_decode;
  vec4 Shadows_cascadeParams;
  vec4 Shadows_atlas;
  mat4 Shadows_atlasCascadeViewProjections[4];
  vec4 Shadows_atlasCascadeRects[4];
  vec4 Shadows_atlasCascadeParams[4];
  mat4 Shadows_atlasSpotViewProjections[2];
  vec4 Shadows_atlasSpotRects[2];
  vec4 Shadows_atlasSpotParams[2];
  vec4 Shadows_atlasSpotPositions[2];
  vec4 Shadows_atlasSpotColors[2];
  vec4 Shadows_atlasPointPosition;
  vec4 Shadows_atlasPointRects[2];
  vec4 Shadows_atlasPointParams;
  vec4 Shadows_atlasPointColor;
  vec4 Fog_color;
  vec4 Fog_params;
  vec4 Fog_height;
  vec4 AmbientLight_color;
  vec4 HemisphereLight_skyColor;
  vec4 HemisphereLight_groundColor;
  vec3 HemisphereLight_up;
  float HemisphereLight_intensity;
  vec3 Camera_position;
  float AmbientLight_intensity;
  vec4 DirectionalLights_directions[4];
  vec4 DirectionalLights_colors[4];
  vec3 Lights_positions[8];
  vec4 Lights_colors[8];
  vec4 Lights_intensities[8];
  vec4 Lights_ranges[8];
  vec3 SpotLights_positions[4];
  vec4 SpotLights_directions[4];
  vec4 SpotLights_colors[4];
  vec4 SpotLights_cones[4];
  float Lights_numLights;
  float DirectionalLights_numLights;
  float SpotLights_numLights;
  // The body of water of the pass, see flame_3d/water_volume.glsl. Last, so
  // that the members of before keep their offsets.
  vec4 WaterVolume_plane;
  vec4 WaterVolume_shallow;
  vec4 WaterVolume_deep;
  vec4 WaterVolume_caustics;
  vec4 WaterVolume_causticColor;
  vec4 WaterVolume_waterline;
  vec4 WaterVolume_boundsMin;
  vec4 WaterVolume_boundsMax;
  vec4 WaterVolume_waterlineFoam;
  // The light grid of the pass, see flame_3d/light_grid.glsl. Last, so that
  // the members of before keep their offsets.
  vec4 LightGrid_origin;
  vec4 LightGrid_cells;
  vec4 LightGrid_data;
  vec4 LightGrid_counts;
} scene;

#define FLAME_SHADOWS(member) scene.Shadows_##member
#include <flame_3d/shadows.glsl>

#define FLAME_FOG(member) scene.Fog_##member
#include <flame_3d/fog.glsl>
#include <flame_3d/dither.glsl>

#define FLAME_WATER_VOLUME(member) scene.WaterVolume_##member
#include <flame_3d/water_volume.glsl>

#define FLAME_LIGHT_GRID(member) scene.LightGrid_##member
#include <flame_3d/light_grid.glsl>

// The instance color as the instance holds it. `fragInstanceColor` arrives
// interpolated across the triangle (or extrapolated to the MSAA samples
// outside it), and so a few ulps off. Less the fine part, it is a few ulps
// from a multiple of 2^-16, which rounding finds exactly; the fine part is at
// most 2^-17, so its own interpolation error is far below the precision of
// the color, and adding it back gives the color itself. Only channels below
// about 2^-13 may stay a float step off: those of 8-bit colors are exact.
vec3 stylizedExactInstanceColor() {
  vec3 coarse = floor(
    (fragInstanceColor.rgb - fragInstanceColorFine) * 65536.0 + 0.5
  ) * (1.0 / 65536.0);
  return coarse + fragInstanceColorFine;
}

float pictureMirror() {
  mat4 p = scene.Camera_projection;
  vec3 rowX = vec3(p[0][0], p[1][0], p[2][0]);
  vec3 rowY = vec3(p[0][1], p[1][1], p[2][1]);
  vec3 rowW = vec3(p[0][3], p[1][3], p[2][3]);
  vec3 rowZ = vec3(p[0][2], p[1][2], p[2][2]);
  vec3 rowR = dot(rowW, rowW) > 1e-12 ? rowW : rowZ;
  return dot(rowX, cross(rowY, rowR)) > 0.0 ? -1.0 : 1.0;
}

void main() {
#ifdef FLAME_STYLIZED_TEXTURED
  // The surface color: the vertex color times the base color texture, or the
  // texture alone. Sampled first, in uniform control flow.
  vec4 texel = texture(baseColorTexture, fragTexCoord);
  vec4 surfaceColor =
    mix(fragColor, vec4(1.0), material.baseColorReplace) * texel;
#define FLAME_STYLIZED_SURFACE_COLOR surfaceColor
#else
#define FLAME_STYLIZED_SURFACE_COLOR fragColor
#endif
  vec3 n = normalize(fragNormal);
  vec3 v;
  if (scene.Camera_projection[3][3] > 0.5) {
    mat4 view = scene.Camera_view;
    v = normalize(vec3(view[0][2], view[1][2], view[2][2]));
  } else {
    v = normalize(scene.Camera_position - fragPosition);
  }

  float tintMask = fragMasks.x;
  float accentMask = fragMasks.y;
  float emissiveMask = fragMasks.z;
  float gloss = fragMasks.w;

  float boost = fragInstanceData.x;
  float highlight = fragInstanceData.y;

  // The vertex stage decoded the `instanceData.w` packed by
  // `StylizedMaterial.packPaletteAndFade` into the palette slot `a + 17 * r`
  // (z), with `a` and `r` the accent and rim palette indices plus one (`0`:
  // none), and the fade (w), see flame_3d/stylized_instance_data.glsl: the
  // instances pick from `material.accentPalette` and `material.rimPalette`
  // without breaking instanced batching. The slot is a whole number,
  // interpolated: rounded to the nearest, it is exact.
  int slot = int(floor(max(fragInstanceData.z, 0.0) + 0.5));
  int rimSlot = slot / 17;
  int accentIndex = slot - rimSlot * 17 - 1;
  vec3 instanceAccent = material.accentColor.rgb;
  if (accentIndex >= 0 && accentIndex < int(material.accentPaletteCount) &&
      accentIndex < 16) {
    instanceAccent = material.accentPalette[accentIndex].rgb;
  }
  int rimIndex = rimSlot - 1;
  bool hasRim = rimIndex >= 0 && rimIndex < int(material.rimPaletteCount) &&
    rimIndex < 8;
  float fade = clamp(fragInstanceData.w, 0.0, 1.0);

  vec3 base = material.albedoColor.rgb * FLAME_STYLIZED_SURFACE_COLOR.rgb;
  base *= mix(vec3(1.0), fragInstanceColor.rgb, tintMask);
  base *= mix(vec3(1.0), instanceAccent, accentMask);

  float nUp = clamp(dot(n, scene.HemisphereLight_up), -1.0, 1.0);
  float hemi = 0.5 + 0.5 * nUp;
  float bounce = max(-nUp, 0.0);
  vec3 ambient =
    scene.AmbientLight_color.rgb * scene.AmbientLight_intensity +
    scene.HemisphereLight_intensity * (
      material.ambientBase.rgb +
      material.skyFill.rgb * hemi * scene.HemisphereLight_skyColor.rgb +
      material.groundBounce * bounce * scene.HemisphereLight_groundColor.rgb
    );
  vec3 lit = fragOcclusion * ambient;

  float specular = 0.0;
  bool glossy = gloss > material.specularThreshold;
  vec3 sunShadow = vec3(1.0);
  int shadowed = int(scene.Shadows_toLight.w);
  if (shadowed >= 0 && shadowed < int(scene.DirectionalLights_numLights) &&
      (glossy ||
       dot(n, scene.DirectionalLights_directions[shadowed].xyz) > 0.0)) {
    sunShadow = shadowFactor(shadowVisibility(fragPosition, n));
  }
  // The direct light of the directional lights alone, for the caustics of a
  // water volume.
  // The direct light of the directional lights alone, and the direction of
  // the one that casts shadows (or of the first), for the caustics of a water
  // volume.
  vec3 sunDirect = vec3(0.0);
  vec3 sunDirection = scene.WaterVolume_plane.xyz;
  int sunIndex =
    shadowed >= 0 && shadowed < int(scene.DirectionalLights_numLights)
      ? shadowed
      : 0;
  for (int i = 0; i < int(scene.DirectionalLights_numLights); i++) {
    vec4 direction = scene.DirectionalLights_directions[i];
    vec4 lightColor = scene.DirectionalLights_colors[i];
    vec3 shadow = castsShadows(i) ? sunShadow : vec3(1.0);
    vec3 direct = max(dot(n, direction.xyz), 0.0) * lightColor.a *
      lightColor.rgb * shadow;
    lit += direct;
    sunDirect += direct;
    if (i == sunIndex) {
      sunDirection = direction.xyz;
    }
    if (glossy) {
      float ndoth = max(dot(n, normalize(direction.xyz + v)), 0.0);
      specular += pow(ndoth, material.specularPower) * direction.w *
        (shadow.r + shadow.g + shadow.b) / 3.0;
    }
  }
  specular *= gloss * material.specularStrength;

  int blockPoints = int(lightGridBlockPointLights(scene.Lights_numLights));
  for (int i = 0; i < blockPoints; i++) {
    vec3 toLight = scene.Lights_positions[i] - fragPosition;
    float dist = length(toLight);
    vec3 l = toLight / max(dist, 0.0001);
    float range = scene.Lights_ranges[i].x;
    float falloff;
    if (range > 0.0) {
      float rangeFade = max(1.0 - dist / range, 0.0);
      falloff = rangeFade * rangeFade;
    } else {
      falloff = 1.0 / max(dist * dist, 0.00000001);
    }
    float wrapped = max(material.pointLightWrap, dot(n, l));
    lit += scene.Lights_intensities[i].x * falloff * wrapped *
      scene.Lights_colors[i].rgb * pointShadowFactor(i, fragPosition, n);
  }

  // The point lights of the light grid listed by this fragment's cell, as
  // above (they have a range and cast no shadows).
  vec4 gridCell = lightGridCell(fragPosition);
  for (int k = 0; k < LIGHT_GRID_POINT_LIGHTS_PER_CELL; k++) {
    if (float(k) >= gridCell.y) {
      break;
    }
    vec4 gridPosition;
    vec4 gridColor;
    lightGridPointLight(gridCell, k, gridPosition, gridColor);
    vec3 toLight = gridPosition.xyz - fragPosition;
    float dist = length(toLight);
    float rangeFade = max(1.0 - dist / gridPosition.w, 0.0);
    if (rangeFade <= 0.0) {
      continue;
    }
    vec3 l = toLight / max(dist, 0.0001);
    float falloff = rangeFade * rangeFade;
    float wrapped = max(material.pointLightWrap, dot(n, l));
    lit += gridColor.a * falloff * wrapped * gridColor.rgb;
  }

  float spotSpecular = 0.0;
  int blockSpots = int(lightGridBlockSpotLights(scene.SpotLights_numLights));
  for (int i = 0; i < blockSpots; i++) {
    vec3 toLight = scene.SpotLights_positions[i] - fragPosition;
    float dist = length(toLight);
    vec3 l = toLight / max(dist, 0.0001);
    vec4 spotDir = scene.SpotLights_directions[i];
    vec4 spotCone = scene.SpotLights_cones[i];
    float cosTheta = dot(l, spotDir.xyz);
    float angular = clamp((cosTheta - spotCone.x) * spotCone.y, 0.0, 1.0);
    angular *= angular;
    if (angular > 0.0) {
      float range = spotCone.z;
      float falloff;
      if (range > 0.0) {
        float rf = max(1.0 - dist / range, 0.0);
        falloff = rf * rf;
      } else {
        falloff = 1.0 / max(dist * dist, 0.00000001);
      }
      vec4 spotColor = scene.SpotLights_colors[i];
      vec3 spotSh = spotShadowFactor(i, fragPosition, n);
      float atten = spotColor.a * falloff * angular;
      float wrapped = max(material.pointLightWrap * 0.5, dot(n, l));
      lit += atten * max(wrapped, 0.0) * spotColor.rgb * spotSh;
      if (glossy && dot(n, l) > 0.0) {
        float ndoth = max(dot(n, normalize(l + v)), 0.0);
        spotSpecular += pow(ndoth, material.specularPower) * spotDir.w * atten *
          (spotSh.r + spotSh.g + spotSh.b) / 3.0;
      }
    }
  }
  // The spot lights of the light grid listed by this fragment's cell.
  for (int k = 0; k < LIGHT_GRID_SPOT_LIGHTS_PER_CELL; k++) {
    if (float(k) >= gridCell.w) {
      break;
    }
    vec4 gridPosition;
    vec4 gridColor;
    vec4 spotDir;
    vec4 spotCone;
    lightGridSpotLight(
      gridCell,
      k,
      gridPosition,
      gridColor,
      spotDir,
      spotCone
    );
    vec3 toLight = gridPosition.xyz - fragPosition;
    float dist = length(toLight);
    float rf = max(1.0 - dist / gridPosition.w, 0.0);
    if (rf <= 0.0) {
      continue;
    }
    vec3 l = toLight / max(dist, 0.0001);
    float cosTheta = dot(l, spotDir.xyz);
    float angular = clamp((cosTheta - spotCone.x) * spotCone.y, 0.0, 1.0);
    angular *= angular;
    if (angular > 0.0) {
      float falloff = rf * rf;
      float atten = gridColor.a * falloff * angular;
      float wrapped = max(material.pointLightWrap * 0.5, dot(n, l));
      lit += atten * max(wrapped, 0.0) * gridColor.rgb;
      if (glossy && dot(n, l) > 0.0) {
        float ndoth = max(dot(n, normalize(l + v)), 0.0);
        spotSpecular += pow(ndoth, material.specularPower) * spotDir.w * atten;
      }
    }
  }
  specular += spotSpecular * gloss * material.specularStrength;

  float ndotv = clamp(dot(n, v), 0.0, 1.0);
  float fresnel = pow(1.0 - ndotv, material.rimPower);
  vec3 rim = fresnel * material.rimStrength *
    (scene.HemisphereLight_skyColor.rgb + material.rimColor.rgb);

  // Sample each MatCap texture in its own uniform-only branch so materials
  // without a gem MatCap (or without a coat MatCap) skip the unused texture
  // fetch completely while keeping well-defined derivatives.
  vec3 coat = vec3(0.0);
  vec3 gem = vec3(0.0);
  bool hasCoat = material.matCapStrength != 0.0;
  bool hasGem = material.gemMatCapStrength != 0.0;
  if (hasCoat || hasGem) {
    vec3 viewNormal = normalize(mat3(scene.Camera_view) * n);
    viewNormal.x *= pictureMirror();
    vec2 matCapUv = vec2(0.5 + 0.5 * viewNormal.x, 0.5 - 0.5 * viewNormal.y);
#ifdef FLAME_STYLIZED_MATCAP_ATLAS
    float clampedX = clamp(matCapUv.x, 0.004, 0.996);
    if (hasCoat) {
      coat = texture(
        matCapAtlasTexture,
        vec2(clampedX * 0.5, matCapUv.y)
      ).rgb * material.matCapStrength *
        mix(1.0, gloss, material.matCapGlossWeight);
    }
    if (hasGem) {
      gem = texture(
        matCapAtlasTexture,
        vec2(0.5 + clampedX * 0.5, matCapUv.y)
      ).rgb * material.gemMatCapStrength;
    }
#else
    if (hasCoat) {
      coat = texture(matCapTexture, matCapUv).rgb * material.matCapStrength *
        mix(1.0, gloss, material.matCapGlossWeight);
    }
    if (hasGem) {
      gem = texture(gemMatCapTexture, matCapUv).rgb *
        material.gemMatCapStrength;
    }
#endif
  }
  float gemWeight = gloss > material.gemThreshold ? 1.0 : 0.0;
  float coatWeight = gloss > material.matCapThreshold ? 1.0 - gemWeight : 0.0;
  vec3 matCap = coatWeight * coat + gemWeight * gem;

  vec3 surface = base * lit + rim;
  vec3 reflected = mix(vec3(1.0), matCap, coatWeight + gemWeight);
  vec3 color = mix(
    surface + matCap,
    min(surface, vec3(1.0)) * reflected,
    material.matCapMetallic
  ) + vec3(specular) + highlight * material.highlightColor.rgb;
  if (hasRim) {
    vec4 rimEntry = material.rimPalette[rimIndex];
    color += pow(1.0 - ndotv, material.rimPalettePower) * rimEntry.rgb *
      (rimEntry.a * material.rimPaletteStrength);
  }
  // The glow color: the material's emissive color, or the instance's color,
  // accent (its palette entry, or accentColor) or rim palette entry (or the
  // emissive color without one), each exact on every pixel. The boost moves it
  // towards emissiveBoostColor, or keeps it. Only the color depends on the
  // source: the glow still mixes the shaded color towards it.
  int glowSource = int(material.emissiveColorSource + 0.5);
  vec3 glowColor = material.emissiveColor.rgb;
  if (glowSource == 1) {
    glowColor = stylizedExactInstanceColor();
  } else if (glowSource == 2) {
    glowColor = instanceAccent;
  } else if (glowSource == 3 && hasRim) {
    glowColor = material.rimPalette[rimIndex].rgb;
  }
  vec3 boostColor = material.emissiveBoostFollows > 0.5
    ? glowColor
    : material.emissiveBoostColor.rgb;
  vec3 emissive = mix(glowColor, boostColor, clamp(boost, 0.0, 1.0));
  float glow = clamp(
    emissiveMask * (material.emissiveStrength + boost),
    0.0,
    1.0
  );
  color = clamp(mix(color, emissive, glow), 0.0, 1.0);

  if (material.saturation != 1.0) {
    float luminosity = dot(color, vec3(0.3, 0.59, 0.11));
    color = clamp(mix(vec3(luminosity), color, material.saturation), 0.0, 1.0);
  }
  if (material.overlayColor.a > 0.0) {
    color = mix(color, material.overlayColor.rgb, material.overlayColor.a);
  }

  // Below the level of the pass's water volume: tinted and darkened with the
  // depth, with caustics, and foam where the surface crosses the level.
  if (waterVolumeActive()) {
    color = applyWaterVolume(
      color,
      base,
      lit,
      sunDirect,
      sunDirection,
      fragPosition,
      n
    );
  }

  color = applyFog(
    color,
    fragPosition,
    scene.Camera_view,
    scene.Camera_projection,
    scene.Camera_position
  );

#ifdef FLAME_STYLIZED_TEXTURED
  // Masked (an alpha cutoff above 0): the pixels whose own alpha is below
  // the cutoff are discarded and the others are opaque, as glTF's MASK alpha
  // mode draws them; the instance alpha and the fade still apply.
  float surfaceAlpha = material.albedoColor.a * surfaceColor.a;
  if (material.alphaCutoff > 0.0) {
    if (surfaceAlpha < material.alphaCutoff) {
      discard;
    }
    surfaceAlpha = 1.0;
  }
  float alpha = surfaceAlpha * fragInstanceColor.a * (1.0 - fade);
#else
  float alpha = material.albedoColor.a * fragColor.a * fragInstanceColor.a *
    (1.0 - fade);
#endif
  if (material.ditherFade > 0.5) {
    if (alpha < bayerDither4x4(gl_FragCoord.xy)) {
      discard;
    }
    outColor = vec4(color, 1.0);
  } else {
    outColor = vec4(color * alpha, alpha);
  }
}

#endif
