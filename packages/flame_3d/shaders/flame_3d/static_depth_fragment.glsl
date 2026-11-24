#ifndef FLAME_STATIC_DEPTH_FRAGMENT_GLSL_
#define FLAME_STATIC_DEPTH_FRAGMENT_GLSL_

// Captures clip-space depth packed into 24-bit RGB plus the direct-sun diffuse
// lighting share in Alpha so moving-caster shadows can be projected accurately
// onto cached static pixels during fullscreen restore.

in vec3 fragWorldNormal;

out vec4 outColor;

uniform StaticDepthParams {
  // xyz: unit vector toward shadowed directional light, w: sun luma.
  vec4 sunDirIntensity;
  // x: ambient+hemiBase luma, y: hemiSkyFill luma, z: hemiGroundBounce luma,
  // w: 1.0 when directional sun is active else 0.0.
  vec4 ambientLuma;
  // xyz: hemisphere up axis, w: unused.
  vec4 hemiUp;
} params;

vec4 packStaticDepth(float clipZ, float sunWeight) {
  float d = floor(clamp(clipZ, 0.0, 1.0) * 16777215.0 + 0.5);
  float hi = floor(d / 65536.0);
  d -= hi * 65536.0;
  float mid = floor(d / 256.0);
  float lo = d - mid * 256.0;
  return vec4(hi / 255.0, mid / 255.0, lo / 255.0, sunWeight);
}

void main() {
  float clipZ = clamp(gl_FragCoord.z, 0.0, 1.0);
  float sunWeight = 0.0;
  if (params.ambientLuma.w > 0.5) {
    vec3 n = normalize(fragWorldNormal);
    float ndotl = max(dot(n, params.sunDirIntensity.xyz), 0.0);
    if (ndotl > 0.0) {
      float nUp = clamp(dot(n, params.hemiUp.xyz), -1.0, 1.0);
      float hemi = 0.5 + 0.5 * nUp;
      float bounce = max(-nUp, 0.0);
      float ambL =
        params.ambientLuma.x +
        params.ambientLuma.y * hemi +
        params.ambientLuma.z * bounce;
      float dirL = ndotl * params.sunDirIntensity.w;
      sunWeight = clamp(dirL / max(ambL + dirL, 0.001), 0.0, 1.0);
    }
  }
  outColor = packStaticDepth(clipZ, sunWeight);
}

#endif
