#version 460 core

// A custom outline whose vertex shader moves vertices on its own (a lean
// along x that grows with y, like wind), then extrudes the displaced vertex
// with flame_3d/outline.glsl.

in vec3 vertexPosition;
in vec3 vertexNormal;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/outline.glsl>

uniform Lean {
  // x: lean along x per unit of y, y: outline thickness.
  vec4 params;
} lean;

out vec4 fragColor;

void main() {
  float k = lean.params.x;
  vec3 p = vertexPosition + vec3(k * vertexPosition.y, 0.0, 0.0);
  // The normal of the displaced surface: the inverse transpose of the
  // displacement's Jacobian times the normal.
  vec3 n = vertexNormal - vec3(0.0, k * vertexNormal.x, 0.0);
  mat4 model = instanceModelMatrix();
  vec3 worldPos = (model * vec4(p, 1.0)).xyz;
  gl_Position = outlineExtrude(
    camera.viewProjection,
    worldPos,
    outlineWorldNormal(model, n),
    lean.params.y,
    false,
    1.0,
    0.0
  );
  fragColor = instanceColor;
}
