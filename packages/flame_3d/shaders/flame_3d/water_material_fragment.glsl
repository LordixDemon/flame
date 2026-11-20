#ifndef FLAME_WATER_MATERIAL_FRAGMENT_GLSL_
#define FLAME_WATER_MATERIAL_FRAGMENT_GLSL_

// The fragment stage of WaterMaterial: stylized + physically-inspired water
// with dual scrolling micro-ripples, a shallow/deep gradient, crest foam, a
// Fresnel blend towards the flat sky color, directional, point and spot light
// glints, shadows, Grab-Pass underwater refraction and fog.
//
// Its options, all off by default (the pixels are then those of before they
// existed): a caustic network, sparkles, a gentle swell of the normals, a
// color and opacity ramp by the depth of the water under each vertex, foam
// where the vertices' foam mask says, rings of ripples (WaterRipples), collars
// of foam around moving things (WaterFoamSources), how much of the light's
// color the lit foam takes, how fast the mask's foam moves and the least light
// it takes.
// They are procedural (flame_3d/water_pattern.glsl) and need neither the
// depth prepass nor the scene color grab.

in vec3 fragPosition;
in vec3 fragNormal;
in vec2 fragUv;
in vec4 fragColor;
in float fragCrest;
in vec4 fragClipPos;
// x: depth of the water under the fragment, y: foam mask, z: calm, see
// flame_3d/water_vertex.glsl.
in vec3 fragWater;
// Where the foam sources reach: |xy|² + z < 0 where one may, see
// flame_3d/water_vertex.glsl.
in vec3 fragFoamGate;

out vec4 outColor;

uniform sampler2D depthNormalTexture;
uniform sampler2D sceneColorTexture;

uniform DepthNormal {
  vec4 params;
} depthNormal;

uniform SceneColor {
  // x: active (1=on, 0=off), y: 1/width, z: 1/height, w: unused
  vec4 params;
} sceneColor;

uniform WaterMaterial {
  vec4 shallowColor;
  vec4 deepColor;
  vec4 foamColor;
  // x: time, y: rippleStrength, z: foamThreshold, w: specularPower
  vec4 params;
  // x: fresnelPower, y: specularStrength, z: opacity, w: rippleScale
  vec4 params2;
  // x: shoreFoamDepth (clip-depth span), y: refractionStrength, z: the phase
  // of the foam of the foam mask and of the foam sources (0 to 2π, slowed
  // down by edgeFoamMotion), w: how much of the light's color the lit foam
  // takes (foamLightTint, 0 to 1).
  vec4 shoreParams;
  // xyz: the world up axis of the rest surface (unit), w: the least light the
  // lit foam takes, a multiple of its color (foamLightFloor, 0.5 by default).
  vec4 upAxis;
  // The options. rgb: the caustics' color, a: their strength.
  vec4 causticColor;
  // x: the phase of the patterns' period (0 to 2π), y: 1 / causticScale,
  // z: sparkleStrength, w: 1 / sparkleScale.
  vec4 pattern;
  // x: detailStrength, y: 1 / detailScale, z: 1 / edgeFoamScale,
  // w: 1 when an option that adds light (caustics, sparkles, ripples) is on.
  vec4 detail;
  // x: 1 / depthRange (0: the ramp is off), y: shallowOpacity, z: the number
  // of foam sources in `foamSourcePositions` and `foamSourceShapes`, w: the
  // number of ripples in `ripplePositions` and `rippleShapes`.
  vec4 ramp;
  // Per ripple, xy: its center in the plane coordinates of the water, z: its
  // age in seconds, w: its strength now (faded with its age).
  vec4 ripplePositions[8];
  // Per ripple, x: the radius of its front, y: 1 / its wavelength, z: its
  // width behind the front in wavelengths, w: unused.
  vec4 rippleShapes[8];
  // Per foam source, xy: its center in the plane coordinates of the water,
  // zw: the unit direction of its length in those coordinates, divided by
  // the width of its foam.
  vec4 foamSourcePositions[16];
  // Per foam source, in widths of its foam, xy: the half length and half
  // width of the straight part of its outline, z: the radius of its corners;
  // w: its strength.
  vec4 foamSourceShapes[16];
} waterMat;

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
} scene;

#define FLAME_SHADOWS(member) scene.Shadows_##member
#include <flame_3d/shadows.glsl>

#define FLAME_FOG(member) scene.Fog_##member
#include <flame_3d/fog.glsl>

#include <flame_3d/water_pattern.glsl>

// The rings of the ripples at the plane coordinates `uv`: adds the slope of
// the water they raise to `slope` and returns how high their crests are
// there (0 to about 1).
float waterRippleRings(vec2 uv, inout vec2 slope) {
  float crest = 0.0;
  int count = int(waterMat.ramp.w + 0.5);
  for (int i = 0; i < 8; i++) {
    if (i >= count) {
      break;
    }
    vec4 position = waterMat.ripplePositions[i];
    vec4 shape = waterMat.rippleShapes[i];
    vec2 d = uv - position.xy;
    float r = length(d);
    // Wavelengths from the front: positive ahead of it, negative behind.
    float x = (r - shape.x) * shape.y;
    if ((x > 0.6 || x < -shape.z) && position.z > 0.34) {
      continue;
    }
    // A packet of waves that rises sharply at the front and dies out over
    // `shape.z` wavelengths behind it.
    float ahead = clamp(1.0 - max(x, 0.0) / 0.6, 0.0, 1.0);
    float behind = clamp(1.0 + x / shape.z, 0.0, 1.0);
    float envelope = ahead * behind * behind * position.w;
    float wave = sin(x * WATER_TAU);
    crest += max(wave, 0.0) * envelope;
    // A splash of foam where it started, for its first third of a second.
    float splash = max(1.0 - position.z * 3.0, 0.0);
    if (splash > 0.0) {
      float reach = shape.x - (shape.x - 0.04) * splash;
      crest += position.w * splash * (1.6 - 1.6 * smoothstep(0.0, reach, r));
    }
    // d(height)/dr, along the direction away from the center.
    float dhdr = cos(x * WATER_TAU) * WATER_TAU * shape.y * envelope;
    slope += d / max(r, 1e-3) * (dhdr * 0.04);
  }
  return crest;
}

// The foam mask of the foam sources at the plane coordinates `uv`: per
// source, its strength inside and against its outline (a rectangle with
// rounded corners, a circle when it has no straight part), falling to 0 at
// the width of its foam from it, `1 - smoothstep(0, width, distance)`; the
// largest of them.
float waterFoamSources(vec2 uv) {
  float mask = 0.0;
  int count = int(waterMat.ramp.z + 0.5);
  for (int i = 0; i < 16; i++) {
    if (i >= count) {
      break;
    }
    vec4 position = waterMat.foamSourcePositions[i];
    vec4 shape = waterMat.foamSourceShapes[i];
    vec2 d = uv - position.xy;
    // Along and across the source, in widths of its foam.
    vec2 local = abs(vec2(
      dot(d, position.zw),
      dot(d, vec2(-position.w, position.z))
    ));
    vec2 q = local - shape.xy;
    // Beyond the box around its reach: no foam (the distance below is more
    // than 1).
    if (max(q.x, q.y) > shape.z + 1.0) {
      continue;
    }
    // The signed distance to the outline, negative inside.
    float outside = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - shape.z;
    if (outside < 1.0) {
      mask = max(mask, shape.w * (1.0 - smoothstep(0.0, 1.0, outside)));
    }
  }
  return mask;
}

// The foam where the vertices' foam mask is above 0: a band whose inner edge
// laps in and out and is broken up into drifting patches.
float waterEdgeFoam(float mask, vec2 uv, float phase) {
  vec2 p = uv * waterMat.detail.z * WATER_TAU;
  float noise = waterNoise(p, phase);
  float fine = waterNoise(p * 3.1 + vec2(3.1, 1.7), -2.0 * phase);
  // The band laps towards the edge and back twice per period, more in some
  // places than in others.
  float lap = (0.07 + 0.05 * noise) * sin(phase * 2.0 - mask * 4.0 + noise);
  float field = mask + lap + 0.16 * noise + 0.12 * fine;
  float band = smoothstep(0.66, 0.74, field);
  // A few holes in the band, and loose flecks in front of it.
  float lace = smoothstep(-0.45, -0.05, fine + 0.8 * (mask - 0.8));
  float flecks = smoothstep(0.8, 0.9, fine * 0.7 + noise * 0.3 + mask * 0.5);
  return max(band * lace, flecks * 0.7);
}

void main() {
  float t = waterMat.params.x;
  float rippleAmt = waterMat.params.y;
  float rScale = waterMat.params2.w;
  float phase = waterMat.pattern.x;

  // Dual analytic scrolling micro-ripple normal perturbation.
  vec2 uv1 = fragUv * rScale + vec2(t * 0.45, t * 0.28);
  vec2 uv2 = fragUv * (rScale * 1.63) - vec2(t * 0.33, t * 0.51);
  float rx = sin(uv1.x * 6.28318) * cos(uv1.y * 6.28318) +
             0.6 * cos(uv2.x * 6.28318 + 1.1);
  float ry = cos(uv1.y * 6.28318) * sin(uv2.x * 6.28318) +
             0.6 * sin(uv2.y * 6.28318 - 0.7);

  vec3 geomN = normalize(fragNormal);
  // The same tangent frame as the waves of water_material.vert.
  vec3 up = normalize(waterMat.upAxis.xyz);
  vec3 ref = abs(up.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
  vec3 tAxis = normalize(cross(ref, up));
  vec3 bAxis = normalize(cross(up, tAxis));
  vec3 n = normalize(geomN + (tAxis * rx + bAxis * ry) * rippleAmt);

  // The options that tilt the normal: the swell and the rings of ripples.
  float ringCrest = 0.0;
  bool addsLight = waterMat.detail.w > 0.5;
  if (waterMat.detail.x > 0.0 || waterMat.ramp.w > 0.5) {
    vec2 slope = vec2(0.0);
    if (waterMat.detail.x > 0.0) {
      slope = waterDetailSlope(fragUv * waterMat.detail.y, phase) *
        waterMat.detail.x;
    }
    if (waterMat.ramp.w > 0.5) {
      ringCrest = waterRippleRings(fragUv, slope);
    }
    n = normalize(n - tAxis * slope.x - bAxis * slope.y);
  }

  vec3 v = scene.Camera_projection[3][3] > 0.5
      ? normalize(vec3(
          scene.Camera_view[0][2],
          scene.Camera_view[1][2],
          scene.Camera_view[2][2]
        ))
      : normalize(scene.Camera_position - fragPosition);

  float ndotv = clamp(dot(n, v), 0.0, 1.0);
  float fresnel = pow(1.0 - ndotv, waterMat.params2.x);

  vec3 waterBody = mix(
    waterMat.deepColor.rgb,
    waterMat.shallowColor.rgb,
    clamp(fragCrest * 0.85 + (1.0 - fresnel) * 0.25, 0.0, 1.0)
  ) * fragColor.rgb;
  // The depth ramp: from the shallow color and opacity where the water is
  // shallow to the deep ones, `1 - exp(-depth / depthRange)` of the way.
  bool ramp = waterMat.ramp.x > 0.0;
  float deepness = 0.0;
  if (ramp) {
    deepness = 1.0 - exp(-max(fragWater.x, 0.0) * waterMat.ramp.x);
    vec3 body = mix(waterMat.shallowColor.rgb, waterMat.deepColor.rgb, deepness);
    // Crests lighten towards the shallow color.
    waterBody = mix(body, waterMat.shallowColor.rgb, fragCrest * 0.3) *
      fragColor.rgb;
  }

  vec3 skyColor = scene.HemisphereLight_intensity > 0.0
      ? scene.HemisphereLight_skyColor.rgb * scene.HemisphereLight_intensity
      : scene.AmbientLight_color.rgb * max(scene.AmbientLight_intensity, 0.35);

  vec3 sunShadow = vec3(1.0);
  int shadowed = int(scene.Shadows_toLight.w);
  if (shadowed >= 0 && shadowed < int(scene.DirectionalLights_numLights)) {
    sunShadow = shadowFactor(shadowVisibility(fragPosition, geomN));
  }

  // The light that reaches the surface, whatever its normal, for the
  // options that add light.
  vec3 incoming = vec3(0.0);
  vec3 directDiffuse = vec3(0.0);
  vec3 specLight = vec3(0.0);
  for (int i = 0; i < int(scene.DirectionalLights_numLights); i++) {
    vec4 dir = scene.DirectionalLights_directions[i];
    vec4 col = scene.DirectionalLights_colors[i];
    vec3 sh = castsShadows(i) ? sunShadow : vec3(1.0);
    float ndotl = max(dot(n, dir.xyz), 0.0);
    directDiffuse += col.rgb * (col.a * (0.35 + 0.65 * ndotl)) * sh;
    float ndoth = max(dot(n, normalize(dir.xyz + v)), 0.0);
    specLight += col.rgb *
      (pow(ndoth, waterMat.params.w) * waterMat.params2.y * dir.w * col.a) * sh;
    incoming += col.rgb * col.a * sh;
  }

  for (int i = 0; i < int(scene.Lights_numLights); i++) {
    vec3 toL = scene.Lights_positions[i] - fragPosition;
    float dist = max(length(toL), 0.001);
    vec3 l = toL / dist;
    float range = scene.Lights_ranges[i].x;
    float atten = range > 0.0
        ? pow(max(1.0 - dist / range, 0.0), 2.0)
        : 1.0 / (dist * dist);
    float e = scene.Lights_intensities[i].x * atten;
    vec3 pointSh = pointShadowFactor(i, fragPosition, geomN);
    directDiffuse += scene.Lights_colors[i].rgb *
      (e * max(dot(n, l), 0.0)) * pointSh;
    float ndoth = max(dot(n, normalize(l + v)), 0.0);
    specLight += scene.Lights_colors[i].rgb *
      (pow(ndoth, waterMat.params.w) * waterMat.params2.y * e) * pointSh;
    incoming += scene.Lights_colors[i].rgb * e * pointSh;
  }

  for (int i = 0; i < int(scene.SpotLights_numLights); i++) {
    vec3 toL = scene.SpotLights_positions[i] - fragPosition;
    float dist = max(length(toL), 0.001);
    vec3 l = toL / dist;
    vec4 spotDir = scene.SpotLights_directions[i];
    vec4 cone = scene.SpotLights_cones[i];
    float angular = clamp((dot(l, spotDir.xyz) - cone.x) * cone.y, 0.0, 1.0);
    angular *= angular;
    if (angular <= 0.0) {
      continue;
    }
    float range = cone.z;
    float atten = range > 0.0
        ? pow(max(1.0 - dist / range, 0.0), 2.0)
        : 1.0 / (dist * dist);
    vec4 col = scene.SpotLights_colors[i];
    float e = col.a * atten * angular;
    vec3 spotSh = spotShadowFactor(i, fragPosition, geomN);
    directDiffuse += col.rgb * (e * max(dot(n, l), 0.0)) * spotSh;
    float ndoth = max(dot(n, normalize(l + v)), 0.0);
    specLight += col.rgb *
      (pow(ndoth, waterMat.params.w) * waterMat.params2.y * spotDir.w * e) *
      spotSh;
    incoming += col.rgb * e * spotSh;
  }

  vec3 ndc = fragClipPos.xyz / max(fragClipPos.w, 1e-6);
  vec2 screenUv = clamp(
    vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y),
    vec2(0.001),
    vec2(0.999)
  );

  // Crest + micro-ripple foam + optional shoreline depth intersection foam.
  float rippleCrest = fragCrest + 0.14 * (rx + ry);
  // A foamThreshold of 1 or more turns the crest foam off (smoothstep is
  // undefined when its edges are equal or reversed).
  float foamTop = min(waterMat.params.z + 0.22, 1.0);
  float foamMask = waterMat.params.z < foamTop
      ? smoothstep(waterMat.params.z, foamTop, rippleCrest)
      : 0.0;
  float shoreAlphaFade = 1.0;
  if (waterMat.shoreParams.x > 1e-5 && depthNormal.params.x > 0.5) {
    vec4 dn = texture(depthNormalTexture, screenUv);
    float sceneDepth = (dn.r * 255.0 * 256.0 + dn.g * 255.0) / 65535.0;
    float columnDepth = max(sceneDepth - ndc.z, 0.0);
    float shore = 1.0 - clamp(columnDepth / waterMat.shoreParams.x, 0.0, 1.0);
    foamMask = max(foamMask, shore * shore * 0.95);
    shoreAlphaFade = clamp(
      columnDepth / (waterMat.shoreParams.x * 0.25),
      0.15,
      1.0
    );
  }
  // The foam of the vertices' foam mask (against a wall, around a rock), of
  // the foam sources (around the things that move) and at the crests of the
  // rings of ripples, lit by the light reaching the water (the crest and
  // shore foam keep their own color). The mask's foam moves with a phase of
  // its own (edgeFoamMotion: 0 holds it still).
  float litFoam = 0.0;
  float edgeMask = fragWater.y;
  float sourceFade = 1.0;
  // The sources' loop runs only where the vertices say that one may reach
  // (elsewhere their mask is 0).
  if (waterMat.ramp.z > 0.5 &&
      dot(fragFoamGate.xy, fragFoamGate.xy) + fragFoamGate.z < 0.0) {
    float sources = waterFoamSources(fragUv);
    if (edgeMask <= 0.001) {
      // Where only the sources foam, their loose flecks fade out with their
      // mask, so that the foam ends where the mask does.
      sourceFade = smoothstep(0.0, 0.1, sources);
    }
    edgeMask = max(edgeMask, sources);
  }
  if (edgeMask > 0.001) {
    litFoam = waterEdgeFoam(edgeMask, fragUv, waterMat.shoreParams.z);
    if (sourceFade < 1.0) {
      litFoam *= sourceFade;
    }
  }
  if (ringCrest > 0.0) {
    litFoam = max(litFoam, smoothstep(0.7, 1.1, ringCrest) * 0.85);
    // The water the rings raise is a little lighter.
    waterBody = mix(waterBody, waterMat.shallowColor.rgb, min(ringCrest, 1.0) *
      0.25);
  }

  vec3 litBody = waterBody * (vec3(0.35) + directDiffuse);
  bool hasRefract = sceneColor.params.x > 0.5;
  if (hasRefract) {
    float refrScale = max(0.015, waterMat.shoreParams.y);
    vec2 refrUv = clamp(
      screenUv + vec2(rx, ry) * refrScale,
      vec2(0.002),
      vec2(0.998)
    );
    vec3 refractedScene = texture(sceneColorTexture, refrUv).rgb;
    litBody = mix(refractedScene * mix(vec3(1.0), waterBody, 0.55), litBody,
      clamp(waterMat.params2.z * 0.65, 0.15, 0.85));
  }

  vec3 color = mix(
    litBody,
    skyColor,
    clamp(fresnel * 0.72, 0.0, 0.92)
  ) + specLight;
  color = mix(color, waterMat.foamColor.rgb, foamMask * waterMat.foamColor.a);
  if (litFoam > 0.0) {
    vec3 foamLight = skyColor * 0.6 + incoming * 0.75;
    if (waterMat.shoreParams.w < 1.0) {
      // Foam scatters every color alike: it takes the brightness of the
      // light (its luminance) and only foamLightTint of its color.
      foamLight = mix(
        vec3(dot(foamLight, WATER_LUMINANCE)),
        foamLight,
        max(waterMat.shoreParams.w, 0.0)
      );
    }
    // Between the floor (foamLightFloor) and 1.15, or the floor when above.
    float lightFloor = waterMat.upAxis.w;
    foamLight = clamp(
      foamLight,
      vec3(lightFloor),
      vec3(max(1.15, lightFloor))
    );
    color = mix(color, waterMat.foamColor.rgb * foamLight,
      litFoam * waterMat.foamColor.a);
    foamMask = max(foamMask, litFoam);
  }
  color = clamp(color, 0.0, 1.5);

  float alpha = hasRefract
      ? fragColor.a
      : clamp(
          waterMat.params2.z + foamMask * 0.25 + fresnel * 0.15,
          0.0,
          1.0
        ) * fragColor.a * shoreAlphaFade;
  if (ramp && !hasRefract) {
    // Clear water: as opaque as its depth says, more at grazing angles,
    // opaque where it foams.
    float bodyAlpha = mix(waterMat.ramp.y, waterMat.params2.z, deepness);
    bodyAlpha += (1.0 - bodyAlpha) * fresnel;
    bodyAlpha = max(bodyAlpha, foamMask * waterMat.foamColor.a);
    alpha = clamp(bodyAlpha, 0.0, 1.0) * fragColor.a * shoreAlphaFade;
  }

  if (addsLight) {
    // The options that add light over the water: the caustic network,
    // sparkles and the highlights of the rings. Added over a translucent
    // surface, they raise its opacity as much as they brighten it, so that
    // they keep their brightness whatever the opacity of the water.
    vec3 light = incoming + skyColor * 0.35;
    vec3 added = vec3(0.0);
    if (waterMat.causticColor.a > 0.0) {
      // With the depth ramp, the network shows more where the water is deep
      // (where the floor, which shows its own caustics, is less visible).
      float weight = ramp ? 0.25 + 0.75 * deepness : 1.0;
      added += waterMat.causticColor.rgb * light *
        (waterCaustics(fragUv * waterMat.pattern.y, phase) *
         waterMat.causticColor.a * weight * (1.0 - foamMask));
    }
    if (waterMat.pattern.z > 0.0) {
      // Brighter where the lights' reflections are.
      float glint = 0.25 + 0.75 * clamp(length(specLight) * 2.0, 0.0, 1.0);
      added += incoming * (waterSparkle(fragUv * waterMat.pattern.w, phase) *
        waterMat.pattern.z * glint * (1.0 - foamMask));
    }
    if (ringCrest > 0.0) {
      added += light * (min(ringCrest, 1.2) * 0.5);
    }
    added *= fragColor.a;
    float addedAlpha = clamp(dot(added, vec3(0.3, 0.59, 0.11)), 0.0, 1.0);
    float outAlpha = alpha + addedAlpha * (1.0 - alpha);
    color = clamp((color * alpha + added) / max(outAlpha, 1e-4), 0.0, 1.5);
    alpha = outAlpha;
  }

  color = applyFog(
    color,
    fragPosition,
    scene.Camera_view,
    scene.Camera_projection,
    scene.Camera_position
  );
  outColor = vec4(color, alpha);
}

#endif
