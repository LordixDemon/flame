#version 460 core

// BillboardMaterial3D's vertex stage (billboard_material.vert), copied.

// Instanced HD-2D billboard / standee vertex shader, see
// <flame_3d/billboard_vertex.glsl> for the instance data.

in vec3 vertexPosition;
in vec2 vertexTexCoord;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/billboard_vertex.glsl>

out vec3 fragPosition;
out vec3 fragNormal;
out vec2 fragUv;
out vec4 fragColor;
out vec4 fragData;

void main() {
  vec3 normal;
  vec3 worldPos = billboardCorner(vertexPosition.xy, normal);
  vec4 uvRect = instanceModel2;

  fragPosition = worldPos;
  fragNormal = normal;
  fragUv = uvRect.xy + vertexTexCoord * uvRect.zw;
  fragColor = instanceColor;
  fragData = instanceData;

  gl_Position = camera.viewProjection * vec4(worldPos, 1.0);
}
