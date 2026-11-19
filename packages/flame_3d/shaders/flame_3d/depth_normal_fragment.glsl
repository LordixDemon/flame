#ifndef FLAME_DEPTH_NORMAL_FRAGMENT_GLSL_
#define FLAME_DEPTH_NORMAL_FRAGMENT_GLSL_

// The fragment shader of the depth-normal prepass: writes the encoding of
// <flame_3d/depth_normal_encoding.glsl> for every fragment.

#include <flame_3d/depth_normal_encoding.glsl>

in vec3 fragViewPos;

out vec4 outColor;

void main() {
  outColor = encodeDepthNormal(fragViewPos);
}

#endif
