#version 460 core

// Stylized + physically-inspired Gerstner water fragment shader with dual
// scrolling micro-ripples, shallow/deep gradient, crest foam, a Fresnel blend
// towards the flat sky color, directional, point and spot light glints,
// directional PCF shadows, Grab-Pass underwater refraction, and fog.

in vec3 fragPosition;
in vec3 fragNormal;
in vec2 fragUv;
in vec4 fragColor;
in float fragCrest;
in vec4 fragClipPos;

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
  // x: shoreFoamDepth (clip-depth span), y: refractionStrength, zw: unused
  vec4 shoreParams;
  // xyz: the world up axis of the rest surface (unit), w: unused
  vec4 upAxis;
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

void main() {
  float t = waterMat.params.x;
  float rippleAmt = waterMat.params.y;
  float rScale = waterMat.params2.w;

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

  vec3 skyColor = scene.HemisphereLight_intensity > 0.0
      ? scene.HemisphereLight_skyColor.rgb * scene.HemisphereLight_intensity
      : scene.AmbientLight_color.rgb * max(scene.AmbientLight_intensity, 0.35);

  vec3 sunShadow = vec3(1.0);
  int shadowed = int(scene.Shadows_toLight.w);
  if (shadowed >= 0 && shadowed < int(scene.DirectionalLights_numLights)) {
    sunShadow = shadowFactor(shadowVisibility(fragPosition, geomN));
  }

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
    directDiffuse += col.rgb * (e * max(dot(n, l), 0.0));
    float ndoth = max(dot(n, normalize(l + v)), 0.0);
    specLight += col.rgb *
      (pow(ndoth, waterMat.params.w) * waterMat.params2.y * spotDir.w * e);
  }

  vec3 ndc = fragClipPos.xyz / max(fragClipPos.w, 1e-6);
  vec2 screenUv = clamp(
    vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y),
    vec2(0.001),
    vec2(0.999)
  );

  // Crest + micro-ripple foam + optional shoreline depth intersection foam.
  float rippleCrest = fragCrest + 0.14 * (rx + ry);
  float foamMask = smoothstep(
    waterMat.params.z,
    min(waterMat.params.z + 0.22, 1.0),
    rippleCrest
  );
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
  color = clamp(color, 0.0, 1.5);

  color = applyFog(
    color,
    fragPosition,
    scene.Camera_view,
    scene.Camera_projection,
    scene.Camera_position
  );

  float alpha = hasRefract
      ? fragColor.a
      : clamp(
          waterMat.params2.z + foamMask * 0.25 + fresnel * 0.15,
          0.0,
          1.0
        ) * fragColor.a * shoreAlphaFade;
  outColor = vec4(color, alpha);
}
