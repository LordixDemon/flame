#version 460 core

// McGuire & Bavoil Weighted Blended OIT pass shader:
// - mode 0 (`wboitAccum`): outputs `vec4(rgb * alpha * w, alpha * w)`
// - mode 1 (`wboitReveal`): outputs `vec4(alpha)` blended with
//   `dst * (1 - src)` so target holds exact `prod(1 - alpha_i)`.

in vec2 fragUv;
in vec4 fragColor;
in vec4 fragInstanceColor;
in vec4 fragInstanceData;
in float fragClipDepth;

out vec4 outColor;

uniform sampler2D albedoTexture;

uniform WboitMaterial {
  vec4 baseColor;
  // x: passMode (0=accum, 1=reveal), y: uvScaleX, z: uvScaleY, w: unused
  vec4 params;
} wboitMat;

void main() {
  vec4 tex = texture(albedoTexture, fragUv * wboitMat.params.yz);
  float fade = clamp(fragInstanceData.w, 0.0, 1.0);
  vec3 rgb = wboitMat.baseColor.rgb * fragColor.rgb * fragInstanceColor.rgb *
    tex.rgb;
  float alpha = clamp(
    wboitMat.baseColor.a * fragColor.a * fragInstanceColor.a * tex.a *
      (1.0 - fade),
    0.0,
    1.0
  );
  if (alpha <= 1e-4) {
    discard;
  }

  if (wboitMat.params.x > 0.5) {
    outColor = vec4(alpha);
    return;
  }

  float z = clamp(fragClipDepth, 0.0, 1.0);
  float zTerm = 1.0 - 0.99 * z;
  float weight = alpha * clamp(10.0 * zTerm * zTerm * zTerm, 1e-2, 3e3);
  outColor = vec4(rgb * (alpha * weight), alpha * weight);
}
