#version 460 core

// implementation based on https://learnopengl.com/PBR/Lighting

#define PI 3.14159265359
#define EPSILON 0.0001

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragPosition;
smooth in vec3 fragNormal;
in vec4 fragInstanceColor;

out vec4 outColor;

uniform sampler2D albedoTexture;  // Albedo texture

// material info

uniform Material {
  vec4 albedoColor;
  float metallic;
  float roughness;
} material;

// light info

#include <flame_3d/lights.glsl>

// camera info

uniform Camera {
  vec3 position;
} camera;

vec3 fresnelSchlick(float cosTheta, vec3 f0) {
  return f0 + (1.0 - f0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

float distributionGGX(vec3 normal, vec3 halfwayDir, float roughness) {
  float a = roughness * roughness;
  float a2 = a * a;
  float num = a2;

  float NdotH = max(dot(normal, halfwayDir), 0.0);
  float NdotH2 = NdotH * NdotH;
  float b = (NdotH2 * (a2 - 1.0) + 1.0);
  float denom = PI * b * b;

  return num / denom;
}

float geometrySchlickGGX(float NdotV, float roughness) {
  float r = (roughness + 1.0);
  float k = (r * r) / 8.0;

  float num = NdotV;
  float denom = NdotV * (1.0 - k) + k;

  return num / denom;
}

float geometrySmith(vec3 normal, vec3 viewDir, vec3 lightDir, float roughness) {
  float NdotV = max(dot(normal, viewDir), 0.0);
  float NdotL = max(dot(normal, lightDir), 0.0);
  float ggx2 = geometrySchlickGGX(NdotV, roughness);
  float ggx1 = geometrySchlickGGX(NdotL, roughness);

  return ggx1 * ggx2;
}

// The light reflected towards the viewer from a light coming from lightDir
// (a unit vector towards the light) with the given radiance.
vec3 processLight(
  vec3 lightDir,
  vec3 radiance,
  float specularFactor,
  vec3 baseColor,
  vec3 normal,
  vec3 viewDir,
  vec3 diffuse
) {
  vec3 halfwayDir = normalize(viewDir + lightDir);

  // cook-torrance brdf
  float ndf = distributionGGX(normal, halfwayDir, material.roughness);
  float g = geometrySmith(normal, viewDir, lightDir, material.roughness);
  vec3 f = fresnelSchlick(max(dot(halfwayDir, viewDir), 0.0), diffuse);

  vec3 kS = f; // reflection/specular fraction
  vec3 kD = (vec3(1.0) - kS) * (1.0 - material.metallic); // refraction/diffuse fraction

  vec3 numerator = ndf * g * f;
  float denominator = 4.0 * max(dot(normal, viewDir), 0.0) * max(dot(normal, lightDir), 0.0) + EPSILON;
  vec3 specular = numerator / denominator;

  // add to outgoing radiance Lo
  float NdotL = max(dot(normal, lightDir), 0.0);
  return (kD * baseColor / PI + specular * specularFactor) * radiance * NdotL;
}

void main() {
  vec3 normal = normalize(fragNormal);
  vec3 viewDir = normalize(camera.position - fragPosition);

  vec3 baseColor = material.albedoColor.rgb * fragInstanceColor.rgb * fragColor.rgb;
  baseColor *= texture(albedoTexture, fragTexCoord).rgb;

  vec3 f0 = vec3(0.04);
  vec3 diffuse = mix(f0, baseColor, material.metallic);

  vec3 kS = fresnelSchlick(max(dot(normal, viewDir), 0.0), diffuse);
  vec3 kD = (vec3(1.0) - kS) * (1.0 - material.metallic);
  vec3 ambient = kD * baseColor * ambientLight.color.rgb * ambientLight.intensity;

  float hemi = 0.5 + 0.5 * dot(normal, hemisphereLight.up);
  vec3 sky = mix(hemisphereLight.groundColor.rgb, hemisphereLight.skyColor.rgb, hemi);
  ambient += kD * baseColor * sky * hemisphereLight.intensity;

  vec3 lo = vec3(0.0);

  for (int i = 0; i < int(lights.numLights); i++) {
    vec3 lightDirVec = lights.positions[i] - fragPosition;
    float distance = length(lightDirVec) + EPSILON;
    float intensity = lights.intensities[i].x;
    float range = lights.ranges[i].x;
    float attenuation;
    if (range > 0.0) {
      float falloff = max(1.0 - distance / range, 0.0);
      attenuation = intensity * falloff * falloff;
    } else {
      attenuation = intensity / (distance * distance);
    }
    lo += processLight(
      normalize(lightDirVec),
      lights.colors[i].rgb * attenuation,
      1.0,
      baseColor, normal, viewDir, diffuse
    );
  }

  for (int i = 0; i < int(directionalLights.numLights); i++) {
    vec4 direction = directionalLights.directions[i];
    vec4 lightColor = directionalLights.colors[i];
    lo += processLight(
      direction.xyz,
      lightColor.rgb * lightColor.a,
      direction.w,
      baseColor, normal, viewDir, diffuse
    );
  }

  vec3 color = ambient + lo;

  color = color / (color + vec3(1.0));
  color = pow(color, vec3(1.0 / 2.2));

  outColor = vec4(color, 1.0);
}
