#version 460 core

in vec2 fragTexCoord;
in vec2 fragNextTexCoord;
in vec2 fragCorner;
in vec4 fragColor;
in vec4 fragParams;

out vec4 outColor;

// Premultiplied alpha, as the images Flutter decodes.
uniform sampler2D particleTexture;

// Written by ParticleMaterial.
uniform ParticleLook {
  // The tint, straight alpha.
  vec4 color;
  // x: the sprite (0 texture only, 1 soft circle, 2 soft blob); y: softness;
  // z: how lumpy blobs are; w: 1 to output premultiplied alpha.
  vec4 shape;
  // x: fragments with a lower alpha are discarded; y: 1 to blend flipbook
  // frames.
  vec4 options;
} look;

void main() {
  vec4 texel = texture(particleTexture, fragTexCoord);
  if (look.options.y > 0.5) {
    texel = mix(texel, texture(particleTexture, fragNextTexCoord), fragParams.x);
  }

  float sprite = look.shape.x;
  float mask = 1.0;
  if (sprite > 0.5) {
    float radius = length(fragCorner);
    float edge = 1.0;
    float billow = 1.0;
    if (sprite > 1.5) {
      // A puff whose outline and inside vary with the particle's seed.
      float amount = look.shape.z;
      float phase = fragParams.y * 6.2831853;
      float angle = atan(fragCorner.y, fragCorner.x + 1e-6);
      float lobes = 0.5 * sin(3.0 * angle + phase) +
          0.3 * sin(5.0 * angle - 2.0 * phase + 1.3) +
          0.2 * sin(7.0 * angle + 3.0 * phase + 2.1);
      edge = 1.0 - amount * (0.18 + 0.12 * lobes);
      float wave = 0.5 + 0.5 * sin(radius * 7.0 + lobes * 2.5 + phase);
      billow = 1.0 - amount * 0.35 * wave * radius;
    }
    float softness = clamp(look.shape.y, 1e-3, 1.0);
    mask = (1.0 - smoothstep(edge * (1.0 - softness), edge, radius)) * billow;
  }

  float tint = fragColor.a * look.color.a * mask;
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
