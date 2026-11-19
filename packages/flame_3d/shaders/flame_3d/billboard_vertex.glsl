#ifndef FLAME_BILLBOARD_VERTEX_GLSL_
#define FLAME_BILLBOARD_VERTEX_GLSL_

// The corners of the instanced billboards of `BillboardBatch3D`, shared by
// the billboard material and its depth-normal prepass variant. Include it
// after <flame_3d/instancing.glsl>. Per instance:
// - instanceModel0: center (xyz, world space) and width (w)
// - instanceModel1: locked upAxis (xyz) and height (w)
// - instanceModel2: uvRect (left, top, width, height)
// - instanceModel3: anchorY (x, 0 = center, -0.5 = bottom edge), tiltRad (y),
//                   rollRad (z), mode (w: 0 = spherical, 1 = cylindrical)
// - instanceColor:  RGBA tint
// - instanceData:   emissiveBoost (x), unlit (y), fade (z),
//                   anchorX (w, 0 = center, -0.5 = left edge)

uniform BillboardFrame {
  vec4 camRight;
  vec4 camUp;
  vec4 camBack;
} bFrame;

// The world position of the billboard corner [corner] (in [-0.5, 0.5]) of
// the instance, and the direction its face looks to in [normal].
vec3 billboardCorner(vec2 corner, out vec3 normal) {
  mat4 inst = instanceModelMatrix();
  vec3 center = inst[0].xyz;
  float width = inst[0].w;
  vec3 lockedUp = inst[1].xyz;
  float height = inst[1].w;
  float anchorY = inst[3].x;
  float tiltRad = inst[3].y;
  float rollRad = inst[3].z;
  float mode = inst[3].w;
  float anchorX = instanceData.w;

  vec3 right = bFrame.camRight.xyz;
  vec3 up = bFrame.camUp.xyz;
  normal = bFrame.camBack.xyz;

  if (mode > 0.5) {
    // Cylindrical / HD-2D standee locked around `lockedUp` with optional tilt.
    vec3 axisUp = length(lockedUp) > 1e-5 ? normalize(lockedUp) : up;
    vec3 side = right - axisUp * dot(right, axisUp);
    if (dot(side, side) < 1e-8) {
      side = cross(axisUp, normal);
    }
    right = normalize(side);
    vec3 faceN = normalize(cross(right, axisUp));
    if (dot(faceN, normal) < 0.0) {
      faceN = -faceN;
    }
    float ct = cos(tiltRad);
    float st = sin(tiltRad);
    up = normalize(axisUp * ct - faceN * st);
    normal = normalize(cross(right, up));
  }

  // The corner in world units around the pivot, rolled as a rigid quad.
  vec2 local = vec2((corner.x - anchorX) * width, (corner.y - anchorY) * height);
  if (abs(rollRad) > 1e-5) {
    float cr = cos(rollRad);
    float sr = sin(rollRad);
    local = vec2(local.x * cr - local.y * sr, local.x * sr + local.y * cr);
  }
  return center + right * local.x + up * local.y;
}

#endif
