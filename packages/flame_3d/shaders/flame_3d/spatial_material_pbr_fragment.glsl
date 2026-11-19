#ifndef FLAME_SPATIAL_MATERIAL_PBR_FRAGMENT_GLSL_
#define FLAME_SPATIAL_MATERIAL_PBR_FRAGMENT_GLSL_

// Extended physically-based Cook-Torrance metallic-roughness + Karis Split-Sum
// Specular IBL + Kulla-Conty multi-scattering + Box-Projected Reflection Probes
// + MikkTSpace vertex TBN + UV1 Lightmap + 3D LightProbeGrid + Clearcoat +
// IOR Transmission / Grab-Pass Refraction + Unified 4-Cascade CSM / Multi-Spot /
// Dual-Paraboloid Point Shadow Atlas + Linear HDR + RenderDebugMode3D shader.

#define PI 3.14159265359
#define EPSILON 0.0001

in vec2 fragTexCoord;
in vec2 fragTexCoord1;
in vec4 fragColor;
in vec3 fragPosition;
smooth in vec3 fragNormal;
in vec4 fragTangent;
in vec4 fragInstanceColor;
in vec4 fragInstanceData;
in vec4 fragClipPos;

out vec4 outColor;

uniform sampler2D albedoTexture;
uniform sampler2D normalTexture;
uniform sampler2D metallicRoughnessTexture;
uniform sampler2D occlusionTexture;
uniform sampler2D emissiveTexture;
uniform sampler2D environmentTexture;
uniform sampler2D brdfLutTexture;
uniform sampler2D lightmapTexture;
uniform sampler2D probeGridTexture;
uniform sampler2D sceneColorTexture;

uniform Material {
  vec4 albedoColor;
  // rgb: emissiveColor * emissiveStrength, a: alphaCutoff
  vec4 emissiveColor;
  // xy: uvScale, zw: uvOffset
  vec4 uvTransform;
  // x: metallic, y: roughness, z: normalScale, w: occlusionStrength
  vec4 params;
  // x: hasNormalTex, y: hasOrmTex, z: hasOcclusionTex, w: environmentIntensity
  vec4 flags;
  // x: doubleSided, y: ditherFade, z: premultiplyAlpha, w: hasEmissiveTex
  vec4 flags2;
  // x: clearcoat, y: clearcoatRoughness, z: transmission, w: ior
  vec4 pbrExt;
  // x: hasLightmap, y: lightmapIntensity, z: maxEnvMip, w: hasSplitSumIbl
  vec4 iblParams;
  // The ReflectionProbeVolume3D the environment comes from, if any.
  // xyz: box min, w: unused
  vec4 probeBoxMin;
  // xyz: box max, w: unused
  vec4 probeBoxMax;
  // xyz: box center, w: box projection (1 = on, 0 = off or no volume)
  vec4 probeCenter;
  // L0..L2 Spherical Harmonics diffuse irradiance (shCoeffs[0].w > 0 enables)
  vec4 shCoeffs[9];
} material;

uniform PassOptions {
  // x: 1 in a pass into the HDR scene target (output extended-range sRGB),
  // y: debugMode, z: sceneColorActive, w: unused
  vec4 flags;
  // xyz: lightProbeGrid bounds min, w: grid intensity (>0 active)
  vec4 gridBoundsMin;
  // xyz: lightProbeGrid 1 / bounds span, w: irradiance of a texel value of 1,
  // divided by pi
  vec4 gridInvSpan;
  // xyz: (resX, resY, resZ), w: unused
  vec4 gridRes;
} passOptions;

#include <flame_3d/lights.glsl>

uniform Camera {
  mat4 view;
  mat4 projection;
  vec3 position;
} camera;

#include <flame_3d/shadows.glsl>
#include <flame_3d/fog.glsl>
#include <flame_3d/dither.glsl>

vec3 fresnelSchlick(float cosTheta, vec3 f0) {
  return f0 + (1.0 - f0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 fresnelSchlickRoughness(float cosTheta, vec3 f0, float roughness) {
  return f0 +
    (max(vec3(1.0 - roughness), f0) - f0) *
    pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

float distributionGGX(vec3 normal, vec3 halfwayDir, float roughness) {
  float a = roughness * roughness;
  float a2 = a * a;
  float NdotH = max(dot(normal, halfwayDir), 0.0);
  float NdotH2 = NdotH * NdotH;
  float b = (NdotH2 * (a2 - 1.0) + 1.0);
  return a2 / max(PI * b * b, EPSILON);
}

float geometrySchlickGGX(float NdotV, float roughness) {
  float r = (roughness + 1.0);
  float k = (r * r) / 8.0;
  return NdotV / (NdotV * (1.0 - k) + k);
}

float geometrySmith(vec3 normal, vec3 viewDir, vec3 lightDir, float roughness) {
  float NdotV = max(dot(normal, viewDir), 0.0);
  float NdotL = max(dot(normal, lightDir), 0.0);
  return geometrySchlickGGX(NdotV, roughness) *
    geometrySchlickGGX(NdotL, roughness);
}

vec3 perturbNormal(
  vec3 n,
  vec4 vTangent,
  vec3 worldPos,
  vec2 uv,
  vec3 mapSample,
  float scale
) {
  vec3 localN = mapSample * 2.0 - 1.0;
  localN.xy *= scale;

  // Use MikkTSpace vertex tangent frame whenever provided (`length(xyz) > 0.5`).
  float tanLen2 = dot(vTangent.xyz, vTangent.xyz);
  if (tanLen2 > 0.25) {
    vec3 t = normalize(vTangent.xyz - n * dot(n, vTangent.xyz));
    float signB = vTangent.w < 0.0 ? -1.0 : 1.0;
    vec3 b = cross(n, t) * signB;
    return normalize(mat3(t, b, n) * localN);
  }

  // Fallback screen-space cotangent frame.
  vec3 dp1 = dFdx(worldPos);
  vec3 dp2 = dFdy(worldPos);
  vec2 duv1 = dFdx(uv);
  vec2 duv2 = dFdy(uv);

  vec3 dp2perp = cross(dp2, n);
  vec3 dp1perp = cross(n, dp1);
  vec3 t = dp2perp * duv1.x + dp1perp * duv2.x;
  vec3 b = dp2perp * duv1.y + dp1perp * duv2.y;
  float maxLen2 = max(dot(t, t), dot(b, b));
  if (maxLen2 < 1e-10) {
    return n;
  }
  float invMax = inversesqrt(maxLen2);
  mat3 tbn = mat3(t * invMax, b * invMax, n);
  return normalize(tbn * localN);
}

vec2 equirectUv(vec3 dir) {
  float phi = atan(dir.z, dir.x);
  float theta = asin(clamp(dir.y, -1.0, 1.0));
  return vec2(phi * (0.5 / PI) + 0.5, 0.5 - theta * (1.0 / PI));
}

vec3 boxProjectDir(vec3 worldPos, vec3 reflDir) {
  if (material.probeCenter.w < 0.5) {
    return reflDir;
  }
  vec3 bMin = material.probeBoxMin.xyz;
  vec3 bMax = material.probeBoxMax.xyz;
  vec3 invR = vec3(
    abs(reflDir.x) > 1e-5 ? 1.0 / reflDir.x : 1e5,
    abs(reflDir.y) > 1e-5 ? 1.0 / reflDir.y : 1e5,
    abs(reflDir.z) > 1e-5 ? 1.0 / reflDir.z : 1e5
  );
  vec3 t1 = (bMin - worldPos) * invR;
  vec3 t2 = (bMax - worldPos) * invR;
  vec3 tMax = max(t1, t2);
  float tHit = min(tMax.x, min(tMax.y, tMax.z));
  if (tHit <= 0.0 || tHit > 1e4) {
    return reflDir;
  }
  vec3 hitPos = worldPos + reflDir * tHit;
  return normalize(hitPos - material.probeCenter.xyz);
}

// One axis band of the LightProbeGrid3D ambient-cube strip (see
// LightProbeGrid3D.volumeTextureFor), trilinear: bilinear in x and y within a
// Z slice, linear across the two nearest slices. Texels hold sqrt(E / range).
vec3 sampleProbeGridBand(float band, vec3 uvw) {
  float rx = max(1.0, passOptions.gridRes.x);
  float ry = max(1.0, passOptions.gridRes.y);
  float rz = max(1.0, passOptions.gridRes.z);

  float zCoord = uvw.z * (rz - 1.0);
  float z0 = floor(zCoord);
  float z1 = min(z0 + 1.0, rz - 1.0);
  float zf = zCoord - z0;

  float xTex = uvw.x * (rx - 1.0) + 0.5;
  float yTex = (band * ry + uvw.y * (ry - 1.0) + 0.5) / (6.0 * ry);
  float invStripW = 1.0 / (rx * rz);

  vec3 s0 = texture(probeGridTexture, vec2((z0 * rx + xTex) * invStripW, yTex)).rgb;
  vec3 s1 = texture(probeGridTexture, vec2((z1 * rx + xTex) * invStripW, yTex)).rgb;
  vec3 t = mix(s0, s1, zf);
  return t * t;
}

// Irradiance of the LightProbeGrid3D at worldPos for the unit normal n,
// divided by pi, times the grid's intensity. With F+ and F- the irradiance
// along +axis and -axis, E(n) = sum over the axes of
//   n_i^2 (F+ + F-) / 2 + n_i (F+ - F-) / 2,
// the probe's SH9 irradiance without the xy, yz and zx terms of band 2.
vec3 sampleProbeGrid3D(vec3 worldPos, vec3 n) {
  vec3 uvw = clamp(
    (worldPos - passOptions.gridBoundsMin.xyz) * passOptions.gridInvSpan.xyz,
    vec3(0.0),
    vec3(1.0)
  );
  vec3 plus = 0.5 * n * (n + 1.0);
  vec3 minus = 0.5 * n * (n - 1.0);
  vec3 e =
    plus.x * sampleProbeGridBand(0.0, uvw) +
    minus.x * sampleProbeGridBand(1.0, uvw) +
    plus.y * sampleProbeGridBand(2.0, uvw) +
    minus.y * sampleProbeGridBand(3.0, uvw) +
    plus.z * sampleProbeGridBand(4.0, uvw) +
    minus.z * sampleProbeGridBand(5.0, uvw);
  return max(e, vec3(0.0)) *
    (passOptions.gridInvSpan.w * passOptions.gridBoundsMin.w);
}

vec3 processLightPbr(
  vec3 lightDir,
  vec3 radiance,
  float specularFactor,
  vec3 baseColor,
  vec3 normal,
  vec3 geomNormal,
  vec3 viewDir,
  vec3 f0,
  float metallic,
  float roughness,
  float transmission,
  float clearcoat,
  float clearcoatRoughness
) {
  vec3 halfwayDir = normalize(viewDir + lightDir);
  float ndf = distributionGGX(normal, halfwayDir, roughness);
  float g = geometrySmith(normal, viewDir, lightDir, roughness);
  float hDotV = max(dot(halfwayDir, viewDir), 0.0);
  vec3 f = fresnelSchlick(hDotV, f0);

  vec3 kS = f;
  vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic) * (1.0 - transmission);

  vec3 numerator = ndf * g * f;
  float denominator =
    4.0 * max(dot(normal, viewDir), 0.0) * max(dot(normal, lightDir), 0.0) +
    EPSILON;
  vec3 specular = numerator / denominator;

  float NdotL = max(dot(normal, lightDir), 0.0);
  vec3 baseLayer =
    (kD * baseColor / PI + specular * specularFactor) * radiance * NdotL;

  if (clearcoat > 1e-4) {
    float ccNdotL = max(dot(geomNormal, lightDir), 0.0);
    float ccNdf = distributionGGX(geomNormal, halfwayDir, clearcoatRoughness);
    float ccG = geometrySmith(
      geomNormal,
      viewDir,
      lightDir,
      clearcoatRoughness
    );
    vec3 ccF = fresnelSchlick(hDotV, vec3(0.04)) * clearcoat;
    float ccDenom =
      4.0 * max(dot(geomNormal, viewDir), 0.0) * ccNdotL + EPSILON;
    vec3 ccSpec = (ccNdf * ccG * ccF / ccDenom) * radiance * ccNdotL *
      specularFactor;
    baseLayer = baseLayer * (vec3(1.0) - ccF) + ccSpec;
  }
  return baseLayer;
}

// sRGB encoding extended above 1, the space of the HDR scene target.
vec3 linearToExtendedSrgb(vec3 linear) {
  vec3 c = max(linear, vec3(0.0));
  vec3 lo = c * 12.92;
  vec3 hi = 1.055 * pow(max(c, vec3(1e-6)), vec3(1.0 / 2.4)) - 0.055;
  return mix(lo, hi, step(vec3(0.0031308), c));
}

vec3 extendedSrgbToLinear(vec3 encoded) {
  vec3 c = max(encoded, vec3(0.0));
  vec3 lo = c / 12.92;
  vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
  return mix(lo, hi, step(vec3(0.04045), c));
}

void main() {
  float debugMode = passOptions.flags.y;
  // Overdraw heat diagnostic mode (`RenderDebugMode3D.overdraw == 6`).
  if (abs(debugMode - 6.0) < 0.25) {
    outColor = vec4(0.22, 0.09, 0.03, 1.0);
    return;
  }

  vec2 uv = fragTexCoord * material.uvTransform.xy + material.uvTransform.zw;
  vec4 albedoTexel = texture(albedoTexture, uv);

  vec3 geomNormal = normalize(fragNormal);
  if (material.flags2.x > 0.5 && !gl_FrontFacing) {
    geomNormal = -geomNormal;
  }

  vec3 normal = geomNormal;
  if (material.flags.x > 0.5) {
    vec3 nSample = texture(normalTexture, uv).rgb;
    normal = perturbNormal(
      geomNormal,
      fragTangent,
      fragPosition,
      uv,
      nSample,
      material.params.z
    );
  }

  // World normal diagnostic mode (`RenderDebugMode3D.normals == 1`).
  if (abs(debugMode - 1.0) < 0.25) {
    outColor = vec4(normal * 0.5 + 0.5, 1.0);
    return;
  }

  float metallic = material.params.x;
  float roughness = material.params.y;
  float ao = 1.0;
  if (material.flags.y > 0.5) {
    vec3 orm = texture(metallicRoughnessTexture, uv).rgb;
    roughness *= orm.g;
    metallic *= orm.b;
  }
  roughness = clamp(roughness, 0.04, 1.0);
  metallic = clamp(metallic, 0.0, 1.0);

  // Roughness / Metallic diagnostic mode (`RenderDebugMode3D.roughnessMetallic == 7`).
  if (abs(debugMode - 7.0) < 0.25) {
    outColor = vec4(0.0, roughness, metallic, 1.0);
    return;
  }

  if (material.flags.z > 0.5) {
    float occTex = texture(occlusionTexture, uv).r;
    ao = mix(1.0, occTex, clamp(material.params.w, 0.0, 1.0));
  }

  vec3 emissive = material.emissiveColor.rgb;
  if (material.flags2.w > 0.5) {
    emissive *= texture(emissiveTexture, uv).rgb;
  }

  float fade = clamp(fragInstanceData.w, 0.0, 1.0);
  float alpha =
    material.albedoColor.a *
    fragInstanceColor.a *
    fragColor.a *
    albedoTexel.a *
    (1.0 - fade);

  if (material.emissiveColor.a > 0.0 && alpha < material.emissiveColor.a) {
    discard;
  }
  if (material.flags2.y > 0.5 && alpha < bayerDither4x4(gl_FragCoord.xy)) {
    discard;
  }

  vec3 baseColor =
    material.albedoColor.rgb *
    fragInstanceColor.rgb *
    fragColor.rgb *
    albedoTexel.rgb;

  // Unlit albedo diagnostic mode (`RenderDebugMode3D.albedo == 8`).
  if (abs(debugMode - 8.0) < 0.25) {
    outColor = vec4(baseColor, alpha);
    return;
  }

  vec3 viewDir = camera.projection[3][3] > 0.5
      ? normalize(vec3(camera.view[0][2], camera.view[1][2], camera.view[2][2]))
      : normalize(camera.position - fragPosition);

  float clearcoat = clamp(material.pbrExt.x, 0.0, 1.0);
  float clearcoatRoughness = clamp(material.pbrExt.y, 0.04, 1.0);
  float transmission = clamp(material.pbrExt.z, 0.0, 1.0);
  float ior = clamp(material.pbrExt.w, 1.0, 3.0);
  if (transmission > 1e-4 && dot(normal, viewDir) < 0.0) {
    normal = -normal;
    geomNormal = -geomNormal;
  }
  float f0Scalar = ((ior - 1.0) / (ior + 1.0));
  f0Scalar = f0Scalar * f0Scalar;

  vec3 f0 = mix(vec3(f0Scalar), baseColor, metallic);
  float nDotV = max(dot(normal, viewDir), 0.0);
  vec3 kS = fresnelSchlick(nDotV, f0);
  vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic) * (1.0 - transmission);

  vec3 ambient = kD * baseColor * ambientLight.color.rgb * ambientLight.intensity;
  float hemi = 0.5 + 0.5 * dot(normal, hemisphereLight.up);
  vec3 sky = mix(
    hemisphereLight.groundColor.rgb,
    hemisphereLight.skyColor.rgb,
    hemi
  );
  ambient += kD * baseColor * sky * hemisphereLight.intensity;

  // shCoeffs[0].w includes the 1 / pi that turns irradiance into the diffuse
  // light of a Lambertian surface (direct lights use kD * base / pi too).
  if (material.shCoeffs[0].w > 0.0) {
    float nx = normal.x;
    float ny = normal.y;
    float nz = normal.z;
    vec3 shIrr =
      material.shCoeffs[0].rgb * 0.886227 +
      material.shCoeffs[1].rgb * (1.023327 * ny) +
      material.shCoeffs[2].rgb * (1.023327 * nz) +
      material.shCoeffs[3].rgb * (1.023327 * nx) +
      material.shCoeffs[4].rgb * (0.858086 * nx * ny) +
      material.shCoeffs[5].rgb * (0.858086 * ny * nz) +
      material.shCoeffs[6].rgb * (0.247708 * (3.0 * nz * nz - 1.0)) +
      material.shCoeffs[7].rgb * (0.858086 * nx * nz) +
      material.shCoeffs[8].rgb * (0.429043 * (nx * nx - ny * ny));
    ambient += kD * baseColor * max(shIrr, vec3(0.0)) * material.shCoeffs[0].w;
  }

  // Baked UV1 lightmap contribution.
  if (material.iblParams.x > 0.5) {
    vec3 lm = texture(lightmapTexture, fragTexCoord1).rgb;
    ambient += kD * baseColor * lm * material.iblParams.y;
  }

  // Volumetric 3D LightProbeGrid3D trilinear indirect irradiance.
  if (passOptions.gridBoundsMin.w > 0.0) {
    ambient += kD * baseColor * sampleProbeGrid3D(fragPosition, normal);
  }

  // Split-Sum Specular IBL + Prefiltered Roughness Mip + Kulla-Conty
  // Multi-Scattering + Box-Projected ReflectionProbeVolume3D (the volume's
  // weight at the object is part of flags.w).
  if (material.flags.w > 0.0) {
    vec3 refl = reflect(-viewDir, normal);
    vec3 corrRefl = boxProjectDir(fragPosition, refl);
    float maxMip = max(0.0, material.iblParams.z);
    vec3 envSample = textureLod(
      environmentTexture,
      equirectUv(corrRefl),
      roughness * maxMip
    ).rgb;

    if (material.iblParams.w > 0.5) {
      vec3 brdf = texture(
        brdfLutTexture,
        clamp(vec2(nDotV, roughness), vec2(0.01), vec2(0.99))
      ).rgb;
      vec3 f0Spec = f0 * brdf.x + brdf.y;
      float ess = clamp(brdf.x + brdf.y, 0.01, 1.0);
      float ems = 1.0 - ess;
      vec3 fAvg = f0 + (1.0 - f0) * (1.0 / 21.0);
      vec3 fms = f0Spec * fAvg / max(vec3(1.0) - ems * fAvg, vec3(1e-4));
      vec3 specBrdf = f0Spec + fms * ems;
      vec3 specIbl = specBrdf * envSample * material.flags.w;

      if (clearcoat > 1e-4) {
        vec3 ccRefl = boxProjectDir(fragPosition, reflect(-viewDir, geomNormal));
        vec3 ccEnv = textureLod(
          environmentTexture,
          equirectUv(ccRefl),
          clearcoatRoughness * maxMip
        ).rgb;
        vec2 ccBrdf = texture(
          brdfLutTexture,
          clamp(
            vec2(max(dot(geomNormal, viewDir), 0.0), clearcoatRoughness),
            vec2(0.01),
            vec2(0.99)
          )
        ).rg;
        vec3 ccSpec = (vec3(0.04) * ccBrdf.x + ccBrdf.y) * clearcoat;
        specIbl = specIbl * (vec3(1.0) - ccSpec) +
          ccSpec * ccEnv * material.flags.w;
      }
      ambient += specIbl;
    } else {
      float glossFactor = 1.0 - roughness * 0.75;
      ambient += kS * envSample * material.flags.w * glossFactor;
    }
  }
  ambient *= ao;

  // Dielectric Transmission & Screen-Space Grab-Pass Refraction.
  if (transmission > 1e-4) {
    vec3 refractedBg;
    if (passOptions.flags.z > 0.5) {
      vec3 ndc = fragClipPos.xyz / max(fragClipPos.w, 1e-6);
      vec2 screenUv = vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y);
      vec3 viewN = mat3(camera.view) * normal;
      float refractScale = (1.0 - 1.0 / max(ior, 1.001)) * 0.32;
      vec2 refractUv = clamp(
        screenUv - vec2(viewN.x, -viewN.y) * refractScale,
        vec2(0.002),
        vec2(0.998)
      );
      refractedBg = texture(sceneColorTexture, refractUv).rgb;
      if (passOptions.flags.x > 0.5) {
        // The HDR scene color is extended-range sRGB.
        refractedBg = extendedSrgbToLinear(refractedBg);
      }
    } else if (material.flags.w > 0.0) {
      vec3 refrRay = refract(-viewDir, normal, 1.0 / max(ior, 1.001));
      refractedBg = textureLod(
        environmentTexture,
        equirectUv(refrRay),
        roughness * max(0.0, material.iblParams.z)
      ).rgb;
    } else {
      refractedBg = baseColor * 0.5;
    }
    vec3 transmittance = mix(vec3(1.0), baseColor, 0.85);
    ambient +=
      refractedBg * transmittance * (vec3(1.0) - kS) * transmission;
  }

  vec3 lo = vec3(0.0);
  int cascadeIndexUsed = -1;

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
    vec3 ptShadow = pointShadowFactor(i, fragPosition, geomNormal);
    lo += processLightPbr(
      normalize(lightDirVec),
      lights.colors[i].rgb * attenuation * ptShadow,
      1.0,
      baseColor,
      normal,
      geomNormal,
      viewDir,
      f0,
      metallic,
      roughness,
      transmission,
      clearcoat,
      clearcoatRoughness
    );
  }

  vec3 sunShadow = vec3(1.0);
  int shadowed = int(FLAME_SHADOWS(toLight).w);
  if (shadowed >= 0 && shadowed < int(directionalLights.numLights) &&
      dot(geomNormal, directionalLights.directions[shadowed].xyz) > -0.05) {
    float vis = shadowCascadeVisibility(
      fragPosition,
      geomNormal,
      cascadeIndexUsed
    );
    sunShadow = shadowFactor(vis);
  }

  for (int i = 0; i < int(directionalLights.numLights); i++) {
    vec4 direction = directionalLights.directions[i];
    vec4 lightColor = directionalLights.colors[i];
    vec3 shadow = castsShadows(i) ? sunShadow : vec3(1.0);
    lo += processLightPbr(
      direction.xyz,
      lightColor.rgb * lightColor.a * shadow,
      direction.w,
      baseColor,
      normal,
      geomNormal,
      viewDir,
      f0,
      metallic,
      roughness,
      transmission,
      clearcoat,
      clearcoatRoughness
    );
  }

  for (int i = 0; i < int(spotLights.numLights); i++) {
    vec3 toLight = spotLights.positions[i] - fragPosition;
    float dist = length(toLight) + EPSILON;
    vec3 l = toLight / dist;
    vec4 spotDir = spotLights.directions[i];
    vec4 spotCone = spotLights.cones[i];
    float cosTheta = dot(l, spotDir.xyz);
    float angular = clamp((cosTheta - spotCone.x) * spotCone.y, 0.0, 1.0);
    angular *= angular;
    if (angular > 0.0) {
      float range = spotCone.z;
      float attenuation;
      if (range > 0.0) {
        float rf = max(1.0 - dist / range, 0.0);
        attenuation = rf * rf;
      } else {
        attenuation = 1.0 / (dist * dist);
      }
      vec4 spotColor = spotLights.colors[i];
      vec3 spotSh = spotShadowFactor(i, fragPosition, geomNormal);
      lo += processLightPbr(
        l,
        spotColor.rgb * (spotColor.a * attenuation * angular) * spotSh,
        spotDir.w,
        baseColor,
        normal,
        geomNormal,
        viewDir,
        f0,
        metallic,
        roughness,
        transmission,
        clearcoat,
        clearcoatRoughness
      );
    }
  }

  float boost = max(0.0, fragInstanceData.x);
  float highlight = clamp(fragInstanceData.y, 0.0, 1.0);
  vec3 color = ambient + lo + emissive * (1.0 + boost) + vec3(highlight);

  // Cascade split diagnostic overlay (`RenderDebugMode3D.cascadeSplits == 4`).
  if (abs(debugMode - 4.0) < 0.25) {
    vec3 splitTint = vec3(0.35, 0.4, 0.45);
    if (cascadeIndexUsed == 0) {
      splitTint = vec3(0.15, 0.92, 0.42);
    } else if (cascadeIndexUsed == 1) {
      splitTint = vec3(0.95, 0.85, 0.15);
    } else if (cascadeIndexUsed == 2) {
      splitTint = vec3(0.98, 0.45, 0.15);
    } else if (cascadeIndexUsed == 3) {
      splitTint = vec3(0.9, 0.2, 0.88);
    }
    color = mix(clamp(color, 0.0, 1.0), splitTint, 0.65);
  }

  // Without HDR the radiance is tone-mapped here (Reinhard, gamma 2.2). In an
  // HDR pass it is sRGB-encoded with an extended range (values above 1 are
  // kept), the space every material writes the HDR scene target in; the
  // composite decodes it to linear light for bloom and tone mapping.
  if (passOptions.flags.x < 0.5) {
    color = color / (color + vec3(1.0));
    color = pow(max(color, vec3(0.0)), vec3(1.0 / 2.2));
  } else {
    color = linearToExtendedSrgb(color);
  }

  color = applyFog(
    color,
    fragPosition,
    camera.view,
    camera.projection,
    camera.position
  );

  // Transmissive glass with Grab-Pass outputs opaque refracted background so it
  // does not double-blend with the background underneath.
  float effectiveAlpha = (transmission > 1e-4 && passOptions.flags.z > 0.5)
      ? max(alpha, transmission)
      : alpha;

  if (material.flags2.y > 0.5) {
    outColor = vec4(color, 1.0);
  } else if (material.flags2.z > 0.5) {
    outColor = vec4(color * effectiveAlpha, effectiveAlpha);
  } else {
    outColor = vec4(color, effectiveAlpha);
  }
}

#endif
