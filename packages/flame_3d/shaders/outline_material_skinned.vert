#version 460 core

// Skinned variant of `outline_material.vert`: skins position and normal by up
// to four joints before extruding the silhouette contour.

in vec3 vertexPosition;
in vec3 vertexNormal;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/skinning.glsl>
#include <flame_3d/outline.glsl>

uniform Outline {
  vec4 color;
  vec4 params;
} outline;

out vec4 fragColor;

void main() {
  mat4 model = instanceModelMatrix();
  mat4 combined = model * computeSkinMatrix();
  float scale = max(0.0, 1.0 + instanceData.x);
  vec3 worldPos = (combined * vec4(vertexPosition, 1.0)).xyz;
  gl_Position = outlineExtrude(
    camera.viewProjection,
    worldPos,
    outlineWorldNormal(combined, vertexNormal),
    outline.params.x * scale,
    outline.params.z > 0.5,
    outline.params.w,
    outline.params.y + instanceData.y
  );
  fragColor = outline.color * instanceColor;
}
