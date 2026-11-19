#version 460 core

// The billboards of `BillboardBatch3D` in the depth-normal prepass, placed as
// in billboard_material.vert.

in vec3 vertexPosition;
in vec2 vertexTexCoord;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/billboard_vertex.glsl>

out vec3 fragViewPos;
out vec2 fragUv;
out float fragAlpha;

void main() {
  vec3 normal;
  vec3 worldPos = billboardCorner(vertexPosition.xy, normal);
  vec4 viewPos = camera.view * vec4(worldPos, 1.0);
  gl_Position = camera.projection * viewPos;
  fragViewPos = viewPos.xyz;
  vec4 uvRect = instanceModel2;
  fragUv = uvRect.xy + vertexTexCoord * uvRect.zw;
  fragAlpha = instanceColor.a * (1.0 - clamp(instanceData.z, 0.0, 1.0));
}
