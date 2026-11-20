#version 460 core

// A custom lit material that reads the lights through flame_3d/lights.glsl
// and the light grid through flame_3d/light_grid.glsl, as the Lighting page
// shows: Lambert shading of the ambient light, the point and spot lights of
// the blocks the grid leaves to them, then those of the fragment's cell.

in vec3 fragPosition;
in vec3 fragNormal;

out vec4 outColor;

#include <flame_3d/lights.glsl>
#include <flame_3d/light_grid.glsl>

// The light of a point light of [color] and [intensity], [range] (0 for the
// inverse square) and position [at], on a surface of normal [n].
vec3 pointLight(vec3 at, float range, vec3 color, float intensity, vec3 n) {
  vec3 toLight = at - fragPosition;
  float d = max(length(toLight), 0.0001);
  float falloff = range > 0.0
    ? pow(max(1.0 - d / range, 0.0), 2.0)
    : 1.0 / (d * d);
  return color * (intensity * falloff * max(dot(n, toLight / d), 0.0));
}

// The same, through the cone of a spot light: [direction] towards the light,
// [cone] (cos outer, 1 / (cos inner - cos outer)).
vec3 spotLight(
  vec3 at,
  float range,
  vec3 color,
  float intensity,
  vec3 direction,
  vec2 cone,
  vec3 n
) {
  vec3 l = normalize(at - fragPosition);
  float angular = clamp((dot(l, direction) - cone.x) * cone.y, 0.0, 1.0);
  return pointLight(at, range, color, intensity * angular * angular, n);
}

void main() {
  vec3 n = normalize(fragNormal);
  vec3 lit = ambientLight.color.rgb * ambientLight.intensity;

  int blockPoints = int(lightGridBlockPointLights(lights.numLights));
  for (int i = 0; i < blockPoints; i++) {
    lit += pointLight(
      lights.positions[i],
      lights.ranges[i].x,
      lights.colors[i].rgb,
      lights.intensities[i].x,
      n
    );
  }
  int blockSpots = int(lightGridBlockSpotLights(spotLights.numLights));
  for (int i = 0; i < blockSpots; i++) {
    lit += spotLight(
      spotLights.positions[i],
      spotLights.cones[i].z,
      spotLights.colors[i].rgb,
      spotLights.colors[i].a,
      spotLights.directions[i].xyz,
      spotLights.cones[i].xy,
      n
    );
  }

  vec4 cell = lightGridCell(fragPosition);
  for (int k = 0; k < LIGHT_GRID_POINT_LIGHTS_PER_CELL; k++) {
    if (float(k) >= cell.y) {
      break;
    }
    vec4 positionRange;
    vec4 colorIntensity;
    lightGridPointLight(cell, k, positionRange, colorIntensity);
    lit += pointLight(
      positionRange.xyz,
      positionRange.w,
      colorIntensity.rgb,
      colorIntensity.a,
      n
    );
  }
  for (int k = 0; k < LIGHT_GRID_SPOT_LIGHTS_PER_CELL; k++) {
    if (float(k) >= cell.w) {
      break;
    }
    vec4 positionRange;
    vec4 colorIntensity;
    vec4 direction;
    vec4 cone;
    lightGridSpotLight(cell, k, positionRange, colorIntensity, direction, cone);
    lit += spotLight(
      positionRange.xyz,
      positionRange.w,
      colorIntensity.rgb,
      colorIntensity.a,
      direction.xyz,
      cone.xy,
      n
    );
  }
  outColor = vec4(clamp(lit * vec3(0.85, 0.82, 0.78), 0.0, 1.0), 1.0);
}
