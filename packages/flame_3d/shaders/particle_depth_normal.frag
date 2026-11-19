#version 460 core

// The opaque particles of `ParticleMaterial` in the depth-normal prepass:
// discards the fragments the particle material discards, then writes the
// encoding of <flame_3d/depth_normal_encoding.glsl>. Soft particles
// (`softDepthFade`) are not drawn into the prepass, so the coverage has no
// fade.

in vec3 fragViewPos;
in vec2 fragTexCoord;
in vec2 fragNextTexCoord;
in vec2 fragCorner;
in vec4 fragColor;
in vec4 fragParams;

out vec4 outColor;

#include <flame_3d/depth_normal_encoding.glsl>
#include <flame_3d/particle_sprite.glsl>

void main() {
  vec4 texel = particleTexel(fragTexCoord, fragNextTexCoord, fragParams.x);
  float mask = particleMask(fragCorner, fragParams.y);
  float alpha = texel.a * fragColor.a * look.color.a * mask;
  if (alpha < look.options.x) {
    discard;
  }
  outColor = encodeDepthNormal(fragViewPos);
}
