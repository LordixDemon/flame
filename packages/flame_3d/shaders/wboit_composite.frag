#version 460 core

in vec2 fragUv;

out vec4 outColor;

uniform sampler2D opaqueTexture;
uniform sampler2D accumTexture;
uniform sampler2D revealTexture;

void main() {
  vec4 opaque = texture(opaqueTexture, fragUv);
  float reveal = clamp(texture(revealTexture, fragUv).r, 0.0, 1.0);
  if (reveal >= 0.9995) {
    outColor = opaque;
    return;
  }
  vec4 accum = texture(accumTexture, fragUv);
  vec3 avgColor = accum.rgb / max(accum.a, 1e-4);
  float transCoverage = 1.0 - reveal;
  float outAlpha = 1.0 - (1.0 - opaque.a) * reveal;
  vec3 outRgb = mix(opaque.rgb, avgColor, transCoverage);
  outColor = vec4(outRgb, outAlpha);
}
