#version 460 core

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

out vec2 fragUv;
out vec4 fragColor;
out vec4 fragInstanceColor;
out vec4 fragInstanceData;
out float fragClipDepth;

void main() {
  vec4 worldPos = instanceModelMatrix() * vec4(vertexPosition, 1.0);
  vec4 clip = camera.viewProjection * worldPos;
  gl_Position = clip;
  fragClipDepth = clamp(clip.z / max(clip.w, 1e-5), 0.0, 1.0);
  fragUv = vertexTexCoord;
  fragColor = vertexColor;
  fragInstanceColor = instanceColor;
  fragInstanceData = instanceData;
}
