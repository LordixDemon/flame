#ifndef FLAME_WATER_VERTEX_GLSL_
#define FLAME_WATER_VERTEX_GLSL_

// The vertex stage of WaterMaterial: four Gerstner waves computed from the
// world position, around any world up axis (`+Y` or `+Z`), drawn instanced.
// water_material.vert reads the standard layout, water_material_masked.vert
// WaterMaterial.vertexLayout, whose vertices also say how deep the water is
// under them, how much they foam and how calm they are. Both feed
// water_material.frag. The stage declares its vertex inputs (at least
// `vertexPosition` and `vertexColor`) before including this file.

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

uniform WaterVertex {
  // x: time, y: waveAmplitude, z: waveFrequency, w: waveSpeed
  vec4 waveParams;
  // xyz: world up axis (unit), w: steepness
  vec4 upAndSteepness;
  // x: the depth of the water under the vertices of layouts without one
  // (WaterMaterial.defaultDepth), yzw: unused.
  vec4 surface;
} waterVert;

out vec3 fragPosition;
out vec3 fragNormal;
out vec2 fragUv;
out vec4 fragColor;
out float fragCrest;
out vec4 fragClipPos;
// x: the depth of the water under the vertex, in world units, y: its foam
// mask, z: how calm it is (0: the full waves, 1: still). Last, so that the
// outputs of before keep their locations.
out vec3 fragWater;

void addGerstnerWave(
  vec2 d,
  float amp,
  float freq,
  float spd,
  float steep,
  float coordU,
  float coordV,
  float t,
  inout float dispU,
  inout float dispV,
  inout float dispH,
  inout float dhdU,
  inout float dhdV
) {
  float phase = (d.x * coordU + d.y * coordV) * freq + t * spd;
  float s = sin(phase);
  float c = cos(phase);
  float q = steep * amp;
  dispU += d.x * q * c;
  dispV += d.y * q * c;
  dispH += amp * s;
  dhdU += d.x * amp * freq * c;
  dhdV += d.y * amp * freq * c;
}

// Emits the vertex: [uvNudge] is added to the plane coordinates passed on
// (the standard layout's texture coordinates times 1e-6, which keeps that
// input alive), [water] is passed on as `fragWater`; its calm (z) scales the
// waves down.
void emitWaterVertex(vec2 uvNudge, vec3 water) {
  mat4 model = instanceModelMatrix();
  vec3 worldPos = (model * vec4(vertexPosition, 1.0)).xyz;
  vec3 up = normalize(waterVert.upAndSteepness.xyz);

  // Orthonormal tangent basis (uAxis, vAxis) on the water plane perpendicular
  // to `up`.
  vec3 ref = abs(up.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
  vec3 uAxis = normalize(cross(ref, up));
  vec3 vAxis = normalize(cross(up, uAxis));

  float coordU = dot(worldPos, uAxis);
  float coordV = dot(worldPos, vAxis);

  float t = waterVert.waveParams.x;
  float amp = waterVert.waveParams.y;
  float freq = waterVert.waveParams.z;
  float spd = waterVert.waveParams.w;
  float steep = waterVert.upAndSteepness.w;

  float dispU = 0.0;
  float dispV = 0.0;
  float dispH = 0.0;
  float dhdU = 0.0;
  float dhdV = 0.0;

  addGerstnerWave(
    vec2(0.8944, 0.4472),
    amp,
    freq,
    spd,
    steep,
    coordU,
    coordV,
    t,
    dispU,
    dispV,
    dispH,
    dhdU,
    dhdV
  );
  addGerstnerWave(
    vec2(-0.6000, 0.8000),
    amp * 0.62,
    freq * 1.65,
    spd * 1.25,
    steep,
    coordU,
    coordV,
    t,
    dispU,
    dispV,
    dispH,
    dhdU,
    dhdV
  );
  addGerstnerWave(
    vec2(0.3162, -0.9487),
    amp * 0.38,
    freq * 2.70,
    spd * 1.55,
    steep,
    coordU,
    coordV,
    t,
    dispU,
    dispV,
    dispH,
    dhdU,
    dhdV
  );
  addGerstnerWave(
    vec2(-0.9239, -0.3827),
    amp * 0.24,
    freq * 4.10,
    spd * 1.90,
    steep,
    coordU,
    coordV,
    t,
    dispU,
    dispV,
    dispH,
    dhdU,
    dhdV
  );

  if (water.z > 0.0) {
    float waves = clamp(1.0 - water.z, 0.0, 1.0);
    dispU *= waves;
    dispV *= waves;
    dispH *= waves;
    dhdU *= waves;
    dhdV *= waves;
  }

  vec3 displaced = worldPos + uAxis * dispU + vAxis * dispV + up * dispH;
  vec3 waveNormal = normalize(up - uAxis * dhdU - vAxis * dhdV);

  fragPosition = displaced;
  fragNormal = waveNormal;
  fragUv = vec2(coordU, coordV) + uvNudge;
  fragColor = vertexColor * instanceColor;
  fragCrest = amp > 1e-5 ? clamp(0.5 + dispH / (amp * 2.2), 0.0, 1.0) : 0.0;
  fragWater = water;

  gl_Position = camera.viewProjection * vec4(displaced, 1.0);
  fragClipPos = gl_Position;
}

#endif
