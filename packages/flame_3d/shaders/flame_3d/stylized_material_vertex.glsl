#ifndef FLAME_STYLIZED_MATERIAL_VERTEX_GLSL_
#define FLAME_STYLIZED_MATERIAL_VERTEX_GLSL_

// The vertex stage of StylizedMaterial for its own vertex layout
// (StylizedMaterial.vertexLayout): stylized_material.vert draws the vertices
// as they are, stylized_material_skinned.vert skins them first. Both feed
// flame_3d/stylized_material_fragment.glsl. With FLAME_STYLIZED_TEXTURED
// defined (stylized_material_textured.vert and
// stylized_material_textured_skinned.vert), the vertices also have the
// texture coordinates of the base color texture, passed on in
// `fragTexCoord`.

#include <flame_3d/instancing.glsl>
#include <flame_3d/stylized_material_vertex_core.glsl>

void emitStylizedVertex(vec3 position, vec3 normal) {
  emitStylizedVertexCore(
    position,
    normal,
    instanceModelMatrix(),
    instanceColor,
    instanceData
  );
}

#endif
