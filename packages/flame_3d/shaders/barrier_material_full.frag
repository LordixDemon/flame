#version 460 core

// A translucent energy wall (`BarrierMaterial`), every option: a fade between
// two heights, a glowing top edge, a body fill that covers what is behind it,
// rows of motifs and the motifs that span cells, a pulse of the whole wall,
// value-noise breakup, a flicker, the thinning of the far side, up to eight
// impacts with up to four rings each and a reach, the wobble's shading,
// points that light the wall where they come close, and a hue-preserving
// output. `BarrierMaterial` draws with it while one of these is on (and with
// `barrier_material.frag`, the lean variant, otherwise).
//
// The output is premultiplied (`glint.z` > 0.5) or straight, with an alpha of
// the brightest channel (or of the fill's cover when larger): added as it is
// by additive blending, which keeps the target's alpha, or laid over the
// target by alpha blending.
//
// With `mode.w` > 0 the shader draws the reaction only (the impacts and the
// near points, scaled by `mode.w`): the second draw of
// `BarrierMaterial.reactionInFront`, which passes the depth test only where
// something stands in front of the wall.

#include "barrier_material_shared.glsl"

void main() {
  float v = clamp(fragWall.y, 0.0, 1.0);
  float appear = barrier.shape.x;
  float soft = max(barrier.glint.w, 1e-3);

  // The rising front: everything below it is shown.
  float front = appear * (1.0 + soft);
  float mask = 1.0 - smoothstep(front - soft, front, v);
  if (mask <= 0.0) {
    discard;
  }

  // Brightest at the foot, thinner above, over the fade between two heights.
  float u = v;
  if (barrier.profile.z > 0.5) {
    u = clamp((v - barrier.profile.x) * barrier.profile.y, 0.0, 1.0);
  }
  float profile = pow(1.0 - u, max(barrier.shape.y, 0.01));

  vec4 near = vec4(0.0);
  if (barrier.proximity.z > 0.5) {
    near = nearGlow();
  }
  vec3 hits = impacts();

  if (barrier.mode.w > 0.0) {
    // The reaction only, where something stands in front of the wall.
    vec3 reaction = hits * (0.35 + 0.65 * profile) + near.rgb;
    reaction *= barrier.mode.w * barrier.shape.z * mask *
        fragInstanceColor.rgb * fragInstanceColor.a;
    writeColor(reaction, 0.0);
    return;
  }

  float frontLine = (v - (front - soft * 0.5)) / (soft * 0.5);
  float frontGlow = exp(-frontLine * frontLine) *
      clamp(4.0 * appear * (1.0 - appear), 0.0, 1.0) * 0.8;

  vec3 tint = mix(barrier.footColor.rgb, barrier.topColor.rgb, v);
  float body = profile * mix(barrier.footColor.a, barrier.topColor.a, v) +
      barrier.shape.w * barrier.footColor.a * exp(-v * 24.0);

  // The pattern travelling along the wall, in a band above the foot.
  float motifValue = 0.0;
  float band = max(barrier.patternExtra.x, 1e-3);
  float y = v / band;
  if (barrier.pattern.x > 0.5 && y < 1.0) {
    float x = fragWall.x * barrier.pattern.y - barrier.pattern.z;
    float rows = y * barrier.patternStyle.x - barrier.patternStyle.w;
    float row = floor(rows);
    float cellY = fract(rows);
    // Every other row is shifted by half a motif.
    float shifted = x + 0.5 * mod(row, 2.0);
    float period = max(barrier.patternExtra.y, 1.0);
    float cell = mod(floor(shifted), period) + period * mod(row, 16.0);
    float f = fract(shifted);
    if (barrier.patternExtra.z < 0.0) {
      f = 1.0 - f;
    }
    float depth = barrier.patternStyle.z;
    float twinkle = (1.0 - depth) +
        depth * sin(barrier.patternExtra.w + hash(cell + 5.0) * 6.2831853);
    motifValue = motifAt(
          barrier.pattern.x,
          vec2(f, cellY),
          cell,
          vec2(x, rows),
          barrier.patternStyle.y
        ) *
        (1.0 - smoothstep(0.82, 1.0, y)) * twinkle;
    if (barrier.patternMore.x > 0.5) {
      motifValue *= smoothstep(0.0, 0.18, y);
    }
  }
  float motif = motifValue * barrier.pattern.w * (0.45 + 0.55 * profile);
  if (barrier.profile.z > 0.5) {
    // Past the end of the fade, the motifs are gone too.
    motif *= sqrt(1.0 - u);
  }
  if (barrier.proximity.z > 0.5) {
    motif *= 1.0 + barrier.patternMore.y * near.a;
  }
  vec3 motifColor = barrier.patternColor.a > 0.5
      ? barrier.patternColor.rgb
      : mix(barrier.footColor.rgb, vec3(1.0), 0.35);

  // The glint where the wall is seen edge-on.
  vec3 toViewer = barrier.viewer.w > 0.5
      ? barrier.viewer.xyz - fragWorldPosition
      : barrier.viewer.xyz;
  float viewLength = length(toViewer);
  toViewer = viewLength > 1e-6 ? toViewer / viewLength : vec3(0.0, 0.0, 1.0);
  float side = dot(normalize(fragNormal), toViewer);
  float glintValue = barrier.glint.x *
      pow(clamp(1.0 - abs(side), 0.0, 1.0), max(barrier.glint.y, 0.01)) *
      profile;
  // The near side of a closed wall (its outside faces the viewer) is thinned
  // so that it never veils what stands inside; the far side shows fully
  // unless thinned too.
  float softness = max(barrier.extra.z, 1e-3);
  float thin = 1.0 - clamp(barrier.extra.x, 0.0, 1.0) *
      smoothstep(0.0, softness, side);
  if (barrier.extra.y > 0.0) {
    thin *= 1.0 - clamp(barrier.extra.y, 0.0, 1.0) *
        smoothstep(0.0, softness, -side);
  }

  vec3 wall = tint * (body + glintValue + frontGlow) + motifColor * motif;
  float breakup = 1.0;
  if (barrier.noise.x > 0.0) {
    vec2 p = vec2(
      fragWall.x * barrier.noise.y,
      fragDetail.x * barrier.noise.z - barrier.noise.w
    );
    float period = barrier.noiseExtra.x;
    float n = 0.6 * valueNoise(p, period) +
        0.4 * valueNoise(p * 2.0 + vec2(0.0, 19.0), period * 2.0);
    breakup = max(1.0 + barrier.noise.x * (2.0 * n - 1.0), 0.0);
  }
  // The top edge, thinned half as much as the rest on the near side, so that
  // a closed wall keeps its outline.
  vec3 edge = vec3(0.0);
  if (barrier.mode.z > 0.5) {
    if (barrier.topEdge.a > 0.0) {
      float e = (1.0 - v) * barrier.topEdge.a;
      edge = barrier.topEdge.rgb * exp(-e * e) * breakup * barrier.profile.w *
          (0.5 + 0.5 * thin);
    }
    wall += barrier.pulse.rgb * (0.3 + 0.7 * profile);
    wall *= breakup * barrier.profile.w *
        max(1.0 + barrier.patternMore.z * fragDetail.y, 0.0);
  }

  vec3 scale = barrier.shape.z * mask * fragInstanceColor.rgb *
      fragInstanceColor.a;
  float cover = 0.0;
  vec3 color;
  if (barrier.mode.y > 0.5) {
    // The wall keeps its hue; the reaction is added after it, and may go
    // above white.
    color = (wall * thin + edge) * scale;
    if (barrier.fill.a > 0.0) {
      cover = fillCover(profile, thin, mask);
      color += barrier.fill.rgb * fragInstanceColor.rgb * cover;
    }
    color = keepHue(max(color, vec3(0.0))) +
        (hits * (0.35 + 0.65 * profile) + near.rgb) * scale;
  } else {
    color = wall * thin + hits * (0.35 + 0.65 * profile) + near.rgb;
    color *= barrier.shape.z * mask * fragInstanceColor.rgb *
        fragInstanceColor.a;
    if (barrier.topEdge.a > 0.0) {
      color += edge * scale;
    }
    if (barrier.fill.a > 0.0) {
      cover = fillCover(profile, thin, mask);
      color += barrier.fill.rgb * fragInstanceColor.rgb * cover;
    }
  }
  writeColor(color, cover);
}
