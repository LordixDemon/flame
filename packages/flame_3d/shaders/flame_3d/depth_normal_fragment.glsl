#ifndef FLAME_DEPTH_NORMAL_FRAGMENT_GLSL_
#define FLAME_DEPTH_NORMAL_FRAGMENT_GLSL_

// Encodes the depth of the fragment [0..1] in 16 bits across RG and the
// view-space geometric normal XY in BA of an RGBA8888 target (clear value
// 0xFFFF8080 -> depth 1.0). The depth is the one the GPU computes for the
// pixel (`gl_FragCoord.z`): `z / w` interpolated from the vertices would be
// wrong across large triangles under a perspective camera, and meaningless
// for triangles that reach behind the camera.

in vec3 fragViewPos;

out vec4 outColor;

void main() {
  float d = floor(clamp(gl_FragCoord.z, 0.0, 1.0) * 65535.0 + 0.5);
  float hi = floor(d / 256.0);
  float lo = d - hi * 256.0;

  vec3 dx = dFdx(fragViewPos);
  vec3 dy = dFdy(fragViewPos);
  vec3 n = cross(dx, dy);
  float len = length(n);
  n = len > 1e-8 ? (n / len) : vec3(0.0, 0.0, 1.0);
  if (n.z < 0.0) {
    n = -n;
  }

  outColor = vec4(hi / 255.0, lo / 255.0, n.xy * 0.5 + 0.5);
}

#endif
