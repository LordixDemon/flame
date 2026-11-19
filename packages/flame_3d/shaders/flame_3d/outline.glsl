#ifndef FLAME_OUTLINE_GLSL_
#define FLAME_OUTLINE_GLSL_

// The vertex step of an inverted-hull outline, shared by OutlineMaterial and
// by custom materials whose vertex shader moves vertices on its own (wind,
// morphs, waves): push each vertex along its normal, transformed correctly,
// so that the hull of a scaled or displaced mesh stays as thick everywhere.
//
//   vec3 n = outlineWorldNormal(model, normal);
//   gl_Position = outlineExtrude(
//     camera.viewProjection, worldPosition, n, thickness, false, 1.0, bias);
//
// Displace the vertex (and its normal) first, exactly as the material that
// draws the object does, then call these with the displaced values: the
// outline then follows the displaced surface.

// The unit world-space normal of a model-space normal under model (any 4x4
// transform whose upper 3x3 part maps directions): the 3x3 part's inverse
// transpose, computed as its cofactor matrix so that it needs no inverse,
// turned back outwards for mirroring transforms. Unlike mat3(model) * normal,
// it stays perpendicular to the surface under non-uniform scale.
vec3 outlineWorldNormal(mat4 model, vec3 normal) {
  vec3 x = model[0].xyz;
  vec3 y = model[1].xyz;
  vec3 z = model[2].xyz;
  mat3 cofactor = mat3(cross(y, z), cross(z, x), cross(x, y));
  float side = dot(x, cross(y, z)) < 0.0 ? -1.0 : 1.0;
  vec3 n = cofactor * normal * side;
  float len = length(n);
  return len > 1e-6 ? n / len : vec3(0.0, 1.0, 0.0);
}

// The clip position of worldPos pushed out along the unit worldNormal by
// thickness, then moved away from the camera by depthBias (in clip depth,
// clamped to the depth range).
//
// Without screenSpace, thickness is in world units. With screenSpace, it is a
// fraction of the viewport height, the same in pixels at any distance: the
// vertex moves in the picture along the projected normal, aspect being the
// viewport's height / width (projection[0][0] / projection[1][1]).
vec4 outlineExtrude(
  mat4 viewProjection,
  vec3 worldPos,
  vec3 worldNormal,
  float thickness,
  bool screenSpace,
  float aspect,
  float depthBias
) {
  vec4 clipPos;
  if (screenSpace) {
    clipPos = viewProjection * vec4(worldPos, 1.0);
    vec4 clipNormal = viewProjection * vec4(worldNormal, 0.0);
    vec2 dir = clipNormal.xy;
    // Compensate for aspect ratio so horizontal and vertical strokes match.
    float a = max(aspect, 1e-4);
    vec2 metric = vec2(dir.x / a, dir.y);
    float mLen = length(metric);
    if (mLen > 1e-6) {
      vec2 unit = metric / mLen;
      clipPos.xy += vec2(unit.x * a, unit.y) * thickness * clipPos.w;
    }
  } else {
    clipPos = viewProjection * vec4(worldPos + worldNormal * thickness, 1.0);
  }
  clipPos.z = clamp(clipPos.z + depthBias * clipPos.w, 0.0, clipPos.w);
  return clipPos;
}

#endif
