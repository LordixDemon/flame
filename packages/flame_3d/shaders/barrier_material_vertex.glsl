#ifndef BARRIER_MATERIAL_VERTEX_GLSL_
#define BARRIER_MATERIAL_VERTEX_GLSL_

// A translucent energy wall (`BarrierMaterial`), drawn on any mesh whose
// vertices carry:
// - `vertexTexCoord.x`: the distance along the wall, in scene units;
// - `vertexTexCoord.y`: the height up the wall, 0 at its foot, 1 at its top;
// - `vertexNormal`: the normal of the wall, for the glint at grazing angles.
// `BarrierMesh` builds such meshes; any mesh with these attributes works.
//
// Besides placing the wall, it scales its height (along the mesh's y axis,
// about y = 0, the foot of `BarrierMesh` walls) and, built with
// `BARRIER_WOBBLE` defined (the full variant), when the wobble is on, moves
// the surface along its normal around each impact: a damped wave that
// spreads from the point hit. Both are off by default (a scale of 1, an
// amplitude of 0), and then the stage computes exactly what it did before.
// The wobble needs a mesh with rows and columns close enough to show it.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/outline.glsl>

uniform BarrierShape {
  // x: the appear factor; at 0 or below nothing is drawn. y: the scale of
  // the wall's height; at 0 or below nothing is drawn. z: the wobble's
  // amplitude in scene units (0: off). w: the number of active impacts.
  vec4 params;
  // x: the wobble's wavenumber (radians per scene unit), y: its speed (scene
  // units per second), z: its decay (per second), w: 1 / its radius squared.
  vec4 wobble;
  // x: 1 / the impact duration, y: 1 / half a wavelength, zw: unused.
  vec4 wobbleExtra;
  // xyz: world position, w: age in seconds. The active impacts come first.
  vec4 impactPositions[8];
  // The strength of each impact: [0].xyzw for 0 to 3, [1].xyzw for 4 to 7.
  vec4 impactStrengths[2];
} barrierShape;

out vec3 fragWorldPosition;
out vec3 fragNormal;
out vec2 fragWall;
out vec4 fragInstanceColor;
// x: the height above the foot in world units, y: the wobble of the surface,
// from -1 to 1 times the strength of the impacts.
out vec2 fragDetail;

#ifdef BARRIER_WOBBLE
// The wobble, from -1 to 1 (x), and its rate of change with the distance
// (y), at a distance [d] from an impact of age [age]: a wave that leaves the
// point hit at the wobble's speed, oscillates behind its front and dies out
// with time, distance and the impact's life.
vec2 wave(float d, float age) {
  float behind = age * barrierShape.wobble.y - d;
  if (behind <= 0.0) {
    return vec2(0.0);
  }
  float k = barrierShape.wobble.x;
  float rise = barrierShape.wobbleExtra.y;
  float onset = clamp(behind * rise, 0.0, 1.0);
  float onsetSlope = onset < 1.0 ? -rise : 0.0;
  float envelope = exp(
        -barrierShape.wobble.z * age - d * d * barrierShape.wobble.w
      ) *
      max(1.0 - age * barrierShape.wobbleExtra.x, 0.0);
  float s = sin(behind * k);
  float c = cos(behind * k);
  float h = s * onset * envelope;
  float slope = envelope *
      (-k * c * onset +
          s * onsetSlope -
          2.0 * d * barrierShape.wobble.w * s * onset);
  return vec2(h, slope);
}

// Adds the wobble of the impact [positionAge] of [strength] at the world
// point [p] of normal [n] to [height], and its slope along the wall to
// [slope].
void addWobble(
  vec4 positionAge,
  float strength,
  vec3 p,
  vec3 n,
  inout float height,
  inout vec3 slope
) {
  if (strength <= 0.0 || positionAge.w < 0.0) {
    return;
  }
  vec3 offset = p - positionAge.xyz;
  vec2 w = wave(length(offset), positionAge.w);
  height += strength * w.x;
  vec3 along = offset - n * dot(offset, n);
  float alongLength = length(along);
  if (alongLength > 1e-5) {
    slope += along * (strength * w.y / alongLength);
  }
}

#endif

void main() {
  mat4 model = instanceModelMatrix();
  vec3 position = vertexPosition;
  vec3 normal = vertexNormal;
  float heightScale = barrierShape.params.y;
  if (heightScale != 1.0) {
    // Scaled about y = 0; the normal by the inverse transpose of the scale.
    position.y *= heightScale;
    normal.y /= max(heightScale, 1e-4);
  }
  vec4 world = model * vec4(position, 1.0);
  // The inverse transpose, so the glint stays right under non-uniform scale.
  vec3 worldNormal = outlineWorldNormal(model, normal);
  float wobble = 0.0;
#ifdef BARRIER_WOBBLE
  float amplitude = barrierShape.params.z;
  float count = barrierShape.params.w;
  if (amplitude > 0.0 && count > 0.5) {
    vec3 p = world.xyz;
    float height = 0.0;
    vec3 slope = vec3(0.0);
    vec4 s0 = barrierShape.impactStrengths[0];
    vec4 s1 = barrierShape.impactStrengths[1];
    addWobble(barrierShape.impactPositions[0], s0.x, p, worldNormal, height,
        slope);
    if (count > 1.5) {
      addWobble(barrierShape.impactPositions[1], s0.y, p, worldNormal,
          height, slope);
    }
    if (count > 2.5) {
      addWobble(barrierShape.impactPositions[2], s0.z, p, worldNormal,
          height, slope);
    }
    if (count > 3.5) {
      addWobble(barrierShape.impactPositions[3], s0.w, p, worldNormal,
          height, slope);
    }
    if (count > 4.5) {
      addWobble(barrierShape.impactPositions[4], s1.x, p, worldNormal,
          height, slope);
    }
    if (count > 5.5) {
      addWobble(barrierShape.impactPositions[5], s1.y, p, worldNormal,
          height, slope);
    }
    if (count > 6.5) {
      addWobble(barrierShape.impactPositions[6], s1.z, p, worldNormal,
          height, slope);
    }
    if (count > 7.5) {
      addWobble(barrierShape.impactPositions[7], s1.w, p, worldNormal,
          height, slope);
    }
    world.xyz += worldNormal * (amplitude * height);
    worldNormal = normalize(worldNormal - slope * amplitude);
    wobble = clamp(height, -1.0, 1.0);
  }
#endif
  fragWorldPosition = world.xyz;
  fragNormal = worldNormal;
  fragWall = vertexTexCoord;
  fragInstanceColor = instanceColor;
  fragDetail = vec2(position.y * length(model[1].xyz), wobble);
  vec4 clip = camera.viewProjection * world;
  if (barrierShape.params.x <= 0.0 ||
      heightScale <= 0.0 ||
      instanceColor.a <= 0.0) {
    // A wall that has not appeared or has no height, or an instance faded
    // out: every vertex lands on one point outside the clip volume, so no
    // fragment runs.
    clip = vec4(2.0, 2.0, 2.0, 1.0);
  }
  gl_Position = clip;
}

#endif
