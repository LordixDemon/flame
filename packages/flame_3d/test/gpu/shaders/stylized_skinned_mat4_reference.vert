#version 460 core

// stylized_material_skinned.vert with the whole joint matrices of before,
// see reference/skinning_mat4.glsl.

#include <flame_3d/stylized_material_vertex.glsl>
#include <reference/skinning_mat4.glsl>

void main() {
  mat4 skin = computeSkinMatrix();
  emitStylizedVertex(
    (skin * vec4(vertexPosition, 1.0)).xyz,
    (skin * vec4(vertexNormal, 0.0)).xyz
  );
}
