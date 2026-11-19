#version 460 core

// ShadowCatcherMaterial: where the surface is in shadow, it outputs the
// material's color (times the per-instance color) with an opacity of
// `color alpha * shadow strength * (1 - visibility)`, premultiplied (the
// largest of those of the lights that cast shadows, see shadowOcclusion); it
// is fully transparent where the surface is lit and when the pass has no
// shadows. Drawn blended over a transparent target, as a Scene3DComponent
// renders, it darkens the 2D art below the layer.

in vec3 fragPosition;
in vec3 fragNormal;
in vec4 fragInstanceColor;

out vec4 outColor;

uniform Material {
  vec4 color;
} material;

#include <flame_3d/shadows.glsl>

void main() {
  vec3 normal = normalize(fragNormal);
  float visibility = shadowVisibility(fragPosition, normal);
  vec4 color = material.color * fragInstanceColor;
  float alpha = color.a * shadows.color.a * (1.0 - visibility);
  if (shadowAtlasActive()) {
    // The shadows of the spot and point lights of the atlas too, see
    // shadowOcclusion.
    alpha = max(
      alpha,
      color.a * atlasSpotAndPointOcclusion(fragPosition, normal)
    );
  }
  outColor = vec4(color.rgb * alpha, alpha);
}
