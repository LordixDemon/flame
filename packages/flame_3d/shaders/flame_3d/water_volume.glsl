#ifndef FLAME_WATER_VOLUME_GLSL_
#define FLAME_WATER_VOLUME_GLSL_

// The body of water of a World3D (WaterVolumeSettings, World3D.waterVolume),
// filled by flame_3d once per render pass for every fragment shader that
// declares the `WaterVolume` uniform block (or folds its members into a
// merged pass block via `#define FLAME_WATER_VOLUME(member) ...` before
// including this file, as StylizedMaterial does): the surfaces below its
// level are tinted and darkened with their depth, receive the caustics the
// water's surface shows, and foam where they cross the level. No depth buffer
// is involved: the depth is the distance of the surface's own fragment below
// the level.

#ifndef FLAME_WATER_VOLUME
uniform WaterVolume {
  // xyz: the unit up axis, w: the level along it.
  vec4 plane;
  // rgb: the color submerged surfaces are filtered by near the surface,
  // a: the absorption, per world unit.
  vec4 shallow;
  // rgb: the color of the deep water, a: 1 when the volume is on.
  vec4 deep;
  // x: the caustics' strength, y: 1 / their size, z: the phase of their
  // period (0 to 2π), w: the width of the waterline foam band.
  vec4 caustics;
  // rgb: the caustics' color, a: how much of the light's color the waterline
  // foam takes (WaterVolumeSettings.waterlineLightTint, 0 to 1).
  vec4 causticColor;
  // rgb: the waterline foam's color, a: how much it covers.
  vec4 waterline;
  // xyz: the minimum corner of the box the water fills, w: 1 when bounded.
  vec4 boundsMin;
  // xyz: the maximum corner of the box.
  vec4 boundsMax;
  // y: the least light the waterline foam takes, a multiple of its color
  // (WaterVolumeSettings.waterlineLightFloor, 0 by default); xzw: unused.
  vec4 waterlineFoam;
} waterVolume;
#define FLAME_WATER_VOLUME(member) waterVolume.member
#endif

#include <flame_3d/water_pattern.glsl>

// Whether the pass has a water volume.
bool waterVolumeActive() {
  return FLAME_WATER_VOLUME(deep).a > 0.5;
}

// The coordinates of `position` in the plane of the water, in the frame
// WaterMaterial builds around its up axis (flame_3d/water_vertex.glsl), so
// that the caustics of the surface and of the floor line up.
vec2 waterVolumePlaneUv(vec3 position, vec3 up) {
  vec3 ref = abs(up.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
  vec3 uAxis = normalize(cross(ref, up));
  vec3 vAxis = normalize(cross(up, uAxis));
  return vec2(dot(position, uAxis), dot(position, vAxis));
}

// The color of a surface at the world `position` with the unit `normal`,
// whose lit `color` is `albedo * irradiance` (plus whatever else it emits),
// given the direct light `sunLight` its directional lights give it (after
// their shadows, its n·l included) and the direction `sunDirection` towards
// the main one. Surfaces above the level and its waterline band, and outside
// the volume's box, are returned unchanged.
vec3 applyWaterVolume(
  vec3 color,
  vec3 albedo,
  vec3 irradiance,
  vec3 sunLight,
  vec3 sunDirection,
  vec3 position,
  vec3 normal
) {
  vec4 plane = FLAME_WATER_VOLUME(plane);
  vec4 caustics = FLAME_WATER_VOLUME(caustics);
  float depth = plane.w - dot(position, plane.xyz);
  float band = caustics.w;
  if (depth < -band) {
    return color;
  }
  if (FLAME_WATER_VOLUME(boundsMin).w > 0.5) {
    vec3 lo = FLAME_WATER_VOLUME(boundsMin).xyz;
    vec3 hi = FLAME_WATER_VOLUME(boundsMax).xyz;
    if (any(lessThan(position, lo)) || any(greaterThan(position, hi))) {
      return color;
    }
  }

  vec3 up = plane.xyz;
  float phase = caustics.z;
  vec3 result = color;
  if (depth > 0.0) {
    if (caustics.x > 0.0) {
      // The network the surface focuses, seen where this surface's sunlight
      // entered the water: along the sunlight refracted by the surface
      // (its slope towards the horizon divided by about 1.33).
      vec3 across = (sunDirection - up * dot(sunDirection, up)) * 0.75;
      float rise = sqrt(max(1.0 - dot(across, across), 0.04));
      vec3 entry = position + across * (depth / rise);
      vec2 uv = waterVolumePlaneUv(entry, up) * caustics.y;
      // Faded in over the first few centimeters, so that the waterline
      // stays clean.
      float focus = waterCaustics(uv, phase) * caustics.x *
        clamp(depth * 8.0, 0.0, 1.0);
      result += albedo * sunLight * FLAME_WATER_VOLUME(causticColor).rgb *
        focus;
    }
    vec4 shallow = FLAME_WATER_VOLUME(shallow);
    float absorbed = 1.0 - exp(-depth * shallow.a);
    // The shallow color filters four times faster than the deep color
    // covers.
    vec3 filtered = result * mix(vec3(1.0), shallow.rgb,
      1.0 - exp(-depth * shallow.a * 4.0));
    result = mix(filtered, FLAME_WATER_VOLUME(deep).rgb, absorbed);
  }

  if (band > 0.0) {
    // A band of foam around the level, lapping up and down and broken up
    // along the surface's outline.
    vec2 uv = waterVolumePlaneUv(position, up) / band;
    float lap = waterNoise(uv * 0.35, phase) * 0.45 +
      0.25 * sin(phase * 3.0 + uv.x * 0.21 + uv.y * 0.17);
    float distance = abs(depth / band + lap);
    float foam = 1.0 - smoothstep(0.35, 1.0, distance);
    float breakup = waterNoise(uv * 0.9 + vec2(2.3, 0.7), -phase * 2.0);
    // Sparser on faces that lie flat in the water (the top of a slab passing
    // through it), where the whole face is in the band at once.
    float lying = abs(dot(normal, up));
    foam *= smoothstep(-0.55 + 0.75 * lying, 0.05 + 0.6 * lying, breakup);
    vec4 waterline = FLAME_WATER_VOLUME(waterline);
    vec3 foamLight = irradiance;
    float tint = FLAME_WATER_VOLUME(causticColor).a;
    if (tint < 1.0) {
      // Foam scatters every color alike: it takes the brightness of the
      // light (its luminance) and only `tint` of its color.
      foamLight = mix(
        vec3(dot(foamLight, WATER_LUMINANCE)),
        foamLight,
        max(tint, 0.0)
      );
    }
    // At most 1.25, at least the floor (waterlineLightFloor), which raises
    // the top when it is above it.
    float lightFloor = FLAME_WATER_VOLUME(waterlineFoam).y;
    foamLight = min(foamLight, vec3(max(1.25, lightFloor)));
    if (lightFloor > 0.0) {
      foamLight = max(foamLight, vec3(lightFloor));
    }
    vec3 foamColor = waterline.rgb * foamLight;
    result = mix(result, foamColor, foam * waterline.a);
  }
  return clamp(result, 0.0, 1.0);
}

#endif
