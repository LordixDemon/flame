#version 460 core

in vec2 fragTexCoord;
in vec2 fragNextTexCoord;
in vec2 fragCorner;
in vec4 fragColor;
in vec4 fragParams;
in vec4 fragClipPos;

out vec4 outColor;

#include <flame_3d/particle_sprite.glsl>

uniform sampler2D depthNormalTexture;

uniform DepthNormal {
  // x: 1 when scene depth-normal prepass is active, yz: inv half-res size
  vec4 params;
} depthNormal;

void main() {
  vec4 texel = particleTexel(fragTexCoord, fragNextTexCoord, fragParams.x);
  float mask = particleMask(fragCorner, fragParams.y);

  float tint = fragColor.a * look.color.a * mask;
  if (look.options.z > 1e-5 && depthNormal.params.x > 0.5) {
    vec3 ndc = fragClipPos.xyz / max(fragClipPos.w, 1e-6);
    vec2 screenUv = clamp(
      vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y),
      vec2(0.001),
      vec2(0.999)
    );
    vec4 dn = texture(depthNormalTexture, screenUv);
    float sceneDepth = (dn.r * 255.0 * 256.0 + dn.g * 255.0) / 65535.0;
    float softFade = clamp((sceneDepth - ndc.z) / look.options.z, 0.0, 1.0);
    tint *= softFade;
  }
  vec3 rgb = fragColor.rgb * look.color.rgb;
  float alpha = texel.a * tint;
  if (alpha < look.options.x) {
    discard;
  }
  if (look.shape.w > 0.5) {
    outColor = vec4(texel.rgb * rgb * tint, alpha);
  } else {
    outColor = vec4(texel.rgb / max(texel.a, 1e-4) * rgb, alpha);
  }
}
