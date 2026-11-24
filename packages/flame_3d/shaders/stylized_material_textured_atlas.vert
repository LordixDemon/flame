#version 460 core

#define FLAME_STYLIZED_TEXTURED
#include <flame_3d/stylized_material_vertex.glsl>

void main() {
  emitStylizedVertex(vertexPosition, vertexNormal);
}
