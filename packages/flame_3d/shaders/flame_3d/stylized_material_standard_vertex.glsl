#ifndef FLAME_STYLIZED_MATERIAL_STANDARD_VERTEX_GLSL_
#define FLAME_STYLIZED_MATERIAL_STANDARD_VERTEX_GLSL_

// The vertex stage of StylizedMaterial for the standard vertex layout
// (stylized_material_standard.vert): the vertex color is read, the other
// per-vertex values are neutral (unoccluded, tinted by the instance color, no
// accent, emissive, gloss nor sway). Skinned surfaces are skinned. The
// instance data is decoded and passed on as in stylized_material.vert (see
// flame_3d/stylized_instance_data.glsl). With FLAME_STYLIZED_TEXTURED defined
// (stylized_material_textured_standard.vert), the texture coordinates of the
// vertices are passed on in `fragTexCoord` for the base color texture.

in vec3 vertexPosition;
in vec4 vertexColor;
in vec3 vertexNormal;
#ifdef FLAME_STYLIZED_TEXTURED
in vec2 vertexTexCoord;
#endif

#include <flame_3d/skinning.glsl>
#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/stylized_instance_data.glsl>

// StylizedMaterial.depthBias (the stylized layout keeps it in its Wind block),
// see flame_3d/stylized_material_vertex.glsl.
uniform StylizedDepth {
  float bias;
} stylizedDepth;

out vec3 fragPosition;
out vec3 fragNormal;
out vec4 fragColor;
out vec4 fragMasks;
out float fragOcclusion;
out vec4 fragInstanceColor;
out vec4 fragInstanceData;
out vec3 fragInstanceColorFine;
#ifdef FLAME_STYLIZED_TEXTURED
out vec2 fragTexCoord;
#endif

// See stylized_material.vert.
vec3 transformNormal(mat4 model, vec3 normal) {
  vec3 x = model[0].xyz;
  vec3 y = model[1].xyz;
  vec3 z = model[2].xyz;
  mat3 cofactor = mat3(cross(y, z), cross(z, x), cross(x, y));
  float side = dot(x, cross(y, z)) < 0.0 ? -1.0 : 1.0;
  return cofactor * normal * side;
}

void main() {
  mat4 skinMatrix = computeSkinMatrix();
  vec3 position = (skinMatrix * vec4(vertexPosition, 1.0)).xyz;
  vec3 normal = (skinMatrix * vec4(vertexNormal, 0.0)).xyz;

  mat4 model = instanceModelMatrix();
  vec4 worldPosition = model * vec4(position, 1.0);
  gl_Position = camera.viewProjection * worldPosition;
  gl_Position.z -= stylizedDepth.bias * gl_Position.w;

  fragPosition = worldPosition.xyz;
  fragNormal = transformNormal(model, normal);
  fragColor = vertexColor;
  fragMasks = vec4(1.0, 0.0, 0.0, 0.0);
  fragOcclusion = 1.0;
  fragInstanceColor = instanceColor;
  fragInstanceData = stylizedFragmentInstanceData(instanceData);
  fragInstanceColorFine = stylizedInstanceColorFine(instanceColor.rgb);
#ifdef FLAME_STYLIZED_TEXTURED
  fragTexCoord = vertexTexCoord;
#endif
}

#endif
