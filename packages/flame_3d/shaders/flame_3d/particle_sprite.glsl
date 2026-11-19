#ifndef FLAME_PARTICLE_SPRITE_GLSL_
#define FLAME_PARTICLE_SPRITE_GLSL_

// What the quads of `ParticleMaterial` show, shared by the material and its
// depth-normal prepass variant: the texture (with its flipbook frames) and
// the sprite mask.

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
  // frames; z: softDepthFade clip-depth span (> 0 fades near scene geometry).
  vec4 options;
} look;

// The texel of the particle at [texCoord], blended towards [nextTexCoord]
// (the next flipbook frame) by [blend] when frames blend.
vec4 particleTexel(vec2 texCoord, vec2 nextTexCoord, float blend) {
  vec4 texel = texture(particleTexture, texCoord);
  if (look.options.y > 0.5) {
    texel = mix(texel, texture(particleTexture, nextTexCoord), blend);
  }
  return texel;
}

// The coverage of the sprite at [corner] (from -1 to 1 across the quad) of
// a particle of [seed].
float particleMask(vec2 corner, float seed) {
  float sprite = look.shape.x;
  float mask = 1.0;
  if (sprite > 0.5) {
    float radius = length(corner);
    float edge = 1.0;
    float billow = 1.0;
    if (sprite > 1.5) {
      // A puff whose outline and inside vary with the particle's seed.
      float amount = look.shape.z;
      float phase = seed * 6.2831853;
      float angle = atan(corner.y, corner.x + 1e-6);
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
  return mask;
}

#endif
