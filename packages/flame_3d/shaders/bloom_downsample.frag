#version 460 core

// Dual Kawase 5-tap half-texel downsample kernel for progressive bloom.

in vec2 fragUv;

out vec4 outColor;

uniform sampler2D sourceTexture;

uniform BloomBlur {
  // xy: halfpixel spread in UV units (`radius / dstResolution`).
  vec4 offset;
} blur;

void main() {
  vec2 hp = blur.offset.xy;
  vec3 sum = texture(sourceTexture, fragUv).rgb * 4.0;
  sum += texture(sourceTexture, fragUv - hp).rgb;
  sum += texture(sourceTexture, fragUv + hp).rgb;
  sum += texture(sourceTexture, fragUv + vec2(hp.x, -hp.y)).rgb;
  sum += texture(sourceTexture, fragUv - vec2(hp.x, -hp.y)).rgb;
  outColor = vec4(sum * 0.125, 1.0);
}
