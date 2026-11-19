#version 460 core

// The billboards of `BillboardBatch3D` in the depth-normal prepass: discards
// the texels the billboard material discards, then writes the encoding of
// <flame_3d/depth_normal_fragment.glsl>.

in vec3 fragViewPos;
in vec2 fragUv;
in float fragAlpha;

out vec4 outColor;

uniform sampler2D albedoTexture;

uniform BillboardDepthLook {
  // x: alphaCutoff, y: albedo alpha, w: ditherFade
  vec4 params;
} look;

#include <flame_3d/dither.glsl>

void main() {
  float alpha = texture(albedoTexture, fragUv).a * look.params.y * fragAlpha;
  if (look.params.x > 0.0 && alpha < look.params.x) {
    discard;
  }
  if (look.params.w > 0.5 && alpha < bayerDither4x4(gl_FragCoord.xy)) {
    discard;
  }

  // The pixel's depth in 16 bits across RG, view-space normal XY in BA.
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
