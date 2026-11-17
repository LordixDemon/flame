#ifndef FLAME_STYLIZED_MATERIAL_FRAGMENT_GLSL_
#define FLAME_STYLIZED_MATERIAL_FRAGMENT_GLSL_

// The fragment stage of StylizedMaterial: vertex-colored surfaces lit by the
// hemisphere, directional and point lights of the scene, with per-vertex
// masks for the instance tint, the accent color, emission and gloss, and per
// instance data for an emissive boost, a highlight and a fade.
//
//   base = albedo * vertex color * mix(1, instance color, tint mask)
//          * mix(1, accent, accent mask)
//   lit  = occlusion * (ambient + hemisphere intensity * (ambientBase
//          + skyFill * sky * hemi + groundBounce * ground * bounce))
//          + sum over suns of max(0, n.l) * intensity * color
//          + sum over points of intensity * color * falloff
//            * max(pointLightWrap, n.l)
//   spec = gloss > specularThreshold:
//          sum over suns of (n.h)^specularPower * specular factor
//          * gloss * specularStrength
//   rim  = (1 - n.v)^rimPower * rimStrength * (sky + rimColor)
//   cap  = gloss > gemThreshold: gemMatCap(view-space normal)
//          * gemMatCapStrength
//          else gloss > matCapThreshold: matCap(view-space normal)
//          * matCapStrength * mix(1, gloss, matCapGlossWeight)
//   glow = clamp(emissive mask * (emissiveStrength + boost), 0, 1)
//   out  = mix(base * lit + spec + rim + cap + highlight * highlightColor,
//              mix(emissive, emissiveBoost, clamp(boost, 0, 1)), glow)
//   alpha = albedo alpha * vertex alpha * (1 - fade)
//
// with hemi = 0.5 + 0.5 * n.up, bounce = max(0, -n.up), skyFill an rgb
// weight, and boost, highlight and fade the x, y and w of the instance data.
// The color is output premultiplied by its alpha.

in vec3 fragPosition;
in vec3 fragNormal;
in vec4 fragColor;
in vec4 fragMasks;
in float fragOcclusion;
in vec4 fragInstanceColor;
in vec4 fragInstanceData;

out vec4 outColor;

uniform sampler2D matCapTexture;
uniform sampler2D gemMatCapTexture;

uniform Material {
  vec4 albedoColor;
  vec4 accentColor;
  vec4 emissiveColor;
  vec4 emissiveBoostColor;
  vec4 ambientBase;
  vec4 skyFill;
  vec4 rimColor;
  vec4 highlightColor;
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
} material;

#include <flame_3d/lights.glsl>

uniform Camera {
  mat4 view;
  mat4 projection;
  vec3 position;
} camera;

void main() {
  vec3 n = normalize(fragNormal);
  // Towards the viewer. Orthographic cameras look along one direction.
  vec3 v;
  if (camera.projection[3][3] > 0.5) {
    v = normalize(vec3(camera.view[0][2], camera.view[1][2], camera.view[2][2]));
  } else {
    v = normalize(camera.position - fragPosition);
  }

  float tintMask = fragMasks.x;
  float accentMask = fragMasks.y;
  float emissiveMask = fragMasks.z;
  float gloss = fragMasks.w;

  float boost = fragInstanceData.x;
  float highlight = fragInstanceData.y;
  float fade = fragInstanceData.w;

  vec3 base = material.albedoColor.rgb * fragColor.rgb;
  base *= mix(vec3(1.0), fragInstanceColor.rgb, tintMask);
  base *= mix(vec3(1.0), material.accentColor.rgb, accentMask);

  float nUp = clamp(dot(n, hemisphereLight.up), -1.0, 1.0);
  float hemi = 0.5 + 0.5 * nUp;
  float bounce = max(-nUp, 0.0);
  vec3 ambient = ambientLight.color.rgb * ambientLight.intensity +
    hemisphereLight.intensity * (
      material.ambientBase.rgb +
      material.skyFill.rgb * hemi * hemisphereLight.skyColor.rgb +
      material.groundBounce * bounce * hemisphereLight.groundColor.rgb
    );
  vec3 lit = fragOcclusion * ambient;

  float specular = 0.0;
  bool glossy = gloss > material.specularThreshold;
  for (int i = 0; i < int(directionalLights.numLights); i++) {
    vec4 direction = directionalLights.directions[i];
    vec4 lightColor = directionalLights.colors[i];
    lit += max(dot(n, direction.xyz), 0.0) * lightColor.a * lightColor.rgb;
    if (glossy) {
      float ndoth = max(dot(n, normalize(direction.xyz + v)), 0.0);
      specular += pow(ndoth, material.specularPower) * direction.w;
    }
  }
  specular *= gloss * material.specularStrength;

  for (int i = 0; i < int(lights.numLights); i++) {
    vec3 toLight = lights.positions[i] - fragPosition;
    float dist = length(toLight);
    vec3 l = toLight / max(dist, 0.0001);
    float range = lights.ranges[i].x;
    float falloff;
    if (range > 0.0) {
      float rangeFade = max(1.0 - dist / range, 0.0);
      falloff = rangeFade * rangeFade;
    } else {
      falloff = 1.0 / max(dist * dist, 0.00000001);
    }
    float wrapped = max(material.pointLightWrap, dot(n, l));
    lit += lights.intensities[i].x * falloff * wrapped * lights.colors[i].rgb;
  }

  float ndotv = clamp(dot(n, v), 0.0, 1.0);
  float fresnel = pow(1.0 - ndotv, material.rimPower);
  vec3 rim = fresnel * material.rimStrength *
    (hemisphereLight.skyColor.rgb + material.rimColor.rgb);

  // Both MatCap textures are sampled outside of any branch, so that their
  // texture coordinates' derivatives are defined.
  vec3 viewNormal = normalize(mat3(camera.view) * n);
  vec2 matCapUv = vec2(0.5 + 0.5 * viewNormal.x, 0.5 - 0.5 * viewNormal.y);
  vec3 coat = texture(matCapTexture, matCapUv).rgb * material.matCapStrength *
    mix(1.0, gloss, material.matCapGlossWeight);
  vec3 gem = texture(gemMatCapTexture, matCapUv).rgb *
    material.gemMatCapStrength;
  float gemWeight = gloss > material.gemThreshold ? 1.0 : 0.0;
  float coatWeight = gloss > material.matCapThreshold ? 1.0 - gemWeight : 0.0;
  vec3 matCap = coatWeight * coat + gemWeight * gem;

  vec3 color = base * lit + vec3(specular) + rim + matCap +
    highlight * material.highlightColor.rgb;
  vec3 emissive = mix(
    material.emissiveColor.rgb,
    material.emissiveBoostColor.rgb,
    clamp(boost, 0.0, 1.0)
  );
  float glow = clamp(
    emissiveMask * (material.emissiveStrength + boost),
    0.0,
    1.0
  );
  color = mix(color, emissive, glow);

  float alpha = material.albedoColor.a * fragColor.a *
    clamp(1.0 - fade, 0.0, 1.0);
  outColor = vec4(clamp(color, 0.0, 1.0) * alpha, alpha);
}

#endif
