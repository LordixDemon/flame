#version 460 core

// WaterMaterial for the standard vertex layout: animated Gerstner waves
// around any world up axis, drawn instanced (see flame_3d/water_vertex.glsl).
// The water under every vertex is WaterMaterial.defaultDepth deep, with no
// foam mask and the full waves.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;

#include <flame_3d/water_vertex.glsl>

void main() {
  emitWaterVertex(
    vertexTexCoord * 1e-6,
    vec3(waterVert.surface.x, 0.0, 0.0)
  );
}
