#version 460 core

// StylizedMaterial for its own vertex layout (StylizedMaterial.vertexLayout).
// stylized_material_standard.vert reads the standard layout instead; both
// feed flame_3d/stylized_material_fragment.glsl.

in vec3 vertexPosition;
in vec3 vertexNormal;
// rgb: the vertex color, a: its alpha.
in vec4 vertexColor;
// x: tint mask, y: accent mask, z: emissive mask, w: gloss.
in vec4 vertexMasks;
// Ambient occlusion: 1 is unoccluded, 0 fully occluded.
in float vertexOcclusion;
// How much the vertex sways in the wind.
in float vertexSway;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

// The wind sway: a vertex moves by
// `direction * amplitude * sin(time * frequency + dot(origin, phaseScale))`
// times its sway weight, where `origin` is the world position of its object.
uniform Wind {
  vec3 direction;
  float amplitude;
  vec3 phaseScale;
  float frequency;
  float time;
} wind;

out vec3 fragPosition;
out vec3 fragNormal;
out vec4 fragColor;
out vec4 fragMasks;
out float fragOcclusion;
out vec4 fragInstanceColor;

// Transforms normals by the model matrix: its cofactor matrix, which is the
// inverse transpose up to a scale, keeps them perpendicular to the surface
// under any scale.
vec3 transformNormal(mat4 model, vec3 normal) {
  vec3 x = model[0].xyz;
  vec3 y = model[1].xyz;
  vec3 z = model[2].xyz;
  mat3 cofactor = mat3(cross(y, z), cross(z, x), cross(x, y));
  float side = dot(x, cross(y, z)) < 0.0 ? -1.0 : 1.0;
  return cofactor * normal * side;
}

void main() {
  mat4 model = instanceModelMatrix();
  vec4 worldPosition = model * vec4(vertexPosition, 1.0);
  float phase = wind.time * wind.frequency + dot(model[3].xyz, wind.phaseScale);
  worldPosition.xyz += wind.direction * (sin(phase) * wind.amplitude * vertexSway);
  gl_Position = camera.viewProjection * worldPosition;

  fragPosition = worldPosition.xyz;
  fragNormal = transformNormal(model, vertexNormal);
  fragColor = vertexColor;
  fragMasks = vertexMasks;
  fragOcclusion = vertexOcclusion;
  fragInstanceColor = instanceColor;
}
