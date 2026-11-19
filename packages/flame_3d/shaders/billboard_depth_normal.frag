#version 460 core

// The billboards of `BillboardBatch3D` in the depth-normal prepass: discards
// the texels the billboard material discards, then writes the encoding of
// <flame_3d/depth_normal_encoding.glsl>.

in vec3 fragViewPos;
in vec2 fragUv;
in float fragAlpha;

out vec4 outColor;

uniform sampler2D albedoTexture;

uniform BillboardDepthLook {
  // x: alphaCutoff, y: albedo alpha, w: ditherFade
  vec4 params;
} look;

#include <flame_3d/depth_normal_encoding.glsl>
#include <flame_3d/dither.glsl>

void main() {
  float alpha = texture(albedoTexture, fragUv).a * look.params.y * fragAlpha;
  if (look.params.x > 0.0 && alpha < look.params.x) {
    discard;
  }
  if (look.params.w > 0.5 && alpha < bayerDither4x4(gl_FragCoord.xy)) {
    discard;
  }

  outColor = encodeDepthNormal(fragViewPos);
}
