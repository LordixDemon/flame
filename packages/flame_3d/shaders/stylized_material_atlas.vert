#version 460 core

#include <flame_3d/stylized_material_vertex.glsl>

void main() {
  emitStylizedVertex(vertexPosition, vertexNormal);
}
