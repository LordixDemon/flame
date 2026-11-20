#version 460 core

// StylizedMaterial with a base color texture, for its textured skinned layout
// (StylizedMaterial.texturedSkinnedVertexLayout): skinned as in
// stylized_material_skinned.vert, with the texture coordinates of the
// vertices passed on.

#define FLAME_STYLIZED_TEXTURED
#include <flame_3d/stylized_material_vertex.glsl>
#include <flame_3d/skinning.glsl>

void main() {
  mat4 skin = computeSkinMatrix();
  emitStylizedVertex(
    (skin * vec4(vertexPosition, 1.0)).xyz,
    (skin * vec4(vertexNormal, 0.0)).xyz
  );
}
