#version 460 core

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;
in vec3 vertexNormal;
in vec4 vertexTangent;
in vec2 vertexTexCoord1;

#include <flame_3d/skinning.glsl>
#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>

out vec2 fragTexCoord;
out vec2 fragTexCoord1;
out vec4 fragColor;
out vec3 fragPosition;
out vec3 fragNormal;
out vec4 fragTangent;
out vec4 fragInstanceColor;
out vec4 fragInstanceData;
out vec4 fragClipPos;

void main() {
  mat4 skinMatrix = computeSkinMatrix();
  vec3 position = (skinMatrix * vec4(vertexPosition, 1.0)).xyz;
  vec3 normal = normalize((skinMatrix * vec4(vertexNormal, 0.0)).xyz);
  vec3 tangent = (skinMatrix * vec4(vertexTangent.xyz, 0.0)).xyz;

  mat4 model = instanceModelMatrix();
  mat3 normalMat = mat3(transpose(inverse(model)));

  vec4 worldPosition = model * vec4(position, 1.0);
  fragPosition = worldPosition.xyz;
  fragNormal = normalMat * normal;
  vec3 worldTan = normalMat * tangent;
  float tanLen = length(worldTan);
  fragTangent = tanLen > 1e-5
      ? vec4(worldTan / tanLen, vertexTangent.w)
      : vec4(0.0);

  vec4 clip = camera.viewProjection * worldPosition;
  gl_Position = clip;
  fragClipPos = clip;

  fragTexCoord = vertexTexCoord;
  fragTexCoord1 = vertexTexCoord1;
  fragColor = vertexColor;
  fragInstanceColor = instanceColor;
  fragInstanceData = instanceData;
}
