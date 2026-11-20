#version 460 core

// A translucent energy wall (`BarrierMaterial`), drawn on any mesh whose
// vertices carry:
// - `vertexTexCoord.x`: the distance along the wall, in scene units;
// - `vertexTexCoord.y`: the height up the wall, 0 at its foot, 1 at its top;
// - `vertexNormal`: the normal of the wall, for the glint at grazing angles.
// `BarrierMesh` builds such meshes; any mesh with these attributes works.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;

#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/outline.glsl>

uniform BarrierShape {
  // x: the appear factor; at 0 or below nothing is drawn.
  vec4 params;
} barrierShape;

out vec3 fragWorldPosition;
out vec3 fragNormal;
out vec2 fragWall;
out vec4 fragInstanceColor;

void main() {
  mat4 model = instanceModelMatrix();
  vec4 world = model * vec4(vertexPosition, 1.0);
  fragWorldPosition = world.xyz;
  // The inverse transpose, so the glint stays right under non-uniform scale.
  fragNormal = outlineWorldNormal(model, vertexNormal);
  fragWall = vertexTexCoord;
  fragInstanceColor = instanceColor;
  vec4 clip = camera.viewProjection * world;
  if (barrierShape.params.x <= 0.0 || instanceColor.a <= 0.0) {
    // A wall that has not appeared, or an instance faded out: every vertex
    // lands on one point outside the clip volume, so no fragment runs.
    clip = vec4(2.0, 2.0, 2.0, 1.0);
  }
  gl_Position = clip;
}
