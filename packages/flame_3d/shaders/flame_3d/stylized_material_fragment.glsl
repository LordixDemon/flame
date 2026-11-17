#ifndef FLAME_STYLIZED_MATERIAL_FRAGMENT_GLSL_
#define FLAME_STYLIZED_MATERIAL_FRAGMENT_GLSL_

// The fragment stage of StylizedMaterial: vertex-colored surfaces lit by the
// hemisphere, directional and point lights of the scene, with per-vertex
// masks for the instance tint, the accent color, emission and gloss.
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
//   cap  = matCap(view-space normal) * gloss * matCapStrength
//   out  = mix(base * lit + spec + rim + cap, emissive,
//              emissive mask * emissiveStrength)
//
// with hemi = 0.5 + 0.5 * n.up and bounce = max(0, -n.up).

in vec3 fragPosition;
in vec3 fragNormal;
in vec4 fragColor;
in vec4 fragMasks;
in float fragOcclusion;
in vec4 fragInstanceColor;

out vec4 outColor;

uniform sampler2D matCapTexture;

uniform Material {
  vec4 albedoColor;
  vec4 accentColor;
  vec4 emissiveColor;
  vec4 ambientBase;
  vec4 rimColor;
  float emissiveStrength;
  float skyFill;
  float groundBounce;
  float pointLightWrap;
  float specularStrength;
  float specularPower;
  float specularThreshold;
  float rimStrength;
  float rimPower;
  float matCapStrength;
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

  vec3 base = material.albedoColor.rgb * fragColor.rgb;
  base *= mix(vec3(1.0), fragInstanceColor.rgb, tintMask);
  base *= mix(vec3(1.0), material.accentColor.rgb, accentMask);

  float nUp = clamp(dot(n, hemisphereLight.up), -1.0, 1.0);
  float hemi = 0.5 + 0.5 * nUp;
  float bounce = max(-nUp, 0.0);
  vec3 ambient = ambientLight.color.rgb * ambientLight.intensity +
    hemisphereLight.intensity * (
      material.ambientBase.rgb +
      material.skyFill * hemi * hemisphereLight.skyColor.rgb +
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
      float fade = max(1.0 - dist / range, 0.0);
      falloff = fade * fade;
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

  vec3 viewNormal = normalize(mat3(camera.view) * n);
  vec2 matCapUv = vec2(0.5 + 0.5 * viewNormal.x, 0.5 - 0.5 * viewNormal.y);
  vec3 matCap = texture(matCapTexture, matCapUv).rgb * gloss *
    material.matCapStrength;

  vec3 color = base * lit + vec3(specular) + rim + matCap;
  float glow = clamp(emissiveMask * material.emissiveStrength, 0.0, 1.0);
  color = mix(color, material.emissiveColor.rgb, glow);

  float alpha = material.albedoColor.a * fragColor.a;
  outColor = vec4(clamp(color, 0.0, 1.0) * alpha, alpha);
}

#endif
