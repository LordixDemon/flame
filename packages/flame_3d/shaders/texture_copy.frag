#version 460 core

// Copies a texture of the same size as the target, texel for texel.

in vec2 fragUv;

out vec4 outColor;

uniform sampler2D sourceTexture;

void main() {
  outColor = texture(sourceTexture, fragUv);
}
