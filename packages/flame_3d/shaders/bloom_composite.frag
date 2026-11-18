#version 460 core

// Composites blurred bloom onto the scene texture while preserving the scene's
// alpha (`base.a`), so bloom halos outside 3D silhouettes add pure light onto
// 2D layers below a `Scene3DComponent` under premultiplied Porter-Duff srcOver.

in vec2 fragUv;

out vec4 outColor;

uniform sampler2D sceneTexture;
uniform sampler2D bloomTexture;

uniform BloomComposite {
  // x: intensity.
  vec4 params;
} composite;

void main() {
  vec4 base = texture(sceneTexture, fragUv);
  vec3 glow = texture(bloomTexture, fragUv).rgb * composite.params.x;
  outColor = vec4(clamp(base.rgb + glow, 0.0, 1.0), base.a);
}
