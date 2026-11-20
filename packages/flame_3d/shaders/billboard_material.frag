#version 460 core

// HD-2D billboard / standee fragment shader with alpha cutout, optional
// hemisphere + directional sun shading, emissive boost, and atmospheric fog.

in vec3 fragPosition;
in vec3 fragNormal;
in vec2 fragUv;
in vec4 fragColor;
in vec4 fragData;

out vec4 outColor;

uniform sampler2D albedoTexture;

uniform BillboardLook {
  vec4 albedoColor;
  // x: alphaCutoff, y: defaultShadeWeight, w: ditherFade,
  // z: 1 when the output is blended as premultiplied colors, plus 2 when the
  //    texture holds premultiplied colors.
  vec4 params;
} bLook;

#include <flame_3d/lights.glsl>
#include <flame_3d/light_grid.glsl>

uniform Camera {
  mat4 view;
  mat4 projection;
  vec3 position;
} camera;

#include <flame_3d/fog.glsl>
#include <flame_3d/dither.glsl>

void main() {
  vec4 tex = texture(albedoTexture, fragUv);
  float premultipliedTexture = step(1.5, bLook.params.z);
  float premultipliedBlend = bLook.params.z - 2.0 * premultipliedTexture;
  // The straight color of the texel.
  vec3 texColor = tex.rgb;
  if (premultipliedTexture > 0.5) {
    texColor = tex.a > 1e-4 ? tex.rgb / tex.a : vec3(0.0);
  }
  float fade = clamp(fragData.z, 0.0, 1.0);
  float alpha = tex.a * bLook.albedoColor.a * fragColor.a * (1.0 - fade);

  if (bLook.params.x > 0.0 && alpha < bLook.params.x) {
    discard;
  }
  if (bLook.params.w > 0.5 && alpha < bayerDither4x4(gl_FragCoord.xy)) {
    discard;
  }

  vec3 base = texColor * bLook.albedoColor.rgb * fragColor.rgb;
  float shadeW = clamp(bLook.params.y * (1.0 - fragData.y), 0.0, 1.0);

  vec3 color = base;
  if (shadeW > 0.0) {
    vec3 n = normalize(fragNormal);
    vec3 irr = ambientLight.color.rgb * ambientLight.intensity;
    float hemi = 0.5 + 0.5 * dot(n, hemisphereLight.up);
    irr += mix(
      hemisphereLight.groundColor.rgb,
      hemisphereLight.skyColor.rgb,
      hemi
    ) * hemisphereLight.intensity;
    for (int i = 0; i < int(directionalLights.numLights); i++) {
      vec4 d = directionalLights.directions[i];
      vec4 c = directionalLights.colors[i];
      float wrapNdotL = 0.35 + 0.65 * max(dot(n, d.xyz), 0.0);
      irr += c.rgb * (c.a * wrapNdotL);
    }
    int blockPoints = int(lightGridBlockPointLights(lights.numLights));
    for (int i = 0; i < blockPoints; i++) {
      vec3 toL = lights.positions[i] - fragPosition;
      float dist = max(length(toL), 0.001);
      vec3 l = toL / dist;
      float range = lights.ranges[i].x;
      float atten = range > 0.0
          ? pow(max(1.0 - dist / range, 0.0), 2.0)
          : 1.0 / (dist * dist);
      float wrapNdotL = 0.35 + 0.65 * max(dot(n, l), 0.0);
      irr += lights.colors[i].rgb * (lights.intensities[i].x * atten * wrapNdotL);
    }
    // The lights of the light grid listed by this fragment's cell, as
    // above, see flame_3d/light_grid.glsl.
    vec4 gridCell = lightGridCell(fragPosition);
    for (int k = 0; k < LIGHT_GRID_POINT_LIGHTS_PER_CELL; k++) {
      if (float(k) >= gridCell.y) {
        break;
      }
      vec4 gridPosition;
      vec4 gridColor;
      lightGridPointLight(gridCell, k, gridPosition, gridColor);
      vec3 toL = gridPosition.xyz - fragPosition;
      float dist = max(length(toL), 0.001);
      float fade = max(1.0 - dist / gridPosition.w, 0.0);
      if (fade <= 0.0) {
        continue;
      }
      vec3 l = toL / dist;
      float wrapNdotL = 0.35 + 0.65 * max(dot(n, l), 0.0);
      irr += gridColor.rgb * (gridColor.a * pow(fade, 2.0) * wrapNdotL);
    }
    int blockSpots = int(lightGridBlockSpotLights(spotLights.numLights));
    for (int i = 0; i < blockSpots; i++) {
      vec3 toL = spotLights.positions[i] - fragPosition;
      float dist = max(length(toL), 0.001);
      vec3 l = toL / dist;
      float cosT = dot(l, spotLights.directions[i].xyz);
      float spotMask = clamp(
        (cosT - spotLights.cones[i].x) * spotLights.cones[i].y,
        0.0,
        1.0
      );
      spotMask = spotMask * spotMask * (3.0 - 2.0 * spotMask);
      float range = spotLights.cones[i].z;
      float atten = range > 0.0
          ? pow(max(1.0 - dist / range, 0.0), 2.0)
          : 1.0 / (dist * dist);
      float wrapNdotL = 0.35 + 0.65 * max(dot(n, l), 0.0);
      irr += spotLights.colors[i].rgb *
        (spotLights.colors[i].a * atten * spotMask * wrapNdotL);
    }
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
      vec3 toL = gridPosition.xyz - fragPosition;
      float dist = max(length(toL), 0.001);
      float fade = max(1.0 - dist / gridPosition.w, 0.0);
      if (fade <= 0.0) {
        continue;
      }
      vec3 l = toL / dist;
      float spotMask = clamp(
        (dot(l, spotDir.xyz) - spotCone.x) * spotCone.y,
        0.0,
        1.0
      );
      spotMask = spotMask * spotMask * (3.0 - 2.0 * spotMask);
      float wrapNdotL = 0.35 + 0.65 * max(dot(n, l), 0.0);
      irr += gridColor.rgb *
        (gridColor.a * pow(fade, 2.0) * spotMask * wrapNdotL);
    }
    color = mix(base, base * clamp(irr, 0.0, 1.6), shadeW);
  }

  color *= (1.0 + max(0.0, fragData.x));

  color = applyFog(
    color,
    fragPosition,
    camera.view,
    camera.projection,
    camera.position
  );

  float outAlpha = bLook.params.x > 0.0 || bLook.params.w > 0.5 ? 1.0 : alpha;
  if (premultipliedBlend > 0.5) {
    outColor = vec4(color * outAlpha, outAlpha);
  } else {
    outColor = vec4(color, outAlpha);
  }
}
