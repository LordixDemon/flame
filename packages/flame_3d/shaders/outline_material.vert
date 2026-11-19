#version 460 core

// Inverted-hull silhouette contour (`OutlineMaterial`): pushes vertices out
// along their normals (flame_3d/outline.glsl) in either world space
// (`params.z < 0.5`) or clip/screen space (`params.z > 0.5`), modulated per
// instance by `instanceColor` and `instanceData` (`x`: thickness multiplier
// `1 + x`, `y`: extra clip depth bias). Drawn with front faces culled
// (`CullMode.frontFace`), only the outer back-face rim appears around the
// object's silhouette.

in vec3 vertexPosition;
in vec3 vertexNormal;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/outline.glsl>

uniform Outline {
  vec4 color;
  // x: thickness, y: clip depth bias, z: 1 for screen-space thickness, w: aspect (height / width).
  vec4 params;
} outline;

out vec4 fragColor;

void main() {
  mat4 model = instanceModelMatrix();
  float scale = max(0.0, 1.0 + instanceData.x);
  vec3 worldPos = (model * vec4(vertexPosition, 1.0)).xyz;
  gl_Position = outlineExtrude(
    camera.viewProjection,
    worldPos,
    outlineWorldNormal(model, vertexNormal),
    outline.params.x * scale,
    outline.params.z > 0.5,
    outline.params.w,
    outline.params.y + instanceData.y
  );
  fragColor = outline.color * instanceColor;
}
