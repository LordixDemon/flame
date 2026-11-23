#version 460 core

// Dual Kawase 8-tap tent upsample filter for progressive bloom.

in vec2 fragUv;

out vec4 outColor;

uniform sampler2D sourceTexture;

uniform BloomBlur {
  // xy: halfpixel spread in UV units (`radius / dstResolution`).
  vec4 offset;
} blur;

void main() {
  vec2 hp = blur.offset.xy;
  vec3 sum = texture(sourceTexture, fragUv + vec2(-hp.x * 2.0, 0.0)).rgb;
  sum += texture(sourceTexture, fragUv + vec2(-hp.x,  hp.y)).rgb * 2.0;
  sum += texture(sourceTexture, fragUv + vec2(0.0,    hp.y * 2.0)).rgb;
  sum += texture(sourceTexture, fragUv + vec2( hp.x,  hp.y)).rgb * 2.0;
  sum += texture(sourceTexture, fragUv + vec2( hp.x * 2.0, 0.0)).rgb;
  sum += texture(sourceTexture, fragUv + vec2( hp.x, -hp.y)).rgb * 2.0;
  sum += texture(sourceTexture, fragUv + vec2(0.0,   -hp.y * 2.0)).rgb;
  sum += texture(sourceTexture, fragUv + vec2(-hp.x, -hp.y)).rgb * 2.0;
  outColor = vec4(sum / 12.0, 1.0);
}
