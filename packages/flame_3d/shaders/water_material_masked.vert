#version 460 core

// WaterMaterial for WaterMaterial.vertexLayout: each vertex says how deep the
// water is under it, how much it foams and how calm it is (vertexWater), see
// flame_3d/water_vertex.glsl.

in vec3 vertexPosition;
in vec4 vertexColor;
// x: the depth of the water under the vertex, in world units, y: its foam
// mask, z: how calm it is (0: the full waves, 1: still).
in vec3 vertexWater;

#include <flame_3d/water_vertex.glsl>

void main() {
  emitWaterVertex(vec2(0.0), vertexWater);
}
