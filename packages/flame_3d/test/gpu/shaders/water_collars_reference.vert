#version 460 core

// WaterMaterial's vertex stage for the standard layout, unchanged (the test
// replaces only the fragment stage).

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
