#version 460 core

// StylizedMaterial with a base color texture, for its textured layout
// (StylizedMaterial.texturedVertexLayout): stylized_material.vert, with the
// texture coordinates of the vertices passed on.

#define FLAME_STYLIZED_TEXTURED
#include <flame_3d/stylized_material_vertex.glsl>

void main() {
  emitStylizedVertex(vertexPosition, vertexNormal);
}
